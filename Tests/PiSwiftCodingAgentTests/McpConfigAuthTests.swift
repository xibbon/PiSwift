import Foundation
import Testing
import PiSwiftMCP
@testable import PiSwiftCodingAgent
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private actor McpAuthFixture: McpOAuthHTTPClient {
    let base = URL(string: "http://127.0.0.1:45454")!
    var paths: [String] = []
    var refreshes = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        paths.append(path)
        let value: [String: Any]
        let status: Int
        switch path {
        case "/custom-resource":
            value = ["resource": "\(base)/mcp", "authorization_servers": [base.absoluteString]]
            status = 200
        case "/.well-known/oauth-authorization-server":
            value = ["issuer": base.absoluteString,
                "authorization_endpoint": "\(base)/authorize",
                "token_endpoint": "\(base)/token",
                "registration_endpoint": "\(base)/register",
                "response_types_supported": ["code"],
                "grant_types_supported": ["authorization_code", "refresh_token"],
                "token_endpoint_auth_methods_supported": ["none"],
                "code_challenge_methods_supported": ["S256"]]
            status = 200
        case "/register":
            var body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            body["client_id"] = "client"
            value = body
            status = 201
        case "/token":
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            if body.contains("grant_type=refresh_token") {
                refreshes += 1
                value = ["access_token": "refreshed", "refresh_token": "rotated", "token_type": "Bearer", "expires_in": 3600]
            } else {
                value = ["access_token": "initial", "refresh_token": "refresh", "token_type": "Bearer", "expires_in": 20]
            }
            status = 200
        default:
            value = [:]
            status = 404
        }
        let data = try JSONSerialization.data(withJSONObject: value)
        let response = HTTPURLResponse(url: request.url ?? base, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (data, response)
    }

    func observedPaths() -> [String] { paths }
    func refreshCount() -> Int { refreshes }
}

private actor McpAuthPresenterFixture: McpSignInPresenter {
    let callback = URL(string: "http://127.0.0.1:6000/callback")!

    func redirectURL(for state: String) -> URL { callback }
    func present(authorizationURL: URL, state: String) -> URL {
        URL(string: "\(callback)?code=test-code&state=\(state)")!
    }
}

private func mcpTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pi-mcp-c4b-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func mcpConfigValidationMatchesUpstreamShapes() throws {
    #expect(validateMcpServerConfig(name: "bad.name", value: ["url": "https://example.com/mcp"])?.contains("invalid server name") == true)
    #expect(validateMcpServerConfig(name: "legacy", value: ["type": "sse", "url": "https://example.com/mcp"])?.contains("legacy SSE") == true)
    #expect(validateMcpServerConfig(name: "http", value: ["type": "streamable-http", "url": "https://example.com/mcp"]) == nil)
    #expect(validateMcpServerConfig(name: "bad", value: ["url": "file:///tmp/socket"])?.contains("http or https") == true)
    #expect(validateMcpServerConfig(name: "bad", value: ["url": "https://example.com", "timeout": -1])?.contains("positive number") == true)
    #expect(validateMcpServerConfig(name: "bad", value: ["url": "https://example.com", "headers": ["Auth": 3]])?.contains("headers") == true)
    #expect(validateMcpServerConfig(name: "bad", value: ["url": "https://example.com", "oauth": ["callbackUrl": "https://example.com/callback"]])?.contains("localhost") == true)
    #expect(validateMcpServerConfig(name: "bad", value: ["url": "https://example.com", "oauth": ["callbackUrl": "http://localhost:8000/callback", "callbackPort": 9000]])?.contains("different ports") == true)
    #expect(isLoopbackRedirectUri("http://[::1]:8080/callback"))
    #expect(!isLoopbackRedirectUri("http://localhost/callback?code=x"))
}

@Test func mcpConfigTrustGateMergeAndPatternOrder() throws {
    let root = try mcpTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let agent = root.appendingPathComponent("agent")
    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: project.appendingPathComponent(".pi"), withIntermediateDirectories: true)
    try #"{"autoEnableCodemode":false,"mcpServers":{"docs":{"url":"https://global.example/mcp","enabled":false,"toolExposure":{"read*":"deferred","*file":"hidden","read_file":"direct"}},"other":{"command":"serve"}}}"#
        .write(to: agent.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
    try #"{"autoEnableCodemode":true,"mcpServers":{"docs":{"url":"https://project.example/mcp","toolExposure":{"read*":"deferred","*file":"hidden"}}}}"#
        .write(to: project.appendingPathComponent(".pi/mcp.json"), atomically: true, encoding: .utf8)
    let untrusted = loadMcpConfig(agentDir: agent, cwd: project, projectTrusted: false)
    #expect(untrusted.servers.count == 2)
    #expect(untrusted.servers.first { $0.name == "docs" }?.config.url == "https://global.example/mcp")
    #expect(untrusted.servers.first { $0.name == "docs" }?.config.isEnabled == false)
    #expect(untrusted.autoEnableCodemode == false)
    let trusted = loadMcpConfig(agentDir: agent, cwd: project, projectTrusted: true)
    let docs = try #require(trusted.servers.first { $0.name == "docs" })
    #expect(docs.config.url == "https://project.example/mcp")
    #expect(docs.scope == .project)
    #expect(trusted.autoEnableCodemode == true)
    #expect(getMcpToolExposure(docs.config, toolName: "read_file") == .deferred)
    let globalDocs = try #require(untrusted.servers.first { $0.name == "docs" })
    #expect(getMcpToolExposure(globalDocs.config, toolName: "read_file") == .direct)
    #expect(mcpServerListReport(trusted).first { $0.name == "docs" }?.scope == .project)
}

@Test func mcpConfigEditsKeepOtherContentAndDefaults() throws {
    let root = try mcpTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("mcp.json")
    try #"{"other":{"keep":[1,2]},"mcpServers":{"docs":{"url":"https://example.com/mcp","enabled":false,"exposure":"direct","custom":"unchanged"}}}"#
        .write(to: path, atomically: true, encoding: .utf8)
    try updateMcpServerConfig(path: path, name: "docs", patch: .init(enabled: true, exposure: .codemode))
    var rootJSON = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    var servers = try #require(rootJSON["mcpServers"] as? [String: [String: Any]])
    #expect(servers["docs"]?["enabled"] == nil)
    #expect(servers["docs"]?["exposure"] == nil)
    #expect(servers["docs"]?["custom"] as? String == "unchanged")
    #expect((rootJSON["other"] as? [String: [Int]])?["keep"] == [1, 2])
    #expect(try addMcpServerConfig(path: path, name: "docs", config: .init(url: "https://new.example/mcp")))
    #expect(!(try addMcpServerConfig(path: path, name: "new", config: .init(url: "https://new.example/mcp"))))
    #expect(try removeMcpServerConfig(path: path, name: "new"))
    #expect(!(try removeMcpServerConfig(path: path, name: "new")))
    rootJSON = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    servers = try #require(rootJSON["mcpServers"] as? [String: [String: Any]])
    #expect(servers["docs"]?["url"] as? String == "https://new.example/mcp")
    #expect(rootJSON["other"] != nil)
}

@Test func mcpConfigEditKeepsPatternPrecedence() throws {
    let root = try mcpTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let agent = root.appendingPathComponent("agent")
    try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
    let path = agent.appendingPathComponent("mcp.json")
    try #"{"mcpServers":{"docs":{"url":"https://example.com/mcp","toolExposure":{"read*":"deferred","*file":"hidden"}}}}"#
        .write(to: path, atomically: true, encoding: .utf8)
    let before = try #require(loadMcpConfig(agentDir: agent, cwd: root, projectTrusted: false).servers.first)
    #expect(getMcpToolExposure(before.config, toolName: "read_file") == .deferred)
    try updateMcpServerConfig(path: path, name: "docs", patch: .init(enabled: false))
    let after = try #require(loadMcpConfig(agentDir: agent, cwd: root, projectTrusted: false).servers.first)
    #expect(getMcpToolExposure(after.config, toolName: "read_file") == .deferred)
    #expect(after.config.toolExposureOrder == ["read*", "*file"])
}

@Test(.timeLimit(.minutes(1)))
func mcpCredentialStoreKeysByServerAndPersistsMilliseconds() async throws {
    let root = try mcpTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = McpOAuthCredentialStore(agentDir: root)
    let one = URL(string: "https://one.example/mcp")!
    let two = URL(string: "https://two.example/mcp")!
    let expires = Date(timeIntervalSince1970: 1_900_000_000)
    try await store.forServer(one).save(McpOAuthState(serverURL: one.absoluteString,
        tokens: McpOAuthTokens(accessToken: "one-token", tokenType: "Bearer", refreshToken: "one-refresh"),
        tokensExpireAt: expires))
    try await store.forServer(two).save(McpOAuthState(serverURL: two.absoluteString,
        tokens: McpOAuthTokens(accessToken: "two-token", tokenType: "Bearer")))
    let reopened = McpOAuthCredentialStore(agentDir: root)
    #expect(try reopened.tokens(for: one)?.accessToken == "one-token")
    #expect(try reopened.tokens(for: two)?.accessToken == "two-token")
    #expect(try reopened.state(for: one)?.tokensExpireAt == expires)
    let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("mcp-auth.json"))) as? [String: [String: Any]])
    #expect((raw[one.absoluteString]?["tokensExpireAt"] as? NSNumber)?.doubleValue == 1_900_000_000_000)
    #expect(try reopened.remove(one))
    #expect(try reopened.tokens(for: one) == nil)
    #expect(try reopened.tokens(for: two)?.accessToken == "two-token")
}

@Test(.timeLimit(.minutes(1)))
func mcpCredentialRefreshLockSerializesConcurrentWork() async throws {
    let root = try mcpTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = McpOAuthCredentialStore(agentDir: root)
    let url = URL(string: "https://example.com/mcp")!
    actor Counter {
        var active = 0
        var peak = 0
        func start() { active += 1; peak = max(peak, active) }
        func stop() { active -= 1 }
        func maxActive() -> Int { peak }
    }
    let counter = Counter()
    async let first: Void = store.withRefreshLock(for: url) {
        await counter.start()
        try await Task.sleep(for: .milliseconds(30))
        await counter.stop()
    }
    async let second: Void = store.withRefreshLock(for: url) {
        await counter.start()
        try await Task.sleep(for: .milliseconds(30))
        await counter.stop()
    }
    try await first
    try await second
    #expect(await counter.maxActive() == 1)
}

@Test(.timeLimit(.minutes(1)))
func mcpListReportIncludesConnectionStateErrorAndJSON() async throws {
    let root = try mcpTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let enabled = McpServerEntry(name: "failed", config: .init(url: "https://example.com/mcp"),
        source: root.appendingPathComponent("mcp.json").path, scope: .global)
    let disabled = McpServerEntry(name: "disabled", config: .init(command: "server", enabled: false),
        source: root.appendingPathComponent("mcp.json").path, scope: .global)
    let report = await inspectMcpServers(LoadedMcpConfig(servers: [enabled, disabled]),
        cwd: root, credentials: McpOAuthCredentialStore(agentDir: root), note: "untrusted project",
        createTransport: { _, _, _ in throw McpRuntimeError.invalidConfig("fixture failure") })
    #expect(report.failed)
    #expect(report.servers[0].state == "failed")
    #expect(report.servers[0].error?.contains("fixture failure") == true)
    #expect(report.servers[1].state == "disabled")
    let json = try #require(JSONSerialization.jsonObject(with: report.jsonData()) as? [String: Any])
    #expect(json["note"] as? String == "untrusted project")
    #expect((json["servers"] as? [[String: Any]])?.count == 2)
}

@Test(.timeLimit(.minutes(1)))
func mcpSignInUsesChallengeResourceAndRefreshesWithinThirtySeconds() async throws {
    let root = try mcpTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let server = URL(string: "http://127.0.0.1:45454/mcp")!
    let fixture = McpAuthFixture()
    let credentials = McpOAuthCredentialStore(agentDir: root)
    try await signInMcpServer(serverURL: server, credentials: credentials,
        challenge: McpOAuthChallenge(resourceMetadataURL: URL(string: "http://127.0.0.1:45454/custom-resource")),
        presenter: McpAuthPresenterFixture(), http: fixture)
    #expect(try credentials.tokens(for: server)?.accessToken == "initial")
    #expect(await fixture.observedPaths().contains("/custom-resource"))
    let provider = McpServerAuthProvider(serverURL: server, credentials: credentials, http: fixture)
    #expect(try await provider.token() == "refreshed")
    #expect(await fixture.refreshCount() == 1)
    #expect(try credentials.tokens(for: server)?.refreshToken == "rotated")
}

#if os(macOS)
@Test(.timeLimit(.minutes(1)))
func mcpConfiguredPresenterUsesFixedLoopbackRedirect() async throws {
    var redirect: URL?
    var lastError: String?
    for _ in 0..<10 {
        let port = Int.random(in: 40_000...60_000)
        let expected = "http://localhost:\(port)/oauth/callback"
        let presenter = try makeMcpMacOSSignInPresenter(
            settings: McpOAuthConfig(callbackPort: port, callbackUrl: expected),
            openAuthorizationURL: { _ in })
        do {
            redirect = try await presenter.redirectURL(for: "test-state")
            await presenter.cancel()
            #expect(redirect?.absoluteString == expected)
            break
        } catch {
            lastError = error.localizedDescription
            await presenter.cancel()
        }
    }
    #expect(redirect != nil, "\(lastError ?? "unknown error")")
}
#endif
