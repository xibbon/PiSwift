import Foundation
import Network
import Testing
@testable import PiSwiftMCP

private enum OAuthV110TestError: Error { case deadline }

private func oauthV110Wait(_ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw OAuthV110TestError.deadline }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private actor OAuthV110Provider: McpOAuthClientProvider {
    nonisolated let redirectURL = URL(string: "http://127.0.0.1/callback")!
    nonisolated let clientMetadata = McpOAuthClientMetadata()
    private var client: McpOAuthClientInformation?
    private var tokenSet: McpOAuthTokens?
    private var discovery: McpOAuthDiscoveryState?
    private let clearOnInvalidation: Bool
    private(set) var redirects: [URL] = []
    private(set) var invalidations: [McpOAuthCredentialKind] = []

    init(origin: URL, cached: Bool = true, hasClient: Bool = true, clearOnInvalidation: Bool = true,
         tokenEndpoint: String? = nil) {
        self.clearOnInvalidation = clearOnInvalidation
        client = hasClient ? McpOAuthClientInformation(clientID: "client") : nil
        tokenSet = McpOAuthTokens(accessToken: "a1", tokenType: "Bearer", refreshToken: "r1")
        if cached {
            discovery = McpOAuthDiscoveryState(authorizationServerURL: origin.absoluteString,
                authorizationServerMetadata: McpOAuthAuthorizationServerMetadata(
                    issuer: origin.absoluteString, authorizationEndpoint: "\(origin)/authorize",
                    tokenEndpoint: tokenEndpoint ?? "\(origin)/token", registrationEndpoint: "\(origin)/register",
                    responseTypesSupported: ["code"]))
        }
    }

    func state() -> String? { "state" }
    func clientInformation() -> McpOAuthClientInformation? { client }
    func saveClientInformation(_ information: McpOAuthClientInformation) { client = information }
    func tokens() -> McpOAuthTokens? { tokenSet }
    func saveTokens(_ tokens: McpOAuthTokens) { tokenSet = tokens }
    func redirectToAuthorization(_ url: URL) { redirects.append(url) }
    func saveCodeVerifier(_ verifier: String) {}
    func codeVerifier() -> String { "verifier" }
    func invalidateCredentials(_ kind: McpOAuthCredentialKind) {
        invalidations.append(kind)
        if clearOnInvalidation { tokenSet = nil }
    }
    func saveDiscoveryState(_ state: McpOAuthDiscoveryState) { discovery = state }
    func discoveryState() -> McpOAuthDiscoveryState? { discovery }
}

private actor OAuthV110HTTPClient: McpOAuthHTTPClient {
    enum Failure: Sendable, CaseIterable {
        case timedOut, cannotConnect, serverError, invalidGrant, invalidScope, cancellation, urlCancellation
    }
    enum Mode: Sendable { case stall, failure(Failure), cancelledOAuthError }
    let mode: Mode
    private(set) var paths: [String] = []
    private(set) var stopped = false

    init(_ mode: Mode) { self.mode = mode }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        paths.append(request.url?.path ?? "")
        switch mode {
        case .stall, .cancelledOAuthError:
            do { try await Task.sleep(for: .seconds(60)) }
            catch {
                stopped = true
                if case .cancelledOAuthError = mode {
                    throw McpOAuthError.authorization(code: "invalid_grant", message: "cancelled refresh", uri: nil)
                }
                throw error
            }
            throw OAuthV110TestError.deadline
        case .failure(let failure):
            switch failure {
            case .timedOut: throw URLError(.timedOut)
            case .cannotConnect: throw URLError(.cannotConnectToHost)
            case .cancellation: throw CancellationError()
            case .urlCancellation: throw URLError(.cancelled)
            case .serverError, .invalidGrant, .invalidScope:
                let code = switch failure {
                case .serverError: "server_error"
                case .invalidGrant: "invalid_grant"
                default: "invalid_scope"
                }
                return (Data("{\"error\":\"\(code)\"}".utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: nil)!)
            }
        }
    }
}

private actor OAuthV110Completion {
    private(set) var done = false
    func finish() { done = true }
}

@Suite("OAuth v1.1.0")
struct OAuthV110Tests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancellationStopsDiscoveryAndRefresh(refreshing: Bool) async throws {
        let origin = URL(string: "http://127.0.0.1:45454")!
        let provider = OAuthV110Provider(origin: origin, cached: refreshing)
        let http = OAuthV110HTTPClient(.stall)
        let completion = OAuthV110Completion()
        let flow = Task {
            let result = await Result { try await McpOAuthFlow.authorize(provider: provider,
                options: McpOAuthFlowOptions(serverURL: origin.appending(path: "/mcp")), http: http) }
            await completion.finish()
            return result
        }
        defer { flow.cancel() }
        try await oauthV110Wait { await !http.paths.isEmpty }
        flow.cancel()
        try await oauthV110Wait { await completion.done }
        switch await flow.value {
        case .success: Issue.record("Expected cancellation")
        case .failure(let error): #expect(error is CancellationError)
        }
        #expect(await http.paths == [refreshing ? "/token" : "/.well-known/oauth-protected-resource/mcp"])
        #expect(await http.stopped)
        #expect(await provider.redirects.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: OAuthV110HTTPClient.Failure.allCases)
    private func refreshFallbackClassifiesErrors(failure: OAuthV110HTTPClient.Failure) async throws {
        let origin = URL(string: "http://127.0.0.1:45454")!
        // Keep tokens on invalidation to observe the refresh error on the outer retry too.
        let provider = OAuthV110Provider(origin: origin, clearOnInvalidation: false)
        let http = OAuthV110HTTPClient(.failure(failure))
        do {
            let result = try await McpOAuthFlow.authorize(provider: provider,
                options: McpOAuthFlowOptions(serverURL: origin.appending(path: "/mcp")), http: http)
            #expect([.timedOut, .cannotConnect, .serverError].contains(failure))
            #expect(result == .redirect)
            #expect(await provider.redirects.count == 1)
        } catch {
            #expect(await provider.redirects.isEmpty)
            switch failure {
            case .invalidGrant, .invalidScope:
                guard case .authorization(let code, _, _) = error as? McpOAuthError else {
                    Issue.record("Expected an OAuth protocol error"); return
                }
                #expect(code == (failure == .invalidGrant ? "invalid_grant" : "invalid_scope"))
                #expect(await provider.invalidations == (failure == .invalidGrant ? [.tokens] : []))
            case .cancellation: #expect(error is CancellationError)
            case .urlCancellation: #expect((error as? URLError)?.code == .cancelled)
            default: Issue.record("Expected refresh fallback: \(error)")
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func invalidGrantClearsTokensBeforeOuterRetryRedirects() async throws {
        let origin = URL(string: "http://127.0.0.1:45454")!
        let provider = OAuthV110Provider(origin: origin)
        let http = OAuthV110HTTPClient(.failure(.invalidGrant))
        #expect(try await McpOAuthFlow.authorize(provider: provider,
            options: McpOAuthFlowOptions(serverURL: origin.appending(path: "/mcp")), http: http) == .redirect)
        #expect(await provider.invalidations == [.tokens])
        #expect(await provider.tokens() == nil)
        #expect(await http.paths == ["/token"])
        #expect(await provider.redirects.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func insecureRefreshDoesNotRedirect() async throws {
        let origin = URL(string: "http://127.0.0.1:45454")!
        let provider = OAuthV110Provider(origin: origin, tokenEndpoint: "http://idp.example/token")
        let http = OAuthV110HTTPClient(.failure(.timedOut))
        do {
            _ = try await McpOAuthFlow.authorize(provider: provider,
                options: McpOAuthFlowOptions(serverURL: origin.appending(path: "/mcp")), http: http)
            Issue.record("Expected an insecure endpoint error")
        } catch {
            guard case .insecureEndpoint(let endpoint) = error as? McpOAuthError else {
                Issue.record("Unexpected error: \(error)"); return
            }
            #expect(endpoint == "http://idp.example/token")
        }
        #expect(await http.paths.isEmpty)
        #expect(await provider.redirects.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledTaskDoesNotRetryAnOAuthError() async throws {
        let origin = URL(string: "http://127.0.0.1:45454")!
        let provider = OAuthV110Provider(origin: origin)
        let http = OAuthV110HTTPClient(.cancelledOAuthError)
        let completion = OAuthV110Completion()
        let task = Task {
            let result = await Result { try await McpOAuthFlow.authorize(provider: provider,
                options: McpOAuthFlowOptions(serverURL: origin.appending(path: "/mcp")), http: http) }
            await completion.finish()
            return result
        }
        defer { task.cancel() }
        try await oauthV110Wait { await !http.paths.isEmpty }
        task.cancel()
        try await oauthV110Wait { await completion.done }
        switch await task.value {
        case .success: Issue.record("Expected the original OAuth error")
        case .failure(let error):
            guard case .authorization(let code, _, _) = error as? McpOAuthError else {
                Issue.record("Unexpected error: \(error)"); return
            }
            #expect(code == "invalid_grant")
        }
        #expect(await provider.invalidations.isEmpty)
        #expect(await provider.redirects.isEmpty)
        #expect(await http.paths == ["/token"])
    }
}

// Capture async errors without a task group that waits for an uncooperative request.
private extension Result where Failure == any Error {
    init(_ operation: () async throws -> Success) async {
        do { self = .success(try await operation()) }
        catch { self = .failure(error) }
    }
}

/// Accept each request, then wait for URLSession to close the connection.
private actor OAuthV110StallingServer {
    private let listener: NWListener
    private var ready = false
    private var connections: [UUID: NWConnection] = [:]
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var stopped = false
    private(set) var paths: [String] = []
    private(set) var disconnected = 0

    init() throws { listener = try NWListener(using: .tcp, on: .any) }

    func start() async throws -> URL {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { Task { await self?.markReady() } }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.start(queue: .global())
        try await oauthV110Wait { await self.ready }
        let port = try #require(listener.port)
        return try #require(URL(string: "http://127.0.0.1:\(port.rawValue)"))
    }

    private func markReady() { ready = true }

    private func accept(_ connection: NWConnection) {
        guard !stopped else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .global())
        workers[id] = Task { await self.handle(connection, id: id) }
    }

    private func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                continuation.resume(returning: error != nil || complete && (data?.isEmpty ?? true) ? nil : data)
            }
        }
    }

    private func handle(_ connection: NWConnection, id: UUID) async {
        let timer = Task {
            do { try await Task.sleep(for: .seconds(10)) }
            catch { return }
            connection.cancel()
        }
        defer {
            timer.cancel()
            connection.cancel()
            connections[id] = nil
            workers[id] = nil
        }
        var request = Data()
        while let data = await receive(connection) {
            request.append(data)
            guard request.count < 64 * 1024 else { return }
            guard let boundary = request.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let head = String(decoding: request[..<boundary.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let length = lines.compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }.first ?? 0
            guard request.count >= boundary.upperBound + length else { continue }
            paths.append(lines[0].split(separator: " ").dropFirst().first.map(String.init) ?? "")
            while await receive(connection) != nil {}
            disconnected += 1
            return
        }
    }

    func stop() {
        stopped = true
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        for worker in workers.values { worker.cancel() }
    }
}

extension OAuthV110Tests {
    @Test(.timeLimit(.minutes(1)), arguments: ["discovery", "refresh", "registration", "code"])
    func urlSessionCancellationStopsRequests(stage: String) async throws {
        let server = try OAuthV110StallingServer()
        let origin = try await server.start()
        let provider = OAuthV110Provider(origin: origin, cached: stage != "discovery", hasClient: stage != "registration")
        let completion = OAuthV110Completion()
        let flow = Task {
            let result = await Result { try await McpOAuthFlow.authorize(provider: provider,
                options: McpOAuthFlowOptions(serverURL: origin.appending(path: "/mcp"),
                    authorizationCode: stage == "code" ? "code" : nil)) }
            await completion.finish()
            return result
        }
        do {
            try await oauthV110Wait { await !server.paths.isEmpty }
            flow.cancel()
            try await oauthV110Wait { await completion.done }
            switch await flow.value {
            case .success: Issue.record("Expected URLSession cancellation")
            case .failure(let error):
                // Observed on Darwin: URLSession task cancellation throws URLError(.cancelled).
                #expect((error as? URLError)?.code == .cancelled)
            }
            let path = switch stage {
            case "discovery": "/.well-known/oauth-protected-resource/mcp"
            case "registration": "/register"
            default: "/token"
            }
            #expect(await server.paths == [path])
            #expect(await provider.redirects.isEmpty)
            #expect(await provider.invalidations.isEmpty)
            try await oauthV110Wait { await server.disconnected == 1 }
        } catch {
            flow.cancel()
            await server.stop()
            throw error
        }
        await server.stop()
    }
}
