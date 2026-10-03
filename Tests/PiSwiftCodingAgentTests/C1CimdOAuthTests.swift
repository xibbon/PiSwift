import Foundation
import Testing
import PiSwiftMCP
@testable import PiSwiftCodingAgent

private let c1CimdServerURL = URL(string: "http://127.0.0.1:45454/mcp")!
private let c1CimdDocumentURL = URL(string: "https://host.example/oauth/client.json")!
private let c1CimdIssuer = "http://127.0.0.1:45454"

private func c1CimdForm(_ body: String) -> [String: String] {
    var result: [String: String] = [:]
    for pair in body.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        let key = String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        let value = String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        if let key, let value { result[key] = value }
    }
    return result
}

private func c1CimdQuery(_ url: URL) -> [String: String] {
    var result: [String: String] = [:]
    for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
        result[item.name] = item.value
    }
    return result
}

private actor C1CimdEarlyPresenter: McpSignInPresenter {
    var redirects = 0
    var presentations = 0
    func redirectURL(for state: String) -> URL {
        redirects += 1
        return URL(string: "http://127.0.0.1:6000/callback")!
    }
    func present(authorizationURL: URL, state: String) -> URL {
        presentations += 1
        return URL(string: "http://127.0.0.1:6000/callback?code=test-code&state=\(state)")!
    }
    func counts() -> (Int, Int) { (redirects, presentations) }
}

private actor C1CimdPasteCapture {
    var authorizationURL: URL?
    func open(_ url: URL) { authorizationURL = url }
    func mismatchedRedirect() throws -> String {
        let authorizationURL = try #require(authorizationURL)
        let query = c1CimdQuery(authorizationURL)
        let redirect = try #require(query["redirect_uri"])
        var parts = try #require(URLComponents(string: redirect))
        parts.path = "/another-callback"
        parts.queryItems = [
            .init(name: "code", value: "test-code"),
            .init(name: "state", value: query["state"]),
            .init(name: "iss", value: c1CimdIssuer),
        ]
        return try #require(parts.url).absoluteString
    }
}

// mcp-oauth-refresh.test.ts:163-265, with host documents and the W2 iss rule.
@Suite("C1 CIMD OAuth")
struct C1CimdOAuthTests {
    @Test(.timeLimit(.minutes(1)))
    func defaultRegistrationRemainsDynamicWhenDocumentsAreSupported() async throws {
        let fixture = McpAuthFixture(issSupported: true, cimd: true)
        let presenter = McpAuthPresenterFixture(iss: c1CimdIssuer)
        let credentials = McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend())
        try await signInMcpServer(name: "test", serverURL: c1CimdServerURL, credentials: credentials,
            presenter: presenter, clientMetadataDocumentURL: c1CimdDocumentURL, http: fixture)
        #expect(await fixture.registeredClientNames() == ["pi"])
        let authorization = try #require(await presenter.authorizationURLs().first)
        #expect(c1CimdQuery(authorization)["client_id"] == "client")
        #expect(try credentials.state(name: "test", url: c1CimdServerURL)?.clientInformation?.clientID == "client")
    }

    @Test(.timeLimit(.minutes(1)))
    func documentSignInUsesHostURLAndSecondSignInRefreshes() async throws {
        let fixture = McpAuthFixture(issSupported: true, cimd: true)
        let presenter = McpAuthPresenterFixture(iss: c1CimdIssuer)
        let credentials = McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend())
        let settings = McpOAuthConfig(clientRegistration: .cimd)
        try await signInMcpServer(name: "test", serverURL: c1CimdServerURL, credentials: credentials,
            settings: settings, presenter: presenter, clientMetadataDocumentURL: c1CimdDocumentURL, http: fixture)
        let authorizations = await presenter.authorizationURLs()
        let authorization = try #require(authorizations.first)
        let query = c1CimdQuery(authorization)
        #expect(query["client_id"] == c1CimdDocumentURL.absoluteString)
        let redirect = try #require(query["redirect_uri"].flatMap(URL.init(string:)))
        #expect(redirect.host == "127.0.0.1")
        #expect(redirect.path == "/callback")
        #expect(redirect.port != nil)
        #expect(await fixture.registeredClientNames().isEmpty)
        let tokenBody = try #require(await fixture.recordedTokenRequests().first)
        #expect(c1CimdForm(tokenBody)["client_id"] == c1CimdDocumentURL.absoluteString)
        #expect(c1CimdForm(tokenBody)["redirect_uri"] == redirect.absoluteString)
        #expect(try credentials.state(name: "test", url: c1CimdServerURL)?.clientInformation == nil)
        try await signInMcpServer(name: "test", serverURL: c1CimdServerURL, credentials: credentials,
            settings: settings, presenter: presenter, clientMetadataDocumentURL: c1CimdDocumentURL, http: fixture)
        #expect(await presenter.authorizationURLs().count == 1)
        let requests = await fixture.recordedTokenRequests()
        #expect(requests.count == 2)
        let refresh = try #require(requests.last)
        #expect(c1CimdForm(refresh)["grant_type"] == "refresh_token")
        #expect(c1CimdForm(refresh)["client_id"] == c1CimdDocumentURL.absoluteString)
        #expect(await fixture.registeredClientNames().isEmpty)
        #expect(try credentials.tokens(name: "test", url: c1CimdServerURL)?.accessToken == "refreshed")
        #expect(try credentials.state(name: "test", url: c1CimdServerURL)?.clientInformation == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func staticDocumentWithoutIssuerSupportFailsBeforeAuthorization() async throws {
        let fixture = McpAuthFixture(cimd: true)
        let presenter = McpAuthPresenterFixture()
        let credentials = McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend())
        do {
            try await signInMcpServer(name: "test", serverURL: c1CimdServerURL, credentials: credentials,
                settings: .init(clientRegistration: .cimd), presenter: presenter,
                clientMetadataDocumentURL: c1CimdDocumentURL, http: fixture)
            Issue.record("Sign-in accepted a static document without issuer support")
        } catch {
            #expect(error.localizedDescription == "The authorization server does not send the iss parameter in authorization responses (RFC 9207), which oauth.clientRegistration \"cimd\" requires; remove oauth.clientRegistration to use dynamic client registration, or set oauth.clientId")
        }
        #expect(await fixture.registeredClientNames().isEmpty)
        #expect(await fixture.recordedTokenRequests().isEmpty)
        #expect(await presenter.authorizationURLs().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func switchingFromDynamicRegistrationDropsClientAndTokens() async throws {
        let fixture = McpAuthFixture(issSupported: true, cimd: true)
        let presenter = McpAuthPresenterFixture(iss: c1CimdIssuer)
        let credentials = McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend())
        try await signInMcpServer(name: "test", serverURL: c1CimdServerURL, credentials: credentials,
            presenter: presenter, http: fixture)
        #expect(try credentials.state(name: "test", url: c1CimdServerURL)?.clientInformation?.clientID == "client")
        try await signInMcpServer(name: "test", serverURL: c1CimdServerURL, credentials: credentials,
            settings: .init(clientRegistration: .cimd), presenter: presenter,
            clientMetadataDocumentURL: c1CimdDocumentURL, http: fixture)
        #expect(await presenter.authorizationURLs().map { c1CimdQuery($0)["client_id"] }
            == ["client", c1CimdDocumentURL.absoluteString])
        #expect(await fixture.refreshCount() == 0)
        #expect(await fixture.registeredClientNames() == ["pi"])
        #expect(try credentials.state(name: "test", url: c1CimdServerURL)?.clientInformation == nil)
        #expect(await fixture.recordedTokenRequests().map { c1CimdForm($0)["grant_type"] }
            == ["authorization_code", "authorization_code"])
    }

    @Test(.timeLimit(.minutes(1)))
    func pastedRedirectWithAnotherPathFails() async throws {
        let fixture = McpAuthFixture(issSupported: true, cimd: true)
        let capture = C1CimdPasteCapture()
        let presenter = McpPasteRedirectPresenter(callbackURL: URL(string: "http://127.0.0.1:6000/callback")!,
            openAuthorizationURL: { await capture.open($0) },
            pasteRedirectURL: { try await capture.mismatchedRedirect() })
        do {
            try await signInMcpServer(name: "test", serverURL: c1CimdServerURL,
                credentials: McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend()),
                settings: .init(clientRegistration: .cimd), presenter: presenter,
                clientMetadataDocumentURL: c1CimdDocumentURL, http: fixture)
            Issue.record("Sign-in accepted a pasted redirect with another path")
        } catch let error as McpOAuthError {
            guard case .invalidRedirect = error else { throw error }
        }
        #expect(await fixture.recordedTokenRequests().isEmpty)
        #expect(await fixture.registeredClientNames().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func missingDocumentSupportFailsBeforeRegistration() async throws {
        let fixture = McpAuthFixture(issSupported: true)
        let presenter = McpAuthPresenterFixture(iss: c1CimdIssuer)
        do {
            try await signInMcpServer(name: "test", serverURL: c1CimdServerURL,
                credentials: McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend()),
                settings: .init(clientRegistration: .cimd), presenter: presenter,
                clientMetadataDocumentURL: c1CimdDocumentURL, http: fixture)
            Issue.record("Sign-in used a document without server support")
        } catch {
            #expect(error.localizedDescription == "The authorization server does not support Client ID Metadata Documents for public clients; remove oauth.clientRegistration \"cimd\"")
        }
        #expect(await fixture.registeredClientNames().isEmpty)
        #expect(await fixture.recordedTokenRequests().isEmpty)
        #expect(await presenter.authorizationURLs().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func missingHostDocumentFailsBeforePresenterStarts() async throws {
        let fixture = McpAuthFixture(issSupported: true, cimd: true)
        let presenter = C1CimdEarlyPresenter()
        do {
            try await signInMcpServer(name: "test", serverURL: c1CimdServerURL,
                credentials: McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend()),
                settings: .init(clientRegistration: .cimd), presenter: presenter, http: fixture)
            Issue.record("Sign-in started without a host document URL")
        } catch {
            #expect(error.localizedDescription == "oauth.clientRegistration \"cimd\" needs a Client ID Metadata Document URL from the host application")
        }
        let counts = await presenter.counts()
        #expect(counts.0 == 0)
        #expect(counts.1 == 0)
        #expect(await fixture.observedPaths().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func refreshProviderUsesDocumentHookAndFallbackRedirect() async throws {
        let fixture = McpAuthFixture(issSupported: true, cimd: true)
        let presenter = McpAuthPresenterFixture(iss: c1CimdIssuer)
        let credentials = McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend())
        let settings = McpOAuthConfig(clientRegistration: .cimd)
        try await signInMcpServer(name: "test", serverURL: c1CimdServerURL, credentials: credentials,
            settings: settings, presenter: presenter, clientMetadataDocumentURL: c1CimdDocumentURL, http: fixture)
        let provider = McpServerAuthProvider(name: "test", serverURL: c1CimdServerURL, credentials: credentials,
            settings: settings, clientMetadataDocumentURL: c1CimdDocumentURL, http: fixture)
        #expect(try await provider.token() == "refreshed")
        #expect(await fixture.refreshCount() == 1)
        #expect(await fixture.registeredClientNames().isEmpty)
        let refresh = try #require(await fixture.recordedTokenRequests().last)
        #expect(c1CimdForm(refresh)["grant_type"] == "refresh_token")
        #expect(c1CimdForm(refresh)["client_id"] == c1CimdDocumentURL.absoluteString)
        #expect(try credentials.state(name: "test", url: c1CimdServerURL)?.clientInformation == nil)
    }
}
