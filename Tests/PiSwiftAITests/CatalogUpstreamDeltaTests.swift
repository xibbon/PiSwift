import Foundation
import Testing
@testable import PiSwiftAI

// Adapted from the v0.84.1...v0.85.0 upstream catalog test changes.
private let catalog085QwenProviders = ["qwen-token-plan", "qwen-token-plan-cn", "qwen-token-plan-individual"]
private let catalog085IndividualModels = ["deepseek-v4-flash-0731", "deepseek-v4-pro", "deepseek-v4-pro-0813", "glm-5.2", "qwen3.6-flash", "qwen3.7-max", "qwen3.7-plus", "qwen3.8-flash", "qwen3.8-max"]

@Test(arguments: ["~anthropic/claude-fable-latest", "~anthropic/claude-haiku-latest", "~anthropic/claude-opus-latest", "~anthropic/claude-sonnet-latest"])
func catalog085OpenRouterLatestAliasesKeepCompletionsCacheControl(_ id: String) throws {
    let model = try #require(getModel(provider: "openrouter", modelId: id))
    #expect(model.api == .openAICompletions)
    #expect(model.compat?.cacheControlFormat == .anthropic)
}

@Test func catalog085IndividualTextModelsMatchDocumentedList() throws {
    let provider = try #require(KnownProvider(rawValue: "qwen-token-plan-individual"))
    #expect(getModels(provider: provider).map(\.id).sorted() == catalog085IndividualModels.sorted())
}

// The strict-generator delta adds these fixture IDs. Swift consumes hydrated data;
// upstream's mock-fetch failure-before-mutation test belongs to that hydrator.
@Test(arguments: ["deepseek-v4-pro-0813", "qwen3.8-flash"])
func catalog085StrictGeneratorNewIndividualIDsSurviveHydration(_ id: String) throws {
    let model = try #require(getModel(provider: "qwen-token-plan-individual", modelId: id))
    #expect(model.api == .openAICompletions)
    #expect(model.reasoning)
    #expect(model.input == (id == "qwen3.8-flash" ? [.text, .image] : [.text]))
}

@Test(arguments: catalog085QwenProviders, ["qwen3.8-flash", "qwen3.8-max"])
func catalog085Qwen38EffortMap(_ provider: String, _ id: String) throws {
    let model = try #require(getModel(provider: provider, modelId: id))
    let map = try #require(model.thinkingLevelMap)
    for level in [ModelThinkingLevel.minimal, .high, .max] {
        #expect(map.keys.contains(level))
        #expect((map[level] ?? nil) == nil)
    }
    #expect((map[.low] ?? nil) == "low")
    #expect((map[.medium] ?? nil) == "medium")
    #expect((map[.xhigh] ?? nil) == "xhigh")
}

private actor Catalog085HTTPClient: ProviderHTTPClient {
    private var request: URLRequest?
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        self.request = request
        let sse = "data: {\"id\":\"catalog-test\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"catalog-test\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}\n\ndata: [DONE]\n\n"
        return ProviderHTTPResponse(statusCode: 200, body: Data(sse.utf8))
    }
    func body() -> Data? { request?.httpBody }
}

private func catalog085Request(_ model: Model, effort: ThinkingLevel) async throws -> [String: Any] {
    let client = Catalog085HTTPClient()
    let output = try await streamSimple(model: model, context: Context(messages: [.user(UserMessage(content: .text("Hi")))]),
        options: SimpleStreamOptions(apiKey: "test", httpClient: client, reasoning: effort)).result()
    #expect(output.stopReason == .stop)
    let body = try #require(await client.body())
    return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

@Test(arguments: catalog085QwenProviders, ["qwen3.8-flash", "qwen3.8-max"])
func catalog085Qwen38SendsXhighEffort(_ provider: String, _ id: String) async throws {
    let model = try #require(getModel(provider: provider, modelId: id))
    let payload = try await catalog085Request(model, effort: .xhigh)
    #expect(payload["enable_thinking"] as? Bool == true)
    #expect(payload["reasoning_effort"] as? String == "xhigh")
    #expect(payload["thinking"] == nil)
}

@Test func catalog085NewIndividualDeepSeekEffort() async throws {
    let model = try #require(getModel(provider: "qwen-token-plan-individual", modelId: "deepseek-v4-pro-0813"))
    let map = try #require(model.thinkingLevelMap)
    for level in [ModelThinkingLevel.minimal, .low, .medium, .xhigh] {
        #expect(map.keys.contains(level))
        #expect((map[level] ?? nil) == nil)
    }
    #expect((map[.high] ?? nil) == "high")
    #expect((map[.max] ?? nil) == "max")
    let payload = try await catalog085Request(model, effort: .high)
    #expect(payload["reasoning_effort"] as? String == "high")
    #expect(payload["enable_thinking"] as? Bool == true)
    #expect(payload["thinking"] == nil)
}

@Test(arguments: ["deepseek", "opencode-go"])
func catalog085DeepSeekV4FlashHasLowHighMaxAndOff(_ provider: String) throws {
    let model = try #require(getModel(provider: provider, modelId: "deepseek-v4-flash"))
    #expect(getSupportedThinkingLevels(model) == [.off, .low, .high, .max])
}

@Test func catalog085Grok46HasXhighWithoutOffOrMax() throws {
    let model = try #require(getModel(provider: "xai", modelId: "grok-4.6"))
    #expect(getSupportedThinkingLevels(model) == [.low, .medium, .high, .xhigh])
}

@Test(arguments: ["xiaomi", "xiaomi-token-plan-cn", "xiaomi-token-plan-ams", "xiaomi-token-plan-sgp"])
func catalog085XiaomiReplacesDeprecatedModels(_ name: String) throws {
    let provider = try #require(KnownProvider(rawValue: name))
    let ids = Set(getModels(provider: provider).map(\.id))
    for retired in ["mimo-v2-flash", "mimo-v2-omni", "mimo-v2-pro"] { #expect(!ids.contains(retired)) }
    for replacement in ["mimo-v2.5", "mimo-v2.5-pro"] { #expect(ids.contains(replacement)) }
}

@Test func catalog085ZaiChinaCodingPlanVision() throws {
    let model = try #require(getModel(provider: "zai-coding-cn", modelId: "glm-4.6v"))
    #expect(model.id == "glm-4.6v")
    #expect(model.provider == "zai-coding-cn")
    #expect(model.api == .openAICompletions)
    #expect(model.baseUrl == "https://open.bigmodel.cn/api/coding/paas/v4")
    #expect(model.reasoning)
    #expect(model.input == [.text, .image])
    #expect(model.cost == ModelCost(input: 0.3, output: 0.9, cacheRead: 0, cacheWrite: 0))
    #expect(model.contextWindow == 128_000)
    #expect(model.maxTokens == 32_768)
    #expect(model.compat?.maxTokensField == .maxTokens)
    #expect(model.compat?.thinkingFormat == .zai)
    #expect(model.compat?.zaiToolStream == true)
}

@Test func catalog085ZaiCodingPlanUsesMatchingAPICosts() throws {
    for (provider, id, cost) in [
        ("zai", "glm-5.2", ModelCost(input: 1.4, output: 4.4, cacheRead: 0.26, cacheWrite: 0)),
        ("zai-coding-cn", "glm-5.1", ModelCost(input: 1.4, output: 4.4, cacheRead: 0.26, cacheWrite: 0)),
        ("zai-coding-cn", "glm-5v-turbo", ModelCost(input: 1.2, output: 4, cacheRead: 0.24, cacheWrite: 0)),
        ("zai", "glm-5.3", ModelCost(input: 1.4, output: 4.4, cacheRead: 0.26, cacheWrite: 0)),
        ("zai-coding-cn", "glm-5.3", ModelCost(input: 1.4, output: 4.4, cacheRead: 0.26, cacheWrite: 0)),
    ] {
        let model = try #require(getModel(provider: provider, modelId: id))
        #expect(model.cost == cost)
    }
}

@Test func catalog085ZaiCodingPlanWithoutAPICostStaysZero() throws {
    for provider in ["zai", "zai-coding-cn"] {
        let model = try #require(getModel(provider: provider, modelId: "glm-5.2-highspeed"))
        #expect(model.cost == ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0))
    }
}
