import Foundation
import Testing
@testable import PiSwiftAI

private func requestTestModel(
    host: String,
    samplingParams: [String: AnyCodable]? = nil,
    reasoning: Bool = false,
    compat: OpenAICompat? = nil,
    thinkingLevelMap: ThinkingLevelMap? = nil,
    maxTokens: Int = 4_096
) -> Model {
    Model(
        id: "request-test",
        name: "Request Test",
        api: .openAICompletions,
        provider: "request-test",
        baseUrl: "https://\(host)/v1",
        reasoning: reasoning,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 32_768,
        maxTokens: maxTokens,
        samplingParams: samplingParams,
        compat: compat,
        thinkingLevelMap: thinkingLevelMap
    )
}

private func captureCompletionsPayload(
    model: Model,
    options: OpenAICompletionsOptions
) async -> [String: Any]? {
    let captured = LockedState<String?>(nil)
    let host = model.baseUrl.components(separatedBy: "/")[2]
    OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = [host] }
    OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = { request in
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 500,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response, Data("request captured".utf8))
    } }
    URLProtocol.registerClass(OpenAICompletionsMockURLProtocol.self)
    defer {
        URLProtocol.unregisterClass(OpenAICompletionsMockURLProtocol.self)
        OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = [] }
        OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = nil }
    }

    var resolvedOptions = options
    resolvedOptions.onPayload = { snapshot in captured.withLock { $0 = snapshot.json } }
    resolvedOptions.maxRetries = 0
    let stream = streamOpenAICompletions(
        model: model,
        context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
        options: resolvedOptions
    )
    _ = await stream.result()

    guard let json = captured.withLock({ $0 }), let data = json.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func captureResponsesPayload(
    model: Model,
    options: OpenAIResponsesOptions
) async -> [String: Any]? {
    let captured = LockedState<String?>(nil)
    let host = model.baseUrl.components(separatedBy: "/")[2]
    OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = [host] }
    OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
        return (response, Data("request captured".utf8))
    } }
    URLProtocol.registerClass(OpenAICompletionsMockURLProtocol.self)
    defer {
        URLProtocol.unregisterClass(OpenAICompletionsMockURLProtocol.self)
        OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = [] }
        OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = nil }
    }

    var resolvedOptions = options
    resolvedOptions.onPayload = { snapshot in captured.withLock { $0 = snapshot.json } }
    resolvedOptions.maxRetries = 0
    let stream = streamOpenAIResponses(
        model: model,
        context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
        options: resolvedOptions
    )
    _ = await stream.result()

    guard let json = captured.withLock({ $0 }), let data = json.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func captureAzureResponsesPayload(
    model: Model,
    options: AzureOpenAIResponsesOptions
) async -> [String: Any]? {
    let captured = LockedState<String?>(nil)
    OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = ["sampling-azure.example"] }
    OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
        return (response, Data("request captured".utf8))
    } }
    URLProtocol.registerClass(OpenAICompletionsMockURLProtocol.self)
    defer {
        URLProtocol.unregisterClass(OpenAICompletionsMockURLProtocol.self)
        OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = [] }
        OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = nil }
    }

    var resolvedOptions = options
    resolvedOptions.azureBaseUrl = "https://sampling-azure.example/openai/v1"
    resolvedOptions.onPayload = { snapshot in captured.withLock { $0 = snapshot.json } }
    resolvedOptions.maxRetries = 0
    let stream = streamAzureOpenAIResponses(
        model: model,
        context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
        options: resolvedOptions
    )
    _ = await stream.result()

    guard let json = captured.withLock({ $0 }), let data = json.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

@Test func samplingParamsMergeModelAndRequestValuesAndApplyLast() async throws {
    await codexRequestLock.withLock {
        let modelOnly = await captureCompletionsPayload(
            model: requestTestModel(
                host: "sampling-model.example",
                samplingParams: [
                    "temperature": AnyCodable(0.61),
                    "top_p": AnyCodable(0.82),
                ]
            ),
            options: OpenAICompletionsOptions(temperature: 0.1, apiKey: "test-key")
        )
        #expect(modelOnly?["temperature"] as? Double == 0.61)
        #expect(modelOnly?["top_p"] as? Double == 0.82)

        let requestOnly = await captureCompletionsPayload(
            model: requestTestModel(host: "sampling-request.example"),
            options: OpenAICompletionsOptions(
                temperature: 0.1,
                samplingParams: [
                    "temperature": AnyCodable(0.72),
                    "min_p": AnyCodable(0.04),
                ],
                apiKey: "test-key"
            )
        )
        #expect(requestOnly?["temperature"] as? Double == 0.72)
        #expect(requestOnly?["min_p"] as? Double == 0.04)

        let merged = await captureCompletionsPayload(
            model: requestTestModel(
                host: "sampling-merged.example",
                samplingParams: [
                    "temperature": AnyCodable(0.33),
                    "top_k": AnyCodable(40),
                    "min_p": AnyCodable(0.02),
                ]
            ),
            options: OpenAICompletionsOptions(
                temperature: 0.1,
                samplingParams: [
                    "temperature": AnyCodable(0.93),
                    "top_k": AnyCodable(12),
                ],
                apiKey: "test-key"
            )
        )
        #expect(merged?["temperature"] as? Double == 0.93)
        #expect(merged?["top_k"] as? Int == 12)
        #expect(merged?["min_p"] as? Double == 0.02)
    }
}

@Test func nonOpenAIAdapterIgnoresModelSamplingParams() async throws {
    await codexRequestLock.withLock {
        let captured = LockedState<String?>(nil)
        MockURLProtocol.allowedHosts.withLock { $0 = ["sampling-google.example"] }
        MockURLProtocol.requestHandler.withLock { $0 = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["content-type": "text/event-stream"]
            )!
            let event = #"{"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}]}"#
            return (response, Data("data: \(event)\n\ndata: [DONE]\n\n".utf8))
        } }
        URLProtocol.registerClass(MockURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(MockURLProtocol.self)
            MockURLProtocol.allowedHosts.withLock { $0 = [] }
            MockURLProtocol.requestHandler.withLock { $0 = nil }
        }

        let model = Model(
            id: "google-sampling-test",
            name: "Google Sampling Test",
            api: .googleGenerativeAI,
            provider: "google",
            baseUrl: "https://sampling-google.example/v1beta",
            reasoning: false,
            input: [.text],
            cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 32_768,
            maxTokens: 4_096,
            samplingParams: ["top_k": AnyCodable(7)]
        )
        let stream = streamGoogle(
            model: model,
            context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
            options: GoogleOptions(
                apiKey: "test-key",
                onPayload: { snapshot in captured.withLock { $0 = snapshot.json } },
                maxRetries: 0
            )
        )
        _ = await stream.result()

        let payload = captured.withLock { $0 }
        #expect(payload?.contains("top_k") == false)
    }
}

@Test func responsesAdaptersApplySamplingParamsLast() async throws {
    await codexRequestLock.withLock {
        let responsesModel = Model(
            id: "responses-sampling-test",
            name: "Responses Sampling Test",
            api: .openAIResponses,
            provider: "openai",
            baseUrl: "https://sampling-responses.example/v1",
            reasoning: false,
            input: [.text],
            cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 32_768,
            maxTokens: 4_096,
            samplingParams: ["top_p": AnyCodable(0.8)]
        )
        let responses = await captureResponsesPayload(
            model: responsesModel,
            options: OpenAIResponsesOptions(
                temperature: 0.1,
                samplingParams: ["temperature": AnyCodable(0.88)],
                apiKey: "test-key"
            )
        )
        #expect(responses?["temperature"] as? Double == 0.88)
        #expect(responses?["top_p"] as? Double == 0.8)

        let azureModel = Model(
            id: "azure-sampling-test",
            name: "Azure Sampling Test",
            api: .azureOpenAIResponses,
            provider: "azure-openai-responses",
            baseUrl: "https://unused.example/openai/v1",
            reasoning: false,
            input: [.text],
            cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 32_768,
            maxTokens: 4_096,
            samplingParams: ["min_p": AnyCodable(0.03)]
        )
        let azure = await captureAzureResponsesPayload(
            model: azureModel,
            options: AzureOpenAIResponsesOptions(
                temperature: 0.1,
                samplingParams: ["temperature": AnyCodable(0.77)],
                apiKey: "test-key"
            )
        )
        #expect(azure?["temperature"] as? Double == 0.77)
        #expect(azure?["min_p"] as? Double == 0.03)
    }
}

@Test func basetenThinkingEmitsTemplateArgsAndMappedReasoningEffort() async throws {
    await codexRequestLock.withLock {
        let catalogModel = getModel(provider: .baseten, modelId: "zai-org/GLM-5.2")
        let model = Model(
            id: catalogModel.id,
            name: catalogModel.name,
            api: catalogModel.api,
            provider: catalogModel.provider,
            baseUrl: "https://baseten-thinking.example/v1",
            reasoning: catalogModel.reasoning,
            input: catalogModel.input,
            cost: catalogModel.cost,
            contextWindow: catalogModel.contextWindow,
            maxTokens: catalogModel.maxTokens,
            samplingParams: catalogModel.samplingParams,
            headers: catalogModel.headers,
            compat: catalogModel.compat,
            thinkingLevelMap: catalogModel.thinkingLevelMap
        )
        let payload = await captureCompletionsPayload(
            model: model,
            options: OpenAICompletionsOptions(apiKey: "test-key", reasoningEffort: .max)
        )
        let args = payload?["chat_template_args"] as? [String: Any]
        #expect(args?["enable_thinking"] as? Bool == true)
        #expect(payload?["reasoning_effort"] as? String == "max")
    }
}

@Test func thinkingTokenBudgetHonorsFlagAndAnswerRoom() async throws {
    await codexRequestLock.withLock {
        let enabled = requestTestModel(
            host: "thinking-budget.example",
            reasoning: true,
            compat: OpenAICompat(supportsThinkingTokenBudget: true),
            maxTokens: 20_000
        )
        let clamped = await captureCompletionsPayload(
            model: enabled,
            options: OpenAICompletionsOptions(
                maxTokens: 1_500,
                apiKey: "test-key",
                reasoningEffort: .xhigh,
                thinkingBudgets: [.high: 9_000]
            )
        )
        #expect(clamped?["thinking_token_budget"] as? Int == 476)

        let noRoom = await captureCompletionsPayload(
            model: Model(
                id: enabled.id,
                name: enabled.name,
                api: enabled.api,
                provider: enabled.provider,
                baseUrl: "https://thinking-no-room.example/v1",
                reasoning: enabled.reasoning,
                input: enabled.input,
                cost: enabled.cost,
                contextWindow: enabled.contextWindow,
                maxTokens: enabled.maxTokens,
                compat: enabled.compat
            ),
            options: OpenAICompletionsOptions(
                maxTokens: minimumAnswerTokens,
                apiKey: "test-key",
                reasoningEffort: .high
            )
        )
        #expect(noRoom?["thinking_token_budget"] == nil)

        let flagUnset = await captureCompletionsPayload(
            model: requestTestModel(
                host: "thinking-flag-unset.example",
                reasoning: true,
                maxTokens: 20_000
            ),
            options: OpenAICompletionsOptions(
                maxTokens: 4_096,
                apiKey: "test-key",
                reasoningEffort: .high
            )
        )
        #expect(flagUnset?["thinking_token_budget"] == nil)
    }
}

@Test func newProvidersAreDiscoverableWithCatalogModels() {
    let providers = Set(getProviders())
    #expect(providers.contains(.baseten))
    #expect(providers.contains(.qwenTokenPlan))
    #expect(providers.contains(.qwenTokenPlanCn))
    #expect(providers.contains(.qwenTokenPlanIndividual))

    #expect(getModel(provider: "baseten", modelId: "zai-org/GLM-5.2") != nil)
    #expect(getModel(provider: "qwen-token-plan", modelId: "qwen3.7-max") != nil)
    #expect(getModel(provider: "qwen-token-plan-cn", modelId: "qwen3.7-max") != nil)
    #expect(getModel(provider: "qwen-token-plan-individual", modelId: "qwen3.8-max") != nil)
}
