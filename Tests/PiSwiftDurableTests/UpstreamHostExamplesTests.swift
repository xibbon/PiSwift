import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting

private let hostExampleAnswer = "This directory holds the durable package sources, tests, and docs."

private final class HostExamplePrint: Sendable {
    private let output = Mutex<[String]>([])
    var lines: [String] { output.withLock { $0 } }
    func line(_ value: String) { output.withLock { $0.append(value) } }
    func json<Value: Encodable>(_ value: Value) throws {
        line(try JSONValue(encoding: value).jsonText())
    }
    func parsed() throws -> [JSONValue] {
        try lines.map { line in
            #expect(!line.contains("\n"))
            return try JSONValue(jsonText: line)
        }
    }
}

private final class HostExamplePartialPrint: Sendable {
    private let output = Mutex("")
    var text: String { output.withLock { $0 } }
    func printText(_ text: String) {
        output.withLock { printed in
            guard text.utf16.count > printed.utf16.count, text.utf16.starts(with: printed.utf16) else { return }
            printed += String(decoding: text.utf16.dropFirst(printed.utf16.count), as: UTF16.self)
        }
    }
}

enum HostExampleMode: String, CaseIterable, Sendable { case events, ops }
enum HostExampleStorage: String, CaseIterable, Sendable { case memory, sqlite, jsonl }

private func hostExampleDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("durable-host-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func hostExampleAssistant(_ text: String) -> AssistantMessage {
    AssistantMessage(content: [.text(.init(text: text))], api: .openAICompletions,
        provider: "faux", model: "faux-1", usage: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .stop)
}

private func hostExampleAnswerEntry(_ root: Conversation, settled: SettledSubmission) async throws -> EntryRecord {
    #expect(settled.status == "done")
    guard case .input = settled.record else { throw TaskDefinitionError("Expected an input submission") }
    let answer = try #require(settled.answer)
    let entry = try #require(try await root.commit({ tx in try await tx.entry(answer) }, context: .background))
    #expect(assistantEntry.matches(entry))
    return entry
}

private func hostExampleAnswerText(_ entry: EntryRecord) throws -> String {
    guard case .assistant(let answer) = try #require(try entry.messages()?.first) else {
        throw TaskDefinitionError("Expected an assistant answer")
    }
    return answer.content.compactMap { if case .text(let text) = $0 { text.text } else { nil } }.joined()
}

#if os(macOS)
private func hostExampleModels(paced: Bool = false) -> FakeDurableModels {
    var call = hostExampleAssistant("")
    call.content = [.toolCall(.init(id: "call-1", name: "bash", arguments: ["command": AnyCodable("ls")]))]
    call.stopReason = .toolUse
    return FakeDurableModels(options: .init(tokensPerSecond: paced ? 200 : nil), responses: [
        .message(call), .message(hostExampleAssistant(hostExampleAnswer))
    ])
}

private func hostExampleRegistry() throws -> Registry {
    let registry = createRegistry()
    try registry.install(Extension(name: "coding", tools: [try createReadTool(), try createBashTool()],
        sections: [section("preamble", tag: false) { _, _ in "You are a concise coding assistant." }]))
    return registry
}

private func hostExampleStorage(_ kind: HostExampleStorage, directory: URL) async throws -> any DurableStorage {
    switch kind {
    case .memory: MemoryStorage()
    case .sqlite: try await SqliteStorage.open(path: directory.appendingPathComponent("run.sqlite").path)
    case .jsonl: try await JsonlStorage.open(directory: directory.appendingPathComponent("storage").path)
    }
}

private func hostExampleCheckShell(_ root: Conversation) async throws {
    let entries = try await root.entries(limit: 100, context: .background)
    let results = try entries.items.flatMap { try $0.messages() ?? [] }.compactMap { message -> ToolResultMessage? in
        if case .toolResult(let result) = message { return result }; return nil
    }
    let result = try #require(results.first)
    #expect(results.count == 1)
    #expect(result.toolCallId == "call-1")
    #expect(result.toolName == "bash")
    #expect(!result.isError)
    #expect(result.content.count == 1)
    guard case .text(let text) = try #require(result.content.first) else {
        throw TaskDefinitionError("Expected shell text")
    }
    #expect(text.text == "docs\nsources\ntests\n")
}
#endif

#if os(macOS)
// The host supplies model services. The same host flow can use a real service.
private func hostExamplePrintRun(directory: URL, models: any DurableModels, model: ModelRef,
                                 verifyFaux: Bool = false) async throws -> [String] {
    for name in ["docs", "sources", "tests"] {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    let env = LocalExecutionEnv(cwd: directory.path), print = HostExamplePrint()
    let harness = try await Harness.open(storage: MemoryStorage(),
        options: .init(models: models, registry: hostExampleRegistry(), env: { _, _ in env }), context: .background)
    do {
        let root = try await harness.root(options: .init(agent: .init(
            model: .set(model))), context: .background)
        let submission = try await root.submit(.input(content: .text("What is in this directory?")), context: .background)
        let settled = try await submission.wait(context: .background)
        print.line(try hostExampleAnswerText(await hostExampleAnswerEntry(root, settled: settled)))
        if verifyFaux {
            #expect(print.lines == [hostExampleAnswer])
            try await hostExampleCheckShell(root)
        }
        try await harness.close(context: .background)
        return print.lines
    } catch {
        try? await harness.close(context: .background)
        throw error
    }
}

private func hostExampleJSONRun(directory: URL, models: any DurableModels, model: ModelRef,
                                mode: HostExampleMode, storageKind: HostExampleStorage,
                                verifyFaux: Bool = false) async throws -> (lines: [String], diagnostics: [String]) {
    let work = directory.appendingPathComponent("work", isDirectory: true)
    for name in ["docs", "sources", "tests"] {
        try FileManager.default.createDirectory(at: work.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    let env = LocalExecutionEnv(cwd: work.path), print = HostExamplePrint()
    let diagnostic = HostExamplePrint()
    let storage = try await hostExampleStorage(storageKind, directory: directory)
    let harness = try await Harness.open(storage: storage,
        options: .init(models: models, registry: hostExampleRegistry(), env: { _, _ in env }), context: .background)
    do {
        let root = try await harness.root(options: .init(agent: .init(
            model: .set(model))), context: .background)
        let events: DurableAgentEventWatch?, watch: CommittedWatch<ConversationView>?
        switch mode {
        case .events:
            let stream = try await harness.watchEvents(conversationId: root.id, context: .background)
            try print.json(stream.snapshot)
            try stream.start { values, _ in for value in values { try print.json(value) } }
            events = stream; watch = nil
        case .ops:
            let stream = try await root.watch(context: .background)
            try print.json(["view": JSONValue(encoding: stream.value)])
            try stream.start { _, ops, _ in try print.json(["ops": JSONValue(encoding: ops)]) }
            events = nil; watch = stream
        }
        let submission = try await root.submit(.input(content: .text("What is in this directory?")), context: .background)
        let settled = try await submission.wait(context: .background)
        try await harness.waitForIdle(context: .background)
        // Drain committed frames instead of using the upstream zero-delay timer.
        if let events { await events.waitUntilIdle(); _ = await events.stop() }
        if let watch { await watch.waitUntilIdle(); _ = await watch.stop() }
        let entry = try await hostExampleAnswerEntry(root, settled: settled)
        if verifyFaux {
            #expect(try hostExampleAnswerText(entry) == hostExampleAnswer)
            try await hostExampleCheckShell(root)
        }
        let lines = try print.parsed()
        #expect(lines.count > 1)
        switch mode {
        case .events:
            let snapshot = try #require(lines.first)
            #expect(snapshot["type"] == "snapshot")
            #expect(snapshot["entries"] == [])
            #expect(snapshot["agent"]?["model"] == ["provider": .string(model.provider), "modelId": .string(model.modelId)])
            for line in lines { _ = try line.decode(DurableAgentEvent.self) }
            let types = lines.compactMap { $0["type"]?.stringValue }
            for type in ["run_start", "turn_start", "message_start", "message_end", "turn_end", "run_end", "submission", "usage_changed"] {
                #expect(types.contains(type))
            }
            if verifyFaux {
                #expect(types.contains("tool_execution_end"))
                let tool = try #require(lines.first { $0["type"] == "tool_execution_start" })
                #expect(tool["toolCallId"] == "call-1")
                #expect(tool["toolName"] == "bash")
                #expect(tool["args"] == ["command": "ls"])
            }
            #expect(lines.contains { $0["type"] == "message_end" && $0["entry"]?["id"] == .number(Double(entry.id.rawValue)) })
            #expect(lines.contains { $0["type"] == "submission" && $0["record"]?["id"] == .number(Double(submission.id.rawValue)) && $0["record"]?["status"] == "done" })
        case .ops:
            var value = try #require(lines.first?["view"])
            #expect(lines.first?.objectValue?.count == 1)
            #expect(value["entries"] == [])
            for line in lines.dropFirst() {
                #expect(line.objectValue?.count == 1)
                let ops = try #require(line["ops"]).decode([Delta.Op].self)
                #expect(!ops.isEmpty)
                value = try #require(try Delta.applyImmutable(value, ops))
            }
            let replay = try value.decode(ConversationView.self)
            #expect(replay == watch?.value)
            #expect(replay.entries.last == entry)
            #expect(replay.docs["pi.live"]?["run"] == nil)
            #expect(replay.docs["pi.live"]?["generation"] == nil)
        }
        try await harness.close(context: .background)
        switch storageKind {
        case .memory:
            #expect(diagnostic.lines.isEmpty)
        case .sqlite, .jsonl:
            let location = directory.appendingPathComponent(storageKind == .sqlite ? "run.sqlite" : "storage").path
            diagnostic.line("\(storageKind.rawValue) storage: \(location)")
            #expect(diagnostic.lines == ["\(storageKind.rawValue) storage: \(location)"])
            #expect(location.hasPrefix(FileManager.default.temporaryDirectory.path))
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: location, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue == (storageKind == .jsonl))
            #expect(storageKind != .sqlite || location.hasSuffix(".sqlite"))
        }
        return (print.lines, diagnostic.lines)
    } catch {
        try? await harness.close(context: .background)
        throw error
    }
}
#endif

private func hostExampleRealModelRun(directory: URL, models: any DurableModels, model: ModelRef) async throws -> [String] {
    let env = LocalExecutionEnv(cwd: directory.path)
    let registry = createRegistry()
    try registry.install(Extension(name: "concise", sections: [
        section("preamble", tag: false) { _, _ in "You are a concise assistant." }
    ]))
    let harness = try await Harness.open(storage: MemoryStorage(),
        options: .init(models: models, registry: registry, env: { _, _ in env }), context: .background)
    do {
        let root = try await harness.root(options: .init(agent: .init(
            model: .set(model), thinkingLevel: .set(.high))), context: .background)
        let liveWatch = try #require(try await harness.watchDoc(LiveDoc, conversationId: root.id, context: .background))
        let output = HostExamplePartialPrint(), print = HostExamplePrint()
        try liveWatch.start { value, _, _ in
            if let block = value?.generation?.message?["content"]?.arrayValue?.first(where: { $0["type"] == "text" }),
               let text = block["text"]?.stringValue { output.printText(text) }
        }
        try harness.resume()
        let poem = try await root.submit(.input(content: .text("Write a long poem")), context: .background)
        let settled = try await poem.wait(context: .background)
        await liveWatch.waitUntilIdle()
        _ = await liveWatch.stop()
        let entry = try await hostExampleAnswerEntry(root, settled: settled)
        guard case .assistant(let message) = try #require(try entry.messages()?.first) else {
            throw TaskDefinitionError("Expected an assistant poem")
        }
        let answer = try #require(message.content.compactMap { if case .text(let block) = $0 { block.text } else { nil } }.first)
        output.printText(answer)
        print.line("answer: " + output.text)
        #expect(!answer.isEmpty)
        #expect(output.text == answer)
        #expect(print.lines == ["answer: " + answer])
        try await harness.close(context: .background)
        return print.lines
    } catch {
        try? await harness.close(context: .background)
        throw error
    }
}

@Suite struct UpstreamHostExamplesTests {
    // v1.1.0 test/examples/16-real-model.ts. The two host flags permit a real request.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PI_DURABLE_REAL_MODEL"] == "1"
        && ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil))
    func example16RealModel() async throws {
        let directory = try hostExampleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try #require(ProcessInfo.processInfo.environment["OPENAI_API_KEY"])
        let models = PiSwiftAIDurableModels(apiKeyResolver: { _ in key })
        let model = try #require(models.getModel(provider: "openai", modelId: "gpt-6-sol"))
        #expect(model.id == "gpt-6-sol")
        let lines = try await hostExampleRealModelRun(directory: directory, models: models,
            model: .init(provider: "openai", modelId: model.id))
        #expect(lines.count == 1)
        #expect(lines.first?.hasPrefix("answer: ") == true)
    }

    #if os(macOS)
    // v1.1.0 test/examples/18-print.ts. Always use the faux branch in default tests.
    @Test func example18Print() async throws {
        let directory = try hostExampleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = hostExampleModels()
        let lines = try await hostExamplePrintRun(directory: directory, models: models,
            model: .init(provider: "faux", modelId: "faux-1"), verifyFaux: true)
        #expect(lines == [hostExampleAnswer])
        #expect(models.state().callCount == 2)
    }

    // v1.1.0 test/examples/19-json.ts. Each mode runs against all three storage implementations.
    @Test(arguments: HostExampleMode.allCases, HostExampleStorage.allCases)
    func example19JSON(mode: HostExampleMode, storageKind: HostExampleStorage) async throws {
        let directory = try hostExampleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = hostExampleModels(paced: true)
        let printed = try await hostExampleJSONRun(directory: directory, models: models,
            model: .init(provider: "faux", modelId: "faux-1"), mode: mode, storageKind: storageKind, verifyFaux: true)
        let values = try printed.lines.map { try JSONValue(jsonText: $0) }
        #expect(values.count > 1)
        #expect(values.first?[mode == .events ? "type" : "view"] != nil)
        #expect(printed.diagnostics.count == (storageKind == .memory ? 0 : 1))
        #expect(models.state().callCount == 2)
    }
    #endif
}
