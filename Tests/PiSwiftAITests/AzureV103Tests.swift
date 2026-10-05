import Foundation
import Testing
@testable import PiSwiftAI

private actor AzureA1HTTPClient: ProviderHTTPClient {
    private var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        let body: String
        if request.url?.path.hasSuffix("/responses") == true {
            body = "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_test\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n"
        } else {
            body = "data: {\"id\":\"test\",\"created\":0,\"model\":\"test\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}\n\ndata: [DONE]\n\n"
        }
        return ProviderHTTPResponse(statusCode: 200, headers: ["content-type": "text/event-stream"], body: Data(body.utf8))
    }

    func lastRequest() -> URLRequest? { requests.last }
}

// Exact built-in Azure model values from v1.0.3 generate-models.ts:3134–3150,3455–3473.
// K1 supplies the generated entry later.
private func azureA1Model(provider: String = "azure", baseUrl: String = "", map: ThinkingLevelMap? = [
    .minimal: nil, .low: "low", .medium: "medium", .high: "high", .xhigh: nil, .max: nil,
]) -> Model {
    Model(id: "deepseek-v4-pro", name: "DeepSeek V4 Pro", api: .openAICompletions,
        provider: provider, baseUrl: baseUrl, reasoning: true, input: [.text],
        cost: ModelCost(input: 1.925, output: 3.828, cacheRead: 0.165, cacheWrite: 0),
        contextWindow: 1_000_000, maxTokens: 384_000,
        compat: OpenAICompat(supportsDeveloperRole: false, thinkingFormat: .openai,
            supportsMidConvoSystemMessages: true, supportsStrictMode: true,
            supportsLongCacheRetention: false, requiresReasoningContentOnAssistantMessages: true),
        thinkingLevelMap: map)
}

private let azureA1Env = ["AZURE_OPENAI_BASE_URL": "https://my-resource.services.ai.azure.com"]
private let azureA1Context = Context(systemPrompt: "sys", messages: [.user(UserMessage(content: .text("hi")))])

private func azureA1Body(_ client: AzureA1HTTPClient) async throws -> [String: Any] {
    let request = try #require(await client.lastRequest())
    let data = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func azureA1Direct(_ client: AzureA1HTTPClient, context: Context = azureA1Context,
    options: OpenAICompletionsOptions? = nil) async -> AssistantMessage {
    var options = options ?? OpenAICompletionsOptions()
    if options.env == nil { options.env = azureA1Env }
    options.apiKey = "test-key"
    options.httpClient = client
    options.maxRetries = 0
    return await streamOpenAICompletions(model: azureA1Model(), context: normalizeContext(context), options: options).result()
}

private func azureA1Simple(_ client: AzureA1HTTPClient, options: SimpleStreamOptions = SimpleStreamOptions()) async -> AssistantMessage {
    var options = options
    if options.env == nil { options.env = azureA1Env }
    options.apiKey = "test-key"
    options.httpClient = client
    options.maxRetries = 0
    let model = azureA1Model()
    return await streamOpenAICompletions(model: model, context: normalizeContext(azureA1Context),
        options: mapOpenAICompletionsSimpleOptions(model: model, options: options, apiKey: "test-key")).result()
}

// Upstream azure-openai-completions.test.ts:112.
@Test func azureA1HighUsesOpenAIEffort() async throws {
    let client = AzureA1HTTPClient()
    #expect(await azureA1Simple(client, options: SimpleStreamOptions(reasoning: .high)).stopReason == .stop)
    let body = try await azureA1Body(client)
    #expect(body["reasoning_effort"] as? String == "high")
    #expect(body["thinking"] == nil)
}

// :119.
@Test func azureA1MaxClampsToHigh() async throws {
    let client = AzureA1HTTPClient()
    _ = await azureA1Simple(client, options: SimpleStreamOptions(reasoning: .max))
    #expect(try await azureA1Body(client)["reasoning_effort"] as? String == "high")
    #expect(getSupportedThinkingLevels(azureA1Model()) == [.off, .low, .medium, .high])
}

// :125.
@Test func azureA1NoRequestedThinkingOmitsEffort() async throws {
    let client = AzureA1HTTPClient()
    _ = await azureA1Simple(client)
    let body = try await azureA1Body(client)
    #expect(body["reasoning_effort"] == nil)
    #expect(body["thinking"] == nil)
}

// :132.
@Test func azureA1EnvironmentLongCacheIsSuppressed() async throws {
    let client = AzureA1HTTPClient()
    var env = azureA1Env
    env["PI_CACHE_RETENTION"] = "long"
    _ = await azureA1Direct(client, options: OpenAICompletionsOptions(env: env, sessionId: "session-env"))
    let body = try await azureA1Body(client)
    #expect(body["prompt_cache_key"] == nil)
    #expect(body["prompt_cache_retention"] == nil)
}

// :143.
@Test func azureA1SystemPromptUsesSystemRole() async throws {
    let client = AzureA1HTTPClient()
    _ = await azureA1Direct(client, options: OpenAICompletionsOptions(reasoningEffort: .low))
    let messages = try #require(try await azureA1Body(client)["messages"] as? [[String: Any]])
    #expect(messages.first?["role"] as? String == "system")
    #expect(messages.first?["content"] as? String == "sys")
}

// :150.
@Test func azureA1MidConversationSystemIsPreserved() async throws {
    let client = AzureA1HTTPClient()
    let context = Context(systemPrompt: "first", messages: [
        .user(UserMessage(content: .text("hi"))), .system(SystemMessage(content: .text("second"))),
        .user(UserMessage(content: .text("again"))),
    ])
    _ = await azureA1Direct(client, context: context)
    let messages = try #require(try await azureA1Body(client)["messages"] as? [[String: Any]])
    #expect(messages.compactMap { $0["role"] as? String } == ["system", "user", "system", "user"])
    #expect(messages[2]["content"] as? String == "second")
}

// :170.
@Test func azureA1ExplicitLongCacheIsSuppressed() async throws {
    let client = AzureA1HTTPClient()
    _ = await azureA1Direct(client, options: OpenAICompletionsOptions(cacheRetention: .long, sessionId: "session-1"))
    let body = try await azureA1Body(client)
    #expect(body["prompt_cache_key"] == nil)
    #expect(body["prompt_cache_retention"] == nil)
}

// :179.
@Test func azureA1SignedReasoningIsReplayed() async throws {
    let client = AzureA1HTTPClient()
    let assistant = AssistantMessage(content: [
        .thinking(ThinkingContent(thinking: "internal reasoning", thinkingSignature: "reasoning_content")),
        .text(TextContent(text: "answer")),
    ], api: .openAICompletions, provider: "azure", model: "deepseek-v4-pro", usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
    let context = Context(systemPrompt: "sys", messages: [.user(UserMessage(content: .text("first"))),
        .assistant(assistant), .user(UserMessage(content: .text("second")))])
    _ = await azureA1Direct(client, context: context)
    let messages = try #require(try await azureA1Body(client)["messages"] as? [[String: Any]])
    #expect(messages.first { $0["role"] as? String == "assistant" }?["reasoning_content"] as? String == "internal reasoning")
}

// :217. Also prove bearer auth and no automatic API version.
@Test func azureA1FoundryEndpointAndBearerAuth() async throws {
    let client = AzureA1HTTPClient()
    var env = azureA1Env
    env["AZURE_OPENAI_API_VERSION"] = "ignored-version"
    _ = await azureA1Direct(client, options: OpenAICompletionsOptions(env: env, azureApiVersion: "also-ignored"))
    let request = try #require(await client.lastRequest())
    #expect(request.url?.absoluteString == "https://my-resource.services.ai.azure.com/openai/v1/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    #expect(request.value(forHTTPHeaderField: "api-key") == nil)
    #expect(request.url?.query == nil)
}

// :223. Resolution stays inside the task, before any request or content event.
@Test func azureA1MissingEndpointIsErrorEvent() async throws {
    let client = AzureA1HTTPClient()
    let model = azureA1Model()
    let events = streamOpenAICompletions(model: model, context: normalizeContext(azureA1Context),
        options: OpenAICompletionsOptions(env: [:], apiKey: "test-key", httpClient: client, maxRetries: 0))
    var count = 0
    for await event in events {
        count += 1
        guard case .error(let reason, let message) = event else { Issue.record("Expected only an error event"); continue }
        #expect(reason == .error)
        #expect(message.api == .openAICompletions)
        #expect(message.provider == "azure")
        #expect(message.model == model.id)
        #expect(message.content.isEmpty)
        #expect(message.usage.input == 0 && message.usage.output == 0 && message.usage.totalTokens == 0)
        #expect(message.usage.cacheRead == 0 && message.usage.cacheWrite == 0 && message.usage.cost.total == 0)
        #expect(message.errorMessage == "Azure OpenAI base URL is required. Set AZURE_OPENAI_BASE_URL or AZURE_OPENAI_RESOURCE_NAME, or pass azureBaseUrl, azureResourceName, or model.baseUrl.")
    }
    #expect(count == 1)
    #expect(await client.lastRequest() == nil)
}

// :233.
@Test func azureA1CatalogIdIsRequestAndResultModel() async throws {
    let client = AzureA1HTTPClient()
    let result = await azureA1Direct(client)
    #expect(try await azureA1Body(client)["model"] as? String == "deepseek-v4-pro")
    #expect(result.model == "deepseek-v4-pro")
}

// :240.
@Test func azureA1SimpleDeploymentKeepsCatalogId() async throws {
    let client = AzureA1HTTPClient()
    var env = azureA1Env
    env["AZURE_OPENAI_DEPLOYMENT_NAME_MAP"] = "deepseek-v4-pro=my-deepseek"
    let result = await azureA1Simple(client, options: SimpleStreamOptions(env: env))
    #expect(try await azureA1Body(client)["model"] as? String == "my-deepseek")
    #expect(result.model == "deepseek-v4-pro")
}

// :249. Y5: Swift observes a snapshot; the caller cannot return a replacement payload.
@Test func azureA1PayloadSnapshotSeesDeploymentAfterSampling() async throws {
    let client = AzureA1HTTPClient()
    let snapshot = LockedState<String?>(nil)
    _ = await azureA1Direct(client, options: OpenAICompletionsOptions(
        samplingParams: ["model": AnyCodable("sampling-model"), "temperature": AnyCodable(0.1)],
        onPayload: { payload in snapshot.withLock { $0 = payload.json } }, azureDeploymentName: "my-deepseek"))
    let json = try #require(snapshot.withLock { $0 })
    let observed = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(observed["model"] as? String == "my-deepseek")
    #expect(observed["temperature"] as? Double == 0.1)
    #expect(try await azureA1Body(client)["model"] as? String == "my-deepseek")
}

// :269. The generated Azure catalog stays outside this order.
@Test func azureA1ResponsesApiStillDispatches() async throws {
    let client = AzureA1HTTPClient()
    let model = Model(id: "gpt-4o-mini", name: "GPT-4o mini", api: .azureOpenAIResponses,
        provider: "azure", baseUrl: "", reasoning: false, input: [.text, .image],
        cost: ModelCost(input: 0.15, output: 0.6, cacheRead: 0.075, cacheWrite: 0),
        contextWindow: 128_000, maxTokens: 16_384)
    let result = try await stream(model: model, context: azureA1Context,
        options: StreamOptions(env: azureA1Env, apiKey: "test-key", httpClient: client, maxRetries: 0,
            azureApiVersion: "test-version", azureBaseUrl: "https://explicit.ai.azure.com/openai/v1/responses",
            azureDeploymentName: "my-gpt")).result()
    let request = try #require(await client.lastRequest())
    #expect(request.url?.path.hasSuffix("/responses") == true)
    #expect(request.url?.host == "explicit.ai.azure.com")
    #expect(request.url?.query?.contains("api-version=test-version") == true)
    #expect(request.value(forHTTPHeaderField: "api-key") == "test-key")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(try await azureA1Body(client)["model"] as? String == "my-gpt")
    #expect(result.stopReason == .stop)
    #expect(result.api == .azureOpenAIResponses)
    #expect(result.model == "gpt-4o-mini")
}

// :275. Generic direct and simple entry points forward all endpoint options.
@Test func azureA1CompletionsApiDispatches() async throws {
    for simple in [false, true] {
        let client = AzureA1HTTPClient()
        let result: AssistantMessage
        if simple {
            result = try await streamSimple(model: azureA1Model(), context: azureA1Context,
                options: SimpleStreamOptions(env: azureA1Env, apiKey: "test-key", httpClient: client, reasoning: .max,
                    maxRetries: 0, azureApiVersion: "ignored", azureResourceName: "explicit-resource",
                    azureBaseUrl: "https://explicit.ai.azure.com", azureDeploymentName: "my-deepseek")).result()
        } else {
            result = try await stream(model: azureA1Model(), context: azureA1Context,
                options: StreamOptions(env: azureA1Env, apiKey: "test-key", httpClient: client, maxRetries: 0,
                    azureApiVersion: "ignored", azureResourceName: "explicit-resource",
                    azureBaseUrl: "https://explicit.ai.azure.com", azureDeploymentName: "my-deepseek")).result()
        }
        let request = try #require(await client.lastRequest())
        #expect(request.url?.absoluteString == "https://explicit.ai.azure.com/openai/v1/chat/completions")
        #expect(try await azureA1Body(client)["model"] as? String == "my-deepseek")
        #expect(result.api == .openAICompletions && result.model == "deepseek-v4-pro")
        #expect(result.stopReason == .stop)
    }
}

@Test func azureA1RenameHasNoAlias() throws {
    #expect(KnownProvider.azure.rawValue == "azure")
    #expect(KnownProvider(rawValue: "azure-openai-responses") == nil)
    #expect(Api.azureOpenAIResponses.rawValue == "azure-openai-responses")
    #expect(getEnvApiKey(provider: "azure", env: ["AZURE_OPENAI_API_KEY": "azure-key"]) == "azure-key")
    #expect(getEnvApiKey(provider: "azure-openai-responses", env: ["AZURE_OPENAI_API_KEY": "azure-key"]) == nil)
    let auth = try #require(getBuiltinProviderAuth("azure"))
    #expect(auth.id == "azure" && auth.name == "Azure")
    #expect(auth.apiKey?.name == "Azure OpenAI API key")
    #expect(auth.apiKey?.envVars == ["AZURE_OPENAI_API_KEY"])
    #expect(getBuiltinProviderAuth("azure-openai-responses") == nil)
    #expect(azureToolCallProviders == ["azure", "openai", "openai-codex", "opencode"])
}

@Test func azureA1DeepSeekInferenceAndOverrideExcludeAzure() {
    #expect(!supportsXhigh(model: azureA1Model(map: nil)))
    #expect(!supportsXhigh(model: azureA1Model()))
    #expect(getSupportedThinkingLevels(azureA1Model()).contains(.max) == false)
    #expect(supportsXhigh(model: azureA1Model(provider: "deepseek", map: nil)))
    #expect(supportsXhigh(model: azureA1Model(provider: "deepseek")))
    #expect(mappedThinkingLevel(model: azureA1Model(provider: "deepseek"), level: .xhigh) == "max")
}

@Test func azureA1UnchangedDeploymentDoesNotOverrideSamplingModel() async throws {
    let client = AzureA1HTTPClient()
    _ = await azureA1Direct(client, options: OpenAICompletionsOptions(samplingParams: ["model": AnyCodable("sampling-model")],
        azureDeploymentName: "deepseek-v4-pro"))
    #expect(try await azureA1Body(client)["model"] as? String == "sampling-model")
}

@Test func azureA1NonAzureCompletionsIgnoreAzureOptions() async throws {
    let client = AzureA1HTTPClient()
    let model = azureA1Model(provider: "custom", baseUrl: "https://proxy.example/v1")
    _ = await streamOpenAICompletions(model: model, context: normalizeContext(azureA1Context),
        options: OpenAICompletionsOptions(apiKey: "test-key", httpClient: client, maxRetries: 0,
            azureBaseUrl: "invalid", azureDeploymentName: "ignored")).result()
    #expect(await client.lastRequest()?.url?.host == "proxy.example")
    #expect(try await azureA1Body(client)["model"] as? String == "deepseek-v4-pro")
}

@Test func azureA1BaseUrlSourcesAndOrder() throws {
    let model = azureA1Model(baseUrl: "https://model.example/v1")
    let env = ["AZURE_OPENAI_BASE_URL": " https://env.ai.azure.com/ ", "AZURE_OPENAI_RESOURCE_NAME": "env-resource"]
    #expect(try resolveAzureBaseUrl(model: model, options: OpenAICompletionsOptions(env: env,
        azureResourceName: "option-resource", azureBaseUrl: " https://option.ai.azure.com/ ")) == "https://option.ai.azure.com/openai/v1")
    #expect(try resolveAzureBaseUrl(model: model, options: OpenAICompletionsOptions(env: env,
        azureResourceName: "option-resource", azureBaseUrl: " \n ")) == "https://env.ai.azure.com/openai/v1")
    #expect(try resolveAzureBaseUrl(model: model, options: OpenAICompletionsOptions(env: ["AZURE_OPENAI_RESOURCE_NAME": "env-resource"],
        azureResourceName: "option-resource")) == "https://option-resource.openai.azure.com/openai/v1")
    #expect(try resolveAzureBaseUrl(model: model, options: OpenAICompletionsOptions(env: ["AZURE_OPENAI_RESOURCE_NAME": "env-resource"],
        azureResourceName: "")) == "https://env-resource.openai.azure.com/openai/v1")
    #expect(try resolveAzureBaseUrl(model: model, options: OpenAICompletionsOptions(env: [:])) == "https://model.example/v1")
    #expect(try resolveAzureBaseUrl(model: model, options: nil) == "https://model.example/v1")
    #expect(try resolveAzureBaseUrl(model: model, options: OpenAICompletionsOptions(env: ["AZURE_OPENAI_BASE_URL": "  "],
        azureBaseUrl: "")) == "https://model.example/v1")
    // Resource strings are not trimmed. A space is truthy upstream and yields an invalid host.
    #expect(throws: AzureOpenAIResponsesError.self) {
        try resolveAzureBaseUrl(model: model, options: OpenAICompletionsOptions(env: [:], azureResourceName: " "))
    }
    #expect(throws: AzureOpenAIResponsesError.self) {
        try resolveAzureBaseUrl(model: model, options: OpenAICompletionsOptions(env: env, azureBaseUrl: "invalid"))
    }
}

@Test func azureA1EveryAzureHostAndPathRewrite() throws {
    for suffix in ["openai.azure.com", "cognitiveservices.azure.com", "ai.azure.com", "services.ai.azure.com"] {
        for path in ["", "/", "/openai", "/openai/", "/openai/v1/responses", "/openai/v1/responses///"] {
            #expect(try normalizeAzureBaseUrl("https://resource.\(suffix)\(path)?remove=1#keep") ==
                "https://resource.\(suffix)/openai/v1#keep")
        }
    }
    #expect(try normalizeAzureBaseUrl(" HTTPS://RESOURCE.AI.AZURE.COM/openai/ ") == "https://resource.ai.azure.com/openai/v1")
}

@Test func azureA1QueryIsClearedOnlyOnPathRewrite() throws {
    #expect(try normalizeAzureBaseUrl("https://resource.ai.azure.com/openai/v1?keep=1") ==
        "https://resource.ai.azure.com/openai/v1?keep=1")
    #expect(try normalizeAzureBaseUrl("https://resource.ai.azure.com/custom///?keep=1") ==
        "https://resource.ai.azure.com/custom///?keep=1")
    #expect(try normalizeAzureBaseUrl("https://proxy.example/openai/v1/responses?keep=1") ==
        "https://proxy.example/openai/v1/responses?keep=1")
    #expect(try normalizeAzureBaseUrl("https://proxy.example/custom///") == "https://proxy.example/custom")
    #expect(try normalizeAzureBaseUrl("https://openai.azure.com?keep=1") == "https://openai.azure.com/?keep=1")
    #expect(try normalizeAzureBaseUrl("https://resource.ai.azure.com.example/openai?keep=1") ==
        "https://resource.ai.azure.com.example/openai?keep=1")
}

@Test func azureA1HelperErrorTexts() {
    for url in ["not a url", "/relative/path", "https://"] {
        do {
            _ = try normalizeAzureBaseUrl(url)
            Issue.record("Expected an invalid URL error")
        } catch {
            #expect(error.localizedDescription == "Invalid Azure OpenAI base URL: \(url)")
        }
    }
    do {
        _ = try resolveAzureBaseUrl(model: azureA1Model(), options: OpenAICompletionsOptions(env: [:]))
        Issue.record("Expected a missing endpoint error")
    } catch {
        #expect(error.localizedDescription == "Azure OpenAI base URL is required. Set AZURE_OPENAI_BASE_URL or AZURE_OPENAI_RESOURCE_NAME, or pass azureBaseUrl, azureResourceName, or model.baseUrl.")
    }
}

@Test func azureA1DeploymentMapMatchesJavaScriptSplit() {
    #expect(parseDeploymentNameMap(nil).isEmpty)
    #expect(parseDeploymentNameMap("").isEmpty)
    #expect(parseDeploymentNameMap(" ,broken,=empty-key,empty-value=,a==third").isEmpty)
    #expect(parseDeploymentNameMap("a=first=discarded, a = second =discarded, spaced = value , =blank-key") ==
        ["a": "second", "spaced": "value"])
    #expect(parseDeploymentNameMap("a=first,a= =discarded") == ["a": ""])
    #expect(parseDeploymentNameMap("  =value") == [:])
    #expect(parseDeploymentNameMap("a =value,  =value") == ["a": "value"])
    // Entry trimming removes a whitespace-only key before the raw part check.
    #expect(parseDeploymentNameMap("x=one, \t =value") == ["x": "one"])
    let model = azureA1Model()
    let env = ["AZURE_OPENAI_DEPLOYMENT_NAME_MAP": "deepseek-v4-pro=first=discarded,deepseek-v4-pro=last"]
    #expect(resolveDeploymentName(model: model, options: OpenAICompletionsOptions(env: env)) == "last")
    #expect(resolveDeploymentName(model: model, options: OpenAICompletionsOptions(env: ["AZURE_OPENAI_DEPLOYMENT_NAME_MAP": "deepseek-v4-pro=first=discarded"])) == "first")
    #expect(resolveDeploymentName(model: model, options: OpenAICompletionsOptions(env: env, azureDeploymentName: " explicit ")) == " explicit ")
    #expect(resolveDeploymentName(model: model, options: OpenAICompletionsOptions(env: env, azureDeploymentName: "")) == "last")
    #expect(resolveDeploymentName(model: model, options: OpenAICompletionsOptions(env: env, azureDeploymentName: " ")) == " ")
    #expect(resolveDeploymentName(model: model, options: OpenAICompletionsOptions(env: [
        "AZURE_OPENAI_DEPLOYMENT_NAME_MAP": "deepseek-v4-pro=first,deepseek-v4-pro= =discarded",
    ])) == model.id)
    #expect(resolveDeploymentName(model: model, options: OpenAICompletionsOptions(env: [:])) == model.id)
}

@Test func azureA1ResponsesVersionOrderAndEmptyFallback() throws {
    let model = azureA1Model(baseUrl: "https://model.example/v1")
    let env = ["AZURE_OPENAI_API_VERSION": "env-version"]
    #expect(try resolveAzureConfig(model: model, options: AzureOpenAIResponsesOptions(env: env, azureApiVersion: "option-version")).apiVersion == "option-version")
    #expect(try resolveAzureConfig(model: model, options: AzureOpenAIResponsesOptions(env: env, azureApiVersion: "")).apiVersion == "env-version")
    #expect(try resolveAzureConfig(model: model, options: AzureOpenAIResponsesOptions(env: [:], azureApiVersion: "")).apiVersion == "v1")
    #expect(try resolveAzureConfig(model: model, options: nil).apiVersion == "v1")
    #expect(try resolveAzureConfig(model: model, options: AzureOpenAIResponsesOptions(env: env, azureApiVersion: " ")).apiVersion == " ")
}

@Test func azureA1SimpleResponsesForwardsAllEndpointFields() async throws {
    let model = Model(id: "gpt-4o-mini", name: "GPT-4o mini", api: .azureOpenAIResponses,
        provider: "azure", baseUrl: "", reasoning: false, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 128_000, maxTokens: 16_384)
    for generic in [false, true] {
        let client = AzureA1HTTPClient()
        let options = SimpleStreamOptions(env: [:], apiKey: "test-key", httpClient: client, maxRetries: 0,
            azureApiVersion: "option-version", azureResourceName: "option-resource", azureDeploymentName: "my-gpt")
        let result: AssistantMessage
        if generic {
            result = try await streamSimple(model: model, context: azureA1Context, options: options).result()
        } else {
            result = await streamSimpleAzureOpenAIResponses(model: model, context: normalizeContext(azureA1Context), options: options).result()
        }
        let request = try #require(await client.lastRequest())
        #expect(request.url?.host == "option-resource.openai.azure.com")
        #expect(request.url?.query?.contains("api-version=option-version") == true)
        #expect(try await azureA1Body(client)["model"] as? String == "my-gpt")
        #expect(result.stopReason == .stop)
        #expect(result.model == "gpt-4o-mini")
    }
    let options = SimpleStreamOptions(azureApiVersion: "version", azureResourceName: "resource",
        azureBaseUrl: "https://explicit.ai.azure.com", azureDeploymentName: "deployment")
    let mapped = mapAzureOpenAIResponsesSimpleOptions(model: model, options: options, apiKey: "key")
    #expect(mapped.azureApiVersion == options.azureApiVersion)
    #expect(mapped.azureResourceName == options.azureResourceName)
    #expect(mapped.azureBaseUrl == options.azureBaseUrl)
    #expect(mapped.azureDeploymentName == options.azureDeploymentName)
}

@Test func azureA1CompletionsPreservesConfiguredQuery() async throws {
    let client = AzureA1HTTPClient()
    _ = await azureA1Direct(client, options: OpenAICompletionsOptions(
        azureBaseUrl: "https://resource.ai.azure.com/openai/v1?custom=1"))
    let request = try #require(await client.lastRequest())
    #expect(request.url?.path == "/openai/v1/chat/completions")
    #expect(request.url?.query == "custom=1")
}

@Test func azureA1UrlSerializationPreservesEncodedPaths() throws {
    #expect(try normalizeAzureBaseUrl("https://resource.ai.azure.com/%6fpenai?keep=1") ==
        "https://resource.ai.azure.com/%6fpenai?keep=1")
    #expect(try normalizeAzureBaseUrl("https://resource.ai.azure.com/openai%2fv1/responses?keep=1") ==
        "https://resource.ai.azure.com/openai%2fv1/responses?keep=1")
    #expect(try normalizeAzureBaseUrl("https://proxy.example?keep=1#fragment") == "https://proxy.example/?keep=1#fragment")
    #expect(try normalizeAzureBaseUrl("https://proxy.example#fragment") == "https://proxy.example/#fragment")
    #expect(try normalizeAzureBaseUrl("https://resource.ai.azure.com:443") == "https://resource.ai.azure.com/openai/v1")
}

@Test func azureA1UrlParsingResolvesDotPathsBeforeRewrite() throws {
    for path in ["/a/../openai", "/a/../openai/v1/responses", "/a/%2e%2e/openai", "/a/.%2e/openai"] {
        #expect(try normalizeAzureBaseUrl("https://resource.ai.azure.com\(path)?remove=1") ==
            "https://resource.ai.azure.com/openai/v1")
    }
}

@Test func azureA1GenericCompletionsForwardsResourceOnly() async throws {
    for simple in [false, true] {
        let client = AzureA1HTTPClient()
        if simple {
            _ = try await streamSimple(model: azureA1Model(), context: azureA1Context,
                options: SimpleStreamOptions(env: [:], apiKey: "key", httpClient: client, maxRetries: 0,
                    azureResourceName: "resource-only")).result()
        } else {
            _ = try await stream(model: azureA1Model(), context: azureA1Context,
                options: StreamOptions(env: [:], apiKey: "key", httpClient: client, maxRetries: 0,
                    azureResourceName: "resource-only")).result()
        }
        #expect(await client.lastRequest()?.url?.absoluteString == "https://resource-only.openai.azure.com/openai/v1/chat/completions")
    }
}

@Test func azureA1InvalidEndpointIsErrorWithoutRequest() async {
    let client = AzureA1HTTPClient()
    let result = await azureA1Direct(client, options: OpenAICompletionsOptions(azureBaseUrl: "invalid"))
    #expect(result.stopReason == .error)
    #expect(result.errorMessage == "Invalid Azure OpenAI base URL: invalid")
    #expect(result.content.isEmpty)
    #expect(result.model == "deepseek-v4-pro" && result.provider == "azure" && result.api == .openAICompletions)
    #expect(result.usage.totalTokens == 0)
    #expect(await client.lastRequest() == nil)
}
