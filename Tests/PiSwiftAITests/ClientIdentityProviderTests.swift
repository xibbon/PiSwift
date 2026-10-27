import Foundation
import Testing
@testable import PiSwiftAI

// Upstream v1.4.0 identity change: test each provider request boundary without network access.
private enum IdentityProviderSite: String, CaseIterable, Sendable {
    case anthropic, anthropicHeaderAuth, anthropicFederation, anthropicCopilot, anthropicOAuth
    case azure, completions, zaiCompletions, responses, codex, google, vertexKey, vertexADC, mistral

    var api: Api {
        switch self {
        case .anthropic, .anthropicHeaderAuth, .anthropicFederation, .anthropicCopilot, .anthropicOAuth: .anthropicMessages
        case .azure: .azureOpenAIResponses
        case .completions, .zaiCompletions: .openAICompletions
        case .responses: .openAIResponses
        case .codex: .openAICodexResponses
        case .google: .googleGenerativeAI
        case .vertexKey, .vertexADC: .googleVertex
        case .mistral: .mistralConversations
        }
    }

    var provider: String {
        switch self {
        case .anthropic, .anthropicHeaderAuth, .anthropicFederation, .anthropicOAuth: "anthropic"
        case .anthropicCopilot: "github-copilot"
        case .azure: "azure"
        case .zaiCompletions: "zai"
        case .codex: "openai-codex"
        case .google: "google"
        case .vertexKey, .vertexADC: "google-vertex"
        case .mistral: "mistral"
        default: "openai"
        }
    }
}

private enum IdentityHeaderCase: CaseIterable, Sendable {
    case defaults, detailed, short, custom, modelOverride, requestOverride, requestDeletion

    var identity: ClientIdentity? {
        switch self {
        case .defaults: nil
        case .detailed: ClientIdentity(userAgent: .detailed)
        case .short: ClientIdentity(userAgent: .short)
        default: ClientIdentity(userAgent: .custom("suite/1.0"))
        }
    }

    var modelHeaders: ProviderHeaders? {
        switch self {
        case .modelOverride, .requestOverride, .requestDeletion: ["USER-AGENT": "model/1.0"]
        default: nil
        }
    }

    var headers: ProviderHeaders? {
        switch self {
        case .requestOverride: ["uSeR-aGeNt": "request/1.0"]
        case .requestDeletion: ["uSeR-aGeNt": nil]
        default: nil
        }
    }

    func expected(oauth: Bool = false) -> String? {
        switch self {
        case .defaults, .detailed: oauth ? "claude-cli/2.1.280" : formatUserAgent()
        case .short: oauth ? "claude-cli/2.1.280" : "pi"
        case .custom: oauth ? "claude-cli/2.1.280" : "suite/1.0"
        case .modelOverride: "model/1.0"
        case .requestOverride: "request/1.0"
        case .requestDeletion: nil
        }
    }
}

private actor IdentityProviderHTTP: ProviderHTTPClient {
    private var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        if request.url?.path.hasSuffix("/v1/oauth/token") == true {
            return ProviderHTTPResponse(statusCode: 200,
                body: Data(#"{"access_token":"federated-identity","expires_in":3600}"#.utf8))
        }
        return ProviderHTTPResponse(statusCode: 403,
            body: Data(#"{"error":{"message":"request captured"}}"#.utf8))
    }

    func captured() -> [URLRequest] { requests }
}

private func identityProviderModel(_ site: IdentityProviderSite, headers: ProviderHeaders?,
                                   baseURL: String = "https://identity.example/v1") -> Model {
    Model(id: "test-model", name: "Test", api: site.api, provider: site.provider,
        baseUrl: baseURL, reasoning: false, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 32_768, maxTokens: 4096, headers: headers)
}

private func identityCodexToken() -> String {
    let payload = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"identity-account"}}"#.utf8)
        .base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "header.\(payload).signature"
}

private func identityProviderRequest(_ site: IdentityProviderSite, _ scenario: IdentityHeaderCase,
                                     identity: ClientIdentity? = nil,
                                     baseURL: String = "https://identity.example/v1") async throws -> URLRequest {
    let client = IdentityProviderHTTP()
    let model = identityProviderModel(site, headers: scenario.modelHeaders, baseURL: baseURL)
    let effectiveIdentity = identity ?? scenario.identity
    let context = normalizeContext(Context(messages: [.user(UserMessage(content: .text("Hello")))]))
    let stream: AssistantMessageEventStream
    switch site {
    case .anthropic, .anthropicHeaderAuth, .anthropicFederation, .anthropicCopilot, .anthropicOAuth:
        let tokenFile = FileManager.default.temporaryDirectory.appendingPathComponent("identity-\(UUID().uuidString).jwt")
        defer { try? FileManager.default.removeItem(at: tokenFile) }
        var env: [String: String] = [:]
        var apiKey: String? = site == .anthropicOAuth ? "sk-ant-oat01-identity" : "test-key"
        var headers = scenario.headers
        if site == .anthropicHeaderAuth {
            apiKey = ""
            headers = mergeProviderHeaders(["Authorization": "Bearer owned-auth"], headers)
        }
        if site == .anthropicFederation {
            apiKey = nil
            try "header.payload.signature".write(to: tokenFile, atomically: true, encoding: .utf8)
            env = ["ANTHROPIC_FEDERATION_RULE_ID": "identity-rule", "ANTHROPIC_ORGANIZATION_ID": "identity-org",
                "ANTHROPIC_IDENTITY_TOKEN_FILE": tokenFile.path]
        }
        var options = AnthropicOptions(env: env, apiKey: apiKey, httpClient: client, headers: headers, maxRetries: 0)
        options.identity = effectiveIdentity
        // Keep the token file until the request has completed.
        _ = await streamAnthropic(model: model, context: context, options: options).result()
        let requests = await client.captured()
        if site == .anthropicFederation {
            #expect(requests.count == 2)
            #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer federated-identity")
        }
        return try #require(requests.last)
    case .azure:
        var options = AzureOpenAIResponsesOptions(apiKey: "test-key", httpClient: client, headers: scenario.headers, maxRetries: 0)
        options.identity = effectiveIdentity
        options.azureBaseUrl = "https://identity.openai.azure.com"
        options.azureApiVersion = "v1"
        options.azureDeploymentName = "identity-test"
        stream = streamAzureOpenAIResponses(model: model, context: context, options: options)
    case .completions, .zaiCompletions:
        var options = OpenAICompletionsOptions(apiKey: "test-key", httpClient: client, headers: scenario.headers, maxRetries: 0)
        options.identity = effectiveIdentity
        stream = streamOpenAICompletions(model: model, context: context, options: options)
    case .responses:
        var options = OpenAIResponsesOptions(apiKey: "test-key", httpClient: client, headers: scenario.headers, maxRetries: 0)
        options.identity = effectiveIdentity
        stream = streamOpenAIResponses(model: model, context: context, options: options)
    case .codex:
        var options = OpenAICodexResponsesOptions(apiKey: identityCodexToken(), httpClient: client,
            transport: .sse, headers: scenario.headers, maxRetries: 0)
        options.identity = effectiveIdentity
        stream = streamOpenAICodexResponses(model: model, context: context, options: options)
    case .google:
        var options = GoogleOptions(apiKey: "test-key", httpClient: client, headers: scenario.headers, maxRetries: 0)
        options.identity = effectiveIdentity
        stream = streamGoogle(model: model, context: context, options: options)
    case .vertexKey, .vertexADC:
        let adc = site == .vertexADC
        var options = GoogleVertexOptions(env: adc ? ["GOOGLE_ACCESS_TOKEN": "adc-token"] : [:],
            apiKey: adc ? "gcp-vertex-credentials" : "key-token", httpClient: client,
            headers: scenario.headers, project: "identity-project", location: "us-central1", maxRetries: 0)
        options.identity = effectiveIdentity
        stream = streamGoogleVertex(model: model, context: context, options: options)
    case .mistral:
        var options = MistralOptions(apiKey: "test-key", httpClient: client, headers: scenario.headers, maxRetries: 0)
        options.identity = effectiveIdentity
        stream = streamMistral(model: model, context: context, options: options)
    }
    _ = await stream.result()
    return try #require(await client.captured().last)
}

@Test(.timeLimit(.minutes(1)), arguments: IdentityProviderSite.allCases, IdentityHeaderCase.allCases)
private func clientIdentityReachesEachProviderSite(_ site: IdentityProviderSite, _ scenario: IdentityHeaderCase) async throws {
    let request = try await identityProviderRequest(site, scenario)
    #expect(request.value(forHTTPHeaderField: "User-Agent") == scenario.expected(oauth: site == .anthropicOAuth))
    #expect((request.allHTTPHeaderFields?.keys.filter { $0.lowercased() == "user-agent" }.count ?? 0) <= 1)
    if site == .anthropicOAuth { #expect(request.value(forHTTPHeaderField: "x-app") == "cli") }
    if site == .codex { #expect(request.value(forHTTPHeaderField: "originator") == "pi") }
    if site == .vertexADC { #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer adc-token") }
    if site == .vertexKey { #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer key-token") }
}

@Test(.timeLimit(.minutes(1)), arguments: IdentityHeaderCase.allCases)
private func clientIdentityReachesOpenRouterImages(_ scenario: IdentityHeaderCase) async throws {
    let client = IdentityProviderHTTP()
    let model = ImageModel(id: "image-test", name: "Image", api: .openrouterImages, provider: "openrouter",
        baseUrl: "https://identity.example/v1", input: [.text], output: [.image],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), headers: scenario.modelHeaders)
    var options = ImagesOptions(apiKey: "test-key", httpClient: client, headers: scenario.headers, maxRetries: 0)
    options.identity = scenario.identity
    _ = await generateImagesOpenRouter(model: model, context: ImagesContext(input: [.text(TextContent(text: "Draw"))]), options: options)
    let request = try #require(await client.captured().last)
    #expect(request.value(forHTTPHeaderField: "User-Agent") == scenario.expected())
}

private enum IdentityClassifierSite: CaseIterable, Sendable {
    case typesafe, cloudflare, decisions

    var api: ClassifierApi {
        switch self {
        case .typesafe: .typesafeSystemOne
        case .cloudflare: .cloudflareWorkersAISystemOne
        case .decisions: .openAIDecisions
        }
    }
}

@Test(.timeLimit(.minutes(1)), arguments: IdentityClassifierSite.allCases, IdentityHeaderCase.allCases)
private func clientIdentityReachesSharedClassifiers(_ site: IdentityClassifierSite, _ scenario: IdentityHeaderCase) async throws {
    let client = IdentityProviderHTTP()
    let model = ClassifierModel(id: "identity-test", name: "Test", api: site.api, provider: "custom",
        baseUrl: "https://identity.example/v1", input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 32_768, headers: scenario.modelHeaders)
    let context = ClassifierContext(state: ["text": AnyCodable("Hello")], questions: [
        "approved": .bool(instructions: "Approved?", trueCriterion: "Yes", falseCriterion: "No")
    ])
    var options = ClassifierOptions(apiKey: "test-key", httpClient: client, headers: scenario.headers, maxRetries: 0)
    options.identity = scenario.identity
    switch site {
    case .typesafe: _ = await classifyTypeSafeSystemOne(model: model, context: context, options: options)
    case .cloudflare: _ = await classifyCloudflareWorkersAISystemOne(model: model, context: context, options: options)
    case .decisions: _ = await classifyOpenAIDecisions(model: model, context: context, options: options)
    }
    let request = try #require(await client.captured().last)
    #expect(request.value(forHTTPHeaderField: "User-Agent") == scenario.expected())
}

// The WebSocket transport uses this header builder before it creates the connection.
@Test(arguments: IdentityHeaderCase.allCases)
private func clientIdentityReachesCodexWebSocket(_ scenario: IdentityHeaderCase) throws {
    let base = try buildOpenAICodexHeaders(baseHeaders: scenario.modelHeaders,
        additionalHeaders: scenario.headers, accessToken: identityCodexToken(), identity: scenario.identity)
    let headers = buildCodexWebSocketHeaders(baseHeaders: base, requestId: "identity-request")
    #expect(providerHeaderValue(headers, name: "User-Agent") == scenario.expected())
    #expect(providerHeaderValue(headers, name: "originator") == "pi")
    #expect(providerHeaderValue(headers, name: "Authorization") == "Bearer \(identityCodexToken())")
}

private let identityBedrockHost = "identity-bedrock.invalid"
private let identityBedrockRequests = LockedState<[URLRequest]>([])

private final class IdentityBedrockProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == identityBedrockHost }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        identityBedrockRequests.withLock { $0.append(request) }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("request captured".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test(.timeLimit(.minutes(1)), arguments: IdentityHeaderCase.allCases)
private func clientIdentityBedrockUsesReducedUserAgentAndProtectsSignedHeaders(_ scenario: IdentityHeaderCase) async throws {
    try await codexRequestLock.withLock {
        #expect(URLProtocol.registerClass(IdentityBedrockProtocol.self))
        defer { URLProtocol.unregisterClass(IdentityBedrockProtocol.self) }
        identityBedrockRequests.withLock { $0.removeAll() }
        let model = Model(id: "anthropic.claude-test", name: "Claude", api: .bedrockConverseStream, provider: "amazon-bedrock",
            baseUrl: "https://\(identityBedrockHost)", reasoning: false, input: [.text],
            cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 32_768, maxTokens: 4096, headers: scenario.modelHeaders)
        let headers = mergeProviderHeaders([
            "AUTHORIZATION": "untrusted", "hOsT": "untrusted.invalid", "X-AMZ-DATE": "untrusted",
            "X-AMZ-CONTENT-SHA256": "untrusted", "X-AMZ-SECURITY-TOKEN": "untrusted"
        ], scenario.headers)
        var options = BedrockOptions(env: [:], region: "us-east-1", headers: headers,
            bearerToken: "identity-bearer", timeoutMs: 5000, maxRetries: 0)
        options.identity = mergeClientIdentity(scenario.identity, ClientIdentity(attribution: .value(PI_ATTRIBUTION)))
        _ = await streamBedrock(model: model,
            context: normalizeContext(Context(messages: [.user(UserMessage(content: .text("Hello")))])), options: options).result()
        let request = try #require(identityBedrockRequests.withLock { $0.last })
        let expected = scenario == .defaults || scenario == .detailed ? "pi/1.4.0" : scenario.expected()
        #expect(request.value(forHTTPHeaderField: "User-Agent") == expected)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer identity-bearer")
        #expect(request.value(forHTTPHeaderField: "Host") == identityBedrockHost)
        #expect(request.value(forHTTPHeaderField: "x-amz-content-sha256") != "untrusted")
        #expect(request.value(forHTTPHeaderField: "x-amz-date") == nil)
        #expect(request.value(forHTTPHeaderField: "x-amz-security-token") == nil)
        #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Title") == nil)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: IdentityProviderSite.allCases)
private func clientAttributionReachesEachHTTPProvider(_ site: IdentityProviderSite) async throws {
    let request = try await identityProviderRequest(site, .custom,
        identity: ClientIdentity(userAgent: .custom("suite/1.0"), attribution: .value(PI_ATTRIBUTION)),
        baseURL: "https://openrouter.ai/api/v1")
    let oauth = site == .anthropicOAuth
    #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == (oauth ? nil : "https://pi.dev"))
    #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Title") == (oauth ? nil : "pi"))
    #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Categories") == (oauth ? nil : "cli-agent"))
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
private func clientAttributionImagesPreservesOverridesAndDeletion(_ disabled: Bool) async throws {
    let client = IdentityProviderHTTP()
    let model = ImageModel(id: "image-test", name: "Image", api: .openrouterImages, provider: "openrouter",
        baseUrl: "https://identity.example/v1", input: [.text], output: [.image],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), headers: ["X-OpenRouter-Title": "model-title"])
    var options = ImagesOptions(apiKey: "test-key", httpClient: client,
        headers: ["http-referer": nil, "x-openrouter-title": "request-title"], maxRetries: 0)
    options.identity = ClientIdentity(attribution: disabled ? .disabled : .value(PI_ATTRIBUTION))
    _ = await generateImagesOpenRouter(model: model, context: ImagesContext(input: [.text(TextContent(text: "Draw"))]), options: options)
    let request = try #require(await client.captured().last)
    #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == nil)
    #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Title") == "request-title")
    #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Categories") == (disabled ? nil : "cli-agent"))
}

@Test(.timeLimit(.minutes(1)), arguments: IdentityClassifierSite.allCases)
private func clientAttributionReachesSharedClassifiers(_ site: IdentityClassifierSite) async throws {
    let client = IdentityProviderHTTP()
    let model = ClassifierModel(id: "identity-test", name: "Test", api: site.api, provider: "openrouter",
        baseUrl: "https://identity.example/v1", input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 32_768,
        headers: ["X-OpenRouter-Title": "model-title"])
    let context = ClassifierContext(state: ["text": AnyCodable("Hello")], questions: [
        "approved": .bool(instructions: "Approved?", trueCriterion: "Yes", falseCriterion: "No")
    ])
    var options = ClassifierOptions(apiKey: "test-key", httpClient: client,
        headers: ["http-referer": nil, "x-openrouter-title": "request-title"], maxRetries: 0)
    options.identity = ClientIdentity(attribution: .value(PI_ATTRIBUTION))
    switch site {
    case .typesafe: _ = await classifyTypeSafeSystemOne(model: model, context: context, options: options)
    case .cloudflare: _ = await classifyCloudflareWorkersAISystemOne(model: model, context: context, options: options)
    case .decisions: _ = await classifyOpenAIDecisions(model: model, context: context, options: options)
    }
    let request = try #require(await client.captured().last)
    #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == nil)
    #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Title") == "request-title")
    #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Categories") == "cli-agent")
}

@Test func clientAttributionReachesCodexWebSocket() throws {
    let base = try buildOpenAICodexHeaders(baseHeaders: ["X-OpenRouter-Title": "model-title"],
        additionalHeaders: ["http-referer": nil], accessToken: identityCodexToken(),
        provider: "openrouter", baseUrl: "https://identity.example/v1",
        identity: ClientIdentity(attribution: .value(PI_ATTRIBUTION)))
    let headers = buildCodexWebSocketHeaders(baseHeaders: base, requestId: "identity-request")
    #expect(providerHeaderValue(headers, name: "HTTP-Referer") == nil)
    #expect(providerHeaderValue(headers, name: "X-OpenRouter-Title") == "model-title")
    #expect(providerHeaderValue(headers, name: "X-OpenRouter-Categories") == "cli-agent")
    #expect(providerHeaderValue(headers, name: "originator") == "pi")
}
