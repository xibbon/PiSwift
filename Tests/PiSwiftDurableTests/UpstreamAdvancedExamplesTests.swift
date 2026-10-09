import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting

// These tests port the printed results from pi-mono v1.1.0 examples.
// Gates replace timer delays. All model responses use the faux provider.
private final class AdvancedExampleLog<Value: Sendable>: Sendable {
    private let storage = Mutex<[Value]>([])
    var values: [Value] { storage.withLock { $0 } }
    func append(_ value: Value) { storage.withLock { $0.append(value) } }
}

private func advancedCall(_ name: String, _ arguments: JSONObject = [:], id: String = "call-1") throws -> AssistantMessage {
    var message = chatAssistant("", reason: .toolUse)
    let object = try #require(try foundationJSON(from: .object(arguments)) as? [String: Any])
    message.content = [.toolCall(ToolCall(id: id, name: name, arguments: object.mapValues(AnyCodable.init)))]
    return message
}

private func advancedTool(_ name: String, replay: ToolReplay? = nil,
    execute: @escaping @Sendable (JSONValue, ToolExecutionApi, ChordContext) async throws -> ToolExecutionResult
) throws -> ToolRegistration {
    try ToolRegistration(name: name, description: "Example tool", parameters: ["type": "object"], replay: replay, execute: execute)
}

private func advancedTexts(_ conversation: Conversation, role: String) async throws -> [String] {
    try await allEntries(conversation).flatMap { try $0.messages() ?? [] }.filter { $0.role == role }.compactMap(textOf)
}

private func advancedDatabase() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("advanced-example-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func advancedTextBlocks(_ message: JSONObject) -> [Int: String] {
    var blocks: [Int: String] = [:]
    for (index, value) in (message["content"]?.arrayValue ?? []).enumerated() {
        if value["type"] == "text" { blocks[index] = value["text"]?.stringValue ?? "" }
    }
    return blocks
}

private func advancedShow(_ conversation: Conversation, label: String) async throws -> [String] {
    let view = try await conversation.context(context: .background)
    let stored = try await allEntries(conversation).count
    var lines = ["\(label): \(view.messages.count) messages in context, \(stored) entries stored"]
    if view.head?.kind == "pi.compaction", let reason = view.head?.data?["reason"]?.stringValue {
        lines.append("  (\(reason) compaction summary first)")
    }
    lines += view.messages.map { message in
        let role = message.role.padding(toLength: 9, withPad: " ", startingAt: 0)
        let text = message.role == "system" ? "(system prompt)" : String((textOf(message) ?? "").replacingOccurrences(of: "\n", with: " ").prefix(70))
        return "  \(role) \(text)"
    }
    return lines
}

@Suite struct UpstreamAdvancedExamplesTests {
    // 20-inbox.ts: reject, withdraw, queue modes, settlements, and transcript.
    @Test func inbox() async throws {
        let setup = HarnessChatSetup(settings: .init(followUpMode: .all))
        let firstAnswer = HarnessGatedResponse(message: chatAssistant("Answer to the first question."))
        setup.models.setResponses([firstAnswer.step, .message(chatAssistant("Answer to the follow-up and the steer."))])
        let chat = try await openChat(setup: setup)
        let first = try await chat.root.submit(.input(content: .text("First question")), context: .background)
        await firstAnswer.reached.wait()
        let followUp = try await chat.root.submit(.input(content: .text("A follow-up")), context: .background)
        let steer = try await chat.root.submit(.input(content: .text("A steer"), whenBusy: .steer), context: .background)
        let note = try await chat.root.submit(.write(entry: .init(kind: "app.note", data: "noted while busy")), context: .background)
        let withdrawn = try await chat.root.submit(.input(content: .text("Never mind")), context: .background)
        do {
            _ = try await chat.root.submit(.input(content: .text("Now or never"), whenBusy: .reject), context: .background)
            Issue.record("A busy conversation must reject the input")
        } catch let error as ConversationBusy {
            #expect(error.description == "Conversation \(chat.root.id.rawValue) is busy")
        }
        #expect(try await withdrawn.abort(context: .background) == .aborted)
        let inbox = try #require(try await chat.harness.snapshot(InboxDoc, conversationId: chat.root.id, context: .background))
        #expect(inbox.items.map(\.id) == [followUp.id, steer.id, note.id])
        #expect(inbox.items.map(\.mode) == [.followUp, .steer, .write])
        firstAnswer.release()
        let settledFirst = try await first.wait(context: .background)
        let settledFollowUp = try await followUp.wait(context: .background)
        let settledSteer = try await steer.wait(context: .background)
        #expect(settledFirst.status == "done")
        #expect(settledFollowUp.status == "done")
        #expect(settledSteer.status == "done")
        #expect(settledFirst.answer != settledFollowUp.answer)
        #expect(settledFollowUp.answer == settledSteer.answer)
        #expect(try await note.wait(context: .background).status == "done")
        #expect(try await withdrawn.wait(context: .background).status == "unanswered")
        #expect(try await withdrawn.wait(context: .background).reason == "aborted")
        #expect(try await allEntries(chat.root).map(\.kind) == ["pi.user", "pi.assistant", "app.note", "pi.user", "pi.user", "pi.assistant"])
        #expect(try await advancedTexts(chat.root, role: "assistant") == ["Answer to the first question.", "Answer to the follow-up and the steer."])
        try await chat.harness.close(context: .background)
    }

    // 21-late-join.ts: hydrate at count five, then apply only later updates.
    @Test func lateJoin() async throws {
        let halfway = HarnessChatSignal(), release = HarnessChatSignal(), counted = HarnessChatSignal(), finish = HarnessChatSignal()
        let setup = HarnessChatSetup(options: .init(tokensPerSecond: 400, minTokenSize: 1, maxTokenSize: 1),
            settings: .init(progress: .init(partialIntervalMs: 0, outputIntervalMs: 0)))
        let count = try advancedTool("count") { _, api, _ in
            for n in 1...10 {
                try api.output(.text("\(n)\n"), nil)
                if n == 5 { halfway.signal(); await release.wait() }
                await Task.yield()
            }
            counted.signal(); await finish.wait()
            return .init(content: [])
        }
        try setup.registry.install(Extension(name: "count", tools: [count]))
        let answer = "Counted to ten, and this answer streams slowly."
        setup.models.setResponses([.message(try advancedCall("count")), .message(chatAssistant(answer))])
        let chat = try await openChat(setup: setup)
        let input = try await chat.root.submit(.input(content: .text("Count to ten, then tell me.")), context: .background)
        await halfway.wait()
        let prefix = "1\n2\n3\n4\n5\n"
        try await eventually {
            try await chat.harness.snapshot(LiveDoc, conversationId: chat.root.id, context: .background)?.tools?.first?.output == prefix
        }
        let view = try await chat.root.viewState(context: .background)
        let live = try JSONValue.object(#require(view.value.docs["pi.live"])).decode(LiveState.self)
        #expect(view.value.entries.map(\.kind) == ["pi.user", "pi.system", "pi.assistant"])
        #expect(live.tools?.first?.status == .running)
        #expect(live.tools?.first?.output == prefix)
        let viewOutputs = AdvancedExampleLog<String>()
        let subscription = view.subscribe { value, _, _ in
            let live = try value.docs["pi.live"].map { try JSONValue.object($0).decode(LiveState.self) }
            if let slot = live?.tools?.first, slot.status == .running { viewOutputs.append(slot.output ?? "") }
        }
        let stream = try await chat.harness.watchEvents(conversationId: chat.root.id, context: .background)
        #expect(stream.snapshot.tools.map { "\($0.name) \($0.status.rawValue)" } == ["count running"])
        #expect(stream.snapshot.tools.first?.output == prefix)
        let output = Mutex(prefix), events = AdvancedExampleLog<DurableAgentEvent>()
        let streamedText = Mutex<[Int: String]>([:]), partialText = AdvancedExampleLog<String>()
        try stream.start { batch, _ in
            for event in batch {
                events.append(event)
                switch event {
                case .messageStart(let message) where message["role"] == "assistant":
                    streamedText.withLock { $0 = advancedTextBlocks(message) }
                case .messageEnd(let entry):
                    // The final entry replaces the partial. The progress throttle
                    // can omit the last partial update before this event.
                    if let message = entry.model?.first?.objectValue, message["role"] == "assistant" {
                        streamedText.withLock { $0 = advancedTextBlocks(message) }
                    }
                case .messageUpdate(_, let changes):
                    for change in changes {
                        streamedText.withLock { blocks in
                            switch change {
                            case .textStart(let index, let block):
                                blocks[index] = block["text"]?.stringValue ?? ""
                            case .block(let index, let block) where block["type"] == "text":
                                blocks[index] = block["text"]?.stringValue ?? ""
                            case .textDelta(let index, let delta): blocks[index, default: ""] += delta
                            case .message(let message): blocks = advancedTextBlocks(message)
                            default: break
                            }
                        }
                        partialText.append(streamedText.withLock { blocks in blocks.keys.sorted().map { blocks[$0] ?? "" }.joined() })
                    }
                default: break
                }
                if case .toolExecutionUpdate(_, _, let change?, _, _) = event {
                    output.withLock { value in
                        switch change {
                        case .set(let text): value = text
                        case .delta(let trim, let append): value = String(value.dropFirst(trim ?? 0)) + (append ?? "")
                        }
                    }
                }
            }
        }
        release.signal()
        await counted.wait()
        let full = (1...10).map { "\($0)\n" }.joined()
        try await eventually {
            try await chat.harness.snapshot(LiveDoc, conversationId: chat.root.id, context: .background)?.tools?.first?.output == full
        }
        await stream.waitUntilIdle()
        try await eventually { viewOutputs.values.contains(full) }
        finish.signal()
        #expect(try await input.wait(context: .background).status == "done")
        try await chat.harness.waitForIdle(context: .background)
        await stream.waitUntilIdle()
        #expect(output.withLock { $0 } == full)
        #expect(viewOutputs.values.contains(full))
        #expect(streamedText.withLock { blocks in blocks.keys.sorted().map { blocks[$0] ?? "" }.joined() } == answer)
        #expect(!partialText.values.isEmpty)
        #expect(partialText.values.allSatisfy { answer.hasPrefix($0) })
        #expect(events.values.contains { if case .messageEnd(let entry) = $0 { return (try? textOf(entry.messages()?.first)) == answer }; return false })
        #expect(!events.values.contains { if case .toolExecutionStart = $0 { return true }; return false })
        #expect(events.values.contains { if case .messageUpdate(_, let changes) = $0 { return changes.contains { if case .textDelta = $0 { return true }; return false } }; return false })
        _ = await stream.stop(); subscription.cancel(); view.dispose()
        try await chat.harness.close(context: .background)
    }

    // 22-subagent-foreground.ts: the tool owns the child and returns its answer.
    @Test func foregroundSubagent() async throws {
        let setup = HarnessChatSetup()
        let childIDs = AdvancedExampleLog<ConversationID>(), childEvents = AdvancedExampleLog<DurableAgentEvent>()
        let childWatches = AdvancedExampleLog<DurableAgentEventWatch>()
        let harnessCell = Mutex<Harness?>(nil)
        let extensionName = "subagent"
        let tool = try advancedTool("subagent", replay: .safe) { arguments, api, context in
            let taskText = try #require(arguments["task"]?.stringValue)
            let child = try await api.commit({ tx in
                if let existing = try await tx.scanConversations(.init(ownerTaskId: api.taskId), limit: 1).items.first { return existing.id }
                let created = try await tx.createConversation(ownership: .task(taskId: api.taskId))
                try await configure(tx: tx, conversationId: created.id,
                    change: .init(extensions: .set(.edit(remove: [Extension(name: extensionName)]))))
                return created.id
            }, context: context)
            childIDs.append(child)
            try await api.details(["conversationId": .number(Double(child.rawValue))], context)
            let harness = try #require(harnessCell.withLock { $0 })
            let watch = try await harness.watchEvents(conversationId: child, context: context)
            try watch.start { events, _ in for event in events { childEvents.append(event) } }
            childWatches.append(watch)
            let handle = try #require(try await api.conversation(id: child, context: context))
            let submission = try await handle.submit(.input(content: .text(taskText), requestId: "subagent:\(api.taskId.rawValue)"), context: context)
            let settled = try await submission.wait(context: context)
            #expect(settled.status == "done")
            let answer = try #require(settled.answer)
            let text = try await api.commit({ tx in
                let entry = try await tx.entry(answer)
                return try textOf(entry?.messages()?.first)
            }, context: context)
            return .init(content: [.text(TextContent(text: try #require(text)))], details: ["conversationId": .number(Double(child.rawValue))])
        }
        try setup.registry.install(Extension(name: extensionName, tools: [tool]))
        setup.models.setResponses([.message(try advancedCall("subagent", ["task": "Name three prime numbers."])),
            .message(chatAssistant("2, 3, and 5.")), .message(chatAssistant("The subagent says: 2, 3, and 5."))])
        let chat = try await openChat(setup: setup)
        harnessCell.withLock { $0 = chat.harness }
        let parentEvents = AdvancedExampleLog<DurableAgentEvent>()
        let watch = try await chat.harness.watchEvents(conversationId: chat.root.id, context: .background)
        try watch.start { events, _ in for event in events { parentEvents.append(event) } }
        let input = try await chat.root.submit(.input(content: .text("Use the subagent tool to find three prime numbers, then tell me what it said.")), context: .background)
        #expect(try await input.wait(context: .background).status == "done")
        try await chat.harness.waitForIdle(context: .background)
        await watch.waitUntilIdle()
        for childWatch in childWatches.values { await childWatch.waitUntilIdle(); _ = await childWatch.stop() }
        #expect(parentEvents.values.contains { if case .toolExecutionStart(_, "subagent", let args) = $0 { return args["task"] == "Name three prime numbers." }; return false })
        #expect(parentEvents.values.contains { if case .messageEnd(let entry) = $0 { return (try? textOf(entry.messages()?.first)) == "The subagent says: 2, 3, and 5." }; return false })
        #expect(childEvents.values.contains { if case .messageEnd(let entry) = $0 { return (try? textOf(entry.messages()?.first)) == "2, 3, and 5." }; return false })
        let childID = try #require(childIDs.values.first)
        #expect(parentEvents.values.contains {
            if case .toolExecutionUpdate(_, "subagent", _, let details, _) = $0 {
                return details?["conversationId"] == .number(Double(childID.rawValue))
            }
            return false
        })
        let child = try #require(try await chat.harness.conversation(id: childID, context: .background))
        #expect(try await child.agent(context: .background).tools.isEmpty)
        #expect(try await advancedTexts(chat.root, role: "toolResult") == ["2, 3, and 5."])
        #expect(try await advancedTexts(child, role: "user") == ["Name three prime numbers."])
        _ = await watch.stop()
        try await chat.harness.close(context: .background)
    }
}

private struct AdvancedSubagent: Codable, Sendable {
    let conversationId: ConversationID
    var reported: [EntryID] = []
}
private struct AdvancedSubagents: Codable, Sendable {
    var agents: [String: AdvancedSubagent] = [:]
    var reporters: [String: TaskID] = [:]
}
private struct AdvancedReporterInput: Codable, Sendable {
    let name: String
    let conversationId: ConversationID
    let message: String
    let followUp: Bool
}
private struct AdvancedReporterCheckpoint: TaskCheckpoint {
    enum Phase: String, Codable, Sendable { case deliver, report }
    var phase: Phase = .deliver
    var report: String?
}
private struct AdvancedDone: TaskCheckpoint {
    enum Phase: String, Codable, Sendable { case done }
    var phase: Phase = .done
}
private typealias AdvancedReporter = TaskDefinition<AdvancedReporterInput, AdvancedReporterCheckpoint, JSONValue, NoTaskHooks>
private typealias AdvancedAnchor = TaskDefinition<JSONValue, AdvancedDone, JSONValue, NoTaskHooks>

private func advancedSave(_ state: AdvancedSubagents, to draft: JSONDraft) throws {
    let object = try JSONValue(encoding: state)
    try draft.set("agents", #require(object["agents"]))
    try draft.set("reporters", #require(object["reporters"]))
}

private func advancedSubagentExtension(_ token: ConversationDocToken<AdvancedSubagents>) throws -> Extension {
    let anchor = AdvancedAnchor(name: "app.subagent-anchor", version: 1, initial: { _ in .init() },
        phase: { _, runtime, context in
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }, abort: { _, runtime, context in
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
        })
    let reporter = AdvancedReporter(name: "app.subagent-reporter", version: 1, initial: { _ in .init() },
        phase: { task, runtime, context in
            switch task.checkpoint.phase {
            case .deliver:
                let subagent = try #require(try await runtime.conversation(task.input.conversationId, context: context))
                let submission = try await subagent.submit(.input(content: .text(task.input.message),
                    whenBusy: task.input.followUp ? .followUp : .steer, requestId: "subagent:\(task.id.rawValue)"), context: context)
                let settled = try await submission.wait(context: context)
                try await runtime.commit({ tx, _ in
                    var checkpoint = AdvancedReporterCheckpoint(phase: .report)
                    if settled.status == "unanswered" {
                        if settled.reason != "aborted" { checkpoint.report = "[subagent \(task.input.name) failed: \(settled.reason ?? "unknown")]" }
                    } else if let answer = settled.answer {
                        let draft = try await tx.doc(token, conversationId: runtime.conversationId)
                        var state = try draft.snapshot().decode(AdvancedSubagents.self)
                        var agent = try #require(state.agents[task.input.name])
                        if !agent.reported.contains(answer) {
                            agent.reported.append(answer); state.agents[task.input.name] = agent
                            try advancedSave(state, to: draft)
                            let entry = try await tx.entry(answer)
                            let text = try textOf(entry?.messages()?.first) ?? ""
                            checkpoint.report = "[subagent \(task.input.name) answered, no reply needed] \(text)"
                        }
                    }
                    return .running(checkpoint: try JSONValue(encoding: checkpoint))
                }, context: context)
            case .report:
                if let report = task.checkpoint.report {
                    let main = try #require(try await runtime.conversation(runtime.conversationId, context: context))
                    _ = try await main.submit(.input(content: .text(report), whenBusy: .followUp,
                        requestId: "subagent-report:\(task.id.rawValue)"), context: context)
                }
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
            }
        }, abort: { _, runtime, context in
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
        })
    let tool = try advancedTool("subagent", replay: .unsafe) { args, api, context in
        let action = try #require(args["action"]?.stringValue)
        let name = args["name"]?.stringValue
        let state = try await api.snapshot(token, conversationId: api.conversationId, context: context) ?? .init()
        func reply(_ text: String, child: ConversationID? = nil) -> ToolExecutionResult {
            .init(content: [.text(TextContent(text: text))], details: child.map {
                ["name": .string(name ?? ""), "conversationId": .number(Double($0.rawValue))]
            })
        }
        if action == "status" {
            var lines: [String] = []
            for each in name.map({ [$0] }) ?? state.agents.keys.sorted() {
                if let found = state.agents[each] {
                    let busy = try await api.snapshot(LiveDoc, conversationId: found.conversationId, context: context)?.run != nil
                    lines.append("\(each): \(busy ? "working" : "idle")")
                }
            }
            return reply(lines.isEmpty ? "No subagents." : lines.joined(separator: "\n"))
        }
        guard let name else { return reply("\(action) needs a name.") }
        let agent = state.agents[name]
        if action != "spawn" && agent == nil { return reply("No subagent named \(name).") }
        if action == "stop" {
            let id = try #require(agent).conversationId
            try await #require(try await api.conversation(id: id, context: context)).abort(context: context)
            return reply("Stopped \(name).", child: id)
        }
        guard let message = args["message"]?.stringValue else { return reply("\(action) needs a message.") }
        let result = try await api.commit({ tx in
            let draft = try await tx.doc(token, conversationId: api.conversationId)
            var state = try draft.snapshot().decode(AdvancedSubagents.self)
            let background = TaskOptions(ownership: .conversation(), background: true)
            if action == "spawn" {
                if state.agents[name] != nil { return "\(name) already exists; use send." }
                let owner = try await tx.createTask(anchor, input: .null, options: background)
                let child = try await tx.createConversation(ownership: .task(taskId: owner))
                try await configure(tx: tx, conversationId: child.id, change: .init(
                    extensions: .set(.edit(remove: [Extension(name: "subagent-tools")])),
                    instructions: .set("You are the subagent \"\(name)\". Answer the main agent's requests.")))
                state.agents[name] = .init(conversationId: child.id)
            }
            let id = try #require(state.agents[name]).conversationId
            state.reporters[String(api.taskId.rawValue)] = try await tx.createTask(reporter,
                input: .init(name: name, conversationId: id, message: message,
                    followUp: action == "send" && args["followUp"] == true), options: background)
            try advancedSave(state, to: draft)
            return action == "send" ? "Sent to \(name)." : "Started \(name)."
        }, context: context)
        let current = try await api.snapshot(token, conversationId: api.conversationId, context: context)?.agents[name]
        return reply(result, child: current?.conversationId)
    }
    return Extension(name: "subagent-tools", tools: [tool], tasks: [AnyTaskDefinition(anchor), AnyTaskDefinition(reporter)])
}

extension UpstreamAdvancedExamplesTests {
    // 23-subagent-background.ts: spawn, report, stop, status, and resume after restart.
    @Test func backgroundSubagent() async throws {
        let token = try ConversationDocToken<AdvancedSubagents>(kind: "app.subagents", version: 1, fork: .initial, initial: { .init() })
        let setup = HarnessChatSetup()
        try setup.registry.install(advancedSubagentExtension(token))
        let longAnswer = HarnessUnanswered(), whaleAnswer = HarnessUnanswered()
        let holdWhale = Mutex(true)
        let route: FakeDurableResponseStep = .factory { transcript, options, state, model in
            let last = transcript.messages.last { $0.role != "system" }
            let text = textOf(last) ?? ""
            if last?.role == "toolResult" { return chatAssistant("OK. \(text)") }
            if text.contains("Start a subagent") { return try advancedCall("subagent", ["action": "spawn", "name": "reader", "message": "Summarize the plot of Moby Dick."], id: "call-\(state.callCount)") }
            if text.contains("whale's name") { return try advancedCall("subagent", ["action": "send", "name": "reader", "message": "What is the whale called?"], id: "call-\(state.callCount)") }
            if text.contains("every chapter") { return try advancedCall("subagent", ["action": "send", "name": "reader", "message": "Now go through all chapters in detail."], id: "call-\(state.callCount)") }
            if text.contains("Stop reader") { return try advancedCall("subagent", ["action": "stop", "name": "reader"], id: "call-\(state.callCount)") }
            if text.contains("my subagents") { return try advancedCall("subagent", ["action": "status"], id: "call-\(state.callCount)") }
            if text.contains("[subagent") { return chatAssistant("Noted.") }
            if text.contains("Summarize the plot") { return chatAssistant("A whale, a captain, an obsession.") }
            if text.contains("whale called") {
                if holdWhale.withLock({ $0 }) {
                    if case .factory(let respond) = whaleAnswer.step { return try await respond(transcript, options, state, model) }
                }
                return chatAssistant("Moby Dick.")
            }
            if case .factory(let respond) = longAnswer.step { return try await respond(transcript, options, state, model) }
            throw TestDeadlineError()
        }
        setup.models.setResponses(Array(repeating: route, count: 40))
        let directory = try advancedDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("session.sqlite").path
        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        func say(_ chat: OpenChatResult, _ text: String) async throws {
            #expect(try await chat.root.submit(.input(content: .text(text)), context: .background).wait(context: .background).status == "done")
        }
        func settle(_ chat: OpenChatResult) async throws {
            let state = try #require(try await chat.harness.snapshot(token, conversationId: chat.root.id, context: .background))
            for id in state.reporters.values { _ = try await chat.harness.waitForTask(id: id, context: .background) }
            try await chat.root.waitForIdle(context: .background)
        }
        try await say(first, "Start a subagent named reader that summarizes Moby Dick.")
        try await settle(first)
        #expect(try await advancedTexts(first.root, role: "assistant") == ["OK. Started reader.", "Noted."])
        #expect(try await advancedTexts(first.root, role: "user").last == "[subagent reader answered, no reply needed] A whale, a captain, an obsession.")
        try await say(first, "Ask reader to summarize every chapter.")
        await longAnswer.reached.wait()
        #expect(try await advancedTexts(first.root, role: "assistant") == ["OK. Started reader.", "Noted.", "OK. Sent to reader."])
        try await say(first, "Stop reader.")
        try await settle(first)
        #expect(try await advancedTexts(first.root, role: "assistant") == ["OK. Started reader.", "Noted.", "OK. Sent to reader.", "OK. Stopped reader."])
        try await say(first, "What are my subagents doing?")
        try await settle(first)
        #expect(try await advancedTexts(first.root, role: "toolResult") == ["Started reader.", "Sent to reader.", "Stopped reader.", "reader: idle"])
        #expect(try await advancedTexts(first.root, role: "assistant") == ["OK. Started reader.", "Noted.", "OK. Sent to reader.", "OK. Stopped reader.", "OK. reader: idle"])
        let saved = try #require(try await first.harness.snapshot(token, conversationId: first.root.id, context: .background))
        #expect(saved.agents["reader"]?.reported.count == 1)
        #expect(saved.reporters.count == 2)
        _ = try await first.root.submit(.input(content: .text("Ask reader for the whale's name.")), context: .background)
        await whaleAnswer.reached.wait()
        try await first.harness.close(context: .background)
        holdWhale.withLock { $0 = false }
        let reopened = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        try await settle(reopened)
        let reports = try await advancedTexts(reopened.root, role: "user").filter { $0.hasPrefix("[subagent") }
        #expect(reports == ["[subagent reader answered, no reply needed] A whale, a captain, an obsession.", "[subagent reader answered, no reply needed] Moby Dick."])
        #expect(try await advancedTexts(reopened.root, role: "assistant") == ["OK. Started reader.", "Noted.", "OK. Sent to reader.", "OK. Stopped reader.", "OK. reader: idle", "OK. Sent to reader.", "Noted."])
        #expect(try await advancedTexts(reopened.root, role: "toolResult") == ["Started reader.", "Sent to reader.", "Stopped reader.", "reader: idle", "Sent to reader."])
        let restored = try #require(try await reopened.harness.snapshot(token, conversationId: reopened.root.id, context: .background))
        #expect(restored.agents["reader"]?.conversationId == saved.agents["reader"]?.conversationId)
        #expect(restored.agents["reader"]?.reported.count == 2)
        #expect(restored.reporters.count == 3)
        let restoredAgent = try #require(restored.agents["reader"])
        let child = try #require(try await reopened.harness.conversation(id: restoredAgent.conversationId, context: .background))
        #expect(try await advancedTexts(child, role: "user") == ["Summarize the plot of Moby Dick.", "Now go through all chapters in detail.", "What is the whale called?"])
        #expect(try await child.agent(context: .background).tools.isEmpty)
        try await reopened.harness.close(context: .background)
    }
}

private struct AdvancedPaymentInput: Codable, Sendable { let card: String }
private struct AdvancedPaymentCheckpoint: TaskCheckpoint {
    enum Phase: String, Codable, Sendable { case charge }
    var phase: Phase = .charge
    let at: Int64
}
private struct AdvancedCheckoutCheckpoint: TaskCheckpoint {
    enum Phase: String, Codable, Sendable { case pay, decide }
    var phase: Phase = .pay
    var payments: [TaskID] = []
}
private typealias AdvancedPayment = TaskDefinition<AdvancedPaymentInput, AdvancedPaymentCheckpoint, AdvancedPaymentInput, NoTaskHooks>
private typealias AdvancedCheckout = TaskDefinition<[String], AdvancedCheckoutCheckpoint, String, NoTaskHooks>

extension UpstreamAdvancedExamplesTests {
    // 24-child-tasks.ts: decline, cancel with refunds, and restart payments.
    @Test func childTasks() async throws {
        let charged = Mutex<Set<String>>([]), refunds = AdvancedExampleLog<String>()
        let paymentOutcomes = AdvancedExampleLog<[String]>(), clock = TestClock()
        let payment = AdvancedPayment(name: "example.payment", version: 1,
            initial: { _ in .init(at: clock.now() + 100) }, phase: { task, runtime, context in
                let card = task.input.card
                if card.hasPrefix("expired") {
                    try await runtime.commit({ _, _ in .terminal(outcome: .failed(error: .init(message: "\(card) declined"))) }, context: context)
                    return
                }
                charged.withLock { _ = $0.insert(card) }
                try await runtime.sleep(until: task.checkpoint.at, context: context)
                try await runtime.commit({ _, _ in try completed(task.input) }, context: context)
            }, abort: { task, runtime, context in
                let refunded = charged.withLock { $0.remove(task.input.card) != nil }
                refunds.append("payment \(task.input.card) aborted\(refunded ? ", refunded" : "")")
                try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
            })
        let checkout = AdvancedCheckout(name: "example.checkout", version: 1, initial: { _ in .init() },
            phase: { task, runtime, context in
                switch task.checkpoint.phase {
                case .pay:
                    try await runtime.commit({ tx, _ in
                        var payments: [TaskID] = []
                        for card in task.input {
                            payments.append(try await tx.createTask(payment, input: .init(card: card),
                                options: .init(ownership: .task(taskId: task.id))))
                        }
                        return .waiting(checkpoint: try JSONValue(encoding: AdvancedCheckoutCheckpoint(phase: .decide, payments: payments)), on: payments, policy: .failFast)
                    }, context: context)
                case .decide:
                    let outcomes = try await runtime.outcomes(task.checkpoint.payments, context: context)
                    paymentOutcomes.append(outcomes.map(\.status))
                    try await runtime.commit({ _, _ in
                        outcomes.allSatisfy { $0.status == "completed" }
                            ? .terminal(outcome: .completed(result: "order placed"))
                            : .terminal(outcome: .failed(error: .init(message: "payment failed")))
                    }, context: context)
                }
            }, abort: { _, runtime, context in
                refunds.append("checkout aborted")
                try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
            })
        let registry = createRegistry()
        try registry.install(Extension(name: "checkout", tasks: [AnyTaskDefinition(payment), AnyTaskDefinition(checkout)]))
        let options = HarnessOptions(models: FakeDurableModels(), registry: registry, clock: clock)
        let directory = try advancedDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("session.sqlite").path
        let first = try await Harness.open(storage: SqliteStorage.open(path: path), options: options, context: .background)
        let root = try await first.root(context: .background)
        func start(_ cards: [String]) async throws -> TaskID {
            try await root.commit({ tx in try await tx.createTask(checkout, input: cards, options: .init(ownership: .conversation())) }, context: .background)
        }
        let declined = try await start(["visa-1", "expired-2", "visa-3", "visa-4"])
        #expect(try await first.waitForTask(id: declined, context: .background).outcome.status == "failed")
        #expect(paymentOutcomes.values.first == ["aborted", "failed", "aborted", "aborted"])
        #expect(charged.withLock { $0.isEmpty })
        let cancelled = try await start(["visa-5", "visa-6", "visa-7", "visa-8"])
        try first.resume()
        try await eventually { charged.withLock { $0.count == 4 } && clock.pendingSleeperCount == 4 }
        let graph = try await first.taskGraph(context: .background)
        let nodes = Array(graph.value.tasks.values)
        #expect(nodes.count == 5)
        #expect(nodes.first { $0.id == cancelled }?.state.status == "waiting")
        #expect(nodes.filter { $0.owner == cancelled }.count == 4)
        #expect(nodes.filter { $0.owner == cancelled }.allSatisfy { $0.kind == "example.payment" && $0.state.status == "running" })
        graph.dispose()
        _ = try await first.abortTask(id: cancelled, context: .background)
        #expect(try await first.waitForTask(id: cancelled, context: .background).outcome.status == "aborted")
        #expect(charged.withLock { $0.isEmpty })
        #expect(refunds.values.filter { $0.contains(", refunded") && ["visa-5", "visa-6", "visa-7", "visa-8"].contains(where: $0.contains) }.count == 4)
        #expect(refunds.values.last == "checkout aborted")
        let resumed = try await start(["visa-9", "visa-10", "visa-11", "visa-12"])
        try await eventually { charged.withLock { $0.count == 4 } && clock.pendingSleeperCount == 4 }
        try await first.close(context: .background)
        let reopened = try await Harness.open(storage: SqliteStorage.open(path: path), options: options, context: .background)
        clock.advance(by: 100)
        let outcome = try await reopened.waitForTask(id: resumed, context: .background).outcome
        #expect(outcome == .completed(result: "order placed"))
        #expect(paymentOutcomes.values.last == ["completed", "completed", "completed", "completed"])
        #expect(charged.withLock { $0 } == Set(["visa-9", "visa-10", "visa-11", "visa-12"]))
        try await reopened.close(context: .background)
    }

    // 25-compaction.ts: background summaries, a busy manual summary, and overflow.
    // The final request is already above 2000 tokens. It first gets a threshold
    // summary. The one-compaction rule then reports the injected overflow as
    // model_error. The upstream comment promises a retry, but this path cannot
    // make a second summary for the same request.
    @Test func compaction() async throws {
        let setup = HarnessChatSetup(options: .init(models: [.init(id: "tiny", contextWindow: 3000, maxTokens: 1000)]),
            settings: .init(compaction: .init(reserveTokens: 1000, keepRecentTokens: 400, backgroundTokens: 800)))
        let summaries = Mutex(0), overflow = Mutex(false), hold = Mutex<HarnessGatedResponse?>(nil)
        let route: FakeDurableResponseStep = .factory { transcript, options, state, model in
            if case .system(let system)? = transcript.messages.first, getSystemMessageText(system).contains("summarization") {
                let number = summaries.withLock { $0 += 1; return $0 }
                return chatAssistant("## Goal\nPlan a week in Lisbon (summary #\(number)).")
            }
            if overflow.withLock({ value in let old = value; value = false; return old }) {
                return chatAssistant("", reason: .error, error: "prompt is too long")
            }
            if let gated = hold.withLock({ value in let old = value; value = nil; return old }), case .factory(let respond) = gated.step {
                return try await respond(transcript, options, state, model)
            }
            let question = textOf(transcript.messages.last { $0.role == "user" }) ?? ""
            return chatAssistant("A detailed answer to \"\(question)\": " + String(repeating: "details ", count: 200))
        }
        setup.models.setResponses(Array(repeating: route, count: 100))
        let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: setup.models, registry: setup.registry, settings: setup.settingsProvider), context: .background)
        let root = try await harness.root(options: .init(agent: .init(model: .set(.init(provider: "faux", modelId: "tiny")))), context: .background)
        // The lines use the upstream show() format. The counts were checked
        // against Swift snapshots; the message text follows the source script.
        let summaryLine = "  user      The conversation history before this point was compacted into the foll"
        let systemLine = "  system    (system prompt)"
        let stayLine = "  assistant A detailed answer to \"Where should we stay?\": details details details "
        let eatLine = "  assistant A detailed answer to \"What should we eat?\": details details details de"
        let tripsLine = "  assistant A detailed answer to \"Which day trips?\": details details details detai"
        let museumsLine = "  assistant A detailed answer to \"Any museums?\": details details details details d"
        let nightlifeLine = "  assistant A detailed answer to \"Nightlife?\": details details details details det"
        let aroundLine = "  assistant A detailed answer to \"How do we get around?\": details details details "
        let packLine = "  assistant A detailed answer to \"What should we pack?\": details details details d"
        let expectedShows: [String: [String]] = [
            "Where should we stay?": [
                "after \"Where should we stay?\" (answered): 2 messages in context, 2 entries stored",
                "  user      Where should we stay?", stayLine],
            "What should we eat?": [
                "after \"What should we eat?\" (answered): 4 messages in context, 4 entries stored",
                "  user      Where should we stay?", stayLine, "  user      What should we eat?", eatLine],
            "Which day trips?": [
                "after \"Which day trips?\" (answered): 4 messages in context, 7 entries stored",
                "  (threshold compaction summary first)", summaryLine, eatLine,
                "  user      Which day trips?", tripsLine],
            "Any museums?": [
                "after \"Any museums?\" (answered): 7 messages in context, 10 entries stored",
                "  (threshold compaction summary first)", summaryLine, eatLine,
                "  user      Which day trips?", tripsLine, "  user      Any museums?", systemLine, museumsLine],
            "Nightlife?": [
                "after \"Nightlife?\" (answered): 5 messages in context, 14 entries stored",
                "  (threshold compaction summary first)", summaryLine, museumsLine,
                "  user      Nightlife?", systemLine, nightlifeLine],
            "What should we pack?": [
                "after \"What should we pack?\" (answered): 7 messages in context, 21 entries stored",
                "  (manual compaction summary first)", summaryLine, nightlifeLine,
                "  user      How do we get around?", aroundLine, "  user      What should we pack?", systemLine, packLine],
            "Summarize the plan for my partner": [
                "after \"Summarize the plan for my partner\" (model_error): 4 messages in context, 25 entries stored",
                "  (threshold compaction summary first)", summaryLine, packLine,
                "  user      Summarize the plan for my partner", systemLine]
        ]
        func ask(_ question: String, expectedStatus: String = "done", expectedReason: String? = nil) async throws -> ContextView {
            let record = try await root.submit(.input(content: .text(question)), context: .background).wait(context: .background)
            #expect(record.status == expectedStatus)
            #expect(record.reason == expectedReason)
            if expectedReason == "model_error" {
                #expect(try JSONValue(encoding: record.record)["detail"] == "prompt is too long")
            }
            let running = try await harness.snapshot(LiveDoc, conversationId: root.id, context: .background)?.compactions ?? []
            for task in running { _ = try await harness.waitForTask(id: task.taskId, context: .background) }
            let view = try await root.context(context: .background)
            #expect(try await allEntries(root).count >= view.entries.count)
            #expect(view.messages.contains { textOf($0)?.contains(question) == true })
            let show = try await advancedShow(root, label: "after \"\(question)\" (\(record.status == "done" ? "answered" : record.reason ?? ""))")
            #expect(show == expectedShows[question])
            return view
        }
        for question in ["Where should we stay?", "What should we eat?", "Which day trips?", "Any museums?", "Nightlife?"] { _ = try await ask(question) }
        #expect(summaries.withLock { $0 } > 0)
        let before = try await allEntries(root)
        #expect(before.contains { $0.kind == "pi.compaction" && $0.data?["reason"] == "threshold" })
        let gated = HarnessGatedResponse(message: chatAssistant("A detailed answer to \"How do we get around?\": " + String(repeating: "details ", count: 200)))
        hold.withLock { $0 = gated }
        let busy = try await root.submit(.input(content: .text("How do we get around?")), context: .background)
        await gated.reached.wait()
        let manual = try await root.compact(instructions: "Keep the hotel shortlist", context: .background)
        let manualOutcome = try await harness.waitForTask(id: manual, context: .background).outcome
        guard case .completed(let result, _) = manualOutcome else { throw TestDeadlineError() }
        let placement = try #require(try result.decode(CompactionResult.self).submissionId)
        let summary = try #require(try await harness.submission(id: placement, context: .background))
        #expect(try await summary.status(context: .background).status == "queued")
        gated.release()
        #expect(try await busy.wait(context: .background).status == "done")
        #expect(try await summary.wait(context: .background).status == "done")
        let entries = try await allEntries(root)
        #expect(Array(entries.prefix(before.count)) == before)
        #expect(entries.last?.kind == "pi.compaction")
        #expect(entries.last?.data?["reason"] == "manual")
        let manualView = try await root.context(context: .background)
        #expect(manualView.head?.kind == "pi.compaction")
        #expect(textOf(manualView.messages.first)?.contains("Plan a week in Lisbon") == true)
        #expect(manualView.messages.count < entries.count)
        let show = try await advancedShow(root, label: "after compact()")
        #expect(show == [
            "after compact(): 4 messages in context, 18 entries stored",
            "  (manual compaction summary first)", summaryLine, nightlifeLine,
            "  user      How do we get around?", aroundLine
        ])
        setup.updateSettings { $0.compaction?.backgroundTokens = 0 }
        _ = try await ask("What should we pack?")
        #expect(generationEstimateContext(view: try await root.context(context: .background)) > 2000)
        let thresholdCount = try await allEntries(root).filter { $0.kind == "pi.compaction" && $0.data?["reason"] == "threshold" }.count
        overflow.withLock { $0 = true }
        let afterOverflow = try await ask("Summarize the plan for my partner", expectedStatus: "unanswered", expectedReason: "model_error")
        let finalEntries = try await allEntries(root)
        #expect(finalEntries.filter { $0.kind == "pi.compaction" && $0.data?["reason"] == "threshold" }.count == thresholdCount + 1)
        #expect(!finalEntries.contains { $0.kind == "pi.compaction" && $0.data?["reason"] == "overflow" })
        #expect(afterOverflow.messages.count < finalEntries.count)
        let last = try #require(try finalEntries.last?.messages()?.first)
        if case .assistant(let failure) = last {
            #expect(failure.stopReason == .error)
            #expect(failure.errorMessage == "prompt is too long")
        } else { Issue.record("The last entry must contain the overflow error") }
        try await harness.close(context: .background)
    }

    // 31-reload-and-restart.ts: retain running code, then bind saved names.
    @Test func reloadAndRestart() async throws {
        let models = FakeDurableModels(), started = HarnessChatSignal(), release = HarnessChatSignal()
        func versioned(_ version: String, held: Bool = false) throws -> Extension {
            let tool = try advancedTool("version") { _, _, _ in
                if held { started.signal(); await release.wait() }
                return .init(content: [.text(TextContent(text: version))])
            }
            return Extension(name: "versioned", tools: [tool])
        }
        models.setResponses([.message(try advancedCall("version", id: "version-1")), .message(chatAssistant("Done.")),
            .message(try advancedCall("version", id: "version-2")), .message(chatAssistant("Done."))])
        let directory = try advancedDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("session.sqlite").path
        let registry = createRegistry(), v1 = try versioned("v1", held: true)
        try registry.install(v1)
        let first = try await Harness.open(storage: SqliteStorage.open(path: path), options: .init(models: models, registry: registry), context: .background)
        let root = try await first.root(options: .init(agent: .init(model: .set(.init(provider: "faux", modelId: "faux-1")), extensions: .set(.exact([v1])))), context: .background)
        let submission = try await root.submit(.input(content: .text("Which version?")), context: .background)
        await started.wait()
        try registry.install(versioned("v2"))
        release.signal()
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(try await advancedTexts(root, role: "toolResult").last == "v1")
        #expect(try await root.submit(.input(content: .text("And now?")), context: .background).wait(context: .background).status == "done")
        #expect(try await advancedTexts(root, role: "toolResult").last == "v2")
        try await first.close(context: .background)
        let nextRegistry = createRegistry()
        let reopened = try await Harness.open(storage: SqliteStorage.open(path: path), options: .init(models: models, registry: nextRegistry), context: .background)
        let restored = try await reopened.root(context: .background)
        #expect(try await restored.agent(context: .background).tools.map(\.name) == [])
        try nextRegistry.install(versioned("v3"))
        #expect(try await restored.agent(context: .background).tools.map(\.name) == ["version"])
        #expect(try await advancedTexts(restored, role: "toolResult") == ["v1", "v2"])
        try await reopened.close(context: .background)
    }
}
