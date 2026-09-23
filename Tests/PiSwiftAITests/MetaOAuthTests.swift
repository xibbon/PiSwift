import Foundation
import Testing
@testable import PiSwiftAI

private actor MetaHTTPFixture {
    struct Reply: Sendable {
        let status: Int
        let body: String
    }

    private var replies: [Reply]
    private var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest, _ signal: CancellationToken?) throws -> OAuthNetworkResponse {
        requests.append(request)
        guard !replies.isEmpty else {
            Issue.record("Unexpected Meta HTTP request")
            return OAuthNetworkResponse(data: Data(), status: 500)
        }
        let reply = replies.removeFirst()
        return OAuthNetworkResponse(data: Data(reply.body.utf8), status: reply.status)
    }

    func recordedRequests() -> [URLRequest] { requests }
}

private final class MetaLoginEvents: Sendable {
    private let state = LockedState((auth: Optional<OAuthAuthInfo>.none, progress: [String]()))

    func recordAuth(_ info: OAuthAuthInfo) { state.withLock { $0.auth = info } }
    func recordProgress(_ message: String) { state.withLock { $0.progress.append(message) } }
    func snapshot() -> (OAuthAuthInfo?, [String]) { state.withLock { ($0.auth, $0.progress) } }
}

private func metaCallbacks(_ events: MetaLoginEvents) -> OAuthLoginCallbacks {
    OAuthLoginCallbacks(
        onAuth: { info in events.recordAuth(info) },
        onPrompt: { _ in throw OAuthError.missingAuthorizationCode },
        onProgress: { message in events.recordProgress(message) }
    )
}

private func metaFixtureClient(_ fixture: MetaHTTPFixture) -> MetaOAuthHTTPClient {
    MetaOAuthHTTPClient(send: { request, signal in try await fixture.send(request, signal) })
}

@Suite("Meta OAuth", .serialized)
struct MetaOAuthTests {
    @Test func deviceFlowPendingSlowDownAndMint() async throws {
        let fixture = MetaHTTPFixture([
            .init(status: 200, body: #"{"device_code":"device-1","user_code":"ABCD","verification_uri":"https://auth.meta.com/enter","verification_uri_complete":"https://auth.meta.com/enter?code=ABCD","interval":1,"expires_in":30}"#),
            .init(status: 400, body: #"{"error":"authorization_pending"}"#),
            .init(status: 400, body: #"{"error":"slow_down","interval":1}"#),
            .init(status: 200, body: #"{"access_token":"identity-1"}"#),
            .init(status: 200, body: #"{"api_key":"minted-1"}"#),
        ])
        let events = MetaLoginEvents()
        let credentials = try await loginMeta(
            metaCallbacks(events), httpClient: metaFixtureClient(fixture), now: { 1_000 }
        )
        #expect(credentials.refresh == "identity-1")
        #expect(credentials.access == "minted-1")
        #expect(credentials.expires == 1_000 + 86_400_000)
        let requests = await fixture.recordedRequests()
        #expect(requests.count == 5)
        #expect(requests[0].url?.absoluteString == "https://auth.meta.com/oidc/device/authorization/")
        #expect(requests[0].httpMethod == "POST")
        #expect(String(data: requests[0].httpBody ?? Data(), encoding: .utf8) == "client_id=1031625952748946")
        #expect(requests[1].url?.absoluteString == "https://auth.meta.com/oidc/device/token/")
        let tokenBody = String(data: requests[1].httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(tokenBody.contains("device_code=device-1"))
        #expect(tokenBody.contains("client_id=1031625952748946"))
        #expect(tokenBody.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"))
        #expect(requests[4].url?.absoluteString == "https://api.meta.ai/muse-code/key")
        #expect(requests[4].value(forHTTPHeaderField: "Authorization") == "Bearer identity-1")
        #expect(requests[4].value(forHTTPHeaderField: "x-api-version") == "1.0.0")
        #expect(requests[4].httpBody == Data("{}".utf8))
        let (auth, progress) = events.snapshot()
        #expect(auth?.url == "https://auth.meta.com/enter?code=ABCD")
        #expect(auth?.instructions?.contains("ABCD") == true)
        #expect(progress.contains("Enabling Meta Model API access..."))
    }

    @Test func expiredDeviceCodeRequiresNewLogin() async {
        let fixture = MetaHTTPFixture([
            .init(status: 200, body: #"{"device_code":"device-1","user_code":"ABCD","verification_uri":"https://auth.meta.com/enter","interval":1,"expires_in":10}"#),
            .init(status: 400, body: #"{"error":"expired_token"}"#),
        ])
        do {
            _ = try await loginMeta(metaCallbacks(MetaLoginEvents()), httpClient: metaFixtureClient(fixture))
            Issue.record("Expired device code must fail")
        } catch {
            #expect(error.localizedDescription.contains("expired"))
        }
        #expect(await fixture.recordedRequests().count == 2)
    }

    @Test func remintsAfterOneDayAndRejectsExpiredIdentity() async throws {
        let fixture = MetaHTTPFixture([
            .init(status: 200, body: #"{"api_key":"first-key"}"#),
            .init(status: 200, body: #"{"api_key":"second-key"}"#),
            .init(status: 401, body: #"{"error":"invalid_token"}"#),
        ])
        let client = metaFixtureClient(fixture)
        let first = try await refreshMetaToken("identity-1", httpClient: client, now: { 2_000 })
        #expect(first.refresh == "identity-1")
        #expect(first.access == "first-key")
        #expect(!oauthCredentialNeedsRefresh(first, now: 2_000))
        #expect(oauthCredentialNeedsRefresh(first, now: 2_000 + 86_400_000))
        let second = try await refreshMetaToken(first.refresh, httpClient: client, now: { 2_000 + 86_400_000 })
        #expect(second.refresh == "identity-1")
        #expect(second.access == "second-key")
        #expect(second.expires == 2_000 + 2 * 86_400_000)
        do {
            _ = try await refreshMetaToken(second.refresh, httpClient: client)
            Issue.record("Expired identity must require login")
        } catch {
            #expect(error.localizedDescription.contains("/login meta"))
        }
        #expect(await fixture.recordedRequests().count == 3)
    }

    @Test func missingKeyReportsSetupURL() async {
        let fixture = MetaHTTPFixture([
            .init(status: 200, body: #"{"action_url":"https://api.meta.ai/setup"}"#),
        ])
        do {
            _ = try await refreshMetaToken("identity-1", httpClient: metaFixtureClient(fixture))
            Issue.record("Missing key must fail")
        } catch {
            #expect(error.localizedDescription.contains("https://api.meta.ai/setup"))
        }
    }

    @Test func environmentKeyAndProviderRegistration() {
        let prior = getenv("META_API_KEY").map { String(cString: $0) }
        setenv("META_API_KEY", "meta-env-key", 1)
        defer {
            if let prior { setenv("META_API_KEY", prior, 1) }
            else { unsetenv("META_API_KEY") }
        }
        #expect(getEnvApiKey(provider: "meta") == "meta-env-key")
        #expect(findEnvKeys(provider: .meta) == ["META_API_KEY"])
        #expect(getOAuthProviders().contains { $0.id == .meta && $0.name == "Meta (Muse subscription)" })
        let model = getModel(provider: .meta, modelId: "muse-spark-1.1")
        #expect(model.api == .openAIResponses)
        #expect(model.baseUrl == "https://api.meta.ai/v1")
    }
}
