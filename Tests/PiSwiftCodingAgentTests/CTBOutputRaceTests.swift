#if os(macOS) || os(Linux)
import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private let raceIterations = 500
private let raceLargeOutput = String(repeating: "q", count: 200 * 1024)
private let raceLargeCommand = "head -c 204800 /dev/zero | tr '\\000' q"
private let ctbLongChildCommand = "sleep 30 & child=$!; printf 'ready:%s\\n' \"$child\"; wait \"$child\""

private func ctbReportedChildPid(_ output: String) -> Int32? {
    guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("ready:") }) else { return nil }
    return Int32(line.dropFirst("ready:".count))
}

private func ctbProcessIsActive(_ pid: Int32) throws -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "stat=", "-p", String(pid)]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let state = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return !state.isEmpty && !state.hasPrefix("Z")
}

private func ctbRaceSession() -> AgentSession {
    let manager = SessionManager.inMemory()
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "test", model: model),
        convertToLlm: { PiSwiftCodingAgent.convertToLlm($0) }, sessionId: manager.getSessionId()))
    return AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager,
        settingsManager: .inMemory(), resourceLoader: TestResourceLoader(),
        modelRegistry: ModelRegistry(AuthStorage(":memory:"))))
}

private struct CTBReadyBashOperations: BashOperations {
    let output: LockedState<String>

    func execute(_ command: String, options: BashExecutorOptions?) async throws -> BashResult {
        var forwarded = options ?? BashExecutorOptions()
        let original = forwarded.onChunk
        forwarded.onChunk = { chunk in
            output.withLock { $0 += chunk }
            original?(chunk)
        }
        return try await DefaultBashOperations().execute(command, options: forwarded)
    }
}

private func ctbToolSession(output: LockedState<String>) -> AgentSession {
    let manager = SessionManager.inMemory()
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey(model.provider, "test-key")
    let tool = createBashTool(cwd: manager.getCwd(),
        options: BashToolOptions(operations: CTBReadyBashOperations(output: output)))
    let calls = LockedState(0)
    let agent = Agent(AgentOptions(
        initialState: AgentState(systemPrompt: "test", model: model, tools: [tool]),
        convertToLlm: { PiSwiftCodingAgent.convertToLlm($0) },
        streamFn: { model, _, _ in
            let call = calls.withLock { $0 += 1; return $0 }
            let content: [ContentBlock] = call == 1
                ? [.toolCall(ToolCall(id: "ctb-bash", name: "bash",
                    arguments: ["command": AnyCodable(ctbLongChildCommand)]))]
                : [.text(TextContent(text: "done"))]
            let reason: StopReason = call == 1 ? .toolUse : .stop
            let message = AssistantMessage(content: content, api: model.api, provider: model.provider,
                model: model.id, usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2),
                stopReason: reason)
            let stream = AssistantMessageEventStream()
            stream.push(.done(reason: reason, message: message))
            stream.end(message)
            return stream
        }, getApiKey: { _ in "test-key" }
    ))
    return AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager,
        settingsManager: .inMemory(), resourceLoader: TestResourceLoader(),
        modelRegistry: ModelRegistry(auth), toolRegistry: ["bash": tool]))
}

private func retainedBashOutput(_ result: BashResult) -> String? {
    guard let path = result.fullOutputPath else { return result.output }
    defer { try? FileManager.default.removeItem(atPath: path) }
    return try? String(contentsOfFile: path, encoding: .utf8)
}

// This is the exact executor chain used for `!` in PiSwiftTui's InteractiveMode.
@Test(.timeLimit(.minutes(10))) func ctbUserBashDrainsShortAndLargeOutput500Times() async throws {
    var failures: [String] = []
    try await withThrowingTaskGroup(of: [String].self) { group in
        for index in 0..<raceIterations {
            if index >= 16, let completed = try await group.next() { failures += completed }
            group.addTask {
                var failed: [String] = []
                let unrelatedCleanup: Task<Void, Never>? = index.isMultiple(of: 25)
                    ? Task.detached { ctbRaceSession().dispose() } : nil
                let short = try await executeBashWithOperations("printf x", operations: DefaultBashOperations(),
                    options: .init(signal: CancellationToken()))
                if short.output != "x" { failed.append("short \(index): \(short.output.utf8.count) bytes") }
                let transcript = try await executeBashWithOperations("printf 'v110-command-output'", operations: DefaultBashOperations(),
                    options: .init(onChunk: { _ in Task { @MainActor in _ = 1 } }, signal: CancellationToken(), cwd: "/tmp"))
                if transcript.output != "v110-command-output" {
                    failed.append("transcript \(index): \(transcript.output.utf8.count) bytes")
                }
                let large = try await executeBashWithOperations(raceLargeCommand, operations: DefaultBashOperations(),
                    options: .init(signal: CancellationToken()))
                let output = retainedBashOutput(large)
                if output != raceLargeOutput { failed.append("large \(index): \(output?.utf8.count ?? -1) bytes") }
                await unrelatedCleanup?.value
                return failed
            }
        }
        for try await completed in group { failures += completed }
    }
    #expect(failures.isEmpty, "\(failures.count) failures: \(failures.prefix(8).joined(separator: ", "))")
}

@Test(.timeLimit(.minutes(10))) func ctbBashToolDrainsShortAndLargeOutput500Times() async throws {
    let tool = createBashTool(cwd: "/")
    var failures: [String] = []
    for index in 0..<raceIterations {
        let unrelatedCleanup: Task<Void, Never>? = index.isMultiple(of: 25)
            ? Task.detached { ctbRaceSession().dispose() } : nil
        for (label, command, expected) in [("short", "printf x", "x"), ("large", raceLargeCommand, raceLargeOutput)] {
            let result = try await tool.execute("ctb-\(label)-\(index)", ["command": AnyCodable(command)], CancellationToken(), nil)
            let payload = result.structuredContent?.value as? [String: Any]
            let output = payload?["output"] as? String
            if output != expected { failures.append("\(label) \(index): \(output?.utf8.count ?? -1) bytes") }
            if let path = payload?["full_output_path"] as? String { try? FileManager.default.removeItem(atPath: path) }
        }
        await unrelatedCleanup?.value
    }
    #expect(failures.isEmpty, "\(failures.count) failures: \(failures.prefix(8).joined(separator: ", "))")
}

@Test(.timeLimit(.minutes(10))) func ctbPiExecDrainsShortAndLargeOutput500Times() async throws {
    var failures: [String] = []
    for index in 0..<raceIterations {
        let unrelatedCleanup: Task<Void, Never>? = index.isMultiple(of: 25)
            ? Task.detached { ctbRaceSession().dispose() } : nil
        let short = try await execCommand("/bin/sh", ["-c", "printf x"], "/", .init(signal: CancellationToken()))
        if short.stdout != "x" { failures.append("short \(index): \(short.stdout.utf8.count) bytes") }
        let large = try await execCommand("/bin/sh", ["-c", raceLargeCommand], "/", .init(signal: CancellationToken()))
        if large.stdout != raceLargeOutput { failures.append("large \(index): \(large.stdout.utf8.count) bytes") }
        await unrelatedCleanup?.value
    }
    #expect(failures.isEmpty, "\(failures.count) failures: \(failures.prefix(8).joined(separator: ", "))")
}

@Test(.timeLimit(.minutes(1))) func ctbDisposingOneSessionStopsOnlyItsOwnBash() async throws {
    let first = ctbRaceSession()
    let second = ctbRaceSession()
    defer { first.dispose(); second.dispose() }
    let firstOutput = LockedState("")
    let secondOutput = LockedState("")
    let firstRun = Task {
        try await first.executeBash(ctbLongChildCommand, onChunk: { chunk in
            firstOutput.withLock { $0 += chunk }
        })
    }
    let secondRun = Task {
        try await second.executeBash(ctbLongChildCommand, onChunk: { chunk in
            secondOutput.withLock { $0 += chunk }
        })
    }
    while ctbReportedChildPid(firstOutput.withLock({ $0 })) == nil ||
          ctbReportedChildPid(secondOutput.withLock({ $0 })) == nil { await Task.yield() }
    let firstChild = try #require(ctbReportedChildPid(firstOutput.withLock { $0 }))
    let secondChild = try #require(ctbReportedChildPid(secondOutput.withLock { $0 }))
    #expect(try ctbProcessIsActive(firstChild))
    #expect(try ctbProcessIsActive(secondChild))
    #expect(first.isBashRunning)
    #expect(second.isBashRunning)
    first.dispose()
    let firstResult = try await firstRun.value
    #expect(firstResult.cancelled)
    #expect(!first.isBashRunning)
    #expect(second.isBashRunning)
    #expect(try !ctbProcessIsActive(firstChild))
    #expect(try ctbProcessIsActive(secondChild))
    second.dispose()
    let secondResult = try await secondRun.value
    #expect(secondResult.cancelled)
    #expect(!second.isBashRunning)
    #expect(try !ctbProcessIsActive(secondChild))
}

@Test(.timeLimit(.minutes(1))) func ctbHostShutdownKillsTrackedShell() async throws {
    let before = getTrackedDetachedChildPids()
    let ready = LockedState(false)
    let run = Task {
        try await executeBashWithOperations("printf ready; sleep 30", operations: DefaultBashOperations(),
            options: .init(onChunk: { chunk in
                if chunk.contains("ready") { ready.withLock { $0 = true } }
            }))
    }
    while !ready.withLock({ $0 }) { await Task.yield() }
    #expect(!getTrackedDetachedChildPids().subtracting(before).isEmpty)
    killTrackedDetachedChildren()
    let result = try await run.value
    #expect(result.exitCode != 0)
    #expect(getTrackedDetachedChildPids().subtracting(before).isEmpty)
}

@Test(.timeLimit(.minutes(1))) func ctbDisposingSessionStopsItsBashToolCall() async throws {
    let output = LockedState("")
    let session = ctbToolSession(output: output)
    defer { session.dispose() }
    let before = getTrackedDetachedChildPids()
    #expect(session.agent.state.tools.contains { $0.name == "bash" })
    let finished = LockedState<String?>(nil)
    let prompt = Task {
        do {
            try await session.prompt("run the bash tool")
            finished.withLock { $0 = "prompt returned" }
        } catch {
            finished.withLock { $0 = String(describing: error) }
        }
    }
    while ctbReportedChildPid(output.withLock({ $0 })) == nil && finished.withLock({ $0 == nil }) { await Task.yield() }
    guard let child = ctbReportedChildPid(output.withLock({ $0 })) else {
        Issue.record("Bash tool did not start: \(finished.withLock { $0 ?? "unknown" })")
        return
    }
    #expect(try ctbProcessIsActive(child))
    #expect(!getTrackedDetachedChildPids().subtracting(before).isEmpty)
    session.dispose()
    await prompt.value
    await session.waitForIdle()
    #expect(getTrackedDetachedChildPids().subtracting(before).isEmpty)
    #expect(try !ctbProcessIsActive(child))
}
#endif
