#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

struct LocalExecutionShellBoundaryTests {
    @Test("aborting one command leaves another command in the same environment active")
    func abortIsScopedToCommand() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-shell-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = LocalExecutionEnv(cwd: directory.path), controller = AbortController()
        let ready = Mutex(Set<String>()), output = Mutex("")
        let first = Task {
            await env.exec(.shell("printf ready; sleep 60"), options: .init(timeout: .seconds(20),
                onOutput: { _, _, _ in ready.withLock { _ = $0.insert("first") } }),
                context: ChordContext.background.withAbortSignal(controller.signal))
        }
        let second = Task {
            await env.exec(.shell("printf ready; while [ ! -e release ]; do sleep 0.05; done; printf survived"),
                options: .init(timeout: .seconds(20), onOutput: { text, _, _ in
                    ready.withLock { _ = $0.insert("second") }; output.withLock { $0 += text }
                }), context: .background)
        }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ready.withLock({ $0.count }) < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(ready.withLock { $0.count } == 2)
            controller.abort()
            switch await first.value {
            case .failure(let error): #expect(error.code == .aborted)
            case .success: Issue.record("Aborted command succeeded")
            }
            try Data().write(to: directory.appendingPathComponent("release"))
            #expect(try await second.value.get().exitCode == 0)
            #expect(output.withLock { $0 } == "readysurvived")
        } catch {
            controller.abort(); await env.cleanup(context: .background)
            _ = await first.value; _ = await second.value
            throw error
        }
        await env.cleanup(context: .background)
    }

    @Test("argv program paths keep a literal tilde")
    func literalProgramPath() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-shell-literal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("~"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("~/literal-program")
        try Data("#!/bin/sh\nexit 17\n".utf8).write(to: script)
        #expect(chmod(script.path, 0o700) == 0)
        let env = LocalExecutionEnv(cwd: directory.path)
        #expect(try await env.exec(.argv(["~/literal-program"]), options: .init(timeout: .seconds(15)), context: .background).get().exitCode == 17)
    }

    @Test("selects custom shell, system bash, PATH bash, then sh")
    func shellSelection() throws {
        #expect(try LocalShell.selectShell(customShellPath: "/custom", pathExists: { $0 == "/custom" }, bashOnPath: { "/path/bash" }) == "/custom")
        #expect(try LocalShell.selectShell(customShellPath: nil, pathExists: { $0 == "/bin/bash" }, bashOnPath: { "/path/bash" }) == "/bin/bash")
        #expect(try LocalShell.selectShell(customShellPath: nil, pathExists: { _ in false }, bashOnPath: { "/path/bash" }) == "/path/bash")
        #expect(try LocalShell.selectShell(customShellPath: "", pathExists: { _ in false }, bashOnPath: { nil }) == "sh")
        do {
            _ = try LocalShell.selectShell(customShellPath: "/missing", pathExists: { _ in false }, bashOnPath: { "/path/bash" })
            Issue.record("A missing custom shell must fail")
        } catch let error as ExecutionError {
            #expect(error.code == .shellUnavailable)
            #expect(error.message == "Custom shell path not found: /missing")
        }
    }

    @Test("a default one MiB spill queue pauses both streams until writes drain")
    func highWaterMark() async throws {
        let firstWrite = DispatchSemaphore(value: 0), releaseWrite = DispatchSemaphore(value: 0)
        defer { releaseWrite.signal() }
        let writes = Mutex(0), delivered = Mutex(0)
        var io = LocalShellIO()
        #expect(io.spillHighWaterMark == 1024 * 1024)
        let write = io.writeSpill
        io.writeSpill = { fd, bytes in
            let index = writes.withLock { value in value += 1; return value }
            if index == 1 {
                firstWrite.signal()
                guard releaseWrite.wait(timeout: .now() + 15) == .success else { throw BoundaryError.writerDeadline }
            }
            try write(fd, bytes)
        }
        let env = LocalExecutionEnv(cwd: FileManager.default.temporaryDirectory.path, shellIO: io)
        let task = Task {
            await env.exec(.shell("head -c 4194304 /dev/zero"), options: .init(timeout: .seconds(30),
                onOutput: { text, _, _ in delivered.withLock { $0 += text.utf8.count } },
                spill: .init(afterBytes: 0, afterLines: 0)), context: .background)
        }
        // The semaphore wait runs outside the cooperative executor.
        let started = await blockingWait(firstWrite)
        if !started { releaseWrite.signal(); await env.cleanup(context: .background) }
        #expect(started)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while delivered.withLock({ $0 }) < io.spillHighWaterMark, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pausedAt = delivered.withLock { $0 }
        #expect(pausedAt >= io.spillHighWaterMark)
        #expect(pausedAt < 4 * 1024 * 1024)
        // Every read is at most 64 KiB, so the queue can cross the mark by at most one chunk.
        #expect(pausedAt <= io.spillHighWaterMark + 64 * 1024)
        releaseWrite.signal()
        let result = try await task.value.get()
        defer { if let path = result.spillPath { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) } }
        #expect(result.exitCode == 0)
        #expect(delivered.withLock { $0 } == 4 * 1024 * 1024)
        let path = try #require(result.spillPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).count == 4 * 1024 * 1024)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        await env.cleanup(context: .background)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("a spill writer error kills the command and returns unknown")
    func writeFailure() async throws {
        var io = LocalShellIO()
        io.writeSpill = { _, _ in throw BoundaryError.writeFailed }
        let filePath = Mutex<String?>(nil)
        let create = io.createSpill
        io.createSpill = { let file = try create(); filePath.withLock { $0 = file.path }; return file }
        let env = LocalExecutionEnv(cwd: FileManager.default.temporaryDirectory.path, shellIO: io)
        let result = await env.exec(.shell("printf output; sleep 60"), options: .init(timeout: .seconds(15),
            spill: .init(afterBytes: 0, afterLines: 0)), context: .background)
        defer { if let path = filePath.withLock({ $0 }) { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) } }
        switch result {
        case .failure(let error):
            #expect(error.code == .unknown)
            #expect(error.message.contains("Failed to preserve complete shell output"))
        case .success: Issue.record("A spill write failure must fail exec")
        }
    }

    @Test("the maximum timeout is accepted and values above it fail before spawn")
    func timeoutBoundary() async throws {
        let env = LocalExecutionEnv()
        #expect(try await env.exec(.argv(["/usr/bin/true"]), options: .init(timeout: .milliseconds(2_147_483_647)), context: .background).get().exitCode == 0)
        let result = await env.exec(.argv([]), options: .init(timeout: .milliseconds(2_147_483_647) + .nanoseconds(1)), context: .background)
        switch result {
        case .failure(let error):
            #expect(error.code == .timeout)
            #expect(error.message == "Invalid timeout: maximum is 2147483.647 seconds")
        case .success: Issue.record("A timeout above the maximum must fail")
        }
    }
}

private enum BoundaryError: Error { case writerDeadline, writeFailed }
private func blockingWait(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: semaphore.wait(timeout: .now() + 10) == .success) }
    }
}
#endif
