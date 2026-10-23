import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable
import Testing

private func deferredTool(_ name: String, callers: [ToolCaller]? = nil, deferred: Bool? = true) throws -> ToolRegistration {
    try ToolRegistration(name: name, description: name, parameters: ["type": "object"], callers: callers, deferred: deferred) { _, _, _ in
        ToolExecutionResult(output: [])
    }
}

@Suite struct DeferredToolTests {
    @Test func registrationFactoriesKeepTheDeferredFlag() throws {
        struct Arguments: Sendable, Decodable {}
        let direct = try deferredTool("direct")
        let declaration = try ToolRegistration(declaration: direct.declaration, deferred: true) { _, _, _ in .init(output: []) }
        let typed = try defineTool(name: "typed", description: "typed", parameters: ["type": "object"],
            args: Arguments.self, deferred: true) { _, _, _ in .init(output: []) }
        #expect(direct.deferred == true)
        #expect(declaration.deferred == true)
        #expect(typed.deferred == true)
        #expect(try deferredTool("ordinary", deferred: nil).deferred == nil)
        #expect(try deferredTool("ordinary", deferred: false).deferred == false)
        #expect(try typed.currentOrderedDeclaration()["deferred"] == nil)
    }

    @Test func enabledAndCallerFiltersApplyBeforeTheDeferredCatalog() throws {
        let registry = createRegistry()
        try registry.install(Extension(name: "tools", tools: [
            try deferredTool("ordinary", deferred: false), try deferredTool("later"),
            try deferredTool("nested", callers: [.tools]), try deferredTool("model", callers: [.model]),
            try deferredTool("disabled", callers: []), try deferredTool("removed")
        ]))
        try registry.install(Extension(name: "wrap", wraps: [.tool("ordinary", { var tool = $0; tool.deferred = true; return tool })]))
        let agent = resolveAgent(state: .init(tools: .remove(["removed"])), snapshot: registry.snapshot())
        #expect(agent.tools.isEmpty)
        #expect(agent.deferred.map(\.name) == ["ordinary", "later", "model"])
        #expect(agent.callable.map(\.name) == ["ordinary", "later", "nested"])
        let hidden = resolveAgent(state: .init(extensions: .exact([]), modelTools: .edit(add: ["later"])), snapshot: registry.snapshot())
        #expect(hidden.tools.isEmpty)
        #expect(hidden.deferred.isEmpty)
        #expect(hidden.callable.isEmpty)
    }

    @Test func loadsFollowOrdinaryToolsWithoutWideningSelection() throws {
        let registry = createRegistry()
        try registry.install(Extension(name: "tools", tools: [
            try deferredTool("first"), try deferredTool("alpha", deferred: nil), try deferredTool("second"),
            try deferredTool("omega", deferred: nil), try deferredTool("nested", callers: [.tools]),
            try deferredTool("disabled", callers: []), try deferredTool("removed")
        ]))
        let state = AgentState(tools: .remove(["removed"]), modelTools: .edit(
            add: ["second", "alpha", "missing", "nested", "disabled", "removed", "first", "second"], remove: ["alpha", "first"]))
        let agent = resolveAgent(state: state, snapshot: registry.snapshot())
        #expect(agent.tools.map(\.name) == ["omega", "second"])
        #expect(agent.deferred.map(\.name) == ["first"])
        #expect(agent.callable.map(\.name) == ["first", "alpha", "second", "omega", "nested"])
        let decoded = try JSONValue(encoding: state).decode(AgentState.self)
        #expect(resolveAgent(state: decoded, snapshot: registry.snapshot()).tools.map(\.name) == ["omega", "second"])
        let explicit = resolveAgent(state: .init(tools: .exact(["second", "alpha", "first", "nested"]),
            modelTools: .exact(["first", "nested", "second", "first", "missing", "omega"])), snapshot: registry.snapshot())
        #expect(explicit.tools.map(\.name) == ["first", "second"])
        #expect(explicit.deferred.isEmpty)
        #expect(explicit.callable.map(\.name) == ["second", "alpha", "first", "nested"])
    }

    @Test func compositionAndWrapsSetTheFinalDeferredPolicy() throws {
        let registry = createRegistry()
        try registry.install(Extension(name: "base", tools: [try deferredTool("same"), try deferredTool("wrapped")]))
        try registry.install(Extension(name: "replace", tools: [try deferredTool("same", deferred: false)],
            wraps: [.tool("wrapped", { var tool = $0; tool.deferred = false; return tool })]))
        let agent = resolveAgent(snapshot: registry.snapshot())
        #expect(agent.tools.map(\.name) == ["same", "wrapped"])
        #expect(agent.deferred.isEmpty)
    }
}
