import PiSwiftAI
import PiSwiftChord
import PiSwiftCodingAgentDurable
import PiSwiftDurable
import PiSwiftDurableTesting
import Testing

@Suite(.timeLimit(.minutes(1))) struct SubagentSelectionTests {
    @Test func childKeepsTypedModelFilterAndSeparateCallableTools() async throws {
        let setup = HarnessChatSetup()
        let subagent = try subagentExtension()
        let read = try ToolRegistration(name: "read", description: "read", parameters: ["type": "object"]) { _, _, _ in
            ToolExecutionResult(output: [])
        }
        let hidden = try ToolRegistration(name: "hidden", description: "hidden", parameters: ["type": "object"], callers: [.tools]) { _, _, _ in
            ToolExecutionResult(output: [])
        }
        try setup.registry.install(subagent)
        try setup.registry.install(Extension(name: "tools", tools: [read, hidden]))
        var call = chatAssistant("")
        call.content = [.toolCall(ToolCall(id: "delegate", name: "subagent", arguments: ["task": AnyCodable("child task")]))]
        call.stopReason = .toolUse
        let childAnswer = HarnessGatedResponse(message: chatAssistant("child answer"))
        setup.models.setResponses([.message(call), childAnswer.step, .message(chatAssistant("parent answer"))])
        let opened = try await openChat(setup: setup)
        try await opened.root.configure(change: .init(modelTools: .set(.exact([subagent.tools[0], read]))), context: .background)
        let input = try await opened.root.submit(.input(content: .text("go")), context: .background)
        await childAnswer.reached.wait()
        let childRecord = try #require(await opened.harness.commit({ tx in
            try await tx.scanConversations(.init(), limit: 10).items.first { $0.owner != nil }
        }, context: .background))
        let child = try #require(await opened.harness.conversation(id: childRecord.id, context: .background))
        let agent = try await child.agent(context: .background)
        #expect(agent.tools.map(\.name) == ["read"])
        #expect(agent.callable.map(\.name) == ["read", "hidden"])
        #expect(try await opened.harness.snapshot(AgentDoc, conversationId: child.id, context: .background)?.modelTools ==
            .exact(["subagent", "read"]))
        let view = try await child.viewState(context: .background)
        #expect(try decodeAgentOf(view.value).modelTools == .exact(["subagent", "read"]))
        view.dispose()
        #expect(subagent.tools[0].replay == .safe)
        childAnswer.release()
        #expect(try await input.wait(context: .background).status == "done")
        try await opened.harness.close(context: .background)
    }
}
