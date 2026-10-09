import PiSwiftChord
import PiSwiftCodingAgentDurable
import PiSwiftDurable
import Synchronization
import Testing

private func conversationView(docs: [String: JSONObject] = [:]) -> ConversationView {
    ConversationView(conversation: .init(id: rootConversationID), entries: [], docs: docs)
}

@Test func agentOfReturnsStoredAgent() throws {
    let agent = PiSwiftDurable.AgentState(
        model: ModelRef(provider: "provider", modelId: "model"),
        thinkingLevel: .off,
        extensions: .exact(["tools"]), tools: .remove(["write"]),
        instructions: "Read the file.", cwd: "/project"
    )
    let document = try #require(JSONValue(encoding: agent).objectValue)
    #expect(agentOf(conversationView(docs: ["pi.agent": document])) == agent)
}

@Test func agentOfReturnsEmptyStateWithoutDocument() {
    #expect(agentOf(conversationView()) == PiSwiftDurable.AgentState())
    #expect(agentOf(conversationView(docs: ["pi.other": ["cwd": .string("/other")]])) == PiSwiftDurable.AgentState())
}

@Test(arguments: [
    ["model": .string("bad model")],
    ["thinkingLevel": .string("bad level")],
    ["cwd": .number(1)],
    ["instructions": .string("Read."), "tools": .bool(false)]
] as [JSONObject])
func agentOfReturnsEmptyStateWhenDocumentCannotBeDecoded(document: JSONObject) {
    #expect(agentOf(conversationView(docs: ["pi.agent": document])) == PiSwiftDurable.AgentState())
}

@Test func agentOfAcceptsEmptyAndUnknownDocumentFields() {
    #expect(agentOf(conversationView(docs: ["pi.agent": [:]])) == PiSwiftDurable.AgentState())
    #expect(agentOf(conversationView(docs: ["pi.agent": ["futureField": .bool(true)]])) == PiSwiftDurable.AgentState())
}

@Test func durableViewKeepsPlainValuesThroughJSON() throws {
    let model = ModelSummary(provider: "provider", modelId: "model", name: "Model", contextWindow: 128_000)
    let summary = ConversationSummary(id: rootConversationID, label: "main")
    let view = DurableView(
        session: .init(id: "session", directory: "/sessions/session", cwd: "/project"),
        conversation: conversationView(), conversations: [summary], models: [model],
        notices: [Notice(id: 1, level: .warning, message: "Select a model.")], tasks: TaskGraph()
    )
    let decoded = try JSONValue(encoding: view).decode(DurableView.self)
    #expect(decoded == view)
    #expect(decoded.session.id == "session")
    #expect(decoded.conversations.first?.title == nil)
    #expect(decoded.tasks?.tasks.isEmpty == true)
    #expect(Notice.Level(rawValue: "error") == .error)
    #expect(SubmitWhenBusy(rawValue: "followUp") == .followUp)
    #expect(SubmitWhenBusy(rawValue: "reject") == nil)
}

@Test func durableViewDefaultsLeaveTaskPanelClosed() {
    let view = DurableView(
        session: .init(id: "session", directory: "/sessions/session", cwd: "/project"),
        conversation: conversationView(), conversations: [], models: []
    )
    #expect(view.notices.isEmpty)
    #expect(view.tasks == nil)
    #expect(OpenDurableOptions().cwd == nil)
    #expect(OpenDurableOptions().continueSession == false)
    #expect(OpenDurableOptions(cwd: "/project", continueSession: true).continueSession)
}

@Test func durableViewSubscriptionCancelsOnceAcrossTasks() async {
    let calls = Mutex(0)
    let subscription = DurableViewSubscription { calls.withLock { $0 += 1 } }
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<32 {
            group.addTask { subscription.cancel() }
        }
    }
    subscription.cancel()
    #expect(calls.withLock { $0 } == 1)
}

@Test func durableViewSubscriptionDoesNotCancelOnRelease() {
    let calls = Mutex(0)
    do {
        let subscription = DurableViewSubscription { calls.withLock { $0 += 1 } }
        _ = subscription
    }
    #expect(calls.withLock { $0 } == 0)
}
