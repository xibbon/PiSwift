import Foundation
import Testing
@testable import PiSwiftAI

private let identityACME = ClientAttribution(name: "acme", url: "https://acme.example")

@Suite("Client identity")
struct ClientIdentityTests {
    @Test func versionMatchesPortTarget() {
        #expect(PI_AI_VERSION == "1.4.0")
    }

    @Test func formatsUserAgents() {
        #if os(macOS)
        let platform = "darwin"
        #elseif os(Linux)
        let platform = "linux"
        #elseif os(iOS)
        let platform = "ios"
        #elseif os(tvOS)
        let platform = "tvos"
        #elseif os(watchOS)
        let platform = "watchos"
        #elseif os(visionOS)
        let platform = "visionos"
        #else
        let platform = "unknown"
        #endif
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x64"
        #elseif arch(i386)
        let architecture = "ia32"
        #elseif arch(arm)
        let architecture = "arm"
        #else
        let architecture = "unknown"
        #endif
        #expect(formatUserAgent() == "pi/\(PI_AI_VERSION) (\(platform); swift; \(architecture))")
        #expect(formatUserAgent(.detailed) == formatUserAgent())
        #expect(formatUserAgent(.short) == "pi")
        #expect(formatUserAgent(.custom("acme/1.0")) == "acme/1.0")
        #expect(formatUserAgent(identity: ClientIdentity(version: "9.9.9")) == "pi/9.9.9 (\(platform); swift; \(architecture))")
        #expect(formatUserAgent(identity: ClientIdentity(userAgent: .short, version: "9.9.9")) == "pi")
        #expect(formatUserAgent(identity: ClientIdentity(userAgent: .custom("acme/1.0"))) == "acme/1.0")
        #expect(formatUserAgent(identity: nil) == formatUserAgent())
        #expect(formatBedrockUserAgent() == "pi/\(PI_AI_VERSION)")
        #expect(formatBedrockUserAgent(.short) == "pi")
        #expect(formatBedrockUserAgent(.custom("acme/1.0")) == "acme/1.0")
        #expect(formatBedrockUserAgent(identity: ClientIdentity(version: "9.9.9")) == "pi/9.9.9")
        #expect(formatBedrockUserAgent(identity: ClientIdentity(userAgent: .short, version: "9.9.9")) == "pi")
    }

    @Test func mergesIdentitiesFieldByField() {
        #expect(mergeClientIdentity(nil, nil) == nil)
        #expect(mergeClientIdentity() == nil)
        #expect(mergeClientIdentity(
            ClientIdentity(userAgent: .short, attribution: .value(PI_ATTRIBUTION)),
            ClientIdentity(version: "1.0.0")
        ) == ClientIdentity(userAgent: .short, attribution: .value(PI_ATTRIBUTION), version: "1.0.0"))
        #expect(mergeClientIdentity(ClientIdentity(attribution: .value(PI_ATTRIBUTION)), ClientIdentity(attribution: .disabled)) == ClientIdentity(attribution: .disabled))
        #expect(mergeClientIdentity(ClientIdentity(), nil) == ClientIdentity())
        #expect(mergeClientIdentity(
            ClientIdentity(userAgent: .short, attribution: .disabled, version: "old"),
            ClientIdentity(userAgent: .custom("acme"), attribution: .value(identityACME), version: "new")
        ) == ClientIdentity(userAgent: .custom("acme"), attribution: .value(identityACME), version: "new"))
    }

    @Test func sendsNoAttributionUnlessEnabled() {
        #expect(attributionHeaders(provider: "openrouter", baseUrl: "https://openrouter.ai/api/v1").isEmpty)
        #expect(attributionHeaders(provider: "openrouter", baseUrl: "https://openrouter.ai/api/v1", identity: ClientIdentity(attribution: .disabled)).isEmpty)
        #expect(identityHeaders(provider: "openrouter", baseUrl: "https://openrouter.ai/api/v1") == ["User-Agent": formatUserAgent()])
    }

    @Test func attributesOpenRouterRequests() {
        #expect(attributionHeaders(provider: "openrouter", baseUrl: "https://openrouter.ai/api/v1", identity: ClientIdentity(attribution: .value(PI_ATTRIBUTION))) == [
            "HTTP-Referer": "https://pi.dev", "X-OpenRouter-Title": "pi", "X-OpenRouter-Categories": "cli-agent",
        ])
        #expect(attributionHeaders(provider: "openrouter", baseUrl: "https://openrouter.ai/api/v1", identity: ClientIdentity(attribution: .value(ClientAttribution(name: identityACME.name, url: identityACME.url, categories: ["cli-agent", "cloud-agent"])))) == [
            "HTTP-Referer": "https://acme.example", "X-OpenRouter-Title": "acme", "X-OpenRouter-Categories": "cli-agent,cloud-agent",
        ])
        let categoryCases: [[String]?] = [nil, []]
        for categories in categoryCases {
            #expect(attributionHeaders(provider: "openrouter", baseUrl: "https://openrouter.ai/api/v1", identity: ClientIdentity(attribution: .value(ClientAttribution(name: identityACME.name, url: identityACME.url, categories: categories)))) == [
                "HTTP-Referer": "https://acme.example", "X-OpenRouter-Title": "acme",
            ])
        }
        #expect(attributionHeaders(provider: "custom", baseUrl: "not-a-url-openrouter.ai", identity: ClientIdentity(attribution: .value(PI_ATTRIBUTION)))["X-OpenRouter-Title"] == "pi")
    }

    @Test func attributesNvidiaAndOpenCodeRequests() {
        #expect(attributionHeaders(provider: "nvidia", baseUrl: "https://example.test/v1", identity: ClientIdentity(attribution: .value(PI_ATTRIBUTION))) == ["X-BILLING-INVOKE-ORIGIN": "Pi"])
        #expect(attributionHeaders(provider: "custom-nim", baseUrl: "https://integrate.api.nvidia.com/v1", identity: ClientIdentity(attribution: .value(identityACME))) == ["X-BILLING-INVOKE-ORIGIN": "Acme"])
        #expect(attributionHeaders(provider: "opencode", baseUrl: "https://opencode.ai/zen/v1", identity: ClientIdentity(attribution: .value(PI_ATTRIBUTION))) == ["x-opencode-client": "pi"])
        #expect(attributionHeaders(provider: "custom", baseUrl: "https://opencode.ai/zen/v1", identity: ClientIdentity(attribution: .value(identityACME))) == ["x-opencode-client": "acme"])
        #expect(attributionHeaders(provider: "opencode-go", baseUrl: "https://example.test/v1", identity: ClientIdentity(attribution: .value(identityACME))) == ["x-opencode-client": "acme"])
    }

    @Test func gatewaysDoNotReceiveNvidiaAttribution() {
        #expect(attributionHeaders(provider: "openrouter", baseUrl: "https://openrouter.ai/api/v1", identity: ClientIdentity(attribution: .value(PI_ATTRIBUTION)))["X-BILLING-INVOKE-ORIGIN"] == nil)
        #expect(attributionHeaders(provider: "vercel-ai-gateway", baseUrl: "https://ai-gateway.vercel.sh/v1", identity: ClientIdentity(attribution: .value(PI_ATTRIBUTION))).isEmpty)
    }

    @Test func hostChecksUseExactHostAndIgnoreHostCase() {
        let identity = ClientIdentity(attribution: .value(identityACME))
        #expect(attributionHeaders(provider: "custom", baseUrl: "https://INTEGRATE.API.NVIDIA.COM/v1", identity: identity) == ["X-BILLING-INVOKE-ORIGIN": "Acme"])
        #expect(attributionHeaders(provider: "custom", baseUrl: "https://OPENCODE.AI/zen/v1", identity: identity) == ["x-opencode-client": "acme"])
        for url in ["https://opencode.ai.example/v1", "https://sub.opencode.ai/v1", "https://example.test/opencode.ai", "not-a-url-opencode.ai", "https://integrate.api.nvidia.com.example/v1", "https://example.test/integrate.api.nvidia.com", "not-a-url-integrate.api.nvidia.com"] {
            #expect(attributionHeaders(provider: "custom", baseUrl: url, identity: identity).isEmpty)
        }
    }

    @Test func identityCodableUsesPlainJSON() throws {
        let cases: [(String, ClientIdentity)] = [
            (#"{}"#, ClientIdentity()),
            (#"{"attribution":null}"#, ClientIdentity(attribution: .disabled)),
            (#"{"attribution":{"name":"acme","url":"https://acme.example"}}"#, ClientIdentity(attribution: .value(identityACME))),
            (#"{"userAgent":"short","version":"9.9.9"}"#, ClientIdentity(userAgent: .short, version: "9.9.9")),
            (#"{"userAgent":"detailed"}"#, ClientIdentity(userAgent: .detailed)),
            (#"{"userAgent":{"custom":"acme/1.0"},"attribution":{"name":"pi","url":"https://pi.dev","categories":["cli-agent"]},"version":"1.0.0"}"#, ClientIdentity(userAgent: .custom("acme/1.0"), attribution: .value(PI_ATTRIBUTION), version: "1.0.0")),
        ]
        for (json, identity) in cases {
            let input = Data(json.utf8)
            #expect(try JSONDecoder().decode(ClientIdentity.self, from: input) == identity)
            let encoded = try JSONEncoder().encode(identity)
            #expect(try JSONSerialization.jsonObject(with: encoded) as? NSDictionary == JSONSerialization.jsonObject(with: input) as? NSDictionary)
        }
    }
}

private actor IdentityRequestClient: ProviderHTTPClient {
    private var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        let frames = "data: {\"id\":\"chatcmpl-identity\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":\"test-model\",\"choices\":[{\"delta\":{\"content\":\"ok\"},\"finish_reason\":null,\"index\":0}]}\n\ndata: {\"id\":\"chatcmpl-identity\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":\"test-model\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\",\"index\":0}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}\n\ndata: [DONE]\n\n"
        return ProviderHTTPResponse(statusCode: 200, headers: ["content-type": "text/event-stream"], body: Data(frames.utf8))
    }

    func lastRequest() -> URLRequest? { requests.last }
}

private func identityRequestModel(provider: String, baseUrl: String, headers: ProviderHeaders? = nil) -> Model {
    Model(id: "test-model", name: "Test Model", api: .openAICompletions, provider: provider,
          baseUrl: baseUrl, reasoning: false, input: [.text],
          cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
          contextWindow: 128_000, maxTokens: 4096, headers: headers)
}

extension ClientIdentityTests {
    @Test(.timeLimit(.minutes(1))) func configuredHeadersOverrideRequestIdentity() async throws {
        let client = IdentityRequestClient()
        let model = identityRequestModel(provider: "openrouter", baseUrl: "https://openrouter.ai/api/v1", headers: ["X-OpenRouter-Title": "model-title"])
        let result = await streamOpenAICompletions(
            model: model,
            context: normalizeContext(Context(messages: [.user(UserMessage(content: .text("hello"), timestamp: 1))])),
            options: OpenAICompletionsOptions(identity: ClientIdentity(userAgent: .short, attribution: .value(PI_ATTRIBUTION)), apiKey: "key", httpClient: client, headers: ["HTTP-Referer": nil])
        ).result()
        #expect(result.stopReason == .stop)
        let request = try #require(await client.lastRequest())
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "pi")
        #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Title") == "model-title")
        #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == nil)
    }

    @Test(.timeLimit(.minutes(1))) func impersonatingModelUserAgentOverridesIdentity() async throws {
        let client = IdentityRequestClient()
        let model = identityRequestModel(provider: "github-copilot", baseUrl: "https://api.githubcopilot.com", headers: ["User-Agent": "GitHubCopilotChat/0.35.0"])
        let result = await streamOpenAICompletions(
            model: model,
            context: normalizeContext(Context(messages: [.user(UserMessage(content: .text("hello"), timestamp: 1))])),
            options: OpenAICompletionsOptions(identity: ClientIdentity(userAgent: .custom("acme")), apiKey: "key", httpClient: client)
        ).result()
        #expect(result.stopReason == .stop)
        let request = try #require(await client.lastRequest())
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "GitHubCopilotChat/0.35.0")
    }
}
