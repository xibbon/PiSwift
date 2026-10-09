#if os(macOS)
import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private final class ShellResumeLog: Sendable {
    private struct State: Sendable {
        var text = ""
        var returned = false
        var callsAfterReturn = 0
    }
    private let state = Mutex(State())
    var text: String { state.withLock { $0.text } }
    var callsAfterReturn: Int { state.withLock { $0.callsAfterReturn } }
    func didReturn() { state.withLock { $0.returned = true } }
    func append(_ text: String) {
        state.withLock {
            $0.text += text
            if $0.returned { $0.callsAfterReturn += 1 }
        }
    }
}

private struct ShellResumeError: Error {
    let message: String
}

private final class ShellResumeWakeCount: Sendable {
    private let state = Mutex(0)
    var value: Int { state.withLock { $0 } }
    func increment() { state.withLock { $0 += 1 } }
}

private func withShellResumeEnv(
    shellIO: LocalShellIO = .init(), hooks: LocalShellHooks = .init(),
    _ use: (LocalExecutionEnv, URL) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-shell-resume-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let env = LocalExecutionEnv(cwd: directory.path, shellPath: "/bin/bash", shellIO: shellIO, shellHooks: hooks)
    do {
        try await use(env, directory)
        await env.cleanup(context: .background)
    } catch {
        await env.cleanup(context: .background)
        throw error
    }
}

private func waitForShellResumeFile(_ file: URL) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while !FileManager.default.fileExists(atPath: file.path) {
        if clock.now >= deadline { throw ShellResumeError(message: "Shell did not create \(file.lastPathComponent) within 10 seconds") }
        try await clock.sleep(for: .milliseconds(20))
    }
}

private func waitForShellResumeCondition(_ description: String, _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while !condition() {
        if clock.now >= deadline { throw ShellResumeError(message: "\(description) did not occur within 10 seconds") }
        try await clock.sleep(for: .milliseconds(20))
    }
}

struct LocalExecutionShellResumeTests {
    @Test("a quiet command without a timeout wakes the loop at most ten times")
    func quietCommandDoesNotPoll() async throws {
        let wakes = ShellResumeWakeCount()
        try await withShellResumeEnv(hooks: .init(loopWoke: { wakes.increment() })) { (env: LocalExecutionEnv, _: URL) async throws in
            let result = await env.exec(.shell("sleep 1"), options: nil, context: .background)
            #expect(try result.get().exitCode == 0)
            #expect(wakes.value <= 10)
        }
    }

    @Test("timeout numbers omit the decimal point for whole seconds")
    func timeoutNumberFormat() {
        #expect(shellTimeoutNumber(.seconds(1)) == "1")
        #expect(shellTimeoutNumber(.milliseconds(100)) == "0.1")
        #expect(shellTimeoutNumber(.milliseconds(1500)) == "1.5")
    }

    @Test("a whole second timeout has the complete upstream error text")
    func wholeSecondTimeoutError() async throws {
        try await withShellResumeEnv { (env: LocalExecutionEnv, _: URL) async throws in
            let result = await env.exec(.shell("sleep 60"), options: .init(timeout: .seconds(1)), context: .background)
            switch result {
            case .failure(let error):
                #expect(error.code == .timeout)
                #expect(error.message == "timeout:1")
            case .success(let value):
                Issue.record("Expected timeout:1, got \(value)")
            }
        }
    }

    @Test("a spill write failure wakes the loop after the parent exits with stdout still open")
    func spillFailureWakesAfterParentExit() async throws {
        let releaseWriter = DispatchSemaphore(value: 0)
        defer { releaseWriter.signal() }
        var io = LocalShellIO()
        io.spillHighWaterMark = 1
        io.writeSpill = { _, _ in
            guard releaseWriter.wait(timeout: .now() + 15) == .success else {
                throw ShellResumeError(message: "Writer gate did not open within 15 seconds")
            }
            throw ShellResumeError(message: "Gated spill write failure")
        }
        // Use a known path so the test also removes spill files on assertion failures.
        let spill = FileManager.default.temporaryDirectory.appendingPathComponent("pi-shell-resume-spill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: spill) }
        io.createSpill = {
            let fd = Darwin.open(spill.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ShellResumeError(message: "Cannot create the test spill file") }
            return (fd, spill.path)
        }
        try await withShellResumeEnv(shellIO: io) { (env: LocalExecutionEnv, directory: URL) async throws in
            let log = ShellResumeLog()
            let childFile = directory.appendingPathComponent("child.pid")
            let parentFile = directory.appendingPathComponent("parent.pid")
            // Job control puts the child in a separate group. A kill of the parent group
            // must not close the child's stdout and hide a missing spill failure wake.
            let command = """
                set -m
                printf '%s' "$$" > parent.pid
                (touch child-ready; while [ ! -f release-child ]; do sleep 0.02; done) &
                printf '%s' "$!" > child.pid
                while [ ! -f child-ready ]; do sleep 0.02; done
                printf output
                """
            var childPID: Int32?
            defer {
                let savedPID = (try? String(contentsOf: childFile, encoding: .utf8)).flatMap(Int32.init)
                if let pid = childPID ?? savedPID, pid > 0 {
                    _ = Darwin.kill(-pid, SIGKILL)
                    _ = Darwin.kill(pid, SIGKILL)
                }
            }
            let execution = Task {
                await env.exec(.shell(command), options: .init(timeout: .seconds(10),
                    onOutput: { text, _, _ in log.append(text) }, spill: .init(afterBytes: 0, afterLines: 0)),
                    context: .background)
            }
            do {
                try await waitForShellResumeCondition("Child PID") {
                    guard let text = try? String(contentsOf: childFile, encoding: .utf8), let pid = Int32(text), pid > 0 else { return false }
                    childPID = pid
                    return true
                }
                let child = try #require(childPID)
                #expect(Darwin.getpgid(child) == child)
                try await waitForShellResumeCondition("Parent exit") {
                    guard let text = try? String(contentsOf: parentFile, encoding: .utf8), let pid = Int32(text), pid > 0 else { return false }
                    return Darwin.kill(pid, 0) == -1 && errno == ESRCH
                }
                try await waitForShellResumeCondition("Output callback") { log.text == "output" }
                #expect(Darwin.kill(child, 0) == 0)
                let start = ContinuousClock.now
                releaseWriter.signal()
                let result = await execution.value
                #expect(ContinuousClock.now - start < .seconds(10))
                switch result {
                case .failure(let error):
                    #expect(error.code == .unknown)
                    #expect(error.message.contains("Gated spill write failure"))
                case .success(let value):
                    Issue.record("Expected a spill write failure, got \(value)")
                }
                #expect(Darwin.kill(child, 0) == 0)
            } catch {
                releaseWriter.signal()
                if let childPID { _ = Darwin.kill(-childPID, SIGKILL); _ = Darwin.kill(childPID, SIGKILL) }
                await env.cleanup(context: .background)
                _ = await execution.value
                throw error
            }
        }
    }

    @Test("idle grace returns while a descendant holds stdout and prevents later callbacks")
    func gatedDescendantStopsCallbacksAfterReturn() async throws {
        try await withShellResumeEnv { (env: LocalExecutionEnv, directory: URL) async throws in
            let log = ShellResumeLog()
            let pidFile = directory.appendingPathComponent("child.pid")
            // The gate stays closed until exec returns. The child must keep stdout open.
            let command = """
                printf initial
                (trap '' PIPE; touch child-ready; while [ ! -f release ]; do sleep 0.02; done; printf late 2>/dev/null; touch child-done) &
                child=$!
                printf '%s' "$child" > child.pid
                while [ ! -f child-ready ]; do sleep 0.02; done
                """
            defer {
                if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text), pid > 0 {
                    _ = Darwin.kill(pid, SIGKILL)
                }
            }
            let start = ContinuousClock.now
            let result = await env.exec(.shell(command), options: .init(timeout: .seconds(10),
                onOutput: { text, _, _ in log.append(text) }), context: .background)
            log.didReturn()
            #expect(ContinuousClock.now - start < .seconds(10))
            #expect(try result.get().exitCode == 0)
            #expect(log.text == "initial")
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("child-ready").path))
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("child-done").path))

            try Data().write(to: directory.appendingPathComponent("release"))
            try await waitForShellResumeFile(directory.appendingPathComponent("child-done"))
            await env.cleanup(context: .background)
            #expect(log.text == "initial")
            #expect(log.callsAfterReturn == 0)
        }
    }
}
#endif
