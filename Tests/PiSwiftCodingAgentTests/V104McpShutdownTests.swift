import Foundation
import Testing
import PiSwiftAI
import PiSwiftMCP
@testable import PiSwiftCodingAgent

private actor V104CloseGate {
    private var released = false
    private(set) var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let current = waiters
        waiters = []
        for waiter in current { waiter.resume() }
    }
}

private actor V104ShutdownTransport: McpTransport {
    let base: InMemoryTransport
    let gate: V104CloseGate?
    let failInitialize: Bool
    private(set) var closeStarted = false
    private(set) var closeCompleted = false
    private(set) var initializeAttempts = 0

    init(_ base: InMemoryTransport, gate: V104CloseGate? = nil, failInitialize: Bool = false) {
        self.base = base
        self.gate = gate
        self.failInitialize = failInitialize
    }

    func start() async throws { try await base.start() }
    func receive() async throws -> Data { try await base.receive() }
    func close() async {
        closeStarted = true
        await gate?.wait()
        await base.close()
        closeCompleted = true
    }
    func setProtocolVersion(_ version: String) async { await base.setProtocolVersion(version) }
    func send(_ data: Data) async throws {
        if let message = try? JsonRpc.decodeIncoming(data), case .request(let request) = message,
           request.method == "initialize" {
            initializeAttempts += 1
            if failInitialize {
                throw McpHTTPError(status: 503, body: "busy", message: "MCP HTTP request failed with status 503")
            }
        }
        try await base.send(data)
    }
}

private func v104ShutdownConnection(_ transport: V104ShutdownTransport, http: Bool = false) -> McpServerConnection {
    let config = http
        ? McpServerConfig(url: "http://unused.invalid", headers: ["Authorization": "x"], timeout: 3)
        : McpServerConfig(command: "unused", timeout: 3)
    return McpServerConnection(entry: McpServerEntry(name: "fake", config: config,
        source: "fixture", scope: .extension), cwd: FileManager.default.temporaryDirectory,
        createTransport: { _, _, _ in transport },
        credentials: McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend()))
}

// Upstream mcp-extension.test.ts #10249: close waits for initialize and transport shutdown.
@Test(.timeLimit(.minutes(1))) func v104McpCloseWaitsForInitializingTransport() async throws {
    let (client, server) = InMemoryTransport.pair()
    let transport = V104ShutdownTransport(client)
    let connection = v104ShutdownConnection(transport)
    try await server.start()
    let attempt = Task { try await connection.connect() }
    let request = try? await server.receive()
    await connection.close()
    let result = await attempt.result
    await server.close()

    #expect(request != nil)
    if let request, case .request(let rpc) = try JsonRpc.decodeIncoming(request) {
        #expect(rpc.method == "initialize")
    } else { Issue.record("Expected an initialize request") }
    #expect(await transport.closeCompleted)
    #expect(await connection.state == .closed)
    switch result {
    case .failure(let error): #expect(error.localizedDescription.contains("failed to connect"))
    case .success: Issue.record("A closed connection must fail its initialize request")
    }
}

// Upstream mcp-extension.test.ts #10249: cancellation keeps the last HTTP error.
@Test(.timeLimit(.minutes(1))) func v104McpCloseStopsRetryWaitAndKeeps503Error() async throws {
    let (client, server) = InMemoryTransport.pair()
    let transport = V104ShutdownTransport(client, failInitialize: true)
    let connection = v104ShutdownConnection(transport, http: true)
    let attempt = Task { try await connection.connect() }
    for _ in 0..<100 where !(await transport.closeCompleted) {
        try? await Task.sleep(for: .milliseconds(2))
    }
    // The failed initialize has closed its transport. Allow its catch to enter the retry wait.
    try? await Task.sleep(for: .milliseconds(10))
    let clock = ContinuousClock()
    let started = clock.now
    await connection.close()
    let elapsed = started.duration(to: clock.now)
    let result = await attempt.result
    await server.close()

    #expect(await transport.initializeAttempts == 1)
    #expect(elapsed < .milliseconds(200))
    #expect(await connection.state == .closed)
    switch result {
    case .failure(let error): #expect(error.localizedDescription.contains("status 503"))
    case .success: Issue.record("A closed connection must fail its retry")
    }
}

@Test(.timeLimit(.minutes(1))) func v104McpRuntimeShutdownClosesServersInParallel() async throws {
    let gate = V104CloseGate()
    let (firstClient, firstServer) = InMemoryTransport.pair()
    let (secondClient, secondServer) = InMemoryTransport.pair()
    let first = V104ShutdownTransport(firstClient, gate: gate)
    let second = V104ShutdownTransport(secondClient, gate: gate)
    let entries = ["first", "second"].map {
        McpServerEntry(name: $0, config: McpServerConfig(command: "unused", timeout: 3),
                       source: "fixture", scope: .extension)
    }
    let config = LoadedMcpConfig(servers: entries)
    let api = HookAPI(events: createEventBus(), hookPath: "builtin:mcp")
    let runtime = McpBuiltinRuntime(api: api, options: McpExtensionOptions(
        agentDir: FileManager.default.temporaryDirectory, loadConfig: { _ in config },
        createTransport: { entry, _, _ in entry.name == "first" ? first : second }))
    let context = HookContext(sessionManager: .inMemory(),
        modelRegistry: ModelRegistry(AuthStorage(":memory:")), model: nil, hasUI: false)
    try await firstServer.start()
    try await secondServer.start()
    await runtime.start(context: context)
    let firstRequest = try? await firstServer.receive()
    let secondRequest = try? await secondServer.receive()
    let shutdown = Task { await runtime.shutdown() }
    for _ in 0..<100 {
        if await first.closeStarted, await second.closeStarted { break }
        try? await Task.sleep(for: .milliseconds(2))
    }
    let firstStarted = await first.closeStarted
    let secondStarted = await second.closeStarted
    await gate.release()
    await shutdown.value
    await firstServer.close()
    await secondServer.close()

    #expect(firstRequest != nil && secondRequest != nil)
    #expect(firstStarted && secondStarted)
    #expect(await first.closeCompleted)
    #expect(await second.closeCompleted)
}

@Test(.timeLimit(.minutes(1))) func v104McpCloseBeforeTransportSetupKeepsClosedState() async {
    let gate = V104CloseGate()
    let supplied = LockedState(0)
    let (client, server) = InMemoryTransport.pair()
    let connection = McpServerConnection(entry: McpServerEntry(name: "fake",
        config: McpServerConfig(command: "unused", timeout: 3), source: "fixture", scope: .extension),
        cwd: FileManager.default.temporaryDirectory, createTransport: { _, _, _ in
            supplied.withLock { $0 += 1 }
            return client
        }, credentials: McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend()),
        onChange: { connection in
            if await connection.state == .connecting { await gate.wait() }
        })
    let attempt = Task { try await connection.connect() }
    for _ in 0..<100 where !(await gate.entered) {
        try? await Task.sleep(for: .milliseconds(2))
    }
    let closing = Task { await connection.close() }
    for _ in 0..<100 where await connection.state != .closed {
        try? await Task.sleep(for: .milliseconds(2))
    }
    await gate.release()
    await closing.value
    let result = await attempt.result
    await server.close()
    await client.close()

    #expect(supplied.withLock { $0 } == 0)
    #expect(await connection.state == .closed)
    switch result {
    case .failure(let error): #expect(error.localizedDescription.contains("failed to connect"))
    case .success: Issue.record("A connection closed before setup must fail")
    }
}
