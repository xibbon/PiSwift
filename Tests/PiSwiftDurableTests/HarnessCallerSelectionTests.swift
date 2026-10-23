import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting
import Synchronization
import Testing

private func selectionTool(_ name: String, callers: [ToolCaller]? = nil) throws -> ToolRegistration {
    try ToolRegistration(name: name, description: name, parameters: ["type": "object"], callers: callers) { _, _, _ in
        ToolExecutionResult(output: [.text(TextContent(text: "\(name) ran"))])
    }
}

private func selectionCall(_ name: String) -> AssistantMessage {
    var message = chatAssistant("")
    message.content = [.toolCall(ToolCall(id: "selection-call", name: name, arguments: [:]))]
    message.stopReason = .toolUse
    return message
}

@Suite(.timeLimit(.minutes(1))) struct HarnessCallerSelectionTests {
    @Test func separatesCallerListsAfterCompositionAndWrappers() throws {
        let registry = createRegistry()
        let model = try selectionTool("model", callers: [.model])
        let nested = try selectionTool("nested", callers: [.tools])
        let both = try selectionTool("both")
        let explicitBoth = try selectionTool("explicit", callers: [.model, .tools])
        let neither = try selectionTool("neither", callers: [])
        try registry.install(Extension(name: "tools", tools: [model, nested, both, explicitBoth, neither]))
        try registry.install(Extension(name: "wrap", wraps: [.tool("both", { var tool = $0; tool.callers = [.tools]; return tool })]))
        let agent = resolveAgent(snapshot: registry.snapshot())
        #expect(agent.tools.map(\.name) == ["model", "explicit"])
        #expect(agent.callable.map(\.name) == ["nested", "both", "explicit"])
        #expect(registry.snapshot().tools().map { $0.tool.name } == ["model", "nested", "both", "explicit", "neither"])
    }

    @Test func modelFilterCannotWidenEnabledOrCallerSelection() throws {
        let registry = createRegistry()
        try registry.install(Extension(name: "tools", tools: [try selectionTool("read"), try selectionTool("bash"),
            try selectionTool("hidden", callers: [.tools])]))
        let snapshot = registry.snapshot()
        let exact = resolveAgent(state: .init(tools: .remove(["bash"]),
            modelTools: .exact(["bash", "hidden", "missing", "read", "read"])), snapshot: snapshot)
        #expect(exact.tools.map(\.name) == ["read"])
        #expect(exact.callable.map(\.name) == ["read", "hidden"])
        let removed = resolveAgent(state: .init(modelTools: .edit(remove: ["read"])), snapshot: snapshot)
        #expect(removed.tools.map(\.name) == ["bash"])
        #expect(removed.callable.map(\.name) == ["read", "bash", "hidden"])
        let added = resolveAgent(state: .init(modelTools: .edit(add: ["read", "missing", "hidden"], remove: ["read"])), snapshot: snapshot)
        #expect(added.tools.map(\.name) == ["bash"])
    }

    @Test func modelFilterHasTypedWireShapeAndRejectsInvalidValues() throws {
        let filters: [ModelToolSelection] = [.exact(["read", "bash"]), .edit(), .edit(add: []),
            .edit(remove: ["read"]), .edit(add: ["bash"], remove: ["read"])]
        for filter in filters {
            let state = AgentState(modelTools: filter)
            #expect(try JSONValue(encoding: state).decode(AgentState.self) == state)
        }
        #expect(try JSONValue(encoding: AgentState(modelTools: .edit(add: ["bash"], remove: ["read"])))["modelTools"] ==
            .object(["add": ["bash"], "remove": ["read"]]))
        for value: JSONValue in [.bool(false), .string("read"), .array([.number(1)]), .object(["remove": .null]), .object(["add": .bool(false)])] {
            #expect(throws: (any Error).self) { try JSONValue.object(["modelTools": value]).decode(AgentState.self) }
        }
    }

    @Test func configureReplacesAndClearsModelFilter() async throws {
        let setup = HarnessChatSetup()
        let read = try selectionTool("read"), bash = try selectionTool("bash")
        try setup.registry.install(Extension(name: "tools", tools: [read, bash]))
        let opened = try await openChat(setup: setup)
        try await opened.root.configure(change: .init(modelTools: .set(.exact([bash, read, bash]))), context: .background)
        #expect(try await opened.root.agent(context: .background).tools.map(\.name) == ["bash", "read"])
        #expect(try await opened.root.agent(context: .background).callable.map(\.name) == ["read", "bash"])
        try await opened.root.configure(change: .init(modelTools: .set(.edit(remove: [bash]))), context: .background)
        #expect(try await opened.harness.snapshot(AgentDoc, conversationId: opened.root.id, context: .background)?.modelTools == .edit(remove: ["bash"]))
        #expect(try await opened.root.agent(context: .background).tools.map(\.name) == ["read"])
        try await opened.root.configure(change: .init(modelTools: .clear), context: .background)
        #expect(try await opened.root.agent(context: .background).tools.map(\.name) == ["read", "bash"])
        try await opened.harness.close(context: .background)
    }

    @Test func addToolsUpdatesBothFiltersAndKeepsNameIdentity() throws {
        var state = AgentState(tools: .exact(["grow"]), modelTools: .exact(["grow"]))
        addAgentTools(&state, ["extra", "extra", "\u{e9}", "e\u{301}"])
        #expect(state.tools == .exact(["grow", "extra", "\u{e9}", "e\u{301}"]))
        #expect(state.modelTools == .exact(["grow", "extra", "\u{e9}", "e\u{301}"]))
        state = AgentState(tools: .remove(["extra", "stay"]), modelTools: .edit(add: ["old"], remove: ["extra", "stay"]))
        addAgentTools(&state, ["extra", "extra"])
        #expect(state.tools == .remove(["stay"]))
        #expect(state.modelTools == .edit(add: ["old", "extra"], remove: ["stay"]))
        state = AgentState()
        addAgentTools(&state, ["unknown"])
        #expect(state.tools == nil)
        #expect(state.modelTools == .edit(add: ["unknown"]))
    }

    @Test func unavailableModelCallDoesNotExecuteHiddenTool() async throws {
        let setup = HarnessChatSetup()
        let read = try selectionTool("read"), bash = try selectionTool("bash")
        try setup.registry.install(Extension(name: "tools", tools: [read, bash]))
        setup.models.setResponses([.message(selectionCall("bash")), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup)
        try await opened.root.configure(change: .init(modelTools: .set(.exact([read]))), context: .background)
        let input = try await opened.root.submit(.input(content: .text("go")), context: .background)
        #expect(try await input.wait(context: .background).status == "done")
        let result = try #require(await allEntries(opened.root).first { $0.kind == "pi.tool-result" })
        #expect(try textOf(result.messages()?.first)?.contains("Tool bash is not available") == true)
        try await opened.harness.close(context: .background)
    }

    @Test func modelControlAddsToStoredModelSelection() async throws {
        let setup = HarnessChatSetup()
        let extra = try selectionTool("extra")
        let grow = try ToolRegistration(name: "grow", description: "grow", parameters: ["type": "object"]) { _, _, _ in
            ToolExecutionResult(output: [], control: .init(addTools: ["extra"]))
        }
        try setup.registry.install(Extension(name: "tools", tools: [extra, grow]))
        setup.models.setResponses([.message(selectionCall("grow")), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup)
        try await opened.root.configure(change: .init(modelTools: .set(.exact([grow]))), context: .background)
        let input = try await opened.root.submit(.input(content: .text("go")), context: .background)
        #expect(try await input.wait(context: .background).status == "done")
        #expect(try await opened.harness.snapshot(AgentDoc, conversationId: opened.root.id, context: .background)?.modelTools == .exact(["grow", "extra"]))
        #expect(try await opened.root.agent(context: .background).tools.map(\.name) == ["grow", "extra"])
        try await opened.harness.close(context: .background)
    }
    @Test func storedModelFilterSurvivesForkAndSQLiteReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let path = directory.appendingPathComponent("selection.sqlite").path
        let setup = HarnessChatSetup()
        let read = try selectionTool("read"), bash = try selectionTool("bash")
        try setup.registry.install(Extension(name: "tools", tools: [read, bash]))
        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        try await first.root.configure(change: .init(modelTools: .set(.edit(add: [read], remove: [bash]))), context: .background)
        let entry = try await first.root.commit({ tx in
            try await tx.appendEntry(first.root.id, value: EntryDraft(kind: "note", data: "fork here"))
        }, context: .background)
        try await first.root.configure(change: .init(modelTools: .set(.exact([bash]))), context: .background)
        let fork = try await first.root.fork(at: entry.id, options: .init(ownership: .ownerless()), context: .background)
        #expect(try await first.harness.snapshot(AgentDoc, conversationId: fork.id, context: .background)?.modelTools ==
            .edit(add: ["read"], remove: ["bash"]))
        try await first.harness.close(context: .background)
        let second = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        let reopenedFork = try #require(await second.harness.conversation(id: fork.id, context: .background))
        #expect(try await second.root.agent(context: .background).tools.map(\.name) == ["bash"])
        #expect(try await reopenedFork.agent(context: .background).tools.map(\.name) == ["read"])
        #expect(try await reopenedFork.agent(context: .background).callable.map(\.name) == ["read", "bash"])
        try await second.harness.close(context: .background)
    }

    @Test(arguments: [0, 1, 2]) func nestedCallsUseCallableList(mode: Int) async throws {
        let setup = HarnessChatSetup()
        let script = try selectionTool("script", callers: [.model])
        let hidden = try selectionTool("hidden", callers: [.tools])
        let both = try selectionTool("both")
        let received = Mutex<[String: NestedToolExecutionResult]>([:])
        let probe = try ToolRegistration(name: "probe", description: "probe", parameters: ["type": "object"]) { _, api, context in
            for name in ["script", "hidden", "both"] {
                let result = try await api.executeTool(name, arguments: [:], context: context)
                received.withLock { $0[name] = result }
            }
            return ToolExecutionResult(output: [])
        }
        try setup.registry.install(Extension(name: "tools", tools: [script, hidden, both, probe]))
        setup.models.setResponses([.message(selectionCall("probe")), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup)
        if mode == 1 {
            try await opened.root.configure(change: .init(modelTools: .set(.exact([probe]))), context: .background)
        } else if mode == 2 {
            try await opened.root.configure(change: .init(tools: .set(.remove([both])),
                modelTools: .set(.exact([both, probe]))), context: .background)
        }
        let agent = try await opened.root.agent(context: .background)
        #expect(agent.tools.map(\.name) == (mode == 0 ? ["script", "both", "probe"] : ["probe"]))
        #expect(agent.callable.map(\.name) == (mode == 2 ? ["hidden", "probe"] : ["hidden", "both", "probe"]))
        let input = try await opened.root.submit(.input(content: .text("go")), context: .background)
        #expect(try await input.wait(context: .background).status == "done")
        let results = received.withLock { $0 }
        #expect(results["script"]?.diagnostics.first?.code == "tool_unavailable")
        #expect(results["hidden"]?.isError == false)
        #expect(results["hidden"]?.structuredOutput == "hidden ran")
        if mode == 2 {
            #expect(results["both"]?.diagnostics.first?.code == "tool_unavailable")
        } else {
            #expect(results["both"]?.isError == false)
            #expect(results["both"]?.structuredOutput == "both ran")
        }
        try await opened.harness.close(context: .background)
    }

    @Test func transactionalAddToolsAppendsExactListsAndKeepsOtherFields() async throws {
        let setup = HarnessChatSetup()
        let grow = try selectionTool("grow")
        let opened = try await openChat(setup: setup)
        try await opened.root.configure(change: .init(tools: .set(.exact([grow])), modelTools: .set(.exact([grow])),
            instructions: .set("Keep this.")), context: .background)
        let operations = Mutex<[Delta.Op]>([])
        let subscription = try opened.harness.subscribeCommits { publication, _ in
            for change in publication.changes {
                if case .document(let document) = change, document.record.kind == AgentDoc.definition.kind {
                    operations.withLock { $0 += document.ops }
                }
            }
        }
        try await opened.root.commit({ tx in
            try await addTools(tx: tx, conversationId: opened.root.id, added: ["extra", "extra"])
        }, context: .background)
        subscription.cancel()
        #expect(operations.withLock { $0 } == [
            .splice(["tools"], index: 1, remove: 0, items: ["extra"]),
            .splice(["modelTools"], index: 1, remove: 0, items: ["extra"])
        ])
        let state = try #require(await opened.harness.snapshot(AgentDoc, conversationId: opened.root.id, context: .background))
        #expect(state.tools == .exact(["grow", "extra"]))
        #expect(state.modelTools == .exact(["grow", "extra"]))
        #expect(state.instructions == "Keep this.")
        try await opened.harness.close(context: .background)
    }

}
