import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import PiSwiftMCP

private actor OAuthV104RegistrationFixture: McpOAuthHTTPClient {
    var applicationTypes: [String] = []
    var scopes: [String?] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data = try #require(request.httpBody)
        var body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        applicationTypes.append(try #require(body["application_type"] as? String))
        scopes.append(body["scope"] as? String)
        body["client_id"] = "client"
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 201,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]))
        return (try JSONSerialization.data(withJSONObject: body), response)
    }

    func recordedApplicationTypes() -> [String] { applicationTypes }
    func recordedScopes() -> [String?] { scopes }
}

@Suite("v1.0.4 OAuth registration")
struct OAuthV104Tests {
    private let origin = URL(string: "http://127.0.0.1:45454")!

    // Upstream oauth.test.ts:411–430, MCP SEP-837 (#10493).
    @Test(.timeLimit(.minutes(1)))
    func registrationDerivesApplicationTypeUnlessSet() async throws {
        let fixture = OAuthV104RegistrationFixture()
        let registrations: [(String, String?, String)] = [
            ("http://127.0.0.1:1234/callback", nil, "native"),
            ("http://[::1]/callback", nil, "native"),
            ("com.example.app:/callback", nil, "native"),
            ("https://app.example/callback", nil, "web"),
            ("http://localhost/callback", "web", "web"),
        ]
        for (redirect, applicationType, expectedType) in registrations {
            let information = try await McpOAuthFlow.registerClient(authorizationServerURL: origin,
                clientMetadata: .init(redirectURIs: [redirect], applicationType: applicationType), http: fixture)
            #expect(information.clientID == "client")
            #expect(information.metadata?.applicationType == expectedType)
        }
        #expect(await fixture.recordedApplicationTypes() == ["native", "native", "native", "web", "web"])
    }

    // #10493: an absolute native URI in any position determines the default.
    @Test(.timeLimit(.minutes(1)))
    func registrationChecksEveryURIAndIgnoresInvalidAndRelativeURIs() async throws {
        let fixture = OAuthV104RegistrationFixture()
        _ = try await McpOAuthFlow.registerClient(authorizationServerURL: origin,
            clientMetadata: .init(redirectURIs: ["https://app.example/callback", "com.example.app:/callback"]), http: fixture)
        _ = try await McpOAuthFlow.registerClient(authorizationServerURL: origin,
            clientMetadata: .init(redirectURIs: ["http://[", "/callback", "not a url"]), http: fixture)
        _ = try await McpOAuthFlow.registerClient(authorizationServerURL: origin,
            clientMetadata: .init(), http: fixture)
        #expect(await fixture.recordedApplicationTypes() == ["native", "web", "web"])
    }

    // #10493: WHATWG normalizes HTTP scheme and host case, and ?? keeps an explicit empty string.
    @Test(.timeLimit(.minutes(1)))
    func registrationNormalizesHTTPCaseAndKeepsExplicitValuesAndScope() async throws {
        let fixture = OAuthV104RegistrationFixture()
        _ = try await McpOAuthFlow.registerClient(authorizationServerURL: origin,
            clientMetadata: .init(redirectURIs: ["HTTP://APP.EXAMPLE/callback"]), http: fixture)
        _ = try await McpOAuthFlow.registerClient(authorizationServerURL: origin,
            clientMetadata: .init(redirectURIs: ["HTTP://LOCALHOST/callback"]), http: fixture)
        _ = try await McpOAuthFlow.registerClient(authorizationServerURL: origin,
            clientMetadata: .init(redirectURIs: ["http://localhost/callback"], applicationType: "", scope: "stored"),
            scope: "override", http: fixture)
        #expect(await fixture.recordedApplicationTypes() == ["web", "native", ""])
        #expect(await fixture.recordedScopes() == [nil, nil, "override"])
    }

    // #10493: stored client metadata preserves application_type on decode and encode.
    @Test
    func storedClientMetadataPreservesApplicationType() throws {
        let document = Data(#"{"redirect_uris":["http://localhost/callback"],"application_type":"web","client_name":"stored"}"#.utf8)
        let metadata = try JSONDecoder().decode(McpOAuthClientMetadata.self, from: document)
        #expect(metadata.applicationType == "web")
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
        #expect(encoded["application_type"] as? String == "web")
        #expect(try JSONDecoder().decode(McpOAuthClientMetadata.self, from: JSONEncoder().encode(metadata)) == metadata)
        let previousDocument = Data(#"{"redirect_uris":["http://localhost/callback"]}"#.utf8)
        #expect(try JSONDecoder().decode(McpOAuthClientMetadata.self, from: previousDocument).applicationType == nil)
    }
}
