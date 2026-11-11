import Foundation
import Network
import PiSwiftAI
import PiSwiftMCP
import Testing
import Darwin

private actor M3DiskOAuthStore: McpOAuthStateStore {
    private let file: URL
    init(directory: URL) { file = directory.appendingPathComponent("mcp-state.json") }
    func load() throws -> McpOAuthState? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(McpOAuthState.self, from: Data(contentsOf: file))
    }
    func save(_ state: McpOAuthState) throws {
        try JSONEncoder().encode(state).write(to: file, options: .atomic)
    }
}

private actor M3RealAuthorizationServer {
    private let listener: NWListener
    private var ready = false
    private var readyWaiter: CheckedContinuation<Void, any Error>?
    private var connections: [UUID: NWConnection] = [:]
    private var origin = ""
    private var tokenRequests = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        listener.stateUpdateHandler = { [weak self] state in Task { await self?.stateChanged(state) } }
        listener.newConnectionHandler = { [weak self] connection in Task { await self?.respond(connection) } }
        listener.start(queue: .global())
        if !ready { try await withCheckedThrowingContinuation { readyWaiter = $0 } }
        origin = "http://127.0.0.1:\(listener.port!.rawValue)"
        return URL(string: origin + "/mcp")!
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready: ready = true; readyWaiter?.resume(); readyWaiter = nil
        case .failed(let error): readyWaiter?.resume(throwing: error); readyWaiter = nil
        default: break
        }
    }

    private func request(_ connection: NWConnection) async -> (method: String, target: String, body: Data)? {
        var bytes = Data()
        while true {
            let chunk: (Data?, Bool) = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, done, error in
                    continuation.resume(returning: (data, done || error != nil))
                }
            }
            if let data = chunk.0 { bytes.append(data) }
            if let separator = bytes.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: bytes[..<separator.lowerBound], as: UTF8.self)
                let lines = header.components(separatedBy: "\r\n")
                let first = lines[0].split(separator: " ")
                guard first.count >= 2 else { return nil }
                let length = lines.dropFirst().first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
                if bytes.count >= separator.upperBound + length {
                    return (String(first[0]), String(first[1]), bytes.subdata(in: separator.upperBound..<(separator.upperBound + length)))
                }
            }
            if chunk.1 { return nil }
        }
    }

    private func respond(_ connection: NWConnection) async {
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .global())
        defer { connections[id] = nil; connection.cancel() }
        guard let request = await request(connection),
              let url = URLComponents(string: origin + request.target) else { return }
        switch url.path {
        case "/.well-known/oauth-protected-resource/mcp":
            await json(connection, ["resource": origin + "/mcp", "authorization_servers": [origin]])
        case "/.well-known/oauth-authorization-server":
            await json(connection, ["issuer": origin, "authorization_endpoint": origin + "/authorize",
                "token_endpoint": origin + "/token", "response_types_supported": ["code"],
                "code_challenge_methods_supported": ["S256"], "token_endpoint_auth_methods_supported": ["none"]])
        case "/authorize":
            guard let redirect = url.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
                  let state = url.queryItems?.first(where: { $0.name == "state" })?.value,
                  var callback = URLComponents(string: redirect) else { return }
            callback.queryItems = [.init(name: "code", value: "fixture-code"), .init(name: "state", value: state),
                                   .init(name: "iss", value: origin)]
            await send(connection, status: "302 Found", headers: ["Location": callback.url!.absoluteString])
        case "/token":
            tokenRequests += 1
            await json(connection, ["access_token": "access-\(tokenRequests)",
                "refresh_token": "refresh-\(tokenRequests)", "token_type": "Bearer", "expires_in": 3600])
        default: await send(connection, status: "404 Not Found")
        }
    }

    private func json(_ connection: NWConnection, _ object: [String: Any]) async {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        await send(connection, status: "200 OK", body: body)
    }

    private func send(_ connection: NWConnection, status: String, body: Data = Data(), headers: [String: String] = [:]) async {
        var header = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in headers { header += "\(name): \(value)\r\n" }
        var data = Data((header + "\r\n").utf8); data.append(body)
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    func count() -> Int { tokenRequests }
    func stop() {
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }
}

private func m3FreePort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
    }
    guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
    let found = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    guard found == 0 else { throw POSIXError(.EIO) }
    return UInt16(bigEndian: address.sin_port)
}

private func m3RealTwoStepSignIn(newStore: Bool, fixedPort: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("m3-oauth-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let auth = try M3RealAuthorizationServer()
    let serverURL = try await auth.start()
    defer { Task { await auth.stop() } }
    let callback = try await OAuthCallbackServer<URL>.start(providerName: "MCP", port: fixedPort ? m3FreePort() : 0,
        path: "/callback", complete: { components in
            guard let url = components.url else { throw McpOAuthError.invalidRedirect }
            return url
        })
    defer { Task { await callback.close() } }
    let redirectURL = try #require(URL(string: await callback.redirectUri()))
    let firstStore = M3DiskOAuthStore(directory: directory)
    let options = McpSignInOptions(serverURL: serverURL, redirectURL: redirectURL, store: firstStore,
        clientMetadata: McpOAuthClientMetadata(clientName: "PiSwift test"), clientID: "client-1")
    let started = try await McpOAuthSignIn.startMcpSignIn(options: options)
    guard case .redirect(let authorization) = started else {
        Issue.record("Expected browser authorization")
        return
    }
    #expect(authorization.redirectURL == redirectURL)
    #expect(!authorization.state.isEmpty)
    let (_, opened) = try await URLSession.shared.data(from: authorization.authorizationURL)
    #expect((opened as? HTTPURLResponse)?.statusCode == 200)
    let callbackURL = try #require(await callback.wait())
    let components = try #require(URLComponents(url: callbackURL, resolvingAgainstBaseURL: false))
    func query(_ name: String) -> String? { components.queryItems?.first { $0.name == name }?.value }
    let response = McpAuthorizationResponse(code: try #require(query("code")),
        state: try #require(query("state")), iss: query("iss"))
    let completionStore: any McpOAuthStateStore = newStore ? M3DiskOAuthStore(directory: directory) : firstStore
    let completionOptions = McpSignInOptions(serverURL: serverURL, redirectURL: redirectURL,
        store: completionStore, clientMetadata: options.clientMetadata, clientID: "client-1")
    try await McpOAuthSignIn.completeMcpSignIn(options: completionOptions,
        authorization: authorization, response: response)
    #expect(try await completionStore.load()?.tokens?.accessToken == "access-1")
    #expect(await auth.count() == 1)
}

@Test(.timeLimit(.minutes(1))) func m3TwoStepRealLoopbackSameDiskStoreFixedFreePort() async throws {
    try await m3RealTwoStepSignIn(newStore: false, fixedPort: true)
}

@Test(.timeLimit(.minutes(1))) func m3TwoStepRealLoopbackNewStoreInstance() async throws {
    try await m3RealTwoStepSignIn(newStore: true, fixedPort: false)
}
