import Foundation
import PiSwiftAI
import PiSwiftAgent
import PiSwiftMCP
import Testing
@testable import PiSwiftCodingAgent
#if os(macOS)
import Network

// Port of v1.1.0 suite/agent-session-mcp-oauth.test.ts, including #10565.
private actor C2OAuthMcpServer {
    struct StalledRequest: Sendable {
        var path: String
        var closed = false
    }
    struct Deletion: Sendable, Equatable {
        var token: String?
        var sessionID: String?
    }
    private struct Request: Sendable {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }
    private struct Read: Sendable {
        var data: Data?
        var complete: Bool
    }
    private let listener: NWListener
    private var ready = false
    private var waiter: CheckedContinuation<Void, Error>?
    private var connections: [UUID: NWConnection] = [:]
    private var stalled: [UUID: StalledRequest] = [:]
    private var stallPaths: Set<String> = []
    private var deletes: [Deletion] = []
    private var issued = 0
    private var received = 0
    private var origin = ""

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        listener.stateUpdateHandler = { [weak self] state in Task { await self?.stateChanged(state) } }
        listener.newConnectionHandler = { [weak self] connection in Task { await self?.respond(connection) } }
        listener.start(queue: .global())
        if !ready { try await withCheckedThrowingContinuation { waiter = $0 } }
        origin = "http://127.0.0.1:\(listener.port!.rawValue)"
        return URL(string: origin + "/mcp")!
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready: ready = true; waiter?.resume(); waiter = nil
        case .failed(let error): waiter?.resume(throwing: error); waiter = nil
        default: break
        }
    }

    func stall(_ path: String) { stallPaths.insert(path) }
    func stalledRequests() -> [StalledRequest] { Array(stalled.values) }
    func deletions() -> [Deletion] { deletes }
    func requestCount() -> Int { received }

    private func read(_ connection: NWConnection) async -> Read {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                continuation.resume(returning: Read(data: data, complete: complete || error != nil))
            }
        }
    }

    private func request(_ connection: NWConnection) async -> Request? {
        var bytes = Data()
        while true {
            let next = await read(connection)
            if let data = next.data { bytes.append(data) }
            if let separator = bytes.range(of: Data("\r\n\r\n".utf8)) {
                let lines = String(decoding: bytes[..<separator.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let first = lines[0].split(separator: " ")
                guard first.count >= 2 else { return nil }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    let pair = line.split(separator: ":", maxSplits: 1)
                    if pair.count == 2 { headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces) }
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                if bytes.count >= separator.upperBound + length {
                    return Request(method: String(first[0]), path: String(first[1]), headers: headers,
                        body: bytes.subdata(in: separator.upperBound..<(separator.upperBound + length)))
                }
            }
            if next.complete { return nil }
        }
    }

    private func respond(_ connection: NWConnection) async {
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .global())
        guard let request = await request(connection) else { connection.cancel(); connections[id] = nil; return }
        received += 1
        let path = URLComponents(string: origin + request.path)?.path ?? request.path
        if stallPaths.contains(path) {
            stalled[id] = StalledRequest(path: path)
            while true {
                let next = await read(connection)
                if next.complete {
                    stalled[id]?.closed = true
                    connection.cancel(); connections[id] = nil
                    return
                }
            }
        }
        switch path {
        case "/.well-known/oauth-protected-resource/mcp":
            await json(connection, body: ["resource": origin + "/mcp", "authorization_servers": [origin]])
        case "/.well-known/oauth-authorization-server":
            await json(connection, body: ["issuer": origin, "authorization_endpoint": origin + "/authorize",
                "token_endpoint": origin + "/token", "registration_endpoint": origin + "/register",
                "response_types_supported": ["code"], "code_challenge_methods_supported": ["S256"],
                "token_endpoint_auth_methods_supported": ["none"]])
        case "/register":
            var registration = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
            registration["client_id"] = "client-1"
            await json(connection, status: "201 Created", body: registration)
        case "/token": await issueTokens(connection)
        case "/mcp": await mcp(connection, request: request)
        default: await send(connection, status: "404 Not Found")
        }
        connections[id] = nil
    }

    private func mcp(_ connection: NWConnection, request: Request) async {
        let token = request.headers["authorization"].map { $0.replacingOccurrences(of: "Bearer ", with: "") }
        if request.method == "DELETE" {
            deletes.append(Deletion(token: token, sessionID: request.headers["mcp-session-id"]))
            await send(connection, status: "200 OK")
            return
        }
        guard request.method == "POST" else { await send(connection, status: "405 Method Not Allowed"); return }
        guard let token, token.hasPrefix("access-"), Int(token.dropFirst(7)).map({ $0 <= issued }) == true else {
            await send(connection, status: "401 Unauthorized", headers: ["WWW-Authenticate": "Bearer resource_metadata=\"\(origin)/.well-known/oauth-protected-resource/mcp\""])
            return
        }
        guard let message = try? JsonRpc.decodeIncoming(request.body), case .request(let rpc) = message else {
            await send(connection, status: "202 Accepted"); return
        }
        let result: [String: Any]
        switch rpc.method {
        case "initialize": result = ["protocolVersion": LATEST_PROTOCOL_VERSION, "capabilities": ["tools": [:]],
            "serverInfo": ["name": "docs", "version": "1.0.0"]]
        case "tools/list": result = ["tools": [["name": "whoami", "inputSchema": ["type": "object", "properties": [:]]]]]
        case "tools/call": result = ["content": [["type": "text", "text": "token \(token)"]]]
        default: result = [:]
        }
        let body = (try? JsonRpc.encodeServerResponseToLine(.init(id: rpc.id, result: AnyCodable(result), error: nil))) ?? Data()
        await send(connection, status: "200 OK", body: body, headers: ["Mcp-Session-Id": "session-1"])
    }

    private func issueTokens(_ connection: NWConnection) async {
        issued += 1
        await json(connection, body: ["access_token": "access-\(issued)", "refresh_token": "refresh-\(issued)",
            "token_type": "Bearer", "expires_in": 3600])
    }

    // Release a refresh after the session has closed. Token rotation must still be saved.
    func releaseTokens() async {
        stallPaths.remove("/token")
        for (id, request) in stalled where request.path == "/token" && !request.closed {
            if let connection = connections[id] { await issueTokens(connection) }
        }
    }

    private func json(_ connection: NWConnection, status: String = "200 OK", body: [String: Any]) async {
        let bytes = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        await send(connection, status: status, body: bytes)
    }

    private func send(_ connection: NWConnection, status: String, body: Data = Data(), headers: [String: String] = [:]) async {
        var header = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in headers { header += "\(name): \(value)\r\n" }
        var bytes = Data((header + "\r\n").utf8)
        bytes.append(body)
        await withCheckedContinuation { continuation in
            connection.send(content: bytes, completion: .contentProcessed { _ in continuation.resume() })
        }
        connection.cancel()
    }

    func stop() {
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        waiter?.resume(throwing: CancellationError()); waiter = nil
    }
}

private struct C2OAuthPresenter: McpSignInPresenter {
    func redirectURL(for state: String) async throws -> URL { URL(string: "http://127.0.0.1:6000/callback")! }
    func present(authorizationURL: URL, state: String) async throws -> URL {
        let query = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)!.queryItems ?? []
        let redirect = query.first { $0.name == "redirect_uri" }!.value!
        var callback = URLComponents(string: redirect)!
        callback.queryItems = [.init(name: "code", value: "fixture-code"), .init(name: "state", value: state)]
        return callback.url!
    }
}

private final class C2NotificationUI: HookUIContext {
    nonisolated let notices = LockedState<[String]>([])
    nonisolated let inputEvents = LockedState((entered: false, cancelled: false, ended: false))
    nonisolated let waitForInput: Bool
    nonisolated init(waitForInput: Bool = false) { self.waitForInput = waitForInput }
    func select(_ title: String, _ options: [String]) async -> String? { nil }
    func confirm(_ title: String, _ message: String) async -> Bool { false }
    func input(_ title: String, _ placeholder: String?) async -> String? {
        guard waitForInput else { return nil }
        inputEvents.withLock { $0.entered = true }
        defer { inputEvents.withLock { $0.ended = true } }
        return await withTaskCancellationHandler {
            do { try await Task.sleep(for: .seconds(60)) } catch {}
            return nil
        } onCancel: {
            inputEvents.withLock { $0.cancelled = true }
        }
    }
    func notify(_ message: String, _ type: HookNotificationType?) { notices.withLock { $0.append(message) } }
    func setStatus(_ key: String, _ text: String?) {}
    func setWorkingMessage(_ message: String?) {}
    func setWidget(_ key: String, _ content: HookWidgetContent?) {}
    func setFooter(_ factory: HookFooterFactory?) {}
    func setTitle(_ title: String) {}
    func custom(_ factory: @escaping HookCustomFactory, options: HookCustomOptions?) async -> HookCustomResult? { nil }
    func pasteToEditor(_ text: String) {}
    func setEditorText(_ text: String) {}
    func getEditorText() -> String { "" }
    func editor(_ title: String, _ prefill: String?) async -> String? { nil }
    func setEditorComponent(_ factory: HookEditorComponentFactory?) {}
    func getAllThemes() -> [HookThemeInfo] { [] }
    func getTheme(_ name: String) -> Theme? { nil }
    func setTheme(_ theme: HookThemeInput) -> HookThemeResult { .init(success: false) }
    func getToolsExpanded() -> Bool { false }
    func setToolsExpanded(_ expanded: Bool) {}
    var theme: Theme { Theme.fallback() }
}

@MainActor private final class C2StatusUI: McpUi {
    private var cancellation: (@MainActor @Sendable () -> Void)?
    private(set) var messages: [String] = []
    func menu(_ menu: McpMenu) async -> String? { nil }
    func status(title: String, message: String) { messages.append(message) }
    func status(title: String, message: String, onCancel: (@MainActor @Sendable () -> Void)?) {
        messages.append(message)
        if cancellation == nil { cancellation = onCancel }
    }
    func redirectURL(title: String, authorizationURL: URL) async -> URL? { nil }
    func cancelSignIn() -> Bool {
        guard let cancellation else { return false }
        cancellation(); return true
    }
}

private func c2Eventually(_ check: @Sendable () async -> Bool) async throws -> Bool {
    for _ in 0..<500 {
        if await check() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return await check()
}

private func c2Entry(_ url: URL) -> McpServerEntry {
    .init(name: "docs", config: .init(url: url.absoluteString, exposure: .direct, timeout: 3), source: "test", scope: .extension)
}

private func c2ToolContext() -> CustomToolContext {
    .init(sessionManager: .inMemory(), modelRegistry: ModelRegistry(AuthStorage(":memory:")), model: nil,
        isIdle: { true }, hasPendingMessages: { false }, abort: {}, events: createEventBus(), sendMessage: { _, _ in })
}

private func c2Session(url: URL, credentials: McpOAuthCredentialStore, statusUI: (any McpUi)? = nil,
                       presenter: any McpSignInPresenter = C2OAuthPresenter(), notificationUI: C2NotificationUI? = nil) throws
    -> (AgentSession, HookRunner, C2NotificationUI) {
    let manager = SessionManager.inMemory()
    let bus = createEventBus()
    let entry = c2Entry(url)
    let extensions = [createCodemodeExtension(), createToolSearchExtension(), createMcpExtension(options: .init(
        agentDir: FileManager.default.temporaryDirectory, loadConfig: { _ in .init(servers: [entry]) },
        credentials: credentials, presenter: presenter, ui: statusUI))]
    let hooks = try extensions.map { try #require(ExtensionLoader.load($0, cwd: manager.getCwd(), eventBus: bus).hook) }
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey(model.provider, "test")
    let registry = ModelRegistry(auth)
    let runner = HookRunner(hooks, manager.getCwd(), manager, registry)
    let definitions = runner.getExtensionTools()
    let tools = definitions.map { wrapToolWithHooks(wrapCustomTool($0) { c2ToolContext() }, runner) }
    let agent = Agent(AgentOptions(initialState: .init(model: model), streamFn: { model, _, _ in
        let stream = AssistantMessageEventStream()
        let message = AssistantMessage(content: [.text(TextContent(text: "ready"))], api: model.api, provider: model.provider,
            model: model.id, usage: .init(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2), stopReason: .stop)
        stream.push(.done(reason: .stop, message: message)); stream.end(message)
        return stream
    }, getApiKey: { _ in "test" }))
    let session = AgentSession(config: .init(agent: agent, sessionManager: manager,
        settingsManager: .inMemory(), resourceLoader: TestResourceLoader(),
        systemPromptOptions: .init(cwd: manager.getCwd(), contextFiles: [], skills: []), hookRunner: runner,
        modelRegistry: registry, toolRegistry: Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) }),
        toolDefinitions: Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, $0) }),
        wrapExtensionTools: { tools in tools.map { wrapToolWithHooks(wrapCustomTool($0) { c2ToolContext() }, runner) } }))
    let ui = notificationUI ?? C2NotificationUI()
    runner.attachUI(ui, hasUI: true, mode: statusUI == nil ? .rpc : .tui)
    return (session, runner, ui)
}

private func c2Shutdown(_ runner: HookRunner) async -> Duration {
    let start = ContinuousClock.now
    _ = await runner.emit(SessionShutdownEvent(reason: .quit))
    return start.duration(to: .now)
}

@Test(.timeLimit(.minutes(1)), arguments: ["/.well-known/oauth-authorization-server", "/token"])
func c2McpSessionShutdownCancelsStalledSignIn(_ path: String) async throws {
    let server = try C2OAuthMcpServer()
    let url = try await server.start()
    let credentials = McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend())
    let (session, runner, ui) = try c2Session(url: url, credentials: credentials)
    defer { session.dispose(); Task { await server.stop() } }
    _ = await runner.emit(SessionStartEvent())
    await server.stall(path)
    let login = Task { try await session.prompt("/mcp login docs") }
    #expect(try await c2Eventually { await server.stalledRequests().count == 1 })
    #expect(await c2Shutdown(runner) < .seconds(2))
    try await login.value
    #expect(try await c2Eventually { await server.stalledRequests().first?.closed == true })
    #expect(ui.notices.withLock { $0.filter { $0.hasPrefix("Sign-in") } }.isEmpty)
    await server.stop()
}

@Test(.timeLimit(.minutes(1)))
func c2McpSessionShutdownDoesNotRefreshExpiringToken() async throws {
    let server = try C2OAuthMcpServer()
    let url = try await server.start()
    let credentials = McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend())
    let (session, runner, ui) = try c2Session(url: url, credentials: credentials)
    defer { session.dispose(); Task { await server.stop() } }
    _ = await runner.emit(SessionStartEvent())
    try await session.prompt("/mcp login docs")
    #expect(ui.notices.withLock { $0.last } == "Signed in to MCP server \"docs\" (1 tools).")
    var state = try #require(try credentials.state(name: "docs", url: url))
    state.tokensExpireAt = Date().addingTimeInterval(10)
    try await credentials.forServer(name: "docs", url: url).save(state)
    await server.stall("/token")
    #expect(await c2Shutdown(runner) < .seconds(2))
    #expect(await server.stalledRequests().isEmpty)
    #expect(await server.deletions() == [.init(token: "access-1", sessionID: "session-1")])
    await server.stop()
}

@Test(.timeLimit(.minutes(1)), arguments: ["/.well-known/oauth-authorization-server", "/register", "/token"])
func c2McpStatusCancelStopsOAuthAndReportsCancelled(_ path: String) async throws {
    let server = try C2OAuthMcpServer()
    let url = try await server.start()
    let statusUI = await C2StatusUI()
    let credentials = McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend())
    let (session, runner, ui) = try c2Session(url: url, credentials: credentials, statusUI: statusUI)
    defer { session.dispose(); Task { await server.stop() } }
    _ = await runner.emit(SessionStartEvent())
    await server.stall(path)
    let login = Task { try await session.prompt("/mcp login docs") }
    #expect(try await c2Eventually { await server.stalledRequests().count == 1 })
    #expect(await statusUI.cancelSignIn())
    try await login.value
    #expect(ui.notices.withLock { $0.last } == "Sign-in cancelled.")
    #expect(try await c2Eventually { await server.stalledRequests().first?.closed == true })
    #expect(try credentials.tokens(name: "docs", url: url) == nil)
    _ = await c2Shutdown(runner)
    await server.stop()
}

private struct C2NeverPresenter: McpSignInPresenter {
    let calls: LockedState<[String]>
    func redirectURL(for state: String) async throws -> URL {
        calls.withLock { $0.append("redirect") }
        return URL(string: "http://127.0.0.1/callback")!
    }
    func present(authorizationURL: URL, state: String) async throws -> URL {
        calls.withLock { $0.append("present") }
        throw C2HostError.failedAfterCancellation
    }
    func cancel() async { calls.withLock { $0.append("cancel") } }
}

@Test(.timeLimit(.minutes(1)))
func c2McpCancelledBeforeStartDoesNoWorkWithInvalidConfig() async throws {
    let server = try C2OAuthMcpServer()
    let url = try await server.start()
    defer { Task { await server.stop() } }
    let gate = LockedState(false)
    let calls = LockedState<[String]>([])
    let credentials = McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend())
    let login = Task {
        while !gate.withLock({ $0 }) { await Task.yield() }
        do {
            try await signInMcpServer(name: "docs", serverURL: url, credentials: credentials,
                settings: .init(clientRegistration: .cimd), presenter: C2NeverPresenter(calls: calls))
            return false
        } catch { return error is CancellationError }
    }
    login.cancel()
    gate.withLock { $0 = true }
    #expect(await login.value)
    #expect(calls.withLock { $0 }.isEmpty)
    #expect(await server.requestCount() == 0)
    #expect(try credentials.state(name: "docs", url: url) == nil)
    await server.stop()
}

// The loopback callback wins while the host's manual input request is open.
@Test(.timeLimit(.minutes(1)))
func c2McpLoopbackSignInCancelsManualInput() async throws {
    let server = try C2OAuthMcpServer()
    let url = try await server.start()
    let ui = C2NotificationUI(waitForInput: true)
    let callbackTask = LockedState<Task<Bool, Never>?>(nil)
    let presenter = try makeMcpMacOSSignInPresenter(settings: .init(), callbackTimeoutSeconds: 10,
        pasteRedirectURL: {
            guard let pasted = await ui.input("Paste the callback URL", nil) else { throw CancellationError() }
            return pasted
        }, openAuthorizationURL: { authorizationURL in
            let browser = Task {
                do {
                    guard try await c2Eventually({ ui.inputEvents.withLock { $0.entered } }) else { return false }
                    let query = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)!.queryItems ?? []
                    let redirect = query.first { $0.name == "redirect_uri" }!.value!
                    let state = query.first { $0.name == "state" }!.value!
                    var callback = URLComponents(string: redirect)!
                    callback.queryItems = [.init(name: "code", value: "fixture-code"), .init(name: "state", value: state)]
                    let (_, response) = try await URLSession.shared.data(from: callback.url!)
                    return (response as? HTTPURLResponse)?.statusCode == 200
                } catch { return false }
            }
            callbackTask.withLock { $0 = browser }
        })
    let credentials = McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend())
    let (session, runner, _) = try c2Session(url: url, credentials: credentials, presenter: presenter, notificationUI: ui)
    defer { session.dispose(); callbackTask.withLock { $0?.cancel() }; Task { await server.stop() } }
    _ = await runner.emit(SessionStartEvent())
    try await session.prompt("/mcp login docs")
    let browser = try #require(callbackTask.withLock { $0 })
    #expect(await browser.value)
    #expect(try await c2Eventually { ui.inputEvents.withLock { $0.cancelled && $0.ended } })
    #expect(ui.notices.withLock { $0.last } == "Signed in to MCP server \"docs\" (1 tools).")
    #expect(try credentials.tokens(name: "docs", url: url)?.accessToken == "access-1")
    _ = await c2Shutdown(runner)
    await server.stop()
}

private enum C2HostCancellation: Sendable, CaseIterable { case cancellationError, urlCancelled, cancelledTask }
private enum C2HostStage: Sendable, CaseIterable { case redirect, presentation }
private enum C2HostError: Error { case failedAfterCancellation }
private actor C2CancellingPresenter: McpSignInPresenter {
    let kind: C2HostCancellation
    let stage: C2HostStage
    private var waiting = false
    private var cancelled = 0
    init(kind: C2HostCancellation, stage: C2HostStage) { self.kind = kind; self.stage = stage }
    func redirectURL(for state: String) async throws -> URL {
        if stage == .redirect { try await fail() }
        return URL(string: "http://127.0.0.1:6000/callback")!
    }
    func present(authorizationURL: URL, state: String) async throws -> URL {
        try await fail()
        throw C2HostError.failedAfterCancellation
    }
    private func fail() async throws {
        waiting = true
        switch kind {
        case .cancellationError: throw CancellationError()
        case .urlCancelled: throw URLError(.cancelled)
        case .cancelledTask:
            do { try await Task.sleep(for: .seconds(60)) } catch {}
            throw C2HostError.failedAfterCancellation
        }
    }
    func isWaiting() -> Bool { waiting }
    func cancel() { cancelled += 1 }
    func cancelCount() -> Int { cancelled }
}

@Test(.timeLimit(.minutes(1)), arguments: C2HostCancellation.allCases, C2HostStage.allCases)
private func c2McpHostCancellationMapsToCancellationError(_ kind: C2HostCancellation, _ stage: C2HostStage) async throws {
    let server = try C2OAuthMcpServer()
    let url = try await server.start()
    defer { Task { await server.stop() } }
    let presenter = C2CancellingPresenter(kind: kind, stage: stage)
    let credentials = McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend())
    let login = Task {
        do {
            try await signInMcpServer(name: "docs", serverURL: url, credentials: credentials, presenter: presenter)
            return false
        } catch { return error is CancellationError }
    }
    if kind == .cancelledTask {
        #expect(try await c2Eventually { await presenter.isWaiting() })
        login.cancel()
    }
    #expect(await login.value)
    #expect(await presenter.cancelCount() >= 1)
    #expect(try credentials.tokens(name: "docs", url: url) == nil)
    await server.stop()
}

@Test(.timeLimit(.minutes(1)))
func c2McpStartedRefreshDelaysCloseUntilRotatedTokenIsSaved() async throws {
    let server = try C2OAuthMcpServer()
    let url = try await server.start()
    let credentials = McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend())
    try await signInMcpServer(name: "docs", serverURL: url, credentials: credentials, presenter: C2OAuthPresenter())
    let connection = McpServerConnection(entry: c2Entry(url), cwd: FileManager.default.temporaryDirectory, credentials: credentials)
    defer { Task { await connection.close(); await server.stop() } }
    try await connection.connect()
    var state = try #require(try credentials.state(name: "docs", url: url))
    state.tokensExpireAt = Date().addingTimeInterval(10)
    try await credentials.forServer(name: "docs", url: url).save(state)
    await server.stall("/token")
    let call = Task { _ = try? await connection.callTool(name: "whoami", arguments: [:]) }
    #expect(try await c2Eventually { await server.stalledRequests().count == 1 })
    let closed = LockedState(false)
    let closing = Task {
        await connection.close()
        closed.withLock { $0 = true }
    }
    #expect(try await c2Eventually { await server.deletions().count == 1 })
    try await Task.sleep(for: .milliseconds(50))
    #expect(!closed.withLock { $0 })
    #expect(try credentials.tokens(name: "docs", url: url)?.accessToken == "access-1")
    #expect(await server.deletions() == [.init(token: "access-1", sessionID: "session-1")])
    await server.releaseTokens()
    await closing.value
    #expect(closed.withLock { $0 })
    #expect(try credentials.tokens(name: "docs", url: url)?.accessToken == "access-2")
    #expect(try credentials.tokens(name: "docs", url: url)?.refreshToken == "refresh-2")
    await call.value
    await server.stop()
}
@Test(.timeLimit(.minutes(1)))
func c2McpStartupRefreshDelaysShutdownUntilRotatedTokenIsSaved() async throws {
    let server = try C2OAuthMcpServer()
    let url = try await server.start()
    let credentials = McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend())
    try await signInMcpServer(name: "docs", serverURL: url, credentials: credentials, presenter: C2OAuthPresenter())
    var state = try #require(try credentials.state(name: "docs", url: url))
    state.tokensExpireAt = Date().addingTimeInterval(10)
    try await credentials.forServer(name: "docs", url: url).save(state)
    await server.stall("/token")
    let entry = c2Entry(url)
    let api = HookAPI(events: createEventBus(), hookPath: "builtin:mcp")
    let runtime = McpBuiltinRuntime(api: api, options: .init(agentDir: FileManager.default.temporaryDirectory,
        loadConfig: { _ in .init(servers: [entry]) }, credentials: credentials))
    defer { Task { await runtime.shutdown(); await server.stop() } }
    let context = HookContext(sessionManager: .inMemory(), modelRegistry: ModelRegistry(AuthStorage(":memory:")), model: nil, hasUI: false)
    await runtime.start(context: context)
    #expect(try await c2Eventually { await server.stalledRequests().count == 1 })
    let closed = LockedState(false)
    let closing = Task {
        await runtime.shutdown()
        closed.withLock { $0 = true }
    }
    #expect(try await c2Eventually { await runtime.menu().items.isEmpty })
    try await Task.sleep(for: .milliseconds(50))
    #expect(!closed.withLock { $0 })
    #expect(try credentials.tokens(name: "docs", url: url)?.accessToken == "access-1")
    #expect(await server.deletions().isEmpty)
    await server.releaseTokens()
    await closing.value
    #expect(closed.withLock { $0 })
    #expect(try credentials.tokens(name: "docs", url: url)?.accessToken == "access-2")
    #expect(try credentials.tokens(name: "docs", url: url)?.refreshToken == "refresh-2")
    #expect(api.tools["mcp__docs__whoami"] == nil)
    await server.stop()
}

#endif
