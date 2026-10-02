import Foundation
import PiSwiftAI
import PiSwiftMCP
import Testing
@testable import PiSwiftCodingAgent
#if os(macOS)
import Network
#endif

private func f2McpDirectory() throws -> URL {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("pi-f2-mcp-\(UUID())")
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    return path
}

private func f2McpContext() -> HookContext {
    HookContext(sessionManager: .inMemory(), modelRegistry: ModelRegistry(AuthStorage(":memory:")),
                model: nil, hasUI: false)
}

private func f2McpEventually(_ check: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await check() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await check()
}

// This fixture follows test/mcp-extension.test.ts: initialize, then the offered lists.
private func f2McpTransport(tools: [String] = [], resources: Int = 0,
                           peer: (@Sendable (InMemoryTransport) -> Void)? = nil) -> any McpTransport {
    let (client, server) = InMemoryTransport.pair()
    peer?(server)
    Task {
        while let data = try? await server.receive() {
            guard let message = try? JsonRpc.decodeIncoming(data), case .request(let request) = message else { continue }
            let result: [String: Any]
            switch request.method {
            case "initialize":
                result = ["protocolVersion": LATEST_PROTOCOL_VERSION,
                          "capabilities": ["tools": [:], "resources": [:]],
                          "serverInfo": ["name": "f2", "version": "1"]]
            case "tools/list":
                result = ["tools": tools.map { ["name": $0, "description": "Use \($0)\nMore text", "inputSchema": ["type": "object"]] }]
            case "resources/list":
                result = ["resources": (0..<resources).map { ["uri": "docs://\($0)", "name": "resource\($0)"] }]
            case "resources/templates/list": result = ["resourceTemplates": []]
            default: result = [:]
            }
            try? await server.send(JsonRpc.encodeServerResponseToLine(
                JsonRpcServerResponse(id: request.id, result: AnyCodable(result), error: nil)))
        }
        await server.close()
    }
    return client
}

@MainActor private final class F2McpUi: McpUi {
    var menus: [McpMenu] = []
    var statuses: [String] = []
    var selections: [String?]

    init(_ selections: [String?]) { self.selections = selections }
    func menu(_ menu: McpMenu) async -> String? {
        menus.append(menu)
        return selections.isEmpty ? nil : selections.removeFirst()
    }
    func status(title: String, message: String) { statuses.append("\(title): \(message)") }
    func redirectURL(title: String, authorizationURL: URL) async -> URL? { nil }
}

private let f2McpExposureDescriptions = [
    // Upstream v1.0.0 exposure text removes the codemode-deferred alias.
    "called from codemode scripts, which find them with searchTools()",
    "not declared until tool_search loads them, then called directly; no codemode needed",
    "declared to the model like built-in tools",
]

@Test(.timeLimit(.minutes(1)), arguments: [0, 1, 2])
func f2McpManagerUsesUpstreamCountRules(_ count: Int) async throws {
    let root = try f2McpDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let entry = McpServerEntry(name: "docs", config: .init(command: "fixture", exposure: .direct),
                               source: "fixture", scope: .extension)
    let runtime = McpBuiltinRuntime(api: HookAPI(), options: .init(agentDir: root,
        loadConfig: { _ in .init(servers: [entry]) },
        createTransport: { _, _, _ in f2McpTransport(tools: (0..<count).map { "tool\($0)" }, resources: count) }))
    let context = f2McpContext()
    await runtime.start(context: context)
    await runtime.waitForFirstPrompt(context: context)
    let resources = count == 0 ? "" : " · \(count) resource\(count == 1 ? "" : "s")"
    #expect(await runtime.menu().items.first?.detail == "connected · \(count) tool\(count == 1 ? "" : "s")\(resources) · direct · extension")
    // Plain status deliberately uses "tools" for all counts in upstream formatStatus.
    #expect(await runtime.status() == "docs: connected, \(count) tools (direct)")
    await runtime.shutdown()
}

@Test(.timeLimit(.minutes(1)), arguments: [McpServerEntry.Scope.global, .project, .extension], [false, true])
@MainActor func f2McpManagerNamesSavedScope(_ scope: McpServerEntry.Scope, _ enabled: Bool) async throws {
    let root = try f2McpDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let entry = McpServerEntry(name: "docs", config: .init(command: "fixture", exposure: .direct, enabled: enabled),
                               source: root.appendingPathComponent("mcp.json").path, scope: scope)
    let runtime = McpBuiltinRuntime(api: HookAPI(), options: .init(agentDir: root,
        loadConfig: { _ in .init(servers: [entry]) }, createTransport: { _, _, _ in f2McpTransport() }))
    let context = f2McpContext()
    await runtime.start(context: context)
    // Upstream agent-session-mcp.test.ts waits explicitly for server readiness.
    try await runtime.waitForServers()
    let ui = F2McpUi(["docs", nil, nil])
    await runtime.runManager(ui)
    let menu = try #require(ui.menus.first { $0.title == "MCP server docs" })
    #expect(menu.items.last?.value == (enabled ? "disable" : "enable"))
    #expect(menu.items.last?.detail == (scope == .extension ? "for this session" : "saved to the \(scope.rawValue) mcp.json"))
    #expect(menu.selected == menu.items.first?.value)
    #expect(menu.details == "fixture\n\(scope.rawValue): \(entry.source)\nState: \(enabled ? "connected · 0 tools" : "disabled")")
    await runtime.shutdown()
}

@Test(.timeLimit(.minutes(1)), arguments: [McpExposure.codemode, .deferred, .direct, .hidden], [false, true])
@MainActor func f2McpManagerDescribesToolsAndExposure(_ exposure: McpExposure, _ overrides: Bool) async throws {
    let root = try f2McpDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let entry = McpServerEntry(name: "docs", config: .init(command: "fixture", exposure: exposure,
        toolExposure: overrides ? ["alpha": .hidden] : nil), source: "extension.swift", scope: .extension)
    let runtime = McpBuiltinRuntime(api: HookAPI(), options: .init(agentDir: root,
        loadConfig: { _ in .init(servers: [entry]) }, createTransport: { _, _, _ in f2McpTransport(tools: ["zebra", "alpha"]) }))
    let context = f2McpContext()
    await runtime.start(context: context)
    // Upstream agent-session-mcp.test.ts waits explicitly for server readiness.
    try await runtime.waitForServers()
    let ui = F2McpUi(["docs", "tools", nil, "exposure", nil, nil, nil])
    await runtime.runManager(ui)
    let tools = try #require(ui.menus.first { $0.title == "Tools of docs" })
    let exposures: [McpExposure] = [.codemode, .deferred, .direct]
    let description = exposures.firstIndex(of: exposure).map { f2McpExposureDescriptions[$0] } ?? "unreachable"
    #expect(tools.details == "Exposure \(exposure.rawValue): \(description)\(overrides ? "\nSome tools override it with toolExposure." : "")")
    #expect(tools.items.map(\.value) == ["zebra", "alpha"])
    #expect(tools.items.map(\.detail) == ["Use zebra", overrides && exposure != .hidden ? "[hidden] Use alpha" : "Use alpha"])
    let choices = try #require(ui.menus.first { $0.title == "Exposure of docs" })
    #expect(choices.details == "Applies to this session; the server is registered by extension.swift.")
    #expect(choices.items.map(\.value) == exposures.map(\.rawValue))
    #expect(choices.items.map(\.detail) == f2McpExposureDescriptions.map(Optional.some))
    #expect(choices.selected == exposure.rawValue)
    #expect(choices.items.map(\.label) == exposures.map { "\($0 == exposure ? "✓ " : "  ")\($0.rawValue)" })
    await runtime.shutdown()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func f2McpManagerReconnectShowsCurrentErrorOnce() async throws {
    let root = try f2McpDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let attempts = LockedState(0)
    let entry = McpServerEntry(name: "docs", config: .init(command: "fixture", exposure: .direct), source: "fixture", scope: .extension)
    let runtime = McpBuiltinRuntime(api: HookAPI(), options: .init(agentDir: root,
        loadConfig: { _ in .init(servers: [entry]) }, createTransport: { _, _, _ in
            if attempts.withLock({ $0 += 1; return $0 }) > 1 { throw McpRuntimeError.connectionFailed("first error\nsecond error") }
            return f2McpTransport()
        }))
    let context = f2McpContext()
    await runtime.start(context: context)
    // Upstream agent-session-mcp.test.ts waits explicitly for server readiness.
    try await runtime.waitForServers()
    let ui = F2McpUi(["docs", "reconnect", nil, nil])
    await runtime.runManager(ui)
    let menu = try #require(ui.menus.last { $0.title == "MCP server docs" })
    #expect(menu.details == "fixture\nextension: fixture\nState: failed")
    #expect(menu.error == "first error\nsecond error")
    #expect(await runtime.menu().items.first?.detail == "failed: first error · direct · extension")
    #expect(await runtime.status() == "docs: failed (direct)\n    first error\n    second error")
    await runtime.shutdown()
}

@Test(.timeLimit(.minutes(1)))
func f2McpManagerSortsAttentionAndLocaleButStatusKeepsInsertionOrder() async throws {
    let root = try f2McpDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let peers = LockedState<[String: InMemoryTransport]>([:])
    let names = ["Zebra", "zebra", "alpha", "Alpha", "parked", "broken", "signin", "dropped", "starting"]
    let entries = names.map { name in McpServerEntry(name: name,
        config: name == "signin" ? .init(url: "http://127.0.0.1/mcp", exposure: .direct) :
            .init(command: "fixture", exposure: .direct, enabled: name != "parked", timeout: 1), source: "fixture", scope: .extension) }
    let runtime = McpBuiltinRuntime(api: HookAPI(), options: .init(agentDir: root,
        loadConfig: { _ in .init(servers: entries) }, createTransport: { entry, _, _ in
            if entry.name == "broken" { throw McpRuntimeError.connectionFailed("broken") }
            if entry.name == "signin" { throw McpOAuthError.authorizationRequired }
            if entry.name == "starting" {
                let (client, server) = InMemoryTransport.pair()
                peers.withLock { $0[entry.name] = server }
                return client
            }
            return f2McpTransport(peer: { server in peers.withLock { $0[entry.name] = server } })
        }))
    await runtime.start(context: f2McpContext())
    #expect(await f2McpEventually { await runtime.menu().items.contains { $0.value == "dropped" && $0.detail?.hasPrefix("connected") == true } })
    await peers.withLock { $0["dropped"] }?.close()
    #expect(await f2McpEventually { await runtime.menu().items.first(where: { $0.value == "dropped" })?.detail?.hasPrefix("disconnected") == true })
    let menu = await runtime.menu()
    #expect(menu.items.map(\.value) == ["signin", "broken", "dropped", "starting", "alpha", "Alpha", "zebra", "Zebra", "parked"])
    let statusNames = await runtime.status().components(separatedBy: "\n").filter { !$0.hasPrefix("    ") }.map { String($0.prefix { $0 != ":" }) }
    #expect(statusNames == names)
    #expect(await runtime.status().contains("signin: needs sign-in, run /mcp login signin (direct)"))
    #expect(await runtime.status().contains("dropped: disconnected, reconnects on next call (direct)"))
    await runtime.shutdown()
    await peers.withLock { $0["starting"] }?.close()
}

#if os(macOS)
// The sign-in tests make only a local token request. Discovery is already in the store.
private actor F2McpTokenServer {
    private let listener: NWListener
    private var ready = false
    private var waiter: CheckedContinuation<Void, Error>?
    private let fail: Bool
    private(set) var requests = 0
    private var connections: [NWConnection] = []

    init(fail: Bool) throws { self.fail = fail; listener = try NWListener(using: .tcp, on: .any) }
    func start() async throws -> URL {
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.stateChanged(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in Task { await self?.respond(connection) } }
        listener.start(queue: .global())
        if !ready { try await withCheckedThrowingContinuation { waiter = $0 } }
        return URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")!
    }
    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready: ready = true; waiter?.resume(); waiter = nil
        case .failed(let error): waiter?.resume(throwing: error); waiter = nil
        default: break
        }
    }
    private func respond(_ connection: NWConnection) async {
        connections.append(connection)
        connection.start(queue: .global())
        let received: Data? = await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
        guard received != nil else { connection.cancel(); return }
        requests += 1
        let body = fail ? "{\"error\":\"server_error\",\"error_description\":\"token rejected\"}" :
            "{\"access_token\":\"fixture-token\",\"token_type\":\"Bearer\",\"expires_in\":3600}"
        let response = "HTTP/1.1 \(fail ? "400 Bad Request" : "200 OK")\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        await withCheckedContinuation { continuation in
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in continuation.resume() })
        }
        connection.cancel()
    }
    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
        waiter?.resume(throwing: CancellationError()); waiter = nil
    }
}

private struct F2McpSignInPresenter: McpSignInPresenter {
    let cancelSignIn: Bool
    func redirectURL(for state: String) async throws -> URL { URL(string: "http://127.0.0.1:6000/callback")! }
    func present(authorizationURL: URL, state: String) async throws -> URL {
        if cancelSignIn { throw CancellationError() }
        var callback = URLComponents(string: "http://127.0.0.1:6000/callback")!
        callback.queryItems = [.init(name: "code", value: "fixture-code"), .init(name: "state", value: state)]
        return callback.url!
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["success", "reconnect", "token", "cancel"])
@MainActor func f2McpManagerSignInReportsEachStage(_ result: String) async throws {
    let root = try f2McpDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let http = try F2McpTokenServer(fail: result == "token")
    let origin = try await http.start()
    let serverURL = origin.appendingPathComponent("mcp")
    let credentials = McpOAuthCredentialStore(agentDir: root)
    var state = McpOAuthState(serverURL: serverURL.absoluteString)
    state.discovery = .init(authorizationServerURL: origin.absoluteString,
        authorizationServerMetadata: .init(issuer: origin.absoluteString,
            authorizationEndpoint: origin.appendingPathComponent("authorize").absoluteString,
            tokenEndpoint: origin.appendingPathComponent("token").absoluteString,
            tokenEndpointAuthMethodsSupported: ["none"], codeChallengeMethodsSupported: ["S256"]))
    // Upstream mcp-oauth-store.test.ts keys credentials by server name and URL.
    try await credentials.forServer(name: "docs", url: serverURL).save(state)
    let entry = McpServerEntry(name: "docs", config: .init(url: serverURL.absoluteString,
        oauth: .init(clientId: "fixture-client"), exposure: .direct, timeout: 1), source: "fixture", scope: .extension)
    let runtime = McpBuiltinRuntime(api: HookAPI(), options: .init(agentDir: root,
        loadConfig: { _ in .init(servers: [entry]) }, createTransport: { _, _, _ in
            guard try credentials.tokens(name: "docs", url: serverURL) != nil else { throw McpOAuthError.authorizationRequired }
            if result == "reconnect" { throw McpRuntimeError.connectionFailed("reconnect rejected") }
            return f2McpTransport(tools: ["read"])
        }, credentials: credentials, presenter: F2McpSignInPresenter(cancelSignIn: result == "cancel")))
    let context = f2McpContext()
    await runtime.start(context: context)
    // Upstream agent-session-mcp.test.ts waits explicitly for server readiness.
    try await runtime.waitForServers()
    let ui = F2McpUi(["docs", "signin", nil, nil])
    await runtime.runManager(ui)
    #expect(ui.statuses == ["Sign in to docs: Contacting the authorization server…", "Sign in to docs: Connecting…"])
    let menu = try #require(ui.menus.last { $0.title == "MCP server docs" })
    switch result {
    case "success":
        #expect(menu.error == nil)
        #expect(menu.details?.hasSuffix("State: connected · 1 tool") == true)
        #expect(try credentials.tokens(name: "docs", url: serverURL)?.accessToken == "fixture-token")
    case "reconnect":
        #expect(menu.error == "Signed in, but MCP server \"docs\" failed to connect: reconnect rejected\nreconnect rejected")
        #expect(menu.details?.hasSuffix("State: failed") == true)
        #expect(try credentials.tokens(name: "docs", url: serverURL)?.accessToken == "fixture-token")
    case "cancel": #expect(menu.error == "Sign-in cancelled.")
    default:
        #expect(menu.error == "Sign-in failed: token rejected")
        #expect(try credentials.tokens(name: "docs", url: serverURL) == nil)
    }
    #expect(await http.requests == (result == "cancel" ? 0 : 1))
    await runtime.shutdown()
    await http.stop()
}
#endif
