import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func c6SessionFile(_ directory: URL, name: String, id: String, modified: Date) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(name)
    let contents = "{\"type\":\"session\",\"id\":\"\(id)\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n"
    try contents.write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    return file
}

@Test func allSessionSnapshotsPrioritizeFileModificationTime() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("c6-list-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appendingPathComponent("sessions")
    let old = try c6SessionFile(sessions.appendingPathComponent("a"), name: "zz-old.jsonl", id: "old",
                                modified: Date(timeIntervalSince1970: 1_700_000_000))
    let new = try c6SessionFile(sessions.appendingPathComponent("b"), name: "aa-new.jsonl", id: "new",
                                modified: Date(timeIntervalSince1970: 1_800_000_000))
    let snapshots = LockedState<[[String]]>([])
    let result = try await SessionManager.listAll(inAgentDir: root.path, onPartial: { _, _, partial in
        snapshots.withLock { $0.append(partial.map(\.path)) }
    })
    #expect(snapshots.withLock { $0.first?.first }.map { URL(fileURLWithPath: $0).lastPathComponent } == new.lastPathComponent)
    #expect(result.map { URL(fileURLWithPath: $0.path).lastPathComponent } == [new.lastPathComponent, old.lastPathComponent])
}

@Test(.timeLimit(.minutes(1))) func cancelledListingThrowsAndPublishesNoLateBatch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("c6-cancel-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("sessions/project")
    for index in 0..<15 {
        _ = try c6SessionFile(folder, name: "\(index).jsonl", id: "\(index)",
                              modified: Date(timeIntervalSince1970: Double(1_800_000_000 + index)))
    }
    let batchCount = LockedState(0)
    let listing = Task {
        try await SessionManager.listAll(inAgentDir: root.path, onPartial: { _, _, _ in
            batchCount.withLock { $0 += 1 }
            withUnsafeCurrentTask { $0?.cancel() }
        })
    }
    do {
        _ = try await listing.value
        Issue.record("Expected cancellation")
    } catch is CancellationError {
        #expect(batchCount.withLock { $0 } == 1)
    }
}

@Test(.timeLimit(.minutes(1))) func rpcQueueInputRunsExtensionHandlersForSteerAndFollowUp() async throws {
    let manager = SessionManager.inMemory("/tmp")
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey("anthropic", "test-key")
    let registry = ModelRegistry(auth)
    let calls = LockedState<[String]>([])
    let hook = LoadedHook(path: "c6", resolvedPath: "c6", handlers: ["input": [{ event, _ in
        guard let input = event as? InputEvent else { return nil }
        calls.withLock { $0.append("\(input.source.rawValue):\(input.streamingBehavior?.rawValue ?? "idle"):\(input.text)") }
        if input.text.hasPrefix("handle") { return InputEventResult.handled }
        return InputEventResult.transform(text: "transformed: \(input.text)")
    }]], isExtension: true)
    let runner = HookRunner([hook], "/tmp", manager, registry)
    let model = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
    let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "test", model: model),
        streamFn: { _, _, options in
            let stream = AssistantMessageEventStream()
            Task {
                stream.push(.start(partial: c6Assistant([])))
                while options.signal?.isCancelled != true {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                stream.push(.error(reason: .aborted, error: c6Assistant([])))
            }
            return stream
        }, getApiKey: { _ in "test-key" }))
    let session = AgentSession(config: AgentSessionConfig(
        agent: agent, sessionManager: manager, settingsManager: SettingsManager.inMemory(),
        resourceLoader: TestResourceLoader(), hookRunner: runner, modelRegistry: registry))
    defer { session.dispose() }
    let prompt = Task { try await session.prompt("start") }
    for _ in 0..<100 where !session.isStreaming {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(session.isStreaming)
    calls.withLock { $0.removeAll() }

    await session.steer("one", source: .rpc)
    await session.steer("handle steer", source: .rpc)
    await session.followUp("two", source: .rpc)
    await session.followUp("handle follow", source: .rpc)
    #expect(calls.withLock { $0 } == ["rpc:steer:one", "rpc:steer:handle steer",
                                     "rpc:followUp:two", "rpc:followUp:handle follow"])
    #expect(session.pendingMessageCount == 2)
    let queued = session.clearQueue()
    #expect(queued.steering == ["transformed: one"])
    #expect(queued.followUp == ["transformed: two"])
    await session.abort()
    _ = try? await prompt.value
}

private func c6Assistant(_ transformations: [[String: Any]]) -> AssistantMessage {
    AssistantMessage(content: [.text(TextContent(text: "ok"))], api: .anthropicMessages,
                     provider: "anthropic", model: "test",
                     usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                     stopReason: .stop,
                     diagnostics: [AssistantMessageDiagnostic(type: "anthropic_input_transformations",
                        details: ["transformations": AnyCodable(transformations)])])
}

@Test func thinkingDropNoticeSuppressesCumulativeRepeatsAndKeepsDetails() {
    let first = c6Assistant([["type": "thinking_dropped", "path": "messages.0", "reason": "bad_signature"]])
    let repeated = c6Assistant([["type": "thinking_dropped", "path": "messages.0", "reason": "bad_signature"]])
    let grown = c6Assistant([
        ["type": "thinking_dropped", "path": "messages.0", "reason": "bad_signature"],
        ["type": "thinking_dropped", "path": "messages.1", "reason": "model_binding_mismatch"],
    ])
    #expect(newThinkingDropNotice(current: first, previous: nil)?.count == 1)
    #expect(newThinkingDropNotice(current: repeated, previous: first) == nil)
    let notice = newThinkingDropNotice(current: grown, previous: first)
    #expect(notice?.count == 2)
    #expect(notice?.transformations[1]["reason"]?.value as? String == "model_binding_mismatch")
    #expect(grown.diagnostics?.first?.details["transformations"] != nil)
}
