import Foundation
import PiSwiftAI
import PiSwiftMCP
import Testing
@testable import PiSwiftCodingAgent

@MainActor private final class C1ManagerUI: McpUi {
    var menus: [McpMenu] = []
    var statuses: [String] = []
    var choices: [String?]
    init(_ choices: [String?] = []) { self.choices = choices }
    func menu(_ menu: McpMenu) async -> String? {
        menus.append(menu)
        return choices.isEmpty ? nil : choices.removeFirst()
    }
    func status(title: String, message: String) { statuses.append("\(title): \(message)") }
    func redirectURL(title: String, authorizationURL: URL) async -> URL? { nil }
}

private struct C1CancelPresenter: McpSignInPresenter {
    let events: LockedState<[String]>
    func redirectURL(for state: String) async throws -> URL { URL(string: "http://127.0.0.1:6000/callback")! }
    func present(authorizationURL: URL, state: String) async throws -> URL {
        events.withLock { $0.append("present") }
        throw CancellationError()
    }
}

@Suite struct C1McpManagerV101Tests {
    private func context() -> HookContext {
        HookContext(sessionManager: .inMemory(), modelRegistry: ModelRegistry(AuthStorage(":memory:")), model: nil, hasUI: false)
    }

    @Test @MainActor func projectActionsSaveToTheOverrideAndShowItsPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("c1-manager-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let global = root.appendingPathComponent("mcp.json"), project = root.appendingPathComponent(".pi/mcp.json")
        _ = try addMcpServerConfig(path: global, name: "docs", config: .init(command: "fixture", exposure: .direct))
        let entry = McpServerEntry(name: "docs", config: .init(command: "fixture", exposure: .direct), source: global.path, scope: .global)
        let runtime = McpBuiltinRuntime(api: HookAPI(), options: .init(agentDir: root,
            loadConfig: { _ in .init(servers: [entry], projectConfig: project.path) },
            createTransport: { _, _, _ in throw McpRuntimeError.connectionFailed("fixture") }))
        await runtime.start(context: context())
        try await runtime.waitForServers()
        let ui = C1ManagerUI(["docs", "disable-project", "enable", "exposure", "codemode", nil, nil])
        await runtime.runManager(ui)
        let visits = ui.menus.filter { $0.title == "MCP server docs" }
        #expect(visits[0].items.last == McpMenuItem(value: "disable-project", label: "Disable in this project", detail: "saved to the project mcp.json"))
        #expect(visits[1].items.map(\.value) == ["enable"])
        #expect(visits[1].items[0].detail == "saved to the project mcp.json")
        #expect(visits[1].details?.contains("global: \(global.path)\nproject override: \(project.path)") == true)
        #expect(ui.menus.first { $0.title == "Exposure of docs" }?.details == "Saved to \(project.path).")
        #expect(await runtime.menu().items[0].detail?.hasSuffix("global, project override") == true)
        let saved = try OrderedJSON.parse(String(contentsOf: project, encoding: .utf8))
        #expect(saved["mcpServers"]?["docs"]?["enabled"]?.serialized() == "true")
        #expect(saved["mcpServers"]?["docs"]?["exposure"]?.serialized() == #""codemode""#)
        let original = try OrderedJSON.parse(String(contentsOf: global, encoding: .utf8))
        #expect(original["mcpServers"]?["docs"]?["enabled"] == nil)
        #expect(original["mcpServers"]?["docs"]?["exposure"]?.serialized() == #""direct""#)
        await runtime.shutdown()
    }

    @Test @MainActor func disabledGlobalServerCanBeEnabledInTheProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("c1-enable-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent(".pi/mcp.json")
        let entry = McpServerEntry(name: "docs", config: .init(command: "fixture", enabled: false), source: "global", scope: .global)
        let runtime = McpBuiltinRuntime(api: HookAPI(), options: .init(agentDir: root,
            loadConfig: { _ in .init(servers: [entry], projectConfig: project.path) },
            createTransport: { _, _, _ in throw McpRuntimeError.connectionFailed("fixture") }))
        await runtime.start(context: context())
        let ui = C1ManagerUI(["docs", "enable-project", nil, nil])
        await runtime.runManager(ui)
        #expect(ui.menus[1].items.last?.label == "Enable in this project")
        #expect(ui.menus[2].items.last?.value == "disable")
        let saved = try OrderedJSON.parse(String(contentsOf: project, encoding: .utf8))
        #expect(saved["mcpServers"]?["docs"]?["enabled"]?.serialized() == "true")
        await runtime.shutdown()
    }

    @Test @MainActor func loginUsesManagerInTuiAndNotifiesTheURLInPrintMode() async throws {
        for mode in [HookMode.tui, .print] {
            let events = LockedState<[String]>([])
            let ui = C1ManagerUI()
            let notifications = C1NotificationUI(events: events)
            let url = URL(string: "http://127.0.0.1:45454/mcp")!
            let credentials = McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend())
            var state = McpOAuthState(serverURL: url.absoluteString)
            state.discovery = .init(authorizationServerURL: "http://127.0.0.1:45454",
                authorizationServerMetadata: .init(issuer: "http://127.0.0.1:45454",
                    authorizationEndpoint: "http://127.0.0.1:45454/authorize", tokenEndpoint: "http://127.0.0.1:45454/token",
                    tokenEndpointAuthMethodsSupported: ["none"], codeChallengeMethodsSupported: ["S256"]))
            try await credentials.forServer(name: "docs", url: url).save(state)
            let entry = McpServerEntry(name: "docs", config: .init(url: url.absoluteString, oauth: .init(clientId: "configured"), exposure: .direct), source: "fixture", scope: .extension)
            let runtime = McpBuiltinRuntime(api: HookAPI(), options: .init(
                loadConfig: { _ in .init(servers: [entry]) },
                createTransport: { _, _, _ in throw McpOAuthError.authorizationRequired },
                credentials: credentials, presenter: C1CancelPresenter(events: events), ui: ui))
            await runtime.start(context: context())
            try await runtime.waitForServers()
            let runner = HookRunner([], "/tmp", .inMemory(), ModelRegistry(AuthStorage(":memory:")))
            runner.attachUI(notifications, hasUI: true)
            var commandContext = runner.createCommandContext()
            commandContext.mode = mode
            await runtime.command("login docs", context: commandContext)
            if mode == .tui {
                #expect(ui.statuses == ["Sign in to docs: Contacting the authorization server…", "Sign in to docs: Connecting…"])
                #expect(events.withLock { $0 } == ["present", "Sign-in cancelled."])
            } else {
                #expect(ui.statuses.isEmpty)
                let recorded = events.withLock { $0 }
                #expect(recorded.count == 3)
                #expect(recorded[0].hasPrefix("Sign in to MCP server \"docs\" in your browser:\nhttp://127.0.0.1:45454/authorize?"))
                #expect(recorded[1...] == ["present", "Sign-in cancelled."])
            }
            await runtime.shutdown()
        }
    }

    @Test func mcpRendererFallbackWorksBeforeConnectionAndKeepsTheBase() throws {
        let hook = try #require(ExtensionLoader.load(createMcpExtension(), cwd: "/tmp", eventBus: createEventBus()).hook)
        let runner = HookRunner([hook], "/tmp", .inMemory(), ModelRegistry(AuthStorage(":memory:")))
        #expect(runner.resolveToolRenderers("mcp__my_docs__search", base: { nil })?.builtIn == .mcp(label: "my_docs/search"))
        #expect(runner.resolveToolRenderers("mcp__a__b__c", base: { nil })?.builtIn == .mcp(label: "a/b__c"))
        #expect(runner.resolveToolRenderers("not_mcp", base: { nil }) == nil)
        #expect(runner.resolveToolRenderers("read", base: { .init(renderShell: .self) })?.renderShell == .self)
        #expect(runner.resolveToolRenderers("mcp__a__b", base: { .init(renderShell: .self) })?.builtIn == nil)
    }
}

private final class C1NotificationUI: HookUIContext {
    let events: LockedState<[String]>
    init(events: LockedState<[String]>) { self.events = events }

    public func select(_ title: String, _ options: [String]) async -> String? { nil }
    public func confirm(_ title: String, _ message: String) async -> Bool { false }
    public func input(_ title: String, _ placeholder: String?) async -> String? { nil }
    public func notify(_ message: String, _ type: HookNotificationType?) { events.withLock { $0.append(message) } }
    public func setStatus(_ key: String, _ text: String?) {}
    public func setWorkingMessage(_ message: String?) {}
    public func setWorkingVisible(_ visible: Bool) {}
    public func setWorkingIndicator(_ options: WorkingIndicatorOptions?) {}
    public func setHiddenThinkingLabel(_ label: String?) {}
    public func addAutocompleteProvider(_ factory: @escaping HookAutocompleteProviderFactory) {}
    public func setWidget(_ key: String, _ content: HookWidgetContent?) {}
    public func setFooter(_ factory: HookFooterFactory?) {}
    public func setTitle(_ title: String) {}
    public func custom(_ factory: @escaping HookCustomFactory, options: HookCustomOptions?) async -> HookCustomResult? { nil }
    public func pasteToEditor(_ text: String) {}
    public func setEditorText(_ text: String) {}
    public func getEditorText() -> String { "" }
    public func editor(_ title: String, _ prefill: String?) async -> String? { nil }
    public func setEditorComponent(_ factory: HookEditorComponentFactory?) {}
    public func getAllThemes() -> [HookThemeInfo] { [] }
    public func getTheme(_ name: String) -> Theme? { nil }
    public func setTheme(_ theme: HookThemeInput) -> HookThemeResult {
        HookThemeResult(success: false, error: "UI not available")
    }
    public func getToolsExpanded() -> Bool { false }
    public func setToolsExpanded(_ expanded: Bool) {}
    public var theme: Theme { Theme.fallback() }
}

