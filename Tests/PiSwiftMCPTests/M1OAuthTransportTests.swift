import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import Synchronization
@testable import PiSwiftMCP

private actor M1OAuthMetadataHTTP: McpOAuthHTTPClient {
    let endpoint: String
    init(endpoint: String) { self.endpoint = endpoint }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let body: [String: Any] = [
            "issuer": "http://127.0.0.1:45454",
            "authorization_endpoint": endpoint,
            "token_endpoint": "http://127.0.0.1:45454/token",
            "response_types_supported": ["code"],
        ]
        return (try JSONSerialization.data(withJSONObject: body),
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

// Upstream oauth.test.ts: rejects non-HTTP authorization endpoints, which the platform URL handler would launch.
@Test("rejects non-HTTP authorization endpoints, which the platform URL handler would launch",
      arguments: ["file://attacker.example/share/x.exe", "search-ms:query=x", "ms-msdt:/id"])
func m1RejectsNonHTTPAuthorizationEndpoints(_ endpoint: String) async throws {
    let issuer = URL(string: "http://127.0.0.1:45454")!
    do {
        _ = try await McpOAuthDiscovery.authorizationServerMetadata(
            issuer: issuer, http: M1OAuthMetadataHTTP(endpoint: endpoint))
        Issue.record("Discovery accepted \(endpoint)")
    } catch let error as McpOAuthError {
        #expect(error.errorDescription == "Invalid authorization endpoint")
    }

    let metadata = McpOAuthAuthorizationServerMetadata(
        issuer: issuer.absoluteString, authorizationEndpoint: endpoint,
        tokenEndpoint: "\(issuer.absoluteString)/token")
    do {
        _ = try McpOAuthFlow.startAuthorization(
            authorizationServerURL: issuer, metadata: metadata,
            clientInformation: McpOAuthClientInformation(clientID: "client"),
            redirectURL: URL(string: "http://127.0.0.1/callback")!)
        Issue.record("Direct authorization accepted \(endpoint)")
    } catch let error as McpOAuthError {
        #expect(error.errorDescription == "Invalid authorization endpoint \(URL(string: endpoint)!.absoluteString)")
    }
}

@Test("OAuth metadata URL checks accept HTTP and HTTPS, and reject other schemes")
func m1OAuthMetadataURLChecks() throws {
    let decoder = JSONDecoder()
    for scheme in ["http", "https"] {
        let data = Data(#"{"resource":"SCHEME://mcp.example/mcp","authorization_servers":["SCHEME://auth.example"]}"#
            .replacingOccurrences(of: "SCHEME", with: scheme).utf8)
        let metadata = try decoder.decode(McpOAuthProtectedResourceMetadata.self, from: data)
        #expect(metadata.resource.hasPrefix(scheme))
    }
    for (field, json) in [
        ("OAuth protected resource metadata resource", #"{"resource":"file://mcp.example/mcp"}"#),
        ("authorization server URL", #"{"resource":"https://mcp.example/mcp","authorization_servers":["file://auth.example"]}"#),
        ("authorization server issuer", #"{"issuer":"file://auth.example","authorization_endpoint":"https://auth.example/authorize","token_endpoint":"https://auth.example/token","response_types_supported":["code"]}"#),
        ("token endpoint", #"{"issuer":"https://auth.example","authorization_endpoint":"https://auth.example/authorize","token_endpoint":"file://auth.example/token","response_types_supported":["code"]}"#),
        ("registration endpoint", #"{"issuer":"https://auth.example","authorization_endpoint":"https://auth.example/authorize","token_endpoint":"https://auth.example/token","registration_endpoint":"file://auth.example/register","response_types_supported":["code"]}"#),
    ] {
        do {
            if field == "OAuth protected resource metadata resource" || field == "authorization server URL" {
                _ = try decoder.decode(McpOAuthProtectedResourceMetadata.self, from: Data(json.utf8))
            } else {
                _ = try decoder.decode(McpOAuthAuthorizationServerMetadata.self, from: Data(json.utf8))
            }
            Issue.record("Accepted \(field)")
        } catch let error as McpOAuthError {
            #expect(error.errorDescription == "Invalid \(field)")
        }
    }
}

#if canImport(Network) && os(macOS)
import Network
import PiSwiftAI

// Upstream oauth.test.ts: closes while the browser keeps an unused connection open.
// Swift sends Connection: close for complete requests, so a spare preconnected socket is the idle case.
@Test("closes while the browser keeps an unused connection open", .timeLimit(.minutes(1)))
func m1CallbackClosesWithIdleConnection() async throws {
    let server = try await OAuthCallbackServer<String>.start(
        providerName: "MCP", port: 0, path: "/callback", state: "s1",
        complete: { components in components.queryItems?.first { $0.name == "code" }?.value ?? "" })
    let redirect = try #require(URL(string: await server.redirectUri()))
    let port = try #require(redirect.port.flatMap { NWEndpoint.Port(rawValue: UInt16($0)) })
    let spare = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
    let queue = DispatchQueue(label: "m1.oauth.idle-socket")
    let resumed = Mutex(false)
    do {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            spare.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.withLock({ done in
                        if done { return false }
                        done = true
                        return true
                    }) { continuation.resume() }
                case .failed(let error):
                    if resumed.withLock({ done in
                        if done { return false }
                        done = true
                        return true
                    }) { continuation.resume(throwing: error) }
                default: break
                }
            }
            spare.start(queue: queue)
        }
        let callbackURL = try #require(URL(string: "\(redirect.absoluteString)?code=abc&state=s1"))
        _ = try await URLSession.shared.data(from: callbackURL)
        #expect(try await server.wait() == "abc")
        let clock = ContinuousClock()
        let start = clock.now
        await server.close()
        #expect(clock.now - start < .seconds(1))
    } catch {
        await server.close()
        spare.cancel()
        throw error
    }
    spare.cancel()
}
#endif
