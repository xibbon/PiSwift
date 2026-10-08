import Foundation
import Testing
@testable import PiSwiftAI

private func a2BedrockModel(
    _ id: String,
    name: String? = nil,
    reasoning: Bool = true,
    cost: ModelCost = ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
    thinkingLevelMap: ThinkingLevelMap? = nil
) -> Model {
    Model(id: id, name: name ?? id, api: .bedrockConverseStream, provider: "amazon-bedrock",
        baseUrl: "https://bedrock-a2.invalid", reasoning: reasoning, input: [.text], cost: cost,
        contextWindow: 200_000, maxTokens: 16_384, thinkingLevelMap: thinkingLevelMap)
}

private func a2BedrockPayload(_ model: Model, options: BedrockOptions) throws -> [String: Any] {
    let context = Context(systemPrompt: "You are helpful.", messages: [.user(UserMessage(content: .text("Hello")))])
    let (_, data) = try buildBedrockRequest(model: model, context: context, options: options, region: "us-east-1")
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private let a2BedrockLevels: [ThinkingLevel] = [.minimal, .low, .medium, .high, .xhigh, .max]

@Suite("A2 Bedrock v1.1.0 OpenAI payload")
struct A2BedrockOpenAIReasoningTests {
    // Port of the four Bedrock OpenAI payload tests in bedrock-thinking-payload.test.ts.
    @Test(arguments: ["global.openai.gpt-6-sol", "us.openai.gpt-6-luna", "global.openai.gpt-5.6-sol"],
        a2BedrockLevels)
    func gptModelsSendAllReasoningLevels(_ id: String, _ level: ThinkingLevel) throws {
        let payload = try a2BedrockPayload(a2BedrockModel(id), options: BedrockOptions(env: [:], reasoning: level))
        let fields = try #require(payload["additionalModelRequestFields"] as? [String: Any])
        let expected = level == .minimal ? "low" : level.rawValue
        #expect(AnyCodable(fields) == AnyCodable(["reasoning": ["effort": expected]]))
    }

    @Test func modelNameIdentifiesGPTInferenceProfile() throws {
        let model = a2BedrockModel("arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/my-profile",
            name: "GPT-6 Sol")
        let payload = try a2BedrockPayload(model, options: BedrockOptions(env: [:], reasoning: .medium))
        let fields = try #require(payload["additionalModelRequestFields"] as? [String: Any])
        #expect(AnyCodable(fields) == AnyCodable(["reasoning": ["effort": "medium"]]))
    }

    @Test(arguments: a2BedrockLevels)
    func gptOssUsesFlatClampedEffort(_ level: ThinkingLevel) throws {
        let model = a2BedrockModel("openai.gpt-oss-120b-1:0", thinkingLevelMap: [.xhigh: "max"])
        let payload = try a2BedrockPayload(model, options: BedrockOptions(env: [:], reasoning: level))
        let expected: String
        switch level {
        case .minimal, .low: expected = "low"
        case .medium: expected = "medium"
        case .high, .xhigh, .max: expected = "high"
        }
        let fields = try #require(payload["additionalModelRequestFields"] as? [String: Any])
        #expect(AnyCodable(fields) == AnyCodable(["reasoning_effort": expected]))
    }

    @Test func noReasoningFieldsWhenReasoningIsOff() throws {
        let model = a2BedrockModel("global.openai.gpt-6-sol")
        #expect(try a2BedrockPayload(model, options: BedrockOptions(env: [:]))["additionalModelRequestFields"] == nil)
        let disabled = a2BedrockModel(model.id, reasoning: false)
        #expect(try a2BedrockPayload(disabled, options: BedrockOptions(env: [:], reasoning: .high))["additionalModelRequestFields"] == nil)
    }

    @Test func gptUsesStringMappingsAndFallsBackForNullMappings() throws {
        let model = a2BedrockModel("global.openai.gpt-6-sol", thinkingLevelMap: [.minimal: "medium", .xhigh: "high", .max: nil])
        for (level, expected) in [(ThinkingLevel.minimal, "medium"), (.xhigh, "high"), (.max, "max"), (.low, "low")] {
            let fields = try #require(buildAdditionalModelRequestFields(model: model, options: BedrockOptions(env: [:], reasoning: level)))
            #expect(fields == ["reasoning": AnyCodable(["effort": expected])])
        }
    }

    @Test func modelNameIdentifiesGPTOSSInferenceProfile() throws {
        let model = a2BedrockModel("arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/my-profile",
            name: "GPT OSS 120B")
        let fields = try #require(buildAdditionalModelRequestFields(model: model, options: BedrockOptions(env: [:], reasoning: .max)))
        #expect(fields == ["reasoning_effort": AnyCodable("high")])
    }
}

@Suite("A2 Bedrock v1.1.0 Haiku thinking")
struct A2BedrockHaikuThinkingTests {
    private func model(_ nameOnly: Bool, map: ThinkingLevelMap? = nil) -> Model {
        a2BedrockModel(nameOnly
            ? "arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/my-profile"
            : "global.anthropic.claude-haiku-5", name: nameOnly ? "Claude Haiku 5" : "Haiku", thinkingLevelMap: map)
    }

    @Test(arguments: [false, true])
    func haikuUsesAdaptiveThinking(_ nameOnly: Bool) throws {
        let fields = try #require(buildAdditionalModelRequestFields(model: model(nameOnly), options: BedrockOptions(env: [:], reasoning: .high)))
        let thinking = try #require(fields["thinking"]?.value as? [String: Any])
        #expect(thinking["type"] as? String == "adaptive")
        #expect(thinking["display"] as? String == "summarized")
        #expect(thinking["budget_tokens"] == nil)
        #expect(fields["output_config"] == AnyCodable(["effort": "high"]))
    }

    @Test(arguments: [false, true])
    func haikuUsesNativeXhighEffort(_ nameOnly: Bool) throws {
        let fields = try #require(buildAdditionalModelRequestFields(model: model(nameOnly, map: [.xhigh: "low"]),
            options: BedrockOptions(env: [:], reasoning: .xhigh)))
        #expect(fields["output_config"] == AnyCodable(["effort": "xhigh"]))
    }

    @Test(arguments: [false, true])
    func haikuSendsThinkingBinding(_ nameOnly: Bool) throws {
        let fields = try #require(buildAdditionalModelRequestFields(model: model(nameOnly), options: BedrockOptions(env: [:], reasoning: .high)))
        let thinking = try #require(fields["thinking"]?.value as? [String: Any])
        let binding = try #require(thinking["block_binding"] as? [String: String])
        #expect(binding == ["prefix_mismatch_behavior": "drop_block"])
        #expect(fields["anthropic_beta"] == AnyCodable(["thinking-binding-controls-2026-08-01"]))
    }
}

private func a2ExpectBedrockCachePoints(_ model: Model, force: String = "0", expected: Bool,
    retention: CacheRetention = .short) throws {
    let env = ["AWS_BEDROCK_FORCE_CACHE": force]
    #expect(supportsPromptCaching(model: model, env: env) == expected)
    let payload = try a2BedrockPayload(model, options: BedrockOptions(env: env, cacheRetention: retention))
    let system = try #require(payload["system"] as? [[String: Any]])
    let messages = try #require(payload["messages"] as? [[String: Any]])
    let content = try #require(messages.last?["content"] as? [[String: Any]])
    let hasCache = expected && retention != .none
    #expect(system.count == (hasCache ? 2 : 1))
    #expect(content.count == (hasCache ? 2 : 1))
    #expect((system.last?["cachePoint"] != nil) == hasCache)
    #expect((content.last?["cachePoint"] != nil) == hasCache)
}

@Suite("A2 Bedrock v1.1.0 prompt cache")
struct A2BedrockPromptCacheTests {
    @Test(arguments: ["global.anthropic.claude-fable-5", "global.anthropic.claude-opus-5",
        "global.anthropic.claude-sonnet-5", "global.anthropic.claude-haiku-5",
        "global.anthropic.claude-opus-4-6-v1", "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
        "us.anthropic.claude-haiku-4-5-20251001-v1:0", "anthropic.claude-3-7-sonnet-20250219-v1:0",
        "anthropic.claude-3-5-haiku-20241022-v1:0"])
    func supportedClaudeModelsGetCachePoints(_ id: String) throws {
        try a2ExpectBedrockCachePoints(a2BedrockModel(id), expected: true)
    }

    @Test(arguments: ["0", "1"])
    func unsupportedClaudeIgnoresForceCache(_ force: String) throws {
        let model = a2BedrockModel("anthropic.claude-3-5-sonnet-20241022-v2:0",
            cost: ModelCost(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75))
        try a2ExpectBedrockCachePoints(model, force: force, expected: false)
    }

    @Test func openAIPricesDoNotEnableCachePoints() throws {
        let model = a2BedrockModel("global.openai.gpt-6-sol",
            cost: ModelCost(input: 2.5, output: 15, cacheRead: 0.25, cacheWrite: 2.5))
        try a2ExpectBedrockCachePoints(model, expected: false)
    }

    @Test(arguments: ["0", "1", "true", "2"])
    func nonClaudeNeedsForceCacheValueOne(_ force: String) throws {
        try a2ExpectBedrockCachePoints(a2BedrockModel("amazon.nova-pro-v1:0"), force: force, expected: force == "1")
    }

    @Test(arguments: ["Claude Sonnet 5", "claude-sonnet-5", "CLAUDE_SONNET_5", "Claude Sonnet 4.6", "Claude 3.7 Sonnet", "Claude 3.5 Haiku"])
    func inferenceProfileUsesModelName(_ name: String) throws {
        let model = a2BedrockModel("arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/my-profile", name: name)
        try a2ExpectBedrockCachePoints(model, expected: true)
    }

    @Test func cacheRetentionNoneOmitsCachePoints() throws {
        try a2ExpectBedrockCachePoints(a2BedrockModel("global.anthropic.claude-haiku-5"), expected: true, retention: .none)
    }
}
