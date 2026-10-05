import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

@Suite struct C1ToolRendererTests {

private func c1RendererRunner(_ hooks: [LoadedHook]) -> HookRunner {
    HookRunner(hooks, "/tmp", .inMemory(), ModelRegistry(AuthStorage(":memory:")))
}

@Test func c1ToolRenderersUseLoadOrderAndNext() {
    let first: ToolRendererResolver = { name, next in
        guard name == "target" else { return next() }
        var slots = next() ?? CustomToolRenderers()
        slots.renderShell = .self
        return slots
    }
    let second: ToolRendererResolver = { _, next in
        var slots = next() ?? CustomToolRenderers()
        slots.builtIn = .mcp(label: "Remote")
        return slots
    }
    let runner = c1RendererRunner([
        LoadedHook(path: "first", resolvedPath: "first", handlers: [:], toolRenderers: [first]),
        LoadedHook(path: "second", resolvedPath: "second", handlers: [:], toolRenderers: [second]),
    ])
    let slots = runner.resolveToolRenderers("target") { CustomToolRenderers(renderShell: .default) }
    #expect(slots?.renderShell == .self)
    #expect(slots?.builtIn == .mcp(label: "Remote"))
}

@Test func c1ToolRenderersSeeLateRegistrationAndStopAfterLoadFailure() {
    let api = HookAPI()
    let hook = LoadedHook(path: "live", resolvedPath: "live", handlers: [:],
                          currentToolRenderers: { api.toolRenderers })
    let runner = c1RendererRunner([hook])
    #expect(runner.resolveToolRenderers("unknown") { nil } == nil)
    api.registerToolRenderer { _, _ in CustomToolRenderers(builtIn: .mcp(label: "Late")) }
    #expect(runner.resolveToolRenderers("unknown") { nil }?.builtIn == .mcp(label: "Late"))
    api.invalidateAfterLoadFailure()
    api.registerToolRenderer { _, _ in CustomToolRenderers(builtIn: .mcp(label: "Invalid")) }
    #expect(runner.resolveToolRenderers("unknown") { nil } == nil)
}

@Test func c1ToolRendererCanSuppressTheBase() {
    let hook = LoadedHook(path: "stop", resolvedPath: "stop", handlers: [:], toolRenderers: [{ _, _ in nil }])
    #expect(c1RendererRunner([hook]).resolveToolRenderers("target") {
        CustomToolRenderers(renderShell: .self)
    } == nil)
}

@Test func c1NvidiaDefaultUsesUltra() {
    #expect(defaultModelPerProvider.first { $0.0 == .nvidia }?.1 == "nvidia/nemotron-3-ultra-550b-a55b")
}

@Test func c1UpstreamResolverCases() throws {
    // Compare returned markers because Swift closures are not Equatable.
    let renderCall: CustomToolRenderCall = { _, _ in "first" }
    let runner = c1RendererRunner([
        LoadedHook(path: "first", resolvedPath: "first", handlers: [:], toolRenderers: [{ name, next in
            name == "a" ? CustomToolRenderers(renderCall: renderCall) : next()
        }]),
        LoadedHook(path: "second", resolvedPath: "second", handlers: [:], toolRenderers: [{ _, next in
            next() ?? CustomToolRenderers(renderShell: .self)
        }]),
    ])
    let first = runner.resolveToolRenderers("a") { nil }
    #expect(try first?.renderCall?([:], .fallback()) as? String == "first")
    #expect(first?.renderShell == nil)
    let fallback = runner.resolveToolRenderers("b") { nil }
    #expect(fallback?.renderShell == .self)
    #expect(fallback?.renderCall == nil)
    let base = runner.resolveToolRenderers("b") { CustomToolRenderers(renderCall: { _, _ in "base" }) }
    #expect(try base?.renderCall?([:], .fallback()) as? String == "base")
    #expect(base?.renderShell == nil)
}

private func c1Tool(_ name: String, shell: ToolRenderShell) -> CustomTool {
    CustomTool(name: name, label: name, description: "Test", parameters: [:],
               execute: { _, _, _, _, _ in AgentToolResult(content: []) }, renderShell: shell)
}

private func c1Session(_ hooks: [LoadedHook], customTools: [LoadedCustomTool]) -> AgentSession {
    AgentSession(config: AgentSessionConfig(
        agent: Agent(), sessionManager: .inMemory(), settingsManager: .inMemory(),
        resourceLoader: TestResourceLoader(), hookRunner: c1RendererRunner(hooks),
        customTools: customTools, modelRegistry: ModelRegistry(AuthStorage(":memory:"))
    ))
}

@Test func c1SessionUsesExtensionThenCustomToolRenderers() {
    let custom = c1Tool("shared", shell: .default)
    let loaded = LoadedCustomTool(path: "custom", resolvedPath: "custom", tool: custom)
    let extensionTool = c1Tool("shared", shell: .self)
    let session = c1Session([
        LoadedHook(path: "extension", resolvedPath: "extension", handlers: [:], tools: ["shared": extensionTool], isExtension: true),
    ], customTools: [loaded])
    defer { session.dispose() }
    #expect(session.toolRenderers(for: "shared")?.renderShell == .self)
    #expect(session.toolRenderers(for: "unknown") == nil)

    let customSession = c1Session([], customTools: [loaded])
    defer { customSession.dispose() }
    #expect(customSession.toolRenderers(for: "shared")?.renderShell == .default)
    #expect(customSession.toolRenderers(for: "shared")?.builtIn == nil)
}

@Test func c1SessionPreservesResolverNil() {
    let tool = c1Tool("shared", shell: .self)
    let session = c1Session([
        LoadedHook(path: "stop", resolvedPath: "stop", handlers: [:], tools: ["shared": tool],
                   toolRenderers: [{ _, _ in nil }], isExtension: true),
    ], customTools: [LoadedCustomTool(path: "custom", resolvedPath: "custom", tool: tool)])
    defer { session.dispose() }
    #expect(session.toolRenderers(for: "shared") == nil)
}

@Test func c1InlineLoaderKeepsRendererRegistrationsLive() throws {
    let capturedAPI = LockedState<HookAPI?>(nil)
    let result = ExtensionLoader.load(InlineExtension(name: "renderers") { api in
        capturedAPI.withLock { $0 = api }
        api.registerToolRenderer { name, next in
            name == "early" ? CustomToolRenderers(renderShell: .self) : next()
        }
    }, cwd: "/tmp", eventBus: createEventBus())
    let hook = try #require(result.hook)
    let api = try #require(capturedAPI.withLock { $0 })
    let runner = c1RendererRunner([hook])
    #expect(runner.resolveToolRenderers("early") { nil }?.renderShell == .self)
    #expect(runner.resolveToolRenderers("late") { nil } == nil)
    api.registerToolRenderer { name, next in
        name == "late" ? CustomToolRenderers(builtIn: .mcp(label: "Late")) : next()
    }
    #expect(hook.toolRenderers.count == 1)
    #expect(hook.currentToolRenderers().count == 2)
    #expect(runner.resolveToolRenderers("late") { nil }?.builtIn == .mcp(label: "Late"))
}

@Test func c1VersionUsesV103() {
    // Upstream v1.0.4 package.json:3: report the release version.
    #expect(VERSION == "1.0.4")
    let renderer: BuiltInToolRenderer = .mcp(label: "server/tool")
    #expect(CustomToolRenderers(builtIn: renderer).builtIn == renderer)
}
}
