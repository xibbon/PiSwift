import Foundation
import Testing
@testable import PiSwiftAI

private func maxTokensModel(api: Api = .openAIResponses, contextWindow: Int = 256_000) -> Model {
    Model(
        id: "max-tokens-test", name: "Max tokens test", api: api,
        provider: "test", baseUrl: "https://example.invalid/v1",
        reasoning: false, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: contextWindow, maxTokens: 128_000
    )
}

@Suite("Simple options max tokens")
struct SimpleOptionsMaxTokensTests {
    enum Mapper: String, CaseIterable, Sendable {
        case anthropic, openAICompletions, openAIResponses, openAICodexResponses
        case azureOpenAIResponses, google, googleValidated, googleVertex, googleVertexValidated, bedrock, mistral

        func maxTokens(model: Model, options: SimpleStreamOptions?) throws -> Int? {
            switch self {
            case .anthropic:
                mapAnthropicSimpleOptions(model: model, context: Context(messages: []), options: options, apiKey: "test").maxTokens
            case .openAICompletions:
                mapOpenAICompletionsSimpleOptions(model: model, options: options, apiKey: "test").maxTokens
            case .openAIResponses:
                mapOpenAIResponsesSimpleOptions(model: model, options: options, apiKey: "test").maxTokens
            case .openAICodexResponses:
                mapOpenAICodexResponsesSimpleOptions(model: model, options: options, apiKey: "test").maxTokens
            case .azureOpenAIResponses:
                mapAzureOpenAIResponsesSimpleOptions(model: model, options: options, apiKey: "test").maxTokens
            case .google:
                mapGoogleSimpleOptions(model: model, options: options, apiKey: "test").maxTokens
            case .googleValidated:
                try mapGoogleSimpleOptionsValidated(model: model, options: options, apiKey: "test").maxTokens
            case .googleVertex:
                mapGoogleVertexSimpleOptions(model: model, options: options, apiKey: "test").maxTokens
            case .googleVertexValidated:
                try mapGoogleVertexSimpleOptionsValidated(model: model, options: options, apiKey: "test").maxTokens
            case .bedrock:
                mapBedrockSimpleOptions(model: model, options: options).maxTokens
            case .mistral:
                mapMistralSimpleOptions(model: model, options: options, apiKey: "test").maxTokens
            }
        }
    }

    @Test(arguments: Mapper.allCases, [false, true])
    func mapperDefaultsToModel(mapper: Mapper, hasOptions: Bool) throws {
        let options: SimpleStreamOptions? = hasOptions ? SimpleStreamOptions() : nil
        #expect(try mapper.maxTokens(model: maxTokensModel(), options: options) == 128_000)
    }

    @Test(arguments: Mapper.allCases)
    func mapperKeepsExplicitMaxTokens(mapper: Mapper) throws {
        #expect(try mapper.maxTokens(model: maxTokensModel(), options: SimpleStreamOptions(maxTokens: 48_000)) == 48_000)
    }

    @Test(arguments: [Api.azureOpenAIResponses, .googleGeminiCli], [nil, 48_000] as [Int?])
    func directProviderUsesResolvedMaxTokens(api: Api, explicitMaxTokens: Int?) async throws {
        let token = CancellationToken()
        let payload = LockedState<String?>(nil)
        let options = SimpleStreamOptions(
            maxTokens: explicitMaxTokens,
            signal: token,
            apiKey: api == .googleGeminiCli ? #"{"token":"test","projectId":"test"}"# : "test",
            onPayload: { snapshot in
                payload.withLock { $0 = snapshot.json }
                token.cancel()
            },
            maxRetries: 0
        )
        let model = maxTokensModel(api: api)
        let events = api == .googleGeminiCli
            ? streamSimpleGoogleGeminiCli(model: model, context: Context(messages: []), options: options)
            : streamSimpleAzureOpenAIResponses(model: model, context: Context(messages: []), options: options)
        let result = await events.result()
        #expect(result.stopReason == .aborted)
        let json = try #require(payload.withLock { $0 })
        let body = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let resolved: Int?
        if api == .googleGeminiCli {
            let request = try #require(body["request"] as? [String: Any])
            let config = try #require(request["generationConfig"] as? [String: Any])
            resolved = config["maxOutputTokens"] as? Int
        } else {
            resolved = body["max_output_tokens"] as? Int
        }
        #expect(resolved == (explicitMaxTokens ?? 128_000))
    }
}

// Keep registry changes in the existing serial suite.
extension ApiRegistryTests {
    @Test(arguments: [256_000, 100_000], [nil, 48_000] as [Int?])
    func streamSimpleResolvesMaxTokens(contextWindow: Int, explicitMaxTokens: Int?) throws {
        resetApiProviders()
        defer { resetApiProviders() }
        let resolved = LockedState<Int?>(nil)
        registerApiProvider(ApiProvider(
            api: .openAIResponses,
            stream: { _, _, _ in createAssistantMessageEventStream() },
            streamSimple: { _, _, options in
                resolved.withLock { $0 = options?.maxTokens }
                return createAssistantMessageEventStream()
            }
        ), sourceId: "simple-options-max-tokens-test")

        let model = maxTokensModel(contextWindow: contextWindow)
        let context = Context(messages: [.user(UserMessage(content: .text(String(repeating: "x", count: 4_000))))])
        let options = explicitMaxTokens.map { SimpleStreamOptions(maxTokens: $0) }
        _ = try streamSimple(model: model, context: context, options: options)

        // Upstream estimates one token for each four text characters.
        let available = contextWindow - 1_000 - 4_096
        let expected = min(explicitMaxTokens ?? 128_000, max(1, available))
        #expect(resolved.withLock { $0 } == expected)
    }
}
