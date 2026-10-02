import Foundation
import Testing
import PiSwiftMCP
@testable import PiSwiftCodingAgent

private func c1McpConfigDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("c1-mcp-config-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("agent"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("project/.pi"), withIntermediateDirectories: true)
    return root
}

// mcp-extension.test.ts #10239: server names share a normalized namespace.
@Test func c1McpConfigRejectsNormalizedServerNameClashes() throws {
    let root = try c1McpConfigDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let agent = root.appendingPathComponent("agent")
    let project = root.appendingPathComponent("project")
    try #"{"mcpServers":{"work-files":{"command":"a"},"work_files":{"command":"b"}}}"#
        .write(to: agent.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
    try #"{"mcpServers":{"work_files":{"command":"c"}}}"#
        .write(to: project.appendingPathComponent(".pi/mcp.json"), atomically: true, encoding: .utf8)
    let loaded = loadMcpConfig(agentDir: agent, cwd: project, projectTrusted: true)
    #expect(loaded.servers.map(\.name) == ["work-files"])
    #expect(loaded.errors.count == 2)
    #expect(loaded.errors.allSatisfy { $0.hasSuffix("server \"work_files\" conflicts with \"work-files\"") })
    #expect(mcpNamespace("work-files") == "mcp__work_files")
}

// mcp-extension.test.ts: descriptions and both exposure alias forms.
@Test func c1McpConfigDecodesDescriptionsAndExposureAliases() throws {
    let config = try JSONDecoder().decode(McpServerConfig.self, from: Data(#"{"command":"x","description":"Docs search","exposure":"codemode-deferred","toolExposure":{"a":"codemode-deferred"}}"#.utf8))
    #expect(config.description == "Docs search")
    #expect(config.exposure == .codemode)
    #expect(config.toolExposure == ["a": .codemode])
    #expect(McpExposure.allCases == [.codemode, .deferred, .direct, .hidden])
    #expect(validateMcpServerConfig(name: "docs", value: ["command": "x", "description": 1]) == "server \"docs\": description must be a string")
    #expect(validateMcpServerConfig(name: "docs", value: ["command": "x", "exposure": "wrong"]) == "server \"docs\": exposure must be one of \"codemode\", \"deferred\", \"direct\", \"hidden\"")
}

// mcp-extension.test.ts #10172: registration name and metadata security rules.
@Test func c1McpConfigValidatesOAuthClientNameAndMetadataURL() throws {
    for text in ["https://idp.example/metadata", "http://localhost/metadata", "http://127.0.0.1/metadata", "http://[::1]/metadata"] {
        #expect(validateMcpServerConfig(name: "docs", value: ["url": "https://example.com/mcp", "oauth": ["clientName": "Claude Code", "authServerMetadataUrl": text]]) == nil)
    }
    #expect(validateMcpServerConfig(name: "docs", value: ["url": "https://example.com/mcp", "oauth": ["clientName": " "]]) == "server \"docs\": oauth.clientName must be a non-empty string")
    #expect(validateMcpServerConfig(name: "docs", value: ["url": "https://example.com/mcp", "oauth": ["clientName": 1]]) == "server \"docs\": oauth.clientName must be a non-empty string")
    for value in ["http://idp.example/metadata", "file:///tmp/metadata", "relative"] {
        #expect(validateMcpServerConfig(name: "docs", value: ["url": "https://example.com/mcp", "oauth": ["authServerMetadataUrl": value]]) == "server \"docs\": oauth.authServerMetadataUrl must be an https URL, or http on localhost, 127.0.0.1, or [::1]")
    }
}

// mcp-extension.test.ts: project files cannot select a provider credential destination.
@Test func c1McpConfigRestrictsProviderAuthToGlobalAndSecureServers() throws {
    let root = try c1McpConfigDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let agent = root.appendingPathComponent("agent")
    let project = root.appendingPathComponent("project")
    try #"{"mcpServers":{"account":{"url":"https://account.example/mcp","auth":{"provider":"custom"}},"local":{"url":"http://localhost:8788/mcp","auth":{"provider":"custom-dev"}},"plain":{"url":"http://account.example/mcp","auth":{"provider":"custom"}},"empty":{"url":"https://account.example/mcp","auth":{"provider":""}}}}"#
        .write(to: agent.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
    try #"{"mcpServers":{"account":{"url":"https://evil.example/mcp","auth":{"provider":"custom"}}}}"#
        .write(to: project.appendingPathComponent(".pi/mcp.json"), atomically: true, encoding: .utf8)
    let loaded = loadMcpConfig(agentDir: agent, cwd: project, projectTrusted: true)
    #expect(loaded.servers.map(\.name) == ["account", "local"])
    #expect(loaded.servers.map(\.scope) == [.global, .global])
    #expect(loaded.servers[0].config.url == "https://account.example/mcp")
    #expect(loaded.servers[0].config.auth?.provider == "custom")
    #expect(loaded.errors.count == 3)
    #expect(loaded.errors[0].hasSuffix("server \"plain\": auth requires an https URL, or http on localhost, 127.0.0.1, or [::1]"))
    #expect(loaded.errors[1].hasSuffix("server \"empty\": auth.provider must be a provider name"))
    #expect(loaded.errors[2].hasSuffix("server \"account\": auth is only allowed in the global mcp.json"))
}

@Test func c1McpConfigSerializesNewServerFields() throws {
    let root = try c1McpConfigDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let agent = root.appendingPathComponent("agent")
    let config = McpServerConfig(url: "https://example.com/mcp",
        oauth: .init(clientName: "Custom client", authServerMetadataUrl: "https://idp.example/metadata"),
        auth: .init(provider: "custom"), description: "Docs search")
    _ = try addMcpServerConfig(path: agent.appendingPathComponent("mcp.json"), name: "docs", config: config)
    let loaded = loadMcpConfig(agentDir: agent, cwd: root, projectTrusted: false)
    #expect(loaded.errors.isEmpty)
    #expect(loaded.servers.first?.config == config)
}

private let c1McpOAuthURL = URL(string: "https://mcp.example.com/mcp")!
private func c1McpState(_ token: String) -> McpOAuthState {
    McpOAuthState(serverURL: c1McpOAuthURL.absoluteString,
        tokens: .init(accessToken: token, tokenType: "Bearer"))
}
private func c1McpStoredKeys(_ backend: InMemoryAuthStorageBackend) throws -> [String] {
    try backend.withLock { current in
        let object = try #require(JSONSerialization.jsonObject(with: Data((current ?? "{}").utf8)) as? [String: Any])
        return AuthStorageLockResult(result: object.keys.sorted())
    }
}
private func c1McpLegacyBackend() throws -> InMemoryAuthStorageBackend {
    let content = """
    {"\(c1McpOAuthURL.absoluteString)":{"serverUrl":"\(c1McpOAuthURL.absoluteString)","tokens":{"access_token":"legacy-token","token_type":"Bearer"}}}
    """
    return InMemoryAuthStorageBackend(content)
}

// mcp-oauth-store.test.ts #10252.
@Test(.timeLimit(.minutes(1))) func c1McpOAuthStoreSeparatesServersSharingURL() async throws {
    let store = McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend())
    try await store.forServer(name: "work", url: c1McpOAuthURL).save(c1McpState("work-token"))
    try await store.forServer(name: "personal", url: c1McpOAuthURL).save(c1McpState("personal-token"))
    #expect(try await store.forServer(name: "work", url: c1McpOAuthURL).load()?.tokens?.accessToken == "work-token")
    #expect(try await store.forServer(name: "personal", url: c1McpOAuthURL).load()?.tokens?.accessToken == "personal-token")
    #expect(try store.remove(name: "work", url: c1McpOAuthURL))
    #expect(try await store.forServer(name: "work", url: c1McpOAuthURL).load() == nil)
    #expect(try store.tokens(name: "personal", url: c1McpOAuthURL)?.accessToken == "personal-token")
}

@Test(.timeLimit(.minutes(1))) func c1McpOAuthStoreMovesLegacyStateToFirstServerLoad() async throws {
    let backend = try c1McpLegacyBackend()
    let store = McpOAuthCredentialStore(backend: backend)
    #expect(try store.tokens(name: "work", url: c1McpOAuthURL)?.accessToken == "legacy-token")
    #expect(try c1McpStoredKeys(backend) == [c1McpOAuthURL.absoluteString])
    #expect(try await store.forServer(name: "my_work", url: c1McpOAuthURL).load()?.tokens?.accessToken == "legacy-token")
    #expect(try store.tokens(name: "my-work", url: c1McpOAuthURL)?.accessToken == "legacy-token")
    #expect(try await store.forServer(name: "personal", url: c1McpOAuthURL).load() == nil)
    #expect(try c1McpStoredKeys(backend) == ["mcp__my_work|" + c1McpOAuthURL.absoluteString])
}

@Test func c1McpOAuthStoreRemovesLegacyState() throws {
    let backend = try c1McpLegacyBackend()
    let store = McpOAuthCredentialStore(backend: backend)
    #expect(try store.remove(name: "work", url: c1McpOAuthURL))
    #expect(try c1McpStoredKeys(backend).isEmpty)
    #expect(try !store.remove(name: "work", url: c1McpOAuthURL))
}

// mcp-oauth-refresh.test.ts: callback and pasted redirect URLs preserve iss.
@Test(.timeLimit(.minutes(1))) func c1McpOAuthSignInRejectsAnotherIssuer() async throws {
    let fixture = McpAuthFixture()
    let credentials = McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend())
    do {
        try await signInMcpServer(name: "test", serverURL: URL(string: "http://127.0.0.1:45454/mcp")!, credentials: credentials,
            challenge: .init(resourceMetadataURL: URL(string: "http://127.0.0.1:45454/custom-resource")!),
            presenter: McpAuthPresenterFixture(iss: "https://attacker.example"), http: fixture)
        Issue.record("Sign-in accepted the wrong issuer")
    } catch let error as McpOAuthError {
        guard case .issuerMismatch(_, let received) = error else { throw error }
        #expect(received == "https://attacker.example")
    }
    #expect(try credentials.tokens(name: "test", url: URL(string: "http://127.0.0.1:45454/mcp")!) == nil)
}

@Test(.timeLimit(.minutes(1))) func c1McpOAuthSignInKeepsGrantedScopeWhenServerAsksForMore() async throws {
    let server = URL(string: "http://127.0.0.1:45454/mcp")!
    let fixture = McpAuthFixture()
    let presenter = McpAuthPresenterFixture(iss: "http://127.0.0.1:45454")
    let credentials = McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend())
    let resource = URL(string: "http://127.0.0.1:45454/custom-resource")!
    try await signInMcpServer(name: "test", serverURL: server, credentials: credentials,
        challenge: .init(resourceMetadataURL: resource, scope: "issues:read"), presenter: presenter, http: fixture)
    #expect(try credentials.tokens(name: "test", url: server)?.scope == "issues:read")
    try await signInMcpServer(name: "test", serverURL: server, credentials: credentials,
        settings: .init(scope: "configured issues:read"),
        challenge: .init(resourceMetadataURL: resource, scope: "issues:write", error: "insufficient_scope"),
        presenter: presenter, http: fixture)
    let scopes = await presenter.authorizationURLs().map { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scope" }?.value }
    #expect(scopes == ["issues:read", "configured issues:read issues:write"])
    #expect(try credentials.tokens(name: "test", url: server)?.scope == "configured issues:read issues:write")
    #expect(await fixture.refreshCount() == 0)
}

// mcp-oauth-refresh.test.ts #10172.
@Test(.timeLimit(.minutes(1))) func c1McpOAuthSignInUsesConfiguredMetadataURL() async throws {
    let fixture = McpAuthFixture()
    do {
        try await signInMcpServer(name: "test", serverURL: URL(string: "http://127.0.0.1:45454/mcp")!,
            credentials: McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend()),
            settings: .init(authServerMetadataUrl: "http://127.0.0.1:45454/missing"),
            presenter: McpAuthPresenterFixture(), http: fixture)
        Issue.record("Sign-in ignored the configured metadata URL")
    } catch let error as McpOAuthError {
        guard case .httpStatus(let status, _) = error else { throw error }
        #expect(status == 404)
    }
    #expect(await fixture.observedPaths().contains("/missing"))
}

@Test(.timeLimit(.minutes(1)), arguments: [String?.none, "Custom client"])
func c1McpOAuthSignInRegistersConfiguredClientName(_ clientName: String?) async throws {
    let fixture = McpAuthFixture()
    try await signInMcpServer(name: "test", serverURL: URL(string: "http://127.0.0.1:45454/mcp")!,
        credentials: McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend()), settings: .init(clientName: clientName),
        challenge: .init(resourceMetadataURL: URL(string: "http://127.0.0.1:45454/custom-resource")!),
        presenter: McpAuthPresenterFixture(), http: fixture)
    #expect(await fixture.registeredClientNames() == [clientName ?? "pi"])
    let registrations = await fixture.recordedRegistrations()
    let request = try #require(registrations.first)
    let metadata = try JSONDecoder().decode(McpOAuthClientMetadata.self, from: request)
    #expect(metadata.redirectURIs == ["http://127.0.0.1:6000/callback"])
    #expect(metadata.clientName == clientName ?? "pi")
}

// Intake MCP11: URL serialization must add the slash when no path is present.
@Test(.timeLimit(.minutes(1))) func c1McpOAuthStoreNormalizesURLWithoutPath() async throws {
    let url = URL(string: "https://mcp.example.com")!
    let backend = InMemoryAuthStorageBackend()
    let store = McpOAuthCredentialStore(backend: backend)
    try await store.forServer(name: "my-work", url: url).save(McpOAuthState(serverURL: url.absoluteString,
        tokens: .init(accessToken: "work-token", tokenType: "Bearer")))
    #expect(try c1McpStoredKeys(backend) == ["mcp__my_work|https://mcp.example.com/"])
    #expect(try store.tokens(name: "my_work", url: URL(string: "https://mcp.example.com/")!)?.accessToken == "work-token")
}

@Test(.timeLimit(.minutes(1))) func c1McpOAuthRefreshUsesNamedStoreAndConfiguredMetadata() async throws {
    let server = URL(string: "http://127.0.0.1:45454/mcp")!
    let fixture = McpAuthFixture()
    let credentials = McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend())
    let settings = McpOAuthConfig(clientName: "Custom client", authServerMetadataUrl: "http://127.0.0.1:45454/.well-known/oauth-authorization-server")
    try await signInMcpServer(name: "test", serverURL: server, credentials: credentials, settings: settings,
        challenge: .init(scope: "issues:read"), presenter: McpAuthPresenterFixture(), http: fixture)
    let provider = McpServerAuthProvider(name: "test", serverURL: server, credentials: credentials, settings: settings, http: fixture)
    #expect(try await provider.token() == "refreshed")
    #expect(try credentials.tokens(name: "test", url: server)?.scope == "issues:read")
    #expect(try credentials.tokens(name: "personal", url: server) == nil)
    #expect(await fixture.refreshCount() == 1)
    #expect(await fixture.registeredClientNames() == ["Custom client"])
    let paths = await fixture.observedPaths()
    #expect(paths.filter { $0 == "/.well-known/oauth-authorization-server" }.count >= 2)
}

@Test(.timeLimit(.minutes(1))) func c1McpOAuthFailedStepUpKeepsPreviousGrant() async throws {
    let server = URL(string: "http://127.0.0.1:45454/mcp")!
    let fixture = McpAuthFixture()
    let credentials = McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend())
    let resource = URL(string: "http://127.0.0.1:45454/custom-resource")!
    try await signInMcpServer(name: "test", serverURL: server, credentials: credentials,
        challenge: .init(resourceMetadataURL: resource, scope: "issues:read"),
        presenter: McpAuthPresenterFixture(), http: fixture)
    let original = try credentials.tokens(name: "test", url: server)
    do {
        try await signInMcpServer(name: "test", serverURL: server, credentials: credentials,
            challenge: .init(resourceMetadataURL: resource, scope: "issues:write", error: "insufficient_scope"),
            presenter: McpAuthPresenterFixture(iss: "https://attacker.example"), http: fixture)
        Issue.record("Step-up accepted the wrong issuer")
    } catch let error as McpOAuthError {
        guard case .issuerMismatch = error else { throw error }
    }
    #expect(try credentials.tokens(name: "test", url: server) == original)
    #expect(await fixture.registeredClientNames() == ["pi"])
}

@Test(.timeLimit(.minutes(1))) func c1McpOAuthStoreMovesLegacyURLWithoutPath() async throws {
    let url = URL(string: "https://mcp.example.com")!
    let content = #"{"https://mcp.example.com/":{"serverUrl":"https://mcp.example.com/","tokens":{"access_token":"legacy","token_type":"Bearer"}}}"#
    let backend = InMemoryAuthStorageBackend(content)
    let store = McpOAuthCredentialStore(backend: backend)
    #expect(try store.tokens(name: "work", url: url)?.accessToken == "legacy")
    #expect(try c1McpStoredKeys(backend) == ["https://mcp.example.com/"])
    #expect(try await store.forServer(name: "work", url: url).load()?.tokens?.accessToken == "legacy")
    #expect(try c1McpStoredKeys(backend) == ["mcp__work|https://mcp.example.com/"])
    #expect(try await store.forServer(name: "personal", url: url).load() == nil)
}

@Test(.timeLimit(.minutes(1))) func c1McpOAuthSignInRejectsMissingPromisedIssuer() async throws {
    let server = URL(string: "http://127.0.0.1:45454/mcp")!
    do {
        try await signInMcpServer(name: "test", serverURL: server,
            credentials: McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend()),
            challenge: .init(resourceMetadataURL: URL(string: "http://127.0.0.1:45454/custom-resource")!),
            presenter: McpAuthPresenterFixture(), http: McpAuthFixture(issSupported: true))
        Issue.record("Sign-in accepted the missing issuer")
    } catch let error as McpOAuthError {
        guard case .issuerMismatch(let expected, let received) = error else { throw error }
        #expect(expected == "http://127.0.0.1:45454")
        #expect(received == nil)
    }
}
