#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private final class ShellTextLog: Sendable {
    private let state = Mutex("")
    var text: String { state.withLock { $0 } }
    func append(_ text: String) { state.withLock { $0 += text } }
}

private struct ShellTestError: Error, Sendable {
    let message: String
}

private func withShellTestEnv(
    shellPath: String? = nil, shellEnv: [String: String]? = nil,
    _ use: (LocalExecutionEnv, URL) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-shell-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let env = LocalExecutionEnv(cwd: directory.path, shellPath: shellPath, shellEnv: shellEnv)
    do {
        try await use(env, directory)
        await env.cleanup(context: .background)
    } catch {
        await env.cleanup(context: .background)
        throw error
    }
}

private func collectShellText(
    _ env: LocalExecutionEnv, _ command: String, options: ShellExecOptions = .init(timeout: .seconds(15)),
    context: ChordContext = .background
) async -> (Result<ShellExecResult, ExecutionError>, String) {
    let log = ShellTextLog()
    var options = options
    options.onOutput = { text, _, _ in log.append(text) }
    let result = await env.exec(.shell(command), options: options, context: context)
    return (result, log.text)
}

private func expectShellError(
    _ result: Result<ShellExecResult, ExecutionError>, _ code: ExecutionErrorCode,
    contains message: String? = nil, sourceLocation: SourceLocation = #_sourceLocation
) {
    switch result {
    case .failure(let error):
        #expect(error.code == code, sourceLocation: sourceLocation)
        if let message { #expect(error.message.contains(message), sourceLocation: sourceLocation) }
    case .success(let value): Issue.record("Expected \(code), got \(value)", sourceLocation: sourceLocation)
    }
}

private func waitForShellFile(_ path: URL) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while !FileManager.default.fileExists(atPath: path.path) {
        if clock.now >= deadline { throw ShellTestError(message: "Shell did not create its marker within 10 seconds") }
        try await clock.sleep(for: .milliseconds(20))
    }
}


private func shellChildPID(_ path: URL) async throws -> Int32 {
    let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while true {
        if let text = try? String(contentsOf: path, encoding: .utf8), let pid = Int32(text), pid > 0 { return pid }
        if clock.now >= deadline { throw ShellTestError(message: "Shell did not report its child pid within 10 seconds") }
        try await clock.sleep(for: .milliseconds(20))
    }
}

private func waitForShellChildExit(_ pid: Int32) async throws {
    let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while Darwin.kill(pid, 0) == 0 || errno != ESRCH {
        if clock.now >= deadline { throw ShellTestError(message: "Shell child \(pid) did not exit within 10 seconds") }
        try await clock.sleep(for: .milliseconds(20))
    }
}

struct LocalExecutionShellTests {
    // env-node.test.ts:587.
    @Test("executes in cwd with environment overrides")
    func cwdAndEnvironment() async throws {
        try await withShellTestEnv { (env: LocalExecutionEnv, directory: URL) async throws in
            let (result, output) = await collectShellText(env,
                "printf '%s' \"$NODE_ENV_TEST\" > cwd-marker.txt; printf '%s:%s' \"$PWD\" \"$NODE_ENV_TEST\"",
                options: .init(env: ["NODE_ENV_TEST": "ok"], timeout: .seconds(15)))
            #expect(try result.get().exitCode == 0)
            #expect(try String(contentsOf: directory.appendingPathComponent("cwd-marker.txt"), encoding: .utf8) == "ok")
            let canonical = try await env.canonicalPath(".", context: .background).get()
            #expect(output == "\(canonical):ok")
        }
    }

    // env-node.test.ts:603, three parameter cases.
    @Test("applies string environment overrides", arguments: [0, 1, 2])
    func stringEnvironmentOverrides(_ index: Int) async throws {
        try await withShellTestEnv(shellEnv: ["PI_SESSION_FILE": "/stale/parent.jsonl", "PI_CODING_AGENT": "true",
                                            "PI_NODE_ENV_PRESERVED_TEST": "preserved"]) { (env: LocalExecutionEnv, _: URL) async throws in
            let overrides: [[String: String]?] = [nil, ["PI_SESSION_FILE": ""], ["PI_SESSION_FILE": "/sessions/current.jsonl"]]
            let expected = ["x:/stale/parent.jsonl", "x:", "x:/sessions/current.jsonl"]
            let (result, output) = await collectShellText(env,
                "printf '%s:%s|%s|%s' \"${PI_SESSION_FILE+x}\" \"${PI_SESSION_FILE-}\" \"$PI_CODING_AGENT\" \"$PI_NODE_ENV_PRESERVED_TEST\"",
                options: .init(env: overrides[index], timeout: .seconds(15)))
            #expect(try result.get().exitCode == 0)
            #expect(output == "\(expected[index])|true|preserved")
        }
    }

    // env-node.test.ts:634. Use HOME so parallel tests do not change the host environment.
    @Test("can replace the inherited and configured environment")
    func replaceEnvironment() async throws {
        #expect(ProcessInfo.processInfo.environment["HOME"] != nil)
        try await withShellTestEnv(shellEnv: ["PI_NODE_ENV_CONFIGURED_TEST": "configured"]) { (env: LocalExecutionEnv, _: URL) async throws in
            let (result, output) = await collectShellText(env,
                "printf '%s:%s:%s' \"${HOME-}\" \"${PI_NODE_ENV_CONFIGURED_TEST-}\" \"${PI_NODE_ENV_EXPLICIT_TEST-}\"",
                options: .init(env: ["PI_NODE_ENV_EXPLICIT_TEST": "explicit"], inheritEnv: false, timeout: .seconds(15)))
            #expect(try result.get().exitCode == 0)
            #expect(output == "::explicit")
        }
    }

    // env-node.test.ts:730.
    @Test("cleanup terminates active shell processes")
    func cleanupActiveProcesses() async throws {
        try await withShellTestEnv { (env: LocalExecutionEnv, directory: URL) async throws in
            let execution = Task { await env.exec(.shell("touch started; sleep 60"), options: .init(timeout: .seconds(15)), context: .background) }
            do { try await waitForShellFile(directory.appendingPathComponent("started")) }
            catch { await env.cleanup(context: .background); _ = await execution.value; throw error }
            let start = ContinuousClock.now
            await env.cleanup(context: .background)
            let result = await execution.value
            #expect(ContinuousClock.now - start < .seconds(10))
            _ = try result.get()
        }
    }

    // env-node.test.ts:742.
    @Test("streams stdout and stderr")
    func combinedStreams() async throws {
        try await withShellTestEnv { (env: LocalExecutionEnv, _: URL) async throws in
            let (result, output) = await collectShellText(env, "printf out; printf err >&2")
            #expect(try result.get() == ShellExecResult(exitCode: 0))
            #expect(output.contains("out"))
            #expect(output.contains("err"))
        }
    }

    // env-node.test.ts:751. Shell octal output replaces Node Buffer writes.
    @Test("decodes UTF-8 split across process chunks")
    func splitUTF8() async throws {
        try await withShellTestEnv { (env: LocalExecutionEnv, _: URL) async throws in
            let (result, output) = await collectShellText(env, "printf '\\360\\237'; sleep 0.1; printf '\\230\\200'")
            #expect(try result.get().exitCode == 0)
            #expect(output == "😀")
        }
    }

    // env-node.test.ts:765.
    @Test("reports a missing cwd before spawn")
    func missingCwd() async throws {
        try await withShellTestEnv { (_: LocalExecutionEnv, directory: URL) async throws in
            let env = LocalExecutionEnv(cwd: directory.appendingPathComponent("missing").path)
            expectShellError(await env.exec(.shell("printf ok"), options: nil, context: .background), .spawnError,
                             contains: "Working directory does not exist")
        }
    }

    // env-node.test.ts:776.
    @Test("returns nonzero command exit codes as successful results")
    func nonzeroExit() async throws {
        try await withShellTestEnv { (env: LocalExecutionEnv, _: URL) async throws in
            #expect(try await env.exec(.shell("exit 7"), options: .init(timeout: .seconds(15)), context: .background).get() == ShellExecResult(exitCode: 7))
        }
    }

    // env-node.test.ts:784.
    @Test("maps a signal exit to 128 plus the signal number")
    func signalExit() async throws {
        try await withShellTestEnv { (env: LocalExecutionEnv, _: URL) async throws in
            #expect(try await env.exec(.shell("kill -9 $$"), options: .init(timeout: .seconds(15)), context: .background).get().exitCode == 137)
        }
    }

    // env-node.test.ts:791.
    @Test("returns a timeout error when the command exceeds its deadline")
    func commandTimeout() async throws {
        try await withShellTestEnv { (env: LocalExecutionEnv, _: URL) async throws in
            expectShellError(await env.exec(.shell("sleep 60"), options: .init(timeout: .milliseconds(100)), context: .background), .timeout)
        }
    }

    // env-node.test.ts:799. NaN and infinity are not values of the Duration timeout API.
    @Test("rejects invalid timeouts before spawn", arguments: [Duration.zero, .milliseconds(-1), .milliseconds(2_147_484_000)])
    func invalidTimeout(_ timeout: Duration) async throws {
        try await withShellTestEnv { (env: LocalExecutionEnv, directory: URL) async throws in
            expectShellError(await env.exec(.shell("touch spawned"), options: .init(timeout: timeout), context: .background),
                             .timeout, contains: "Invalid timeout")
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("spawned").path))
        }
    }

    // env-node.test.ts:811.
    @Test("returns output callback errors")
    func callbackError() async throws {
        try await withShellTestEnv { (env: LocalExecutionEnv, _: URL) async throws in
            let options = ShellExecOptions(timeout: .seconds(15), onOutput: { _, _, _ in throw ShellTestError(message: "callback failed") })
            expectShellError(await env.exec(.shell("printf out"), options: options, context: .background), .callbackError,
                             contains: "callback failed")
        }
    }

    // env-node.test.ts:827.
    @Test("returns shell unavailable and spawn errors")
    func shellErrors() async throws {
        try await withShellTestEnv { (_: LocalExecutionEnv, directory: URL) async throws in
            let missing = LocalExecutionEnv(cwd: directory.path, shellPath: directory.appendingPathComponent("missing-shell").path)
            expectShellError(await missing.exec(.shell("printf ok"), options: nil, context: .background), .shellUnavailable)
            let file = directory.appendingPathComponent("not-executable-shell")
            try Data("not executable".utf8).write(to: file)
            let invalid = LocalExecutionEnv(cwd: directory.path, shellPath: file.path)
            expectShellError(await invalid.exec(.shell("printf ok"), options: nil, context: .background), .spawnError)
        }
    }

    // env-node.test.ts:843.
    @Test("returns an aborted result before and during execution")
    func abortedCommands() async throws {
        try await withShellTestEnv { (env: LocalExecutionEnv, directory: URL) async throws in
            let before = AbortController(); before.abort()
            expectShellError(await env.exec(.shell("touch spawned"), options: nil,
                context: ChordContext.background.withAbortSignal(before.signal)), .aborted)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("spawned").path))
            let active = AbortController()
            let execution = Task { await env.exec(.shell("touch started; sleep 60"), options: .init(timeout: .seconds(15)),
                context: ChordContext.background.withAbortSignal(active.signal)) }
            do { try await waitForShellFile(directory.appendingPathComponent("started")) }
            catch { active.abort(); _ = await execution.value; throw error }
            active.abort()
            expectShellError(await execution.value, .aborted)
        }
    }


    @Test("abort, timeout, and cleanup stop descendants", arguments: ["abort", "timeout", "cleanup"])
    func descendantsStop(_ action: String) async throws {
        try await withShellTestEnv { (env: LocalExecutionEnv, directory: URL) async throws in
            let controller = AbortController()
            let execution = Task {
                await env.exec(.shell("(exec sleep 60) & child=$!; printf '%s' \"$child\" > child.pid; wait"),
                    options: .init(timeout: action == "timeout" ? .seconds(5) : .seconds(15)),
                    context: ChordContext.background.withAbortSignal(controller.signal))
            }
            let pid: Int32
            do { pid = try await shellChildPID(directory.appendingPathComponent("child.pid")) }
            catch { controller.abort(); _ = await execution.value; throw error }
            defer { _ = Darwin.kill(pid, SIGKILL) }
            switch action {
            case "abort": controller.abort()
            case "cleanup": await env.cleanup(context: .background)
            default: break
            }
            let result = await execution.value
            if action == "timeout" { expectShellError(result, .timeout) }
            else if action == "abort" { expectShellError(result, .aborted) }
            else { _ = try result.get() }
            try await waitForShellChildExit(pid)
        }
    }

    @Test("an output callback receives the command context")
    func callbackContext() async throws {
        try await withShellTestEnv { (env: LocalExecutionEnv, _: URL) async throws in
            let controller = AbortController()
            let context = ChordContext.background.withAbortSignal(controller.signal)
            let calls = Mutex(0)
            let result = await env.exec(.shell("printf output"), options: .init(timeout: .seconds(15),
                onOutput: { _, actual, _ in
                    #expect(actual.abortSignal === controller.signal)
                    calls.withLock { $0 += 1 }
                }), context: context)
            #expect(try result.get().exitCode == 0)
            #expect(calls.withLock { $0 } > 0)
        }
    }

    @Test("cleanup leaves other environments active")
    func cleanupIsScoped() async throws {
        try await withShellTestEnv { (first: LocalExecutionEnv, firstDirectory: URL) async throws in
            try await withShellTestEnv { (second: LocalExecutionEnv, secondDirectory: URL) async throws in
                let controller = AbortController()
                let command = "(exec sleep 60) & child=$!; printf '%s' \"$child\" > child.pid; wait"
                let execution = Task { await first.exec(.shell(command), options: .init(timeout: .seconds(15)), context: .background) }
                let otherExecution = Task { await second.exec(.shell(command), options: .init(timeout: .seconds(15)),
                    context: ChordContext.background.withAbortSignal(controller.signal)) }
                let firstPID: Int32, secondPID: Int32
                do {
                    firstPID = try await shellChildPID(firstDirectory.appendingPathComponent("child.pid"))
                    secondPID = try await shellChildPID(secondDirectory.appendingPathComponent("child.pid"))
                } catch {
                    await first.cleanup(context: .background); controller.abort()
                    _ = await execution.value; _ = await otherExecution.value
                    throw error
                }
                defer { _ = Darwin.kill(firstPID, SIGKILL); _ = Darwin.kill(secondPID, SIGKILL) }
                await first.cleanup(context: .background)
                _ = try await execution.value.get()
                try await waitForShellChildExit(firstPID)
                #expect(Darwin.kill(secondPID, 0) == 0)
                controller.abort()
                expectShellError(await otherExecution.value, .aborted)
                try await waitForShellChildExit(secondPID)
            }
        }
    }

    @Test("concurrent commands keep their environment and callback context separate")
    func concurrentCommandContext() async throws {
        try await withShellTestEnv { (env: LocalExecutionEnv, _: URL) async throws in
            let key = ChordContextKey<String>("shell-test-command")
            let firstLog = ShellTextLog(), secondLog = ShellTextLog()
            let firstOptions = ShellExecOptions(env: ["COMMAND_VALUE": "first"], timeout: .seconds(15),
                onOutput: { text, context, _ in
                    #expect(context.value(key) == "first")
                    firstLog.append(text)
                })
            let secondOptions = ShellExecOptions(env: ["COMMAND_VALUE": "second"], timeout: .seconds(15),
                onOutput: { text, context, _ in
                    #expect(context.value(key) == "second")
                    secondLog.append(text)
                })
            async let first = env.exec(.shell("sleep 0.1; printf '%s' \"$COMMAND_VALUE\""), options: firstOptions,
                context: ChordContext.background.withValue("first", for: key))
            async let second = env.exec(.shell("printf '%s' \"$COMMAND_VALUE\"; sleep 0.1"), options: secondOptions,
                context: ChordContext.background.withValue("second", for: key))
            let results = await (first, second)
            #expect(try results.0.get().exitCode == 0)
            #expect(try results.1.get().exitCode == 0)
            #expect(firstLog.text == "first")
            #expect(secondLog.text == "second")
        }
    }


    @Test("decodes stdout and stderr separately and flushes incomplete UTF-8 at EOF")
    func separateDecodersAndEOF() async throws {
        try await withShellTestEnv { (env: LocalExecutionEnv, _: URL) async throws in
            let stdout = ShellTextLog(), stderr = ShellTextLog()
            let command = "printf '\\357\\273\\277\\360\\237'; printf '\\357\\273\\277err\\342' >&2; sleep 0.1; printf '\\230\\200'"
            let result = await env.exec(.shell(command), options: .init(timeout: .seconds(15),
                onOutput: { text, _, info in
                    if info.stream == .stdout { stdout.append(text) }
                    else { stderr.append(text) }
                }), context: .background)
            #expect(try result.get().exitCode == 0)
            #expect(stdout.text == "😀")
            #expect(stderr.text == "err\u{FFFD}")
        }
    }

    @Test("uses a custom shell, per-command cwd, and merged environment")
    func customShellCwdAndMergedEnvironment() async throws {
        try await withShellTestEnv { (_: LocalExecutionEnv, directory: URL) async throws in
            let shell = directory.appendingPathComponent("custom-shell")
            try Data("#!/bin/sh\nprintf 'custom:'\nexec /bin/bash \"$@\"\n".utf8).write(to: shell)
            #expect(chmod(shell.path, 0o700) == 0)
            let child = directory.appendingPathComponent("child")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            let env = LocalExecutionEnv(cwd: directory.path, shellPath: shell.path,
                                        shellEnv: ["BASE_VALUE": "base", "OVERRIDE_VALUE": "old"])
            let (result, output) = await collectShellText(env,
                "printf '%s:%s:%s' \"$PWD\" \"$BASE_VALUE\" \"$OVERRIDE_VALUE\"",
                options: .init(cwd: "child", env: ["OVERRIDE_VALUE": "new"], timeout: .seconds(15)))
            let path = try await env.canonicalPath(child.path, context: .background).get()
            #expect(try result.get().exitCode == 0)
            #expect(output == "custom:\(path):base:new")
            await env.cleanup(context: .background)
        }
    }

    @Test("ends after the idle grace period and does not call back after return")
    func idleGraceStopsCallbacks() async throws {
        try await withShellTestEnv { (env: LocalExecutionEnv, directory: URL) async throws in
            let log = ShellTextLog()
            let result = await env.exec(.shell("printf initial; (sleep 2; touch descendant-done; printf late) &"),
                options: .init(timeout: .seconds(15), onOutput: { text, _, _ in log.append(text) }), context: .background)
            #expect(try result.get().exitCode == 0)
            #expect(log.text == "initial")
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("descendant-done").path))
            try await waitForShellFile(directory.appendingPathComponent("descendant-done"))
            try await ContinuousClock().sleep(for: .milliseconds(200))
            #expect(log.text == "initial")
        }
    }

    @Test("an output callback failure stops descendants")
    func callbackErrorStopsDescendants() async throws {
        try await withShellTestEnv { (env: LocalExecutionEnv, directory: URL) async throws in
            let command = "(exec sleep 60) & child=$!; printf '%s' \"$child\" > child.pid; printf output; wait"
            let result = await env.exec(.shell(command), options: .init(timeout: .seconds(15),
                onOutput: { _, _, _ in throw ShellTestError(message: "callback failed") }), context: .background)
            expectShellError(result, .callbackError)
            let pid = try await shellChildPID(directory.appendingPathComponent("child.pid"))
            defer { _ = Darwin.kill(pid, SIGKILL) }
            try await waitForShellChildExit(pid)
        }
    }

    // env-node.test.ts:657, 703, 860: legacy WSL transport, Windows inherited stdio,
    // and taskkill spawn errors do not apply to the macOS shell implementation.
}
#endif
