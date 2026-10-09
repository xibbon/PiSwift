import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

func codingChat(storage: any DurableStorage = MemoryStorage(), setup: HarnessChatSetup,
                directory: String, resume: Bool = true) async throws -> OpenChatResult {
    let harness = try await Harness.open(storage: storage, options: .init(models: setup.models,
        registry: setup.registry, settings: setup.settingsProvider,
        env: { target, _ in LocalExecutionEnv(cwd: target.cwd ?? directory) },
        onReport: { setup.reports.append($0) }), context: .background)
    let root = try await harness.root(options: .init(agent: .init(
        model: .set(.init(provider: "faux", modelId: "faux-1")), cwd: .set(directory))), context: .background)
    if resume { try harness.resume() }
    return OpenChatResult(harness: harness, root: root)
}

@Suite struct HarnessCodingToolsTests {
    #if os(macOS)
    // harness-tools.test.ts:875. The harness retains the tail and orders diagnostics.
    @Test func failingCommandKeepsTailAndDiagnosticOrder() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = HarnessChatSetup()
        try setup.registry.install(Extension(name: "bash", tools: [createBashTool()]))
        setup.models.setResponses([.message(try toolCalls([("bash", ["command": "i=1; while [ $i -le 3000 ]; do echo line-$i; i=$((i + 1)); done; exit 7"], "b")])), .message(chatAssistant("done"))])
        let opened = try await codingChat(setup: setup, directory: directory.path)
        #expect(try await opened.root.submit(.input(content: .text("go")), context: .background).wait(context: .background).status == "done")
        let entry = try #require(try await allEntries(opened.root).first { $0.kind == toolResultEntry.kind })
        let result = try #require(try harnessToolResults([entry]).first)
        #expect(result.isError)
        let text = harnessToolText(result)
        #expect(text.hasPrefix("line-1001\n"))
        let data = try #require(entry.data)
        let diagnostics = try data.decode(ToolResultEntryData.self).diagnostics
        #expect(diagnostics.map(\.code) == ["full_output", "tool_error", "truncated"])
        #expect(text.contains("line-3000\n|<harness>\n[info] Full output: "))
        #expect(text.contains("\n[error] Command exited with code 7\n[warn] Output truncated to its end: 1000 lines, "))
        if let spill = diagnostics.first?.message.components(separatedBy: "Full output: ").last {
            #expect(try String(contentsOfFile: spill, encoding: .utf8).hasPrefix("line-1\n"))
            #expect(try String(contentsOfFile: spill, encoding: .utf8).hasSuffix("line-3000\n"))
            try? FileManager.default.removeItem(atPath: (spill as NSString).deletingLastPathComponent)
        }
        try await opened.harness.close(context: .background)
    }

    // harness-tools.test.ts:905. Each tool uses the real local environment.
    @Test func readsEditsAndRunsCommandThenAnswers() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("hello world\n".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        let setup = HarnessChatSetup()
        try setup.registry.install(try CodingTools)
        setup.models.setResponses([
            .message(try toolCalls([("read", ["path": "notes.txt"], "r")])),
            .message(try toolCalls([("edit", ["path": "notes.txt", "edits": [["oldText": "world", "newText": "durable"]]], "e")])),
            .message(try toolCalls([("bash", ["command": "cat notes.txt"], "b")])),
            .message(chatAssistant("done"))])
        let opened = try await codingChat(setup: setup, directory: directory.path)
        #expect(try await opened.root.submit(.input(content: .text("go")), context: .background).wait(context: .background).status == "done")
        let entries = try await allEntries(opened.root)
        let results = try harnessToolResults(entries)
        #expect(results.map(\.toolName) == ["read", "edit", "bash"])
        #expect(results.allSatisfy { !$0.isError })
        #expect(results.map(harnessToolText) == ["hello world\n", "Successfully replaced 1 block(s) in notes.txt.", "hello durable\n"])
        #expect(entries.last?.kind == "pi.assistant")
        #expect(try String(contentsOf: directory.appendingPathComponent("notes.txt"), encoding: .utf8) == "hello durable\n")
        try await opened.harness.close(context: .background)
    }

    // harness-tools-recovery.test.ts:338. A committed output watch replaces polling.
    @Test func realCommandCloseAndReopenReturnsInterruptedResult() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("recovery.sqlite").path
        let setup = HarnessChatSetup(settings: .init(progress: .init(outputIntervalMs: 0)))
        try setup.registry.install(Extension(name: "bash", tools: [createBashTool()]))
        setup.models.setResponses([.message(try toolCalls([("bash", ["command": "echo started; sleep 30"], "b")])), .message(chatAssistant("done"))])
        let first = try await codingChat(storage: SqliteStorage.open(path: path), setup: setup, directory: directory.path)
        let watch = try #require(try await first.harness.watchDoc(LiveDoc, conversationId: first.root.id, context: .background))
        let started = HarnessChatSignal()
        try watch.start { live, _, _ in if live?.tools?.first?.output == "started\n" { started.signal() } }
        let id = try await first.root.submit(.input(content: .text("go")), context: .background).id
        await started.wait()
        try await first.harness.close(context: .background)
        let second = try await codingChat(storage: SqliteStorage.open(path: path), setup: setup, directory: directory.path)
        let submission = try #require(try await second.harness.submission(id: id, context: .background))
        #expect(try await submission.wait(context: .background).status == "done")
        let results = try harnessToolResults(try await allEntries(second.root))
        #expect(results.count == 1)
        #expect(results.first?.isError == true)
        #expect(results.map(harnessToolText) == ["started\n|<harness>\n[error] Tool bash was interrupted and may have partially run\n</harness>"])
        #expect(setup.models.state().callCount == 2)
        try await second.harness.close(context: .background)
    }
    #endif

    // The mobile selection uses read/write/edit and does not offer bash.
    @Test func fileToolsRunWithBashExcluded() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = HarnessChatSetup()
        try setup.registry.install(try CodingTools)
        setup.models.setResponses([
            .message(try toolCalls([("write", ["path": "note.txt", "content": "hello world\r\n"], "w")])),
            .message(try toolCalls([("edit", ["path": "note.txt", "edits": [["oldText": "world", "newText": "durable"]]], "e")])),
            .message(try toolCalls([("read", ["path": "note.txt"], "r")])), .message(chatAssistant("done"))])
        let opened = try await codingChat(setup: setup, directory: directory.path)
        try await opened.root.configure(change: .init(tools: .set(.exact([createReadTool(), createWriteTool(), createEditTool()]))), context: .background)
        #expect(try await opened.root.agent(context: .background).tools.map(\.name) == ["read", "write", "edit"])
        #expect(try await opened.root.submit(.input(content: .text("change greeting")), context: .background).wait(context: .background).status == "done")
        let results = try harnessToolResults(try await allEntries(opened.root))
        #expect(results.count == 3)
        #expect(results.allSatisfy { !$0.isError })
        #expect(results.last.map(harnessToolText) == "hello durable\r\n")
        try await opened.harness.close(context: .background)
    }
}
