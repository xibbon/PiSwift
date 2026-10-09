import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting

private final class ExampleLog<Value: Sendable>: Sendable {
    private let state = Mutex<[Value]>([])
    var values: [Value] { state.withLock { $0 } }
    var count: Int { state.withLock { $0.count } }
    func append(_ value: Value) { state.withLock { $0.append(value) } }
}
private final class ExampleGate: Sendable {
    private struct State { var open = false; var waiters: [CheckedContinuation<Void, Never>] = [] }
    private let state = Mutex(State())
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { value in
                if value.open { return true }
                value.waiters.append(continuation); return false
            }
            if ready { continuation.resume() }
        }
    }
    func release() {
        let waiters = state.withLock { value in
            value.open = true; let result = value.waiters; value.waiters = []; return result
        }
        for waiter in waiters { waiter.resume() }
    }
}

private struct ExampleNotes: Codable, Sendable, Equatable { var text = "" }
private struct ExampleTodos: Codable, Sendable, Equatable { var items: [String] = [] }
private struct ExampleCheckpoint: TaskCheckpoint {
    enum Phase: String, Codable, Sendable { case ready, prepare, charge, tick }
    var phase: Phase = .ready
    var key: String = ""
    var n = 1
}
private struct ExampleTickerCheckpoint: TaskCheckpoint {
    enum Phase: String, Codable, Sendable { case tick }
    var phase: Phase = .tick
    var n = 1
}
private struct ExamplePaymentInput: Codable, Sendable { let amount: Int }
private struct ExamplePaymentResult: Codable, Sendable { let receipt: Int }
private struct ExampleAgentRegistry: Codable, Sendable, Equatable {
    struct Agent: Codable, Sendable, Equatable { let conversationId: ConversationID; let requestId: String }
    var agents: [String: Agent] = [:]
}
private func exampleNotes() throws -> RewindableConversationDocToken<ExampleNotes> {
    try .init(kind: "example.notes", version: 1, fork: .asOf, initial: { ExampleNotes() })
}
private func exampleHarness(registry: Registry = createRegistry(), models: FakeDurableModels = FakeDurableModels(),
                            settings: HarnessSettingsProvider? = nil) async throws -> Harness {
    try await Harness.open(storage: MemoryStorage(), options: .init(models: models, registry: registry, settings: settings), context: .background)
}
private func exampleTool(_ name: String, _ description: String) throws -> ToolRegistration {
    try ToolRegistration(name: name, description: description,
        parameters: ["type": "object", "properties": .object(["path": .object(["type": "string"])])]) { args, _, _ in
        ToolExecutionResult(content: [.text(TextContent(text: "\(name) \(args["path"]?.stringValue ?? "")"))])
    }
}
private func exampleAssistant(_ text: String, calls: [String] = [], reason: StopReason? = nil) -> AssistantMessage {
    AssistantMessage(content: [.text(TextContent(text: text))] + calls.map {
        .toolCall(ToolCall(id: $0, name: "read", arguments: [:]))
    }, api: .openAICompletions, provider: "faux", model: "faux-1",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: reason ?? (calls.isEmpty ? .stop : .toolUse), timestamp: 2)
}
private func exampleUser(_ text: String) -> Message { .user(UserMessage(content: .text(text), timestamp: 1)) }
private func exampleShow(_ message: Message) -> String {
    switch message {
    case .user(let user): if case .text(let text) = user.content { return "user: \(text)" }; return "user"
    case .assistant(let assistant): return "assistant: " + assistant.content.map {
        switch $0 { case .text(let text): text.text; case .toolCall(let call): "call(\(call.id))"; default: "" }
    }.joined(separator: " ")
    case .toolResult(let result): return "result(\(result.toolCallId))" + (result.isError ? " error" : "")
    case .system(let system):
        let fields = (system.sections?.entries ?? []).map { entry in
            let key = OrderedJSON.string(entry.name).serialized(escapeSlashes: false)
            let value = entry.value.map { OrderedJSON.string($0).serialized(escapeSlashes: false) } ?? "null"
            return "\(key):\(value)"
        }.joined(separator: ",")
        return "system: {\(fields)}"
    }
}

@Suite struct UpstreamBasicExamplesTests {
    @Test func example00Conversation() async throws {
        let session = try await Session.open(storage: MemoryStorage(), context: .background)
        let standalone = try await session.commit({ tx in try await tx.createConversation(ownership: .ownerless()) }, context: .background)
        #expect(standalone.id.rawValue == 2)
        #expect(standalone.owner == nil)
        #expect(standalone.parent == nil)
        try await session.close(context: .background)
    }

    @Test func example01Documents() async throws {
        let session = try await Session.open(storage: MemoryStorage(), context: .background)
        let notes = try exampleNotes()
        let chat = try await session.commit({ tx in try await tx.createConversation(ownership: .ownerless()) }, context: .background)
        let first = try await session.commit({ tx in
            let entry = try await tx.appendEntry(chat.id, value: .init(kind: "note", data: "hello"))
            try await tx.doc(notes, conversationId: chat.id).set("text", "after hello")
            return entry
        }, context: .background)
        let second = try await session.commit({ tx in
            let entry = try await tx.appendEntry(chat.id, value: .init(kind: "note", data: "goodbye"))
            try await tx.doc(notes, conversationId: chat.id).set("text", "after goodbye")
            return entry
        }, context: .background)
        #expect(try await session.snapshot(notes, conversationId: chat.id, context: .background) == ExampleNotes(text: "after goodbye"))
        #expect(try await session.snapshotAsOf(notes, conversationId: chat.id, at: first.id, context: .background) == ExampleNotes(text: "after hello"))
        #expect(try await session.snapshotAsOf(notes, conversationId: chat.id, at: second.id, context: .background) == ExampleNotes(text: "after goodbye"))
        try await session.close(context: .background)
    }

    @Test func example02Forks() async throws {
        let session = try await Session.open(storage: MemoryStorage(), context: .background)
        let notes = try exampleNotes()
        let chat = try await session.commit({ tx in try await tx.createConversation(ownership: .ownerless()) }, context: .background)
        let first = try await session.commit({ tx in
            let entry = try await tx.appendEntry(chat.id, value: .init(kind: "note", data: "hello"))
            try await tx.doc(notes, conversationId: chat.id).set("text", "after hello")
            return entry
        }, context: .background)
        try await session.commit({ tx in
            _ = try await tx.appendEntry(chat.id, value: .init(kind: "note", data: "goodbye"))
            try await tx.doc(notes, conversationId: chat.id).set("text", "after goodbye")
        }, context: .background)
        let branch = try await session.commit({ tx in try await tx.forkConversation(chat.id, at: first.id, ownership: .ownerless()) }, context: .background)
        let entries = try await session.commit({ tx in try await tx.scanEntries(.init(conversationId: branch.id), limit: 10) }, context: .background)
        #expect(entries.items.map(\.data) == [.string("hello")])
        #expect(try await session.snapshot(notes, conversationId: branch.id, context: .background)?.text == "after hello")
        try await session.commit({ tx in try await tx.doc(notes, conversationId: branch.id).set("text", "changed only in the fork") }, context: .background)
        #expect(try await session.snapshot(notes, conversationId: branch.id, context: .background)?.text == "changed only in the fork")
        #expect(try await session.snapshot(notes, conversationId: chat.id, context: .background)?.text == "after goodbye")
        try await session.close(context: .background)
    }

    @Test func example03OwnedConversations() async throws {
        let session = try await Session.open(storage: MemoryStorage(), context: .background)
        let supervisor = TaskDefinition<JSONValue, ExampleCheckpoint, JSONValue, NoTaskHooks>(name: "example.supervisor", version: 1,
            initial: { _ in ExampleCheckpoint() }, phase: { _, _, _ in }, abort: { _, _, _ in })
        let registry = try ConversationDocToken<ExampleAgentRegistry>(kind: "example.agent-registry", version: 1, fork: .initial, initial: { .init() })
        let main = try await session.commit({ tx in try await tx.createConversation(ownership: .ownerless()) }, context: .background)
        let setup = try await session.commit({ tx in
            let task = try await tx.createTask(supervisor, input: .null, options: .init(ownership: .conversation(), conversationId: main.id, background: true))
            let child = try await tx.createConversation(ownership: .task(taskId: task))
            let value = ExampleAgentRegistry.Agent(conversationId: child.id, requestId: "researcher:first-message:\(task.rawValue)")
            try await tx.doc(registry, conversationId: main.id).set("agents", .object(["researcher": try JSONValue(encoding: value)]))
            return (task, child, value)
        }, context: .background)
        #expect(setup.0.rawValue > 0)
        #expect(setup.1.owner?.taskId == setup.0)
        #expect(setup.1.owner?.conversationId == main.id)
        #expect(try await session.snapshot(registry, conversationId: main.id, context: .background) == ExampleAgentRegistry(agents: ["researcher": setup.2]))
        try await session.close(context: .background)
    }

    @Test func example04ChordState() async throws {
        let session = try await Session.open(storage: MemoryStorage(), context: .background)
        let notes = try exampleNotes()
        let chat = try await session.commit({ tx in
            let chat = try await tx.createConversation(ownership: .ownerless())
            try await tx.doc(notes, conversationId: chat.id).set("text", "first")
            return chat
        }, context: .background)
        let state = try #require(try await session.documentState(notes, conversationId: chat.id, context: .background))
        let deliveries = ExampleLog<(String, Int, ExampleNotes?)>()
        let delivered = ExampleGate()
        let stop = state.subscribe { value, _, delivery in
            deliveries.append((String(describing: delivery.kind), delivery.sequence, value))
            if delivery.kind == .update { delivered.release() }
        }
        try await session.commit({ tx in try await tx.doc(notes, conversationId: chat.id).set("text", "published through Chord") }, context: .background)
        await delivered.wait()
        #expect(deliveries.values.map { $0.2?.text } == ["first", "published through Chord"])
        #expect(deliveries.values.map { $0.0 } == ["hydrate", "update"])
        #expect(deliveries.values.map { $0.1 } == [0, 1])
        stop.cancel(); state.dispose()
        try await session.close(context: .background)
    }

    @Test func example05Watches() async throws {
        let session = try await Session.open(storage: MemoryStorage(), context: .background)
        let notes = try exampleNotes()
        let chat = try await session.commit({ tx in
            let chat = try await tx.createConversation(ownership: .ownerless())
            try await tx.doc(notes, conversationId: chat.id).set("text", "first")
            return chat
        }, context: .background)
        let watch = try #require(try await session.watchDoc(notes, conversationId: chat.id, context: .background))
        #expect(watch.value == ExampleNotes(text: "first"))
        let values = ExampleLog<ExampleNotes?>(), delivered = ExampleGate()
        try watch.start { value, _, _ in values.append(value); delivered.release() }
        try await session.commit({ tx in try await tx.doc(notes, conversationId: chat.id).set("text", "observed asynchronously") }, context: .background)
        await delivered.wait()
        #expect(values.values == [ExampleNotes(text: "observed asynchronously")])
        _ = await watch.stop()
        try await session.close(context: .background)
    }

    @Test func example06Harness() async throws {
        let read = try exampleTool("read", "Read a file")
        let registry = createRegistry(); try registry.install(Extension(name: "files", tools: [read]))
        let harness = try await exampleHarness(registry: registry)
        let notes = try exampleNotes()
        let root = try await harness.root(options: .init(agent: .init(thinkingLevel: .set(.low)), initialize: { tx, id in
            try await tx.doc(notes, conversationId: id).set("text", "root notes")
        }), context: .background)
        #expect(root.id == rootConversationID)
        #expect(try await harness.snapshot(notes, conversationId: root.id, context: .background)?.text == "root notes")
        #expect(try await harness.snapshot(AgentDoc, conversationId: root.id, context: .background) == AgentState(thinkingLevel: .low))
        let agent = try await root.agent(context: .background)
        #expect(agent.thinkingLevel == .low); #expect(agent.extensions.map(\.name) == ["files"]); #expect(agent.tools.map(\.name) == ["read"])
        try await harness.close(context: .background)
    }

    @Test func example07Configuration() async throws {
        let read = try exampleTool("read", "Read a file"), write = try exampleTool("write", "Write a file"), grep = try exampleTool("grep", "Search files")
        let files = Extension(name: "files", tools: [read, write]), search = Extension(name: "search", tools: [grep])
        // Swift uses value types. The section derives app snippets from the tool names.
        let snippets = Extension(name: "snippets", sections: [section("tool_snippets") { input, _ in
            input.agent.tools.map { "Use \($0.name) for files." }.joined(separator: "\n")
        }])
        let registry = createRegistry(); try registry.install(files); try registry.install(search); try registry.install(snippets)
        let timeout = Mutex(60_000)
        let settings = HarnessSettingsProvider { HarnessSettings(stream: .init(timeoutMs: timeout.withLock { $0 }), retry: .init(maxRetries: 5), toolExecution: .sequential) }
        let harness = try await exampleHarness(registry: registry, settings: settings)
        let root = try await harness.root(context: .background)
        #expect(try await root.agent(context: .background).tools.map(\.name) == ["read", "write", "grep"])
        let model = ModelRef(provider: "anthropic", modelId: "claude-sonnet-4-5")
        try await root.configure(change: .init(model: .set(model), thinkingLevel: .set(.high), tools: .set(.exact([write, read]))), context: .background)
        #expect(try await harness.snapshot(AgentDoc, conversationId: root.id, context: .background) == AgentState(model: model, thinkingLevel: .high, tools: .exact(["write", "read"])))
        let agent = try await root.agent(context: .background)
        #expect(agent.model == model); #expect(agent.thinkingLevel == .high); #expect(agent.tools.map(\.name) == ["write", "read"])
        try await root.configure(change: .init(extensions: .set(.edit(remove: [search])), tools: .clear), context: .background)
        #expect(try await root.agent(context: .background).tools.map(\.name) == ["read", "write"])
        try await root.configure(change: .init(extensions: .set(.exact([files, search]))), context: .background)
        registry.uninstall(files)
        #expect(try await root.agent(context: .background).tools.map(\.name) == ["grep"])
        try registry.install(files)
        #expect(try await root.agent(context: .background).tools.map(\.name) == ["read", "write", "grep"])
        timeout.withLock { $0 = 120_000 }
        #expect(settings.resolve().stream.timeoutMs == 120_000)
        try await harness.close(context: .background)
    }

    @Test func example08HarnessConversations() async throws {
        struct From: Codable, Sendable { let from: String }
        let harness = try await exampleHarness(); let root = try await harness.root(context: .background)
        try await root.configure(change: .init(thinkingLevel: .set(.high)), context: .background)
        let message = try EntryKind<From>("message")
        let hello = try await root.commit({ tx in
            try await tx.appendEntry(message, conversationId: root.id, value: .init(model: EntryRecord.encodeMessages([exampleUser("hello")]), data: From(from: "example")))
        }, context: .background)
        #expect(message.matches(hello.record)); #expect(try message.data(from: hello.record)?.from == "example")
        let helper = try await harness.createConversation(options: .init(ownership: .ownerless(), agent: .init(thinkingLevel: .set(.minimal))), context: .background)
        let retry = try await root.fork(at: hello.id, options: .init(ownership: .ownerless()), context: .background)
        #expect(try await helper.agent(context: .background).thinkingLevel == .minimal)
        #expect(try await retry.agent(context: .background).thinkingLevel == .high)
        #expect(try await harness.conversation(id: retry.id, context: .background)?.id == retry.id)
        try await harness.close(context: .background)
    }

    @Test func example09Context() async throws {
        let harness = try await exampleHarness()
        let transcript = try await harness.createConversation(options: .init(ownership: .ownerless()), context: .background)
        func say(_ message: Message) async throws -> EntryRecord {
            try await transcript.commit({ tx in try await tx.appendEntry(transcript.id, value: .init(kind: "message", model: EntryRecord.encodeMessages([message]))) }, context: .background)
        }
        let question = try await say(exampleUser("read a and b"))
        _ = try await say(.assistant(exampleAssistant("I crashed", reason: .aborted)))
        let calls = try await say(.assistant(exampleAssistant("reading", calls: ["a", "b"])))
        func result(_ id: String) -> Message { .toolResult(ToolResultMessage(toolCallId: id, toolName: "read", content: [.text(TextContent(text: "file \(id)"))], isError: false, timestamp: 3)) }
        _ = try await say(result("b"))
        try await transcript.commit({ tx in
            _ = try await tx.appendEntry(transcript.id, value: .init(kind: "pi.system", model: EntryRecord.encodeMessages([.system(SystemMessage(content: .text(""), sections: .init([("cwd", "<cwd>/repo</cwd>")]), timestamp: 4))])))
        }, context: .background)
        _ = try await say(result("a")); _ = try await say(.assistant(exampleAssistant("a and b look fine")))
        try await transcript.commit({ tx in
            _ = try await tx.appendEntry(transcript.id, value: .init(kind: "edit", data: "user fixed a typo", edits: [.replace(target: question.id, messages: EntryRecord.encodeMessages([exampleUser("read files a and b")]))]))
            _ = try await tx.appendEntry(transcript.id, value: .init(kind: "note", data: "display only"))
        }, context: .background)
        let view = try await transcript.context(context: .background)
        #expect(view.entries.map(\.kind) == ["message", "message", "message", "message", "pi.system", "message", "message", "edit", "note"])
        #expect(view.messages.map(exampleShow) == ["user: read files a and b", "assistant: reading call(a) call(b)", "result(a)", "result(b)", "system: {\"cwd\":\"<cwd>/repo</cwd>\"}", "assistant: a and b look fine"])
        let cut = try await transcript.fork(at: calls.id, options: .init(ownership: .ownerless()), context: .background)
        #expect(try await cut.context(context: .background).messages.map(exampleShow) == ["user: read a and b", "assistant: reading call(a) call(b)", "result(a) error", "result(b) error"])
        try await transcript.commit({ tx in
            _ = try await tx.appendEntry(transcript.id, value: .init(kind: "summary", model: EntryRecord.encodeMessages([exampleUser("Summary: a and b are fine.")]), head: .self))
        }, context: .background)
        let summarized = try await transcript.context(context: .background)
        #expect(summarized.head?.kind == "summary"); #expect(summarized.messages.map(exampleShow) == ["user: Summary: a and b are fine."])
        let history = try await transcript.entries(limit: 3, context: .background)
        #expect(history.items.map(\.kind) == ["summary", "note", "edit"]); #expect(history.next != nil)
        try await harness.close(context: .background)
    }

    @Test func example10RegistryReload() async throws {
        let read = try exampleTool("read", "Read a file")
        let registry = createRegistry(); try registry.install(Extension(name: "files", tools: [read, exampleTool("grep", "Search files")]))
        let harness = try await exampleHarness(registry: registry); let root = try await harness.root(context: .background)
        try registry.install(Extension(name: "files", tools: [read, exampleTool("grep", "Search files, faster")]))
        func tools() async throws -> [String] { try await root.agent(context: .background).tools.map { "\($0.name): \($0.description)" } }
        #expect(try await tools() == ["read: Read a file", "grep: Search files, faster"])
        let audit = Extension(name: "audit", wraps: [wrapTool(read) { tool in var changed = tool; changed.description += " (audited)"; return changed }])
        try registry.install(audit)
        #expect(try await tools() == ["read: Read a file (audited)", "grep: Search files, faster"])
        registry.uninstall(audit)
        #expect(try await tools() == ["read: Read a file", "grep: Search files, faster"])
        try await harness.close(context: .background)
    }

    @Test func example11ExtensionState() async throws {
        let todos = try RewindableConversationDocToken<ExampleTodos>(kind: "example.todos", version: 1, fork: .asOf, initial: { .init() })
        let todo = try ToolRegistration(name: "todo", description: "Add an item to your todo list", parameters: ["type": "object", "properties": .object(["item": .object(["type": "string"])])]) { args, api, context in
            let item = args["item"]?.stringValue ?? ""
            try await api.commit({ tx in try await tx.doc(todos, conversationId: api.conversationId).child("items")!.append(.string(item)) }, context: context)
            return ToolExecutionResult(content: [.text(TextContent(text: "added \(item)"))])
        }
        let registry = createRegistry()
        try registry.install(Extension(name: "todo", tools: [todo], sections: [section("todos") { input, context in
            let value = try await input.read.snapshot(todos, conversationId: input.conversationId, context: context)
            return value?.items.isEmpty == false ? value?.items.joined(separator: "\n") : nil
        }]))
        var call = exampleAssistant("")
        call.content = [.toolCall(ToolCall(id: "todo-1", name: "todo", arguments: ["item": AnyCodable("fix the build")]))]; call.stopReason = .toolUse
        let models = FakeDurableModels(responses: [.message(call), .message(exampleAssistant("Noted.")), .message(exampleAssistant("Working on it."))])
        let harness = try await exampleHarness(registry: registry, models: models)
        let root = try await harness.root(options: .init(agent: .init(model: .set(.init(provider: "faux", modelId: "faux-1")))), context: .background)
        #expect(try await root.submit(.input(content: .text("Remember to fix the build.")), context: .background).wait(context: .background).status == "done")
        #expect(try await harness.snapshot(todos, conversationId: root.id, context: .background) == ExampleTodos(items: ["fix the build"]))
        #expect(try await root.submit(.input(content: .text("What is next?")), context: .background).wait(context: .background).status == "done")
        let systems = try await root.context(context: .background).messages.compactMap { message -> SystemMessage? in if case .system(let system) = message { system } else { nil } }
        #expect(systems.count == 2)
        #expect(systems.first?.sections == nil)
        #expect(systems.first?.toolsAdded?.map(\.name) == ["todo"])
        #expect(systems.last?.sections?.entries.map(\.value) == ["<todos>\nfix the build\n</todos>"])
        #expect(systems.last?.toolsAdded == nil)
        try await harness.close(context: .background)
    }

    @Test func example12Tasks() async throws {
        let payments = Mutex<[String: Int]>([:])
        let payment = TaskDefinition<ExamplePaymentInput, ExampleCheckpoint, ExamplePaymentResult, NoTaskHooks>(name: "example.payment", version: 1,
            initial: { _ in ExampleCheckpoint(phase: .prepare) }, phase: { task, runtime, context in
                switch task.checkpoint.phase {
                case .prepare:
                    try await runtime.commit({ _, _ in .running(checkpoint: try JSONValue(encoding: ExampleCheckpoint(phase: .charge, key: "payment-\(task.id.rawValue)"))) }, context: context)
                case .charge:
                    let receipt = payments.withLock { values in
                        if values[task.checkpoint.key] == nil { values[task.checkpoint.key] = task.input.amount * 100 }
                        return values[task.checkpoint.key]!
                    }
                    try await runtime.commit({ _, _ in try completed(ExamplePaymentResult(receipt: receipt)) }, context: context)
                default: throw TaskDefinitionError("Unexpected payment phase")
                }
            }, abort: { _, runtime, context in try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context) })
        let registry = createRegistry(); try registry.install(Extension(name: "payments", tasks: [AnyTaskDefinition(payment)]))
        let harness = try await exampleHarness(registry: registry); let root = try await harness.root(context: .background)
        let id = try await root.commit({ tx in try await tx.createTask(payment, input: .init(amount: 5), options: .init(ownership: .conversation())) }, context: .background)
        let paid = try await harness.waitForTask(id: id, context: .background)
        #expect(paid.outcome == .completed(result: .object(["receipt": 500])))
        try await harness.close(context: .background)
    }

    @Test func example13Recovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-durable-example-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("session.sqlite").path
        let ticks = ExampleLog<String>(), tickTwo = ExampleGate()
        let clock = TestClock()
        let ticker = TaskDefinition<Int, ExampleTickerCheckpoint, String, NoTaskHooks>(name: "example.ticker", version: 1,
            initial: { _ in ExampleTickerCheckpoint() }, phase: { task, runtime, context in
                let n = task.checkpoint.n
                if try await runtime.memo("printed-\(n)", context: context) == nil {
                    _ = try await runtime.memo("printed-\(n)", value: .bool(true), context: context)
                    ticks.append("tick \(n)")
                }
                // Hold tick 2 before its outcome commit. This makes the crash point deterministic.
                if n == 2 && ticks.count == 2 && clock.now() == 0 {
                    tickTwo.release()
                    try await runtime.sleep(until: 1, context: context)
                }
                try await runtime.commit({ _, _ in
                    n == task.input ? try completed("counted to \(n)") : .running(checkpoint: try JSONValue(encoding: ExampleTickerCheckpoint(n: n + 1)))
                }, context: context)
            }, abort: { _, runtime, context in try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context) })
        let registry = createRegistry(); try registry.install(Extension(name: "ticker", tasks: [AnyTaskDefinition(ticker)]))
        let options = HarnessOptions(models: FakeDurableModels(), registry: registry, clock: clock)
        let first = try await Harness.open(storage: SqliteStorage.open(path: path), options: options, context: .background)
        let root = try await first.root(context: .background)
        let id = try await root.commit({ tx in try await tx.createTask(ticker, input: 5, options: .init(ownership: .conversation())) }, context: .background)
        try first.resume(); await tickTwo.wait(); try await first.close(context: .background)
        let reader = try await Harness.open(storage: SqliteStorage.open(path: path), options: options, context: .background)
        let saved = try #require(try await reader.getTask(id: id, context: .background))
        guard case .pending(let checkpoint, _) = saved.state else { throw TaskDefinitionError("Expected saved pending task after reopen") }
        #expect(checkpoint == .object(["phase": "tick", "n": 2]))
        #expect(saved.memos == ["printed-1": true, "printed-2": true])
        try await reader.close(context: .background)
        clock.advance(by: 1)
        let second = try await Harness.open(storage: SqliteStorage.open(path: path), options: options, context: .background)
        let counted = try await second.waitForTask(id: id, context: .background)
        #expect(counted.outcome == .completed(result: "counted to 5"))
        #expect(ticks.values == ["tick 1", "tick 2", "tick 3", "tick 4", "tick 5"])
        try await second.close(context: .background)
    }

    @Test func example14Chat() async throws {
        let models = FakeDurableModels(responses: [.message(exampleAssistant("Paris."))])
        let registry = createRegistry(); try registry.install(Extension(name: "terse", sections: [section("preamble", tag: false) { _, _ in "You answer in one word." }]))
        let harness = try await exampleHarness(registry: registry, models: models)
        let root = try await harness.root(options: .init(agent: .init(model: .set(.init(provider: "faux", modelId: "faux-1")))), context: .background)
        let capital = try await root.submit(.input(content: .text("Capital of France?")), context: .background)
        let answered = try await capital.wait(context: .background)
        #expect(answered.status == "done")
        let answer = try #require(answered.answer)
        let entry = try #require(try await root.commit({ tx in try await tx.entry(answer) }, context: .background))
        #expect(assistantEntry.matches(entry))
        #expect(try entry.messages()?.map(exampleShow) == ["assistant: Paris."])
        let transcript = try await root.entries(limit: 10, context: .background)
        #expect(transcript.items.reversed().map(\.kind) == ["pi.user", "pi.system", "pi.assistant"])
        try await harness.close(context: .background)
    }
}
