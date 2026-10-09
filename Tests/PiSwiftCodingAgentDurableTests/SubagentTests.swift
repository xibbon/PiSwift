import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftCodingAgentDurable
import PiSwiftDurable
import PiSwiftDurableTesting
import Synchronization
import Testing

private func subagentCall() -> AssistantMessage {
    var message = chatAssistant("")
    message.content = [.toolCall(ToolCall(id: "delegate", name: "subagent", arguments: ["task": AnyCodable("child task")]))]
    message.stopReason = .toolUse
    return message
}

private final class SubagentInvocations: Sendable {
    private let state = Mutex<[TaskID]>([])
    var values: [TaskID] { state.withLock { $0 } }
    func append(_ taskId: TaskID) { state.withLock { $0.append(taskId) } }
}

private func subagentSetup(invocations: SubagentInvocations = SubagentInvocations()) throws -> HarnessChatSetup {
    let setup = HarnessChatSetup(settings: .init(retry: .init(enabled: false)))
    var extensionValue = try subagentExtension()
    let execute = extensionValue.tools[0].execute
    extensionValue.tools[0].execute = { args, api, context in
        invocations.append(api.taskId)
        return try await execute(args, api, context)
    }
    try setup.registry.install(extensionValue)
    try setup.registry.install(Extension(name: "other", tools: [try defineTool(
        name: "other", description: "Other tool", parameters: ["type": "object"], args: SubagentEmptyInput.self
    ) { _, _, _ in ToolExecutionResult(content: []) }]))
    return setup
}

private struct SubagentEmptyInput: Decodable, Sendable {}

private func subagentChild(_ harness: Harness, owner: TaskID) async throws -> ConversationRecord {
    let children = try await harness.commit({ tx in
        try await tx.scanConversations(.init(ownerTaskId: owner), limit: 10).items
    }, context: .background)
    #expect(children.count == 1)
    return try #require(children.first)
}

private func subagentResult(_ root: Conversation) async throws -> (EntryRecord, ToolResultMessage) {
    let entry = try #require(await allEntries(root).first { $0.kind == toolResultEntry.kind })
    guard case .toolResult(let message) = try entry.messages()?.first else {
        throw TaskDefinitionError("Expected a tool result")
    }
    return (entry, message)
}

@Suite(.timeLimit(.minutes(1))) struct SubagentTests {
    @Test func declarationMatchesUpstream() throws {
        let extensionValue = try subagentExtension()
        #expect(extensionValue.name == "subagent")
        #expect(extensionValue.tools.count == 1)
        let tool = try #require(extensionValue.tools.first)
        #expect(tool.name == "subagent")
        #expect(tool.description == "Delegate a self-contained task to a subagent with the same tools and get its answer back. Give it everything it needs to know; it does not see this conversation.")
        #expect(tool.replay == .safe)
        #expect(tool.orderedDeclaration["parameters"] == [
            "type": "object", "properties": ["task": ["description": "What the subagent should do", "type": "string"]],
            "required": ["task"],
        ])
    }

    @Test func childOwnershipToolsAnswerAndDetails() async throws {
        let invocations = SubagentInvocations(), setup = try subagentSetup(invocations: invocations)
        var answer = chatAssistant("")
        answer.content = [.text(TextContent(text: "first")), .thinking(ThinkingContent(thinking: "hidden")), .text(TextContent(text: "second"))]
        let gate = HarnessGatedResponse(message: answer)
        setup.models.setResponses([.message(subagentCall()), gate.step, .message(chatAssistant("parent answer"))])
        let opened = try await openChat(setup: setup)
        try await opened.root.configure(change: .init(instructions: .set("inherited instructions")), context: .background)
        let input = try await opened.root.submit(.input(content: .text("parent task")), context: .background)
        await gate.reached.wait()
        let owner = try #require(invocations.values.first)
        let childRecord = try await subagentChild(opened.harness, owner: owner)
        let child = try #require(await opened.harness.conversation(id: childRecord.id, context: .background))
        #expect(childRecord.owner?.taskId == owner)
        #expect(childRecord.owner?.conversationId == opened.root.id)
        let agent = try await child.agent(context: .background)
        #expect(agent.model == ModelRef(provider: "faux", modelId: "faux-1"))
        #expect(agent.instructions == "inherited instructions")
        #expect(!agent.extensions.contains { $0.name == "subagent" })
        #expect(agent.tools.map(\.name) == ["other"])
        #expect(try await opened.root.agent(context: .background).tools.map(\.name) == ["subagent", "other"])
        let live = try #require(await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background))
        #expect(live.tools?.first?.details == ["conversationId": .number(Double(child.id.rawValue))])
        let user = try #require(await allEntries(child).first { $0.kind == userEntry.kind })
        #expect(try textOf(user.messages()?.first) == "child task")
        gate.release()
        #expect(try await input.wait(context: .background).status == "done")
        let result = try await subagentResult(opened.root).1
        #expect(textOf(.toolResult(result)) == "firstsecond")
        #expect(result.isError == false)
        #expect(try durableJSON(fromFoundation: #require(result.details).value) == ["conversationId": .number(Double(child.id.rawValue))])
        #expect(try await opened.harness.commit({ tx in
            try await tx.submissionByRequest(child.id, requestId: "subagent:\(owner.rawValue)")?.status
        }, context: .background) == "done")
        #expect(try await opened.harness.conversation(id: child.id, context: .background) != nil)
        try await opened.harness.close(context: .background)
    }

    @Test func sqliteReopenUsesSameChildAndRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("subagent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("session.sqlite").path
        let invocations = SubagentInvocations(), setup = try subagentSetup(invocations: invocations)
        let hold = HarnessUnanswered()
        setup.models.setResponses([.message(subagentCall()), hold.step, .message(chatAssistant("child answer")), .message(chatAssistant("parent answer"))])
        var opened = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        let input = try await opened.root.submit(.input(content: .text("parent task")), context: .background)
        await hold.reached.wait()
        let owner = try #require(invocations.values.first)
        let originalChild = try await subagentChild(opened.harness, owner: owner)
        let requestId = "subagent:\(owner.rawValue)"
        let originalRequest = try #require(await opened.harness.commit({ tx in
            try await tx.submissionByRequest(originalChild.id, requestId: requestId)
        }, context: .background))
        try await opened.harness.close(context: .background)
        opened = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        let resumed = try #require(await opened.harness.submission(id: input.id, context: .background))
        #expect(try await resumed.wait(context: .background).status == "done")
        #expect(invocations.values == [owner, owner])
        #expect(try await subagentChild(opened.harness, owner: owner).id == originalChild.id)
        let replayed = try #require(await opened.harness.commit({ tx in
            try await tx.submissionByRequest(originalChild.id, requestId: requestId)
        }, context: .background))
        #expect(replayed.id == originalRequest.id)
        #expect(replayed.status == "done")
        let child = try #require(await opened.harness.conversation(id: originalChild.id, context: .background))
        #expect(try await allEntries(child).filter { $0.kind == userEntry.kind }.count == 1)
        #expect(try textOf(.toolResult(await subagentResult(opened.root).1)) == "child answer")
        try await opened.harness.close(context: .background)
    }

    @Test func unansweredChildFailsWithStatus() async throws {
        let invocations = SubagentInvocations(), setup = try subagentSetup(invocations: invocations)
        setup.models.setResponses([.message(subagentCall()), .message(chatAssistant("", reason: .error, error: "Child model failed")), .message(chatAssistant("parent answer"))])
        let opened = try await openChat(setup: setup)
        #expect(try await opened.root.submit(.input(content: .text("parent task")), context: .background).wait(context: .background).status == "done")
        let owner = try #require(invocations.values.first)
        let child = try await subagentChild(opened.harness, owner: owner)
        let result = try await subagentResult(opened.root)
        #expect(result.1.isError == true)
        #expect(result.0.data?["diagnostics"]?[0]?["message"] == .string("Subagent \(child.id.rawValue) failed: unanswered"))
        #expect(try durableJSON(fromFoundation: #require(result.1.details).value) == ["conversationId": .number(Double(child.id.rawValue))])
        try await opened.harness.close(context: .background)
    }

    @Test func abortingParentAbortsChildWork() async throws {
        let invocations = SubagentInvocations(), setup = try subagentSetup(invocations: invocations)
        let hold = HarnessUnanswered()
        setup.models.setResponses([.message(subagentCall()), hold.step])
        let opened = try await openChat(setup: setup)
        let input = try await opened.root.submit(.input(content: .text("parent task")), context: .background)
        await hold.reached.wait()
        let owner = try #require(invocations.values.first)
        let childRecord = try await subagentChild(opened.harness, owner: owner)
        try await opened.root.abort(context: .background)
        #expect(try await input.wait(context: .background).status == "unanswered")
        #expect(try await opened.harness.waitForTask(id: owner, context: .background).outcome.status == "aborted")
        let request = try #require(await opened.harness.commit({ tx in
            try await tx.submissionByRequest(childRecord.id, requestId: "subagent:\(owner.rawValue)")
        }, context: .background))
        #expect(request.status == "unanswered")
        if case .input(_, _, _, .unanswered(let reason, _, _, _)) = request { #expect(reason == "aborted") }
        else { Issue.record("Expected aborted child input") }
        let child = try #require(await opened.harness.conversation(id: childRecord.id, context: .background))
        #expect(try await opened.harness.snapshot(LiveDoc, conversationId: child.id, context: .background) == LiveState())
        #expect(try await child.agent(context: .background).tools.map(\.name) == ["other"])
        try await opened.harness.close(context: .background)
    }
}
