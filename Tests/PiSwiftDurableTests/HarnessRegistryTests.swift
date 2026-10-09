import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting

private func registryTool(_ name: String, description: String? = nil) throws -> ToolRegistration {
    try ToolRegistration(name: name, description: description ?? "\(name) tool",
                         parameters: ["type": .string("object"), "properties": .object([:])]) { _, _, _ in
        ToolExecutionResult(content: [])
    }
}
private func registryCoding() throws -> Extension {
    Extension(name: "coding", tools: try [registryTool("read"), registryTool("bash"), registryTool("edit")],
              sections: [section("preamble", tag: false) { _, _ in "You code." }, section("cwd") { _, _ in "/repo" }])
}
private func registryFixture() throws -> Registry {
    let registry = createRegistry()
    try registry.install(registryCoding())
    try registry.install(Extension(name: "skills", sections: [section("skills") { _, _ in "S" }]))
    try registry.install(Extension(name: "reviewer", sections: [section("role") { _, _ in "Review." }]))
    return registry
}
private enum RegistryTestError: Error { case wrapper, section }

@Suite struct HarnessRegistryTests {
    @Test("installs, replaces in place, and uninstalls extensions by name")
    func installation() throws {
        let registry = createRegistry()
        let listener = Mutex<[String]>([])
        let unsubscribe = registry.subscribe {
            let names = registry.snapshot().installed().map(\.name).joined(separator: ",")
            listener.withLock { $0.append(names) }
        }
        let a = Extension(name: "a", tools: [try registryTool("read", description: "Read files")])
        let b = Extension(name: "b", tools: try [registryTool("read"), registryTool("bash")])
        try registry.install(a); try registry.install(b)
        let before = registry.snapshot()
        try registry.install(Extension(name: "a", tools: [try registryTool("grep")]))
        #expect(registry.snapshot().installed().map(\.name) == ["a", "b"])
        #expect(registry.snapshot().tools().map { "\($0.tool.name)@\($0.extension.name)" } == ["grep@a", "read@b", "bash@b"])
        #expect(before.extension(name: "a")?.tools.first?.description == "Read files")
        registry.uninstall(a); registry.uninstall(a)
        #expect(registry.snapshot().installed().map(\.name) == ["b"])
        try registry.install(a)
        #expect(listener.withLock { $0 } == ["a", "a,b", "a,b", "b", "b,a"])
        unsubscribe(); registry.uninstall(a)
        #expect(listener.withLock { $0.count } == 5)
    }

    @Test("validates the registry as it would be after an install and publishes nothing when invalid")
    func validation() throws {
        let registry = createRegistry()
        try registry.install(Extension(name: "base"))
        let published = Mutex(0)
        _ = registry.subscribe { published.withLock { $0 += 1 } }
        let invalid = [
            Extension(name: "x", tools: try [registryTool("read"), registryTool("read")]),
            Extension(name: "x", sections: [section("a") { _, _ in "1" }, section("a") { _, _ in "2" }]),
            Extension(name: "x", sections: [section("Bad Key") { _, _ in "" }]),
            Extension(name: "x", sections: [section("instructions") { _, _ in "" }])
        ]
        for item in invalid { #expect(throws: HarnessDefinitionError.self) { try registry.install(item) } }
        #expect(registry.snapshot().installed().map(\.name) == ["base"])
        #expect(published.withLock { $0 } == 0)
    }

    @Test("keeps the default of a progress interval given as undefined")
    func progressDefault() {
        #expect(resolveSettings(HarnessSettings(progress: .init(partialIntervalMs: nil, outputIntervalMs: 250))).progress ==
                ProgressPolicy(partialIntervalMs: 100, outputIntervalMs: 250))
    }

    @Test("selects the default, an array, or the default edited by add and remove")
    func extensionSelection() throws {
        let registry = try registryFixture()
        let coding = try registryCoding()
        let skills = Extension(name: "skills")
        let settings = resolveSettings(HarnessSettings(extensions: [coding, skills]))
        #expect(resolveAgent(snapshot: registry.snapshot()).extensions.map(\.name) == ["coding", "skills", "reviewer"])
        #expect(resolveAgent(state: .init(), snapshot: registry.snapshot(), settings: settings).extensions.map(\.name) == ["coding", "skills"])
        #expect(resolveAgent(state: .init(extensions: .exact(["reviewer", "coding"])), snapshot: registry.snapshot(), settings: settings).extensions.map(\.name) == ["reviewer", "coding"])
        let state = AgentState(extensions: .edit(add: ["reviewer", "coding", "gone"], remove: ["skills"]))
        #expect(resolveAgent(state: state, snapshot: registry.snapshot(), settings: settings).extensions.map(\.name) == ["coding", "reviewer"])
        let stale = resolveSettings(HarnessSettings(extensions: [skills, skills]))
        #expect(resolveAgent(snapshot: registry.snapshot(), settings: stale).extensions.first?.sections.first?.key == "skills")
    }

    @Test("skips uninstalled names and resolves them again once they are installed")
    func missingNames() throws {
        let registry = createRegistry()
        try registry.install(registryCoding())
        let state = AgentState(extensions: .exact(["coding", "skills"]))
        #expect(resolveAgent(state: state, snapshot: registry.snapshot()).extensions.map(\.name) == ["coding"])
        try registry.install(Extension(name: "skills"))
        #expect(resolveAgent(state: state, snapshot: registry.snapshot()).extensions.map(\.name) == ["coding", "skills"])
    }

    @Test("replaces same-name tools in place, wraps the winner, then applies the filter")
    func winningTool() throws {
        let registry = createRegistry()
        try registry.install(registryCoding())
        try registry.install(Extension(name: "venv", tools: [try registryTool("bash", description: "venv bash")]))
        let calls = Mutex(0)
        try registry.install(Extension(name: "timing", wraps: [
            .tool("bash", { var item = $0; item.description += " (timed)"; return item }),
            .tool("bash", { var item = $0; item.description += " [2]"; return item }),
            .tool("grep", { item in calls.withLock { $0 += 1 }; return item })
        ]))
        let reports = Mutex(0)
        let agent = resolveAgent(snapshot: registry.snapshot(), report: { _ in reports.withLock { $0 += 1 } })
        #expect(agent.tools.map(\.name) == ["read", "bash", "edit"])
        #expect(agent.tools[1].description == "venv bash (timed) [2]")
        #expect(calls.withLock { $0 } == 0); #expect(reports.withLock { $0 } == 0)
        #expect(resolveAgent(state: .init(tools: .exact(["edit", "missing", "read", "edit"])), snapshot: registry.snapshot()).tools.map(\.name) == ["edit", "read"])
        #expect(resolveAgent(state: .init(tools: .remove(["bash"])), snapshot: registry.snapshot()).tools.map(\.name) == ["read", "edit"])
    }

    @Test("drops a tool or section whose wrapper throws or renames it and reports the failure")
    func failedWrappers() throws {
        let registry = createRegistry()
        try registry.install(registryCoding())
        try registry.install(Extension(name: "broken", wraps: [
            .tool("read", { _ in throw RegistryTestError.wrapper }),
            .tool("edit", { var tool = $0; tool.name = "renamed"; return tool }),
            .section("cwd", { _ in throw RegistryTestError.section })
        ]))
        let errors = Mutex<[String]>([])
        let agent = resolveAgent(snapshot: registry.snapshot(), report: { error in errors.withLock { $0.append(String(describing: error)) } })
        #expect(agent.tools.map(\.name) == ["bash"])
        #expect(agent.sections.map(\.key) == ["preamble"])
        #expect(errors.withLock { $0 } == ["wrapper", "Wrapper renamed edit to renamed", "section"])
    }

    @Test("orders sections by extension, replaces same keys in place, and renders instructions last and unwrapped")
    func sectionOrder() async throws {
        let registry = createRegistry()
        try registry.install(registryCoding())
        try registry.install(Extension(name: "skills", sections: [section("skills") { _, _ in "S" }]))
        try registry.install(Extension(name: "override", sections: [section("preamble", tag: false) { _, _ in "You review." }], wraps: [
            .section("cwd", { inner in var changed = inner; changed.render = { input, context in "\(try await inner.render(input, context) ?? "")!" }; return changed }),
            .section("instructions", { _ in throw RegistryTestError.wrapper })
        ]))
        let reports = Mutex(0)
        let agent = resolveAgent(state: .init(instructions: "Be terse."), snapshot: registry.snapshot(), report: { _ in reports.withLock { $0 += 1 } })
        let input = PromptInput(conversationId: rootConversationID, agent: agent)
        var texts: [String?] = []
        for item in agent.sections { texts.append(try await item.render(input, .background)) }
        #expect(agent.sections.map(\.key) == ["preamble", "cwd", "skills", "instructions"])
        #expect(texts == ["You review.", "/repo!", "S", "Be terse."])
        #expect(agent.sections.last?.tag == nil)
        #expect(reports.withLock { $0 } == 0)
    }

    @Test("collects hooks of the selected extensions in extension order and applies field defaults")
    func hookOrder() throws {
        struct CustomHooks: Sendable { var id: Int }
        let registry = createRegistry()
        try registry.install(Extension(name: "a", hooks: [hook("pi.tool", handlers: CustomHooks(id: 1)), hook(GenerationHooks())]))
        try registry.install(Extension(name: "b", hooks: [hook("pi.tool", handlers: CustomHooks(id: 2))]))
        let defaults = resolveAgent(snapshot: registry.snapshot())
        #expect(agentHooks(defaults, taskName: "pi.tool", as: CustomHooks.self).map(\.id) == [1, 2])
        let reverse = resolveAgent(state: .init(extensions: .exact(["b", "a"])), snapshot: registry.snapshot())
        #expect(agentHooks(reverse, taskName: "pi.tool", as: CustomHooks.self).map(\.id) == [2, 1])
        let onlyB = resolveAgent(state: .init(extensions: .exact(["b"])), snapshot: registry.snapshot())
        #expect(agentHooks(onlyB, taskName: "pi.generation").isEmpty)
        #expect(defaults.model == nil); #expect(defaults.thinkingLevel == .off); #expect(defaults.cwd == nil)
        let configured = resolveAgent(state: .init(model: .init(provider: "p", modelId: "m"), thinkingLevel: .high, cwd: "/w"), snapshot: registry.snapshot())
        #expect(configured.model == .init(provider: "p", modelId: "m")); #expect(configured.thinkingLevel == .high); #expect(configured.cwd == "/w")
    }

    @Test func settingsStayLiveAndDefaultsMerge() {
        let source = Mutex(HarnessSettings(retry: .init(maxRetries: 7), compaction: .init(enabled: false)))
        let provider = HarnessSettingsProvider { source.withLock { $0 } }
        #expect(provider.resolve().retry == .init(maxRetries: 7))
        #expect(provider.resolve().compaction == .init(enabled: false))
        #expect(provider.resolve().contextRetentionMs == 600000)
        source.withLock { $0.progress = .init(outputIntervalMs: 300); $0.toolExecution = .sequential }
        #expect(provider.resolve().progress.outputIntervalMs == 300)
        #expect(provider.resolve().toolExecution == .sequential)
    }

    @Test func agentChangesAndJSONShape() throws {
        let coding = try registryCoding()
        let read = try registryTool("read")
        var state = AgentState(model: .init(provider: "p", modelId: "m"), tools: .exact(["bash"]), cwd: "/old")
        applyAgentChange(&state, .init(model: .clear, extensions: .set(.edit(add: [coding], remove: [])),
                                     tools: .set(.exact([read])), instructions: .set("Short.")))
        #expect(state.model == nil); #expect(state.cwd == "/old")
        #expect(state.extensions == .edit(add: ["coding"], remove: [])); #expect(state.tools == .exact(["read"]))
        let data = try JSONEncoder().encode(state)
        let json = try JSONValue(jsonText: String(decoding: data, as: UTF8.self))
        #expect(json["model"] == nil)
        #expect(json["extensions"] == .object(["add": .array([.string("coding")]), "remove": .array([])]))
        #expect(try JSONDecoder().decode(AgentState.self, from: data) == state)
        addAgentTools(&state, ["read", "bash", "bash"]); #expect(state.tools == .exact(["read", "bash"]))
        state.tools = .remove(["read", "bash", "edit"]); addAgentTools(&state, ["read", "edit"])
        #expect(state.tools == .remove(["bash"]))
        state.tools = nil; addAgentTools(&state, ["read"]); #expect(state.tools == nil)
        applyAgentChange(&state, .init(extensions: .clear, instructions: .clear, cwd: .clear))
        #expect(state.extensions == nil); #expect(state.instructions == nil); #expect(state.cwd == nil)
    }

    @Test func typedToolValidatesAndDecodes() async throws {
        struct Args: Decodable, Sendable { var count: Int }
        let schema: JSONObject = ["type": .string("object"), "properties": .object(["count": .object(["type": .string("integer")])]), "required": .array([.string("count")])]
        let tool = try defineTool(name: "count", description: "Counts", parameters: schema, args: Args.self,
                                  prepareArguments: { value in
            var object = value.objectValue ?? [:]; if object["count"] == nil { object["count"] = .number(4) }; return .object(object)
        }) { args, _, _ in ToolExecutionResult(details: .number(Double(args.count)), control: .init(terminate: true, handoff: "done")) }
        let api = ToolExecutionApi(taskId: try TaskID(2), conversationId: rootConversationID, callId: "call", registry: .init(), models: FakeDurableModels(), agent: { _ in Agent() })
        let input = try #require(try tool.prepareArguments?(.object([:])))
        let result = try await tool.execute(input, api, .background)
        #expect(result.details == .number(4)); #expect(result.control?.terminate == true)
        #expect(result.control?.handoff == "done"); #expect(tool.orderedDeclaration["parameters"] == .object(schema))
        await #expect(throws: ValidationError.self) { try await tool.execute(.object(["count": .string("bad")]), api, .background) }
        await #expect(throws: HarnessDefinitionError.self) { try await tool.execute(.array([]), api, .background) }
    }

    @Test func exactNameIdentityUsesUTF16() throws {
        let registry = createRegistry()
        let first = "\u{e9}", second = "e\u{301}"
        try registry.install(Extension(name: first, tools: [try registryTool(first)]))
        try registry.install(Extension(name: second, tools: [try registryTool(second)]))
        #expect(registry.snapshot().installed().count == 2)
        #expect(resolveAgent(snapshot: registry.snapshot()).tools.count == 2)
        #expect(resolveAgent(state: .init(tools: .exact([first, second])), snapshot: registry.snapshot()).tools.count == 2)
    }
}
