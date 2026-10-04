import Foundation
import Testing
@testable import PiSwiftAI

private actor ThinkingSamplingHTTPClient: ProviderHTTPClient {
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        ProviderHTTPResponse(statusCode: 403, headers: ["content-type": "application/json"],
            body: Data(#"{"error":{"message":"captured"}}"#.utf8))
    }
}

private func thinkingSamplingModel(
    api: Api = .openAICompletions,
    reasoning: Bool = true,
    samplingParams: SamplingParams? = nil,
    thinkingLevelMap: [ModelThinkingLevel: String?]? = nil,
    levels: SamplingParamsByThinkingLevel? = nil,
    compat: OpenAICompat? = nil
) -> Model {
    Model(id: "custom-model", name: "Custom Model", api: api, provider: "custom-provider",
        baseUrl: api == .azureOpenAIResponses ? "https://fixture.openai.azure.com" : "https://example.invalid/v1",
        reasoning: reasoning, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 128_000, maxTokens: 16_384, samplingParams: samplingParams,
        compat: compat, thinkingLevelMap: thinkingLevelMap, samplingParamsByThinkingLevel: levels)
}

private func thinkingSamplingPayload(
    model: Model,
    reasoning: ThinkingLevel? = nil,
    request: SamplingParams? = nil,
    summary: OpenAIReasoningSummary? = nil,
    simple: Bool = false,
    azureSimpleEntry: Bool = false
) async throws -> [String: Any] {
    let captured = LockedState<String?>(nil)
    let client = ThinkingSamplingHTTPClient()
    let onPayload: PayloadHandler = { snapshot in captured.withLock { $0 = snapshot.json } }
    let context = normalizeContext(Context(messages: [.user(UserMessage(content: .text("Hello")))]))
    if simple {
        let options = SimpleStreamOptions(samplingParams: request, apiKey: "test", httpClient: client,
            reasoning: reasoning, onPayload: onPayload, maxRetries: 0)
        switch model.api {
        case .openAICompletions:
            let mapped = mapOpenAICompletionsSimpleOptions(model: model, options: options, apiKey: "test")
            _ = await streamOpenAICompletions(model: model, context: context, options: mapped).result()
        case .openAIResponses:
            let mapped = mapOpenAIResponsesSimpleOptions(model: model, options: options, apiKey: "test")
            _ = await streamOpenAIResponses(model: model, context: context, options: mapped).result()
        case .azureOpenAIResponses:
            if azureSimpleEntry {
                _ = await streamSimpleAzureOpenAIResponses(model: model, context: context, options: options).result()
            } else {
                let mapped = mapAzureOpenAIResponsesSimpleOptions(model: model, options: options, apiKey: "test")
                _ = await streamAzureOpenAIResponses(model: model, context: context, options: mapped).result()
            }
        default:
            Issue.record("Unexpected API in thinking-level sampling test")
        }
    } else {
        switch model.api {
        case .openAICompletions:
            _ = await streamOpenAICompletions(model: model, context: context,
                options: OpenAICompletionsOptions(samplingParams: request, apiKey: "test", httpClient: client,
                    reasoningEffort: reasoning, onPayload: onPayload, maxRetries: 0)).result()
        case .openAIResponses:
            _ = await streamOpenAIResponses(model: model, context: context,
                options: OpenAIResponsesOptions(samplingParams: request, apiKey: "test", httpClient: client,
                    reasoningEffort: reasoning, reasoningSummary: summary, onPayload: onPayload, maxRetries: 0)).result()
        case .azureOpenAIResponses:
            _ = await streamAzureOpenAIResponses(model: model, context: context,
                options: AzureOpenAIResponsesOptions(samplingParams: request, apiKey: "test", httpClient: client,
                    reasoningEffort: reasoning, reasoningSummary: summary, onPayload: onPayload, maxRetries: 0)).result()
        default:
            Issue.record("Unexpected API in thinking-level sampling test")
        }
    }
    let json = try #require(captured.withLock { $0 })
    return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

@Suite struct SamplingByThinkingLevelTests {
    // Port of sampling-options.test.ts:135–152, including null unsupported levels.
    @Test(.timeLimit(.minutes(1))) func simpleCompletionsUsesClampedLevel() async throws {
        let model = thinkingSamplingModel(samplingParams: ["temperature": AnyCodable(1), "top_p": AnyCodable(0.95)],
            thinkingLevelMap: [.low: nil, .medium: nil],
            levels: [.high: ["temperature": AnyCodable(0.8), "top_k": AnyCodable(64)]])
        let payload = try await thinkingSamplingPayload(model: model, reasoning: .low, simple: true)
        #expect(payload["temperature"] as? Double == 0.8)
        #expect(payload["top_p"] as? Double == 0.95)
        #expect(payload["top_k"] as? Int == 64)
    }

    // Port of sampling-options.test.ts:154–162.
    @Test(.timeLimit(.minutes(1))) func simpleCompletionsUsesOffWhenReasoningIsDisabled() async throws {
        let model = thinkingSamplingModel(reasoning: false, levels: [.off: ["temperature": AnyCodable(0.7)]])
        let payload = try await thinkingSamplingPayload(model: model, simple: true)
        #expect(payload["temperature"] as? Double == 0.7)
    }

    // Port of sampling-options.test.ts:164–175.
    @Test(.timeLimit(.minutes(1))) func simpleCompletionsRequestWinsOverLevel() async throws {
        let model = thinkingSamplingModel(levels: [.low: ["temperature": AnyCodable(0.6), "top_p": AnyCodable(0.95)]])
        let payload = try await thinkingSamplingPayload(model: model, reasoning: .low,
            request: ["top_p": AnyCodable(0.5)], simple: true)
        #expect(payload["temperature"] as? Double == 0.6)
        #expect(payload["top_p"] as? Double == 0.5)
    }

    // Port of sampling-options.test.ts:177–196 for all three APIs.
    @Test(.timeLimit(.minutes(1)), arguments: [Api.openAICompletions, .openAIResponses, .azureOpenAIResponses])
    func directStreamMergesModelLevelAndRequest(api: Api) async throws {
        let model = thinkingSamplingModel(api: api,
            samplingParams: ["temperature": AnyCodable(1), "top_p": AnyCodable(0.95)],
            levels: [.off: ["temperature": AnyCodable(0.7)],
                .low: ["temperature": AnyCodable(0.6), "top_k": AnyCodable(64)]])
        let payload = try await thinkingSamplingPayload(model: model, reasoning: .low,
            request: ["top_p": AnyCodable(0.5)])
        #expect(payload["temperature"] as? Double == 0.6)
        #expect(payload["top_p"] as? Double == 0.5)
        #expect(payload["top_k"] as? Int == 64)
    }

    // Port of sampling-options.test.ts:198–215 for both Responses APIs.
    @Test(.timeLimit(.minutes(1)), arguments: [Api.openAIResponses, .azureOpenAIResponses])
    func summaryOnlyUsesMediumLevel(api: Api) async throws {
        let model = thinkingSamplingModel(api: api,
            levels: [.off: ["temperature": AnyCodable(0.7)], .medium: ["temperature": AnyCodable(0.8)]])
        let payload = try await thinkingSamplingPayload(model: model, summary: .auto)
        let reasoning = try #require(payload["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "medium")
        #expect(payload["temperature"] as? Double == 0.8)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [Api.openAIResponses, .azureOpenAIResponses])
    func responsesSimpleMappersUseRequestedLevel(api: Api) async throws {
        let model = thinkingSamplingModel(api: api,
            levels: [.off: ["temperature": AnyCodable(0.7)], .low: ["temperature": AnyCodable(0.6)]])
        let payload = try await thinkingSamplingPayload(model: model, reasoning: .low, simple: true)
        #expect(payload["temperature"] as? Double == 0.6)
    }

    @Test(.timeLimit(.minutes(1))) func azureSimpleEntryUsesRequestedLevel() async throws {
        let model = thinkingSamplingModel(api: .azureOpenAIResponses,
            levels: [.off: ["temperature": AnyCodable(0.7)], .low: ["temperature": AnyCodable(0.6)]])
        let payload = try await thinkingSamplingPayload(model: model, reasoning: .low,
            simple: true, azureSimpleEntry: true)
        #expect(payload["temperature"] as? Double == 0.6)
    }

    @Test(.timeLimit(.minutes(1))) func simpleResolvedRequestWinsDuringDirectResolution() async throws {
        let model = thinkingSamplingModel(levels: [.low: ["temperature": AnyCodable(0.6)],
            .medium: ["temperature": AnyCodable(0.8), "top_k": AnyCodable(64)]])
        let captured = LockedState<String?>(nil)
        let options = SimpleStreamOptions(apiKey: "test", httpClient: ThinkingSamplingHTTPClient(),
            reasoning: .low, onPayload: { snapshot in captured.withLock { $0 = snapshot.json } }, maxRetries: 0)
        var mapped = mapOpenAICompletionsSimpleOptions(model: model, options: options, apiKey: "test")
        #expect(mapped.samplingParams?["temperature"] == AnyCodable(0.6))
        mapped.reasoningEffort = .medium
        let context = normalizeContext(Context(messages: [.user(UserMessage(content: .text("Hello")))]))
        _ = await streamOpenAICompletions(model: model, context: context, options: mapped).result()
        let json = try #require(captured.withLock { $0 })
        let payload = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(payload["temperature"] as? Double == 0.6)
        #expect(payload["top_k"] as? Int == 64)
    }

    @Test func resolverKeepsNilAndEmptyDistinct() {
        let absent = thinkingSamplingModel()
        #expect(resolveSamplingParams(model: absent, thinkingLevel: .low, request: nil) == nil)
        #expect(resolveSamplingParams(model: absent, thinkingLevel: .low, request: [:]) == [:])
        let emptyModel = thinkingSamplingModel(samplingParams: [:])
        #expect(resolveSamplingParams(model: emptyModel, thinkingLevel: .low, request: nil) == [:])
        let emptyLevel = thinkingSamplingModel(levels: [.low: [:]])
        #expect(resolveSamplingParams(model: emptyLevel, thinkingLevel: .low, request: nil) == [:])
        #expect(resolveSamplingParams(model: emptyLevel, thinkingLevel: .medium, request: nil) == nil)
    }

    @Test func resolverUsesPiLevelKeyBeforeProviderMapping() {
        let model = thinkingSamplingModel(thinkingLevelMap: [.low: "provider-low"],
            levels: [.low: ["temperature": AnyCodable(0.6)]])
        #expect(resolveSamplingParams(model: model, thinkingLevel: .low, request: nil)?["temperature"] == AnyCodable(0.6))
    }

    @Test func modelJSONRoundTripUsesLevelObjectKeys() throws {
        let levels: SamplingParamsByThinkingLevel = [.off: [:], .low: ["temperature": AnyCodable(0.6)],
            .max: ["top_k": AnyCodable(64)]]
        let model = thinkingSamplingModel(levels: levels)
        let data = try JSONEncoder().encode(model)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedLevels = try #require(object["samplingParamsByThinkingLevel"] as? [String: Any])
        #expect(Set(encodedLevels.keys) == ["off", "low", "max"])
        let low = try #require(encodedLevels["low"] as? [String: Any])
        #expect(low["temperature"] as? Double == 0.6)
        #expect(try JSONDecoder().decode(Model.self, from: data).samplingParamsByThinkingLevel == levels)
        let absent = thinkingSamplingModel()
        #expect(try JSONDecoder().decode(Model.self,
            from: JSONEncoder().encode(absent)).samplingParamsByThinkingLevel == nil)
    }

    @Test func modelWithBaseURLKeepsLevelSampling() {
        let levels: SamplingParamsByThinkingLevel = [.low: ["temperature": AnyCodable(0.6)]]
        let copied = thinkingSamplingModel(levels: levels).with(baseUrl: "https://other.invalid/v1")
        #expect(copied.baseUrl == "https://other.invalid/v1")
        #expect(copied.samplingParamsByThinkingLevel == levels)
        #expect(AnyModel.chat(copied).samplingParamsByThinkingLevel == levels)
    }

    @Test func mistralCompatInitializerKeepsLevelSampling() {
        let levels: SamplingParamsByThinkingLevel = [.low: ["temperature": AnyCodable(0.6)]]
        let model = Model(id: "mistral", name: "Mistral", api: .mistralConversations, provider: "mistral",
            baseUrl: "https://example.invalid/v1", reasoning: true, input: [.text],
            cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 32_000, maxTokens: 4_096, compat: MistralConversationsCompat(),
            samplingParamsByThinkingLevel: levels)
        #expect(model.samplingParamsByThinkingLevel == levels)
    }

    @Test func anthropicFallbackCopyKeepsLevelSampling() {
        let levels: SamplingParamsByThinkingLevel = [.low: ["temperature": AnyCodable(0.6)]]
        let fallbackCost = ModelCost(input: 1, output: 2, cacheRead: 3, cacheWrite: 4)
        let model = thinkingSamplingModel(api: .anthropicMessages, levels: levels,
            compat: OpenAICompat(allowedFallbackModels: [
                AnthropicAllowedFallbackModel(provider: "custom-provider", model: "fallback-model", cost: fallbackCost),
            ]))
        let fallback = anthropicUsageModel(model, servingModel: "fallback-model")
        #expect(fallback.id == "fallback-model")
        #expect(fallback.cost.input == 1)
        #expect(fallback.samplingParamsByThinkingLevel == levels)
    }

    @Test func nonChatAnyModelHasNoLevelSampling() {
        let cost = ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
        let image = ImageModel(id: "image", name: "Image", api: .openrouterImages, provider: "custom",
            baseUrl: "https://example.invalid/v1", input: [.text], output: [.image], cost: cost)
        let classifier = ClassifierModel(id: "classifier", name: "Classifier", api: .typesafeSystemOne,
            provider: "custom", baseUrl: "https://example.invalid/v1", input: [.text], cost: cost,
            contextWindow: 32_000)
        #expect(AnyModel.image(image).samplingParamsByThinkingLevel == nil)
        #expect(AnyModel.classifier(classifier).samplingParamsByThinkingLevel == nil)
    }

    @Test(.timeLimit(.minutes(1))) func modelsStoreRoundTripKeepsLevelSampling() async throws {
        let levels: SamplingParamsByThinkingLevel = [.low: ["temperature": AnyCodable(0.6)]]
        let entry = ModelsStoreEntry(models: [thinkingSamplingModel(levels: levels)], etag: "test-etag")
        let decoded = try JSONDecoder().decode(ModelsStoreEntry.self, from: JSONEncoder().encode(entry))
        #expect(decoded.models.first?.samplingParamsByThinkingLevel == levels)
        let store = InMemoryModelsStore()
        try await store.write(providerId: "custom-provider", entry: decoded, signal: nil)
        let restored = try #require(try await store.read(providerId: "custom-provider", signal: nil))
        #expect(restored.models.first?.samplingParamsByThinkingLevel == levels)
    }
}
