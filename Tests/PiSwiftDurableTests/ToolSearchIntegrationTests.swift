import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting
import Testing

private func searchIntegrationTool(_ name: String, _ description: String, deferred: Bool? = nil) throws -> ToolRegistration {
    try ToolRegistration(name: name, description: description, parameters: [
        "type": "object", "properties": ["number": ["type": "number", "description": "Issue number"]]
    ], deferred: deferred) { _, _, _ in
        ToolExecutionResult(output: [.text(TextContent(text: "\(name) ran"))])
    }
}

private func searchIntegrationCall(_ name: String, _ arguments: [String: Any] = [:], id: String = "c1") -> AssistantMessage {
    var message = chatAssistant("")
    message.content = [.toolCall(ToolCall(id: id, name: name, arguments: arguments.mapValues { AnyCodable($0) }))]
    message.stopReason = .toolUse
    return message
}

private func searchIntegrationSetup() throws -> HarnessChatSetup {
    let setup = HarnessChatSetup()
    for tool in [
        try searchIntegrationTool("alpha", "Alpha tool"),
        try searchIntegrationTool("github_get_issue", "Get a GitHub issue by number", deferred: true),
        try searchIntegrationTool("github_list_repos", "List the repositories of a user", deferred: true),
        try searchIntegrationTool("omega", "Omega tool")
    ] {
        try setup.registry.install(Extension(name: "tool:\(tool.name)", tools: [tool]))
    }
    try setup.registry.install(createToolSearchExtension())
    return setup
}

private func searchOffered(_ conversation: Conversation) async throws -> [String] {
    try await conversation.agent(context: .background).tools.map(\.name)
}

private func searchSystemMessages(_ entries: [EntryRecord]) -> [JSONValue] {
    entries.filter { $0.kind == "pi.system" }.compactMap { $0.model?.first }
}

private func searchAddedNames(_ message: JSONValue) -> [String]? {
    message["toolsAdded"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
}

private func searchResultTexts(_ entries: [EntryRecord]) throws -> [String] {
    try entries.filter { $0.kind == "pi.tool-result" }.compactMap { try textOf($0.messages()?.first) }
}

private func searchSubmit(_ conversation: Conversation, _ text: String = "go") async throws {
    let input = try await conversation.submit(.input(content: .text(text)), context: .background)
    #expect(try await input.wait(context: .background).status == "done")
}

@Suite(.timeLimit(.minutes(1))) struct ToolSearchIntegrationTests {
    @Test func searchLoadsDeferredToolAndAppendsDeclaration() async throws {
        let setup = try searchIntegrationSetup()
        setup.models.setResponses([
            .message(searchIntegrationCall("tool_search", ["query": "github issue", "limit": 1])),
            .message(searchIntegrationCall("github_get_issue", ["number": 42], id: "c2")),
            .message(chatAssistant("done"))
        ])
        let opened = try await openChat(setup: setup)
        #expect(try await searchOffered(opened.root) == ["alpha", "omega", "tool_search"])
        let initial = try await opened.root.agent(context: .background)
        #expect(initial.deferred.map(\.name) == ["github_get_issue", "github_list_repos"])
        #expect(initial.callable.map(\.name).contains("github_get_issue"))
        try await searchSubmit(opened.root)
        let entries = try await allEntries(opened.root)
        #expect(try searchResultTexts(entries) == [
            "Loaded 1 tool. They are available from your next call:\n- github_get_issue: Get a GitHub issue by number",
            "github_get_issue ran"
        ])
        let search = try #require(entries.first { $0.kind == "pi.tool-result" }?.model?.first)
        #expect(search["details"] == .object(["loaded": ["github_get_issue"]]))
        #expect(try await opened.harness.snapshot(AgentDoc, conversationId: opened.root.id, context: .background)?.modelTools ==
            .edit(add: ["github_get_issue"]))
        #expect(try await searchOffered(opened.root) == ["alpha", "omega", "tool_search", "github_get_issue"])
        #expect(try await opened.root.agent(context: .background).deferred.map(\.name) == ["github_list_repos"])
        let system = searchSystemMessages(entries)
        #expect(system.count == 2)
        #expect(searchAddedNames(try #require(system.first)) == ["alpha", "omega", "tool_search"])
        let load = try #require(system.last)
        #expect(searchAddedNames(load) == ["github_get_issue"])
        #expect(load["toolsRemoved"] == nil)
        try await opened.harness.close(context: .background)
    }

    @Test func appendsToolsInLoadOrder() async throws {
        let setup = try searchIntegrationSetup()
        setup.models.setResponses([
            .message(searchIntegrationCall("tool_search", ["query": "repositories", "limit": 1])),
            .message(searchIntegrationCall("tool_search", ["query": "issue", "limit": 1], id: "c2")),
            .message(chatAssistant("done"))
        ])
        let opened = try await openChat(setup: setup)
        try await searchSubmit(opened.root)
        #expect(try await searchOffered(opened.root) == ["alpha", "omega", "tool_search", "github_list_repos", "github_get_issue"])
        let loads = searchSystemMessages(try await allEntries(opened.root)).dropFirst()
        #expect(loads.map(searchAddedNames) == [["github_list_repos"], ["github_get_issue"]])
        #expect(loads.allSatisfy { $0["toolsRemoved"] == nil })
        try await opened.harness.close(context: .background)
    }

    @Test func recordsNamesAndLoadClearsRemoval() async throws {
        let setup = try searchIntegrationSetup()
        let grow = try ToolRegistration(name: "grow", description: "grow", parameters: ["type": "object"]) { _, _, _ in
            ToolExecutionResult(output: [], control: .init(addTools: ["github_get_issue", "alpha", "ghost"]))
        }
        try setup.registry.install(Extension(name: "tool:grow", tools: [grow]))
        setup.models.setResponses([.message(searchIntegrationCall("grow")), .message(chatAssistant("done")),
            .message(searchIntegrationCall("grow")), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup)
        try await searchSubmit(opened.root)
        let loaded = ModelToolSelection.edit(add: ["github_get_issue", "alpha", "ghost"])
        #expect(try await opened.harness.snapshot(AgentDoc, conversationId: opened.root.id, context: .background)?.modelTools == loaded)
        #expect(try await searchOffered(opened.root) == ["alpha", "omega", "tool_search", "grow", "github_get_issue"])
        let issue = try #require(await opened.root.agent(context: .background).callable.first { $0.name == "github_get_issue" })
        try await opened.root.configure(change: .init(modelTools: .set(.edit(add: [issue], remove: [issue]))), context: .background)
        #expect(try await !searchOffered(opened.root).contains("github_get_issue"))
        try await searchSubmit(opened.root, "again")
        #expect(try await opened.harness.snapshot(AgentDoc, conversationId: opened.root.id, context: .background)?.modelTools == loaded)
        #expect(try await searchOffered(opened.root).contains("github_get_issue"))
        try await opened.harness.close(context: .background)
    }

    @Test func retainsLoadAcrossExtensionLossAndAppendsToExplicitSelection() async throws {
        let setup = try searchIntegrationSetup()
        let issue = try searchIntegrationTool("github_get_issue", "Get a GitHub issue by number", deferred: true)
        setup.models.setResponses([.message(searchIntegrationCall("tool_search", ["query": "github issue", "limit": 1])),
            .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup)
        try await searchSubmit(opened.root)
        try setup.registry.install(Extension(name: "tool:github_get_issue", tools: []))
        #expect(try await !searchOffered(opened.root).contains("github_get_issue"))
        try setup.registry.install(Extension(name: "tool:github_get_issue", tools: [issue]))
        #expect(try await searchOffered(opened.root).contains("github_get_issue"))
        let agent = try await opened.root.agent(context: .background)
        let alpha = try #require(agent.tools.first { $0.name == "alpha" })
        let search = try #require(agent.tools.first { $0.name == "tool_search" })
        try await opened.root.configure(change: .init(modelTools: .set(.exact([alpha, search]))), context: .background)
        setup.models.setResponses([.message(searchIntegrationCall("tool_search", ["query": "repositories", "limit": 1])),
            .message(chatAssistant("done"))])
        try await searchSubmit(opened.root, "more")
        #expect(try await opened.harness.snapshot(AgentDoc, conversationId: opened.root.id, context: .background)?.modelTools ==
            .exact(["alpha", "tool_search", "github_list_repos"]))
        #expect(try await searchOffered(opened.root) == ["alpha", "tool_search", "github_list_repos"])
        try await opened.harness.close(context: .background)
    }

    @Test func retainsLoadsPerBranchAndInResetBaseline() async throws {
        let setup = try searchIntegrationSetup()
        setup.models.setResponses([.message(searchIntegrationCall("tool_search", ["query": "github issue", "limit": 1])),
            .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup)
        try await searchSubmit(opened.root)
        let entries = try await allEntries(opened.root)
        let first = try #require(entries.first)
        let last = try #require(entries.last)
        let before = try await opened.root.fork(at: first.id, options: .init(ownership: .ownerless()), context: .background)
        let after = try await opened.root.fork(at: last.id, options: .init(ownership: .ownerless()), context: .background)
        #expect(try await !searchOffered(before).contains("github_get_issue"))
        #expect(try await searchOffered(after).contains("github_get_issue"))
        try await opened.root.reset(context: .background)
        setup.models.setResponses([.message(chatAssistant("done"))])
        try await searchSubmit(opened.root, "fresh")
        let baseline = try #require(searchSystemMessages(try await allEntries(opened.root)).last)
        #expect(searchAddedNames(baseline) == ["alpha", "omega", "tool_search", "github_get_issue"])
        try await opened.harness.close(context: .background)
    }

    @Test func unrelatedQueryLoadsNothing() async throws {
        let setup = try searchIntegrationSetup()
        setup.models.setResponses([.message(searchIntegrationCall("tool_search", ["query": "weather forecast"])),
            .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup)
        try await searchSubmit(opened.root)
        let entries = try await allEntries(opened.root)
        #expect(try searchResultTexts(entries) == ["No matching tools found."])
        let search = try #require(entries.first { $0.kind == "pi.tool-result" }?.model?.first)
        #expect(search["details"] == .object(["loaded": []]))
        #expect(try await opened.harness.snapshot(AgentDoc, conversationId: opened.root.id, context: .background)?.modelTools == nil)
        #expect(try await searchOffered(opened.root) == ["alpha", "omega", "tool_search"])
        try await opened.harness.close(context: .background)
    }

    @Test func deferredLoadSurvivesSQLiteReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let path = directory.appendingPathComponent("tool-search.sqlite").path
        let setup = try searchIntegrationSetup()
        setup.models.setResponses([.message(searchIntegrationCall("tool_search", ["query": "github issue", "limit": 1])),
            .message(chatAssistant("done"))])
        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        try await searchSubmit(first.root)
        try await first.harness.close(context: .background)
        let second = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        #expect(try await second.harness.snapshot(AgentDoc, conversationId: second.root.id, context: .background)?.modelTools ==
            .edit(add: ["github_get_issue"]))
        #expect(try await searchOffered(second.root) == ["alpha", "omega", "tool_search", "github_get_issue"])
        #expect(try await second.root.agent(context: .background).deferred.map(\.name) == ["github_list_repos"])
        try await second.harness.close(context: .background)
    }
}
