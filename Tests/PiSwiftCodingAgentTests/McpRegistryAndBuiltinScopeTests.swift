import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

private func registryTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-mcp-registry-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test(.timeLimit(.minutes(1))) func mcpRegistryKeepsOwnerAndEmitsChanges() async throws {
    let directory = try registryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let apiStore = LockedState<HookAPI?>(nil)
    let changes = LockedState<[[String]]>([])
    let registered = InlineExtension(name: "registrar") { api in
        apiStore.withLock { $0 = api }
        try api.registerMcpServer("docs", config: McpServerConfig(url: "https://example.invalid/mcp"))
    }
    let connector = InlineExtension(name: "connector") { api in
        api.on("mcp_servers_change") { (event: McpServersChangeEvent, _) in
            changes.withLock { $0.append(event.servers.map(\.name)) }
            return nil
        }
    }
    let bus = createEventBus()
    let hooks = try [registered, connector].map { item in
        try #require(ExtensionLoader.load(item, cwd: directory.path, eventBus: bus).hook)
    }
    let runner = HookRunner(hooks, directory.path, .inMemory(), ModelRegistry(AuthStorage(":memory:")))
    runner.initialize(getModel: { nil })
    defer { runner.dispose() }
    let api = try #require(apiStore.withLock { $0 })
    #expect(runner.getMcpServers().map(\.name) == ["docs"])
    #expect(api.getMcpServers().map(\.name) == ["docs"])
    #expect(runner.getMcpServers()[0].extensionPath == "<inline:registrar>")

    try api.registerMcpServer("late", config: McpServerConfig(url: "https://example.invalid/late"))
    #expect(runner.getMcpServers().map(\.name) == ["docs", "late"])
    let other = HookAPI(events: bus, hookPath: "<inline:other>")
    #expect(throws: HookAPIError.self) {
        try other.registerMcpServer("docs", config: McpServerConfig(url: "https://example.invalid/conflict"))
    }
    api.unregisterMcpServer("late")
    #expect(runner.getMcpServers().map(\.name) == ["docs"])
    try await Task.sleep(for: .milliseconds(100))
    #expect(changes.withLock { $0 }.contains(["docs", "late"]))
    #expect(changes.withLock { $0 }.contains(["docs"]))
}

@Test func mcpRegistryReportsMissingConnector() throws {
    let directory = try registryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let extensionHook = try #require(ExtensionLoader.load(
        InlineExtension(name: "registrar") { api in
            try api.registerMcpServer("orphan", config: McpServerConfig(url: "https://example.invalid/mcp"))
        }, cwd: directory.path, eventBus: createEventBus()).hook)
    let runner = HookRunner([extensionHook], directory.path, .inMemory(), ModelRegistry(AuthStorage(":memory:")))
    let errors = LockedState<[HookError]>([])
    _ = runner.onError { error in errors.withLock { $0.append(error) } }
    runner.initialize(getModel: { nil })
    defer { runner.dispose() }
    #expect(errors.withLock { $0 }.contains { $0.event == "register_mcp_server" && $0.error.contains("orphan") })
}

@Test func mcpRegistryRejectsAnotherExtensionDuringLoad() throws {
    let directory = try registryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bus = createEventBus()
    let first = ExtensionLoader.load(InlineExtension(name: "first") { api in
        try api.registerMcpServer("taken", config: McpServerConfig(url: "https://example.invalid/one"))
    }, cwd: directory.path, eventBus: bus)
    #expect(first.hook != nil)
    let observed = LockedState<[String]>([])
    let second = ExtensionLoader.load(InlineExtension(name: "second") { api in
        observed.withLock { $0 = api.getMcpServers().map(\.name) }
        try api.registerMcpServer("taken", config: McpServerConfig(url: "https://example.invalid/two"))
    }, cwd: directory.path, eventBus: bus)
    #expect(observed.withLock { $0 } == ["taken"])
    #expect(second.hook == nil)
    #expect(second.error?.localizedDescription.contains("already registered by extension") == true)
}

@Test func mcpRegistryReloadKeepsNewRegistrationsAndRemovesOldOnes() throws {
    let directory = try registryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bus = createEventBus()
    let initial = try #require(ExtensionLoader.load(InlineExtension(name: "server") { api in
        try api.registerMcpServer("kept", config: McpServerConfig(url: "https://example.invalid/old"))
        try api.registerMcpServer("removed", config: McpServerConfig(url: "https://example.invalid/removed"))
    }, cwd: directory.path, eventBus: bus).hook)
    let runner = HookRunner([initial], directory.path, .inMemory(), ModelRegistry(AuthStorage(":memory:")))
    runner.initialize(getModel: { nil })
    defer { runner.dispose() }
    let replacement = try #require(ExtensionLoader.load(InlineExtension(name: "server") { api in
        try api.registerMcpServer("kept", config: McpServerConfig(url: "https://example.invalid/new"))
    }, cwd: directory.path, eventBus: bus).hook)
    runner.replaceExtensionHooks([replacement])
    #expect(runner.getMcpServers().map(\.name) == ["kept"])
    #expect(runner.getMcpServers().first?.config.url == "https://example.invalid/new")
}

@Test func projectMcpConfigRequiresTrustAndPromptNamesDocs() throws {
    let directory = try registryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let projectConfig = directory.appendingPathComponent(".pi")
    try FileManager.default.createDirectory(at: projectConfig, withIntermediateDirectories: true)
    try Data(#"{"mcpServers":{}}"#.utf8).write(to: projectConfig.appendingPathComponent("mcp.json"))
    #expect(hasTrustRequiringProjectResources(directory.path))
    let prompt = try buildSystemPrompt(BuildSystemPromptOptions(cwd: directory.path, contextFiles: [], skills: []))
    #expect(prompt.contains("MCP servers (docs/mcp.md)"))
}

@Test(.timeLimit(.minutes(1))) func projectBuiltinOverrideWinsAndReportsScope() async throws {
    let directory = try registryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let agentDir = directory.appendingPathComponent("agent")
    let project = directory.appendingPathComponent("project")
    let projectConfig = project.appendingPathComponent(".pi")
    try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: projectConfig, withIntermediateDirectories: true)
    try Data(#"{"extensions":["-builtin:mcp"]}"#.utf8).write(to: agentDir.appendingPathComponent("settings.json"))
    try Data(#"{"extensions":["+builtin:mcp"]}"#.utf8).write(to: projectConfig.appendingPathComponent("settings.json"))
    let settings = SettingsManager.create(project.path, agentDir.path)
    let trusted = DefaultPackageManager(cwd: project.path, agentDir: agentDir.path,
        settingsManager: settings, projectTrusted: true, offline: true, builtinExtensions: ["mcp"])
    let enabled = try #require(try await trusted.resolve().extensions.first { $0.path == "builtin:mcp" })
    #expect(enabled.enabled && enabled.metadata.scope == "project")
    let untrusted = DefaultPackageManager(cwd: project.path, agentDir: agentDir.path,
        settingsManager: settings, projectTrusted: false, offline: true, builtinExtensions: ["mcp"])
    let disabled = try #require(try await untrusted.resolve().extensions.first { $0.path == "builtin:mcp" })
    #expect(!disabled.enabled && disabled.metadata.scope == "user")

    try Data(#"{"extensions":["+builtin:mcp"]}"#.utf8).write(to: agentDir.appendingPathComponent("settings.json"))
    try Data(#"{"extensions":["-builtin:mcp"]}"#.utf8).write(to: projectConfig.appendingPathComponent("settings.json"))
    let reversedSettings = SettingsManager.create(project.path, agentDir.path)
    let projectDisabled = DefaultPackageManager(cwd: project.path, agentDir: agentDir.path,
        settingsManager: reversedSettings, projectTrusted: true, offline: true, builtinExtensions: ["mcp"])
    let reversed = try #require(try await projectDisabled.resolve().extensions.first { $0.path == "builtin:mcp" })
    #expect(!reversed.enabled && reversed.metadata.scope == "project")
}
