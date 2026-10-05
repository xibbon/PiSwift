import Foundation
import Testing
@testable import PiSwiftAI

private actor K1CloudflareHTTPClient: ProviderHTTPClient {
    private var request: URLRequest?

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        self.request = request
        // Reply from the A1 Cloudflare direct-output test.
        let reply = #"{"result":{"model":"clef","answers":{"is_urgent":{"type":"noul","noul":0.9912},"department":{"type":"choice","choice":"technical","probabilities":{"billing":0.1632,"technical":0.8368},"confidence":0.4538}},"usage":{"input_tokens":222,"output_tokens":0}},"success":true,"errors":[],"messages":[]}"#
        return ProviderHTTPResponse(statusCode: 200, body: Data(reply.utf8))
    }

    func captured() -> URLRequest? { request }
}

@Suite("K1 v1.0.1 catalog", .timeLimit(.minutes(1)))
struct K1CatalogV101Tests {
    @Test(arguments: ["@cf/cloudflare/clef", "@cf/cloudflare/clef-flash"])
    func clefCatalogMetadata(_ id: String) throws {
        let model = try #require(getClassifierModel(provider: "cloudflare-workers-ai", modelId: id))
        let price = id.hasSuffix("-flash") ? 0.09 : 0.24
        #expect(model.id == id)
        #expect(model.provider == "cloudflare-workers-ai")
        #expect(model.api == .cloudflareWorkersAISystemOne)
        #expect(model.baseUrl == "https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/ai")
        #expect(model.contextWindow == 65_536)
        #expect(model.input == [.text])
        #expect(model.cost == ModelCost(input: price, output: 0, cacheRead: 0, cacheWrite: 0))
    }

    @Test(arguments: ["@cf/cloudflare/clef", "@cf/cloudflare/clef-flash"])
    func clefCatalogClassifyCost(_ id: String) async throws {
        let model = try #require(getClassifierModel(provider: "cloudflare-workers-ai", modelId: id))
        let client = K1CloudflareHTTPClient()
        let context = ClassifierContext(
            state: ["text": AnyCodable("The app crashes when I open settings. Please help today.")],
            questions: [
                "is_urgent": .bool(instructions: "Is this urgent?", trueCriterion: "Urgent", falseCriterion: "Not urgent"),
                "department": .choice(instructions: "Which department?", criteria: ["billing": "Billing", "technical": "Technical"]),
            ])
        let result = await classify(model: model, context: context,
            options: ClassifierOptions(apiKey: "token", httpClient: client,
                env: ["CLOUDFLARE_ACCOUNT_ID": "account-id"]))
        #expect(result.stopReason == .stop)
        if case .bool(let probability)? = result.answers["is_urgent"] {
            #expect(probability == 0.9912)
        } else { Issue.record("Missing bool answer") }
        if case .choice(let choice, let probabilities, let confidence)? = result.answers["department"] {
            #expect(choice == "technical")
            #expect(probabilities == ["billing": 0.1632, "technical": 0.8368])
            #expect(confidence == 0.4538)
        } else { Issue.record("Missing choice answer") }
        let usage = try #require(result.usage)
        let price = id.hasSuffix("-flash") ? 0.09 : 0.24
        let expected = 222 * price / 1_000_000
        #expect(usage.input == 222)
        #expect(usage.output == 0)
        #expect(usage.totalTokens == 222)
        #expect(abs(usage.cost.input - expected) < 1e-12)
        #expect(usage.cost.output == 0)
        #expect(abs(usage.cost.total - expected) < 1e-12)
        let request = try #require(await client.captured())
        #expect(request.url?.absoluteString == "https://api.cloudflare.com/client/v4/accounts/account-id/ai/run")
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == id)
    }

    // Port of the DeepSeek assertions in v1.0.1 together-models.test.ts.
    @Test func togetherDeepSeekReplacement() throws {
        #expect(getModel(provider: "together", modelId: "deepseek-ai/DeepSeek-V4-Pro") == nil)
        let model = try #require(getModel(provider: "together", modelId: "deepseek-ai/DeepSeek-V4-Pro-0813"))
        let expected: ThinkingLevelMap = [.minimal: nil, .low: nil, .medium: nil, .high: "high", .xhigh: nil]
        #expect(model.thinkingLevelMap == expected)
        #expect(model.compat?.supportsReasoningEffort == true)
        #expect(model.compat?.thinkingFormat == .together)
    }

    @Test func bedrockOpenAITierCost() throws {
        let model = try #require(getModel(provider: "amazon-bedrock", modelId: "global.openai.gpt-5.6-luna"))
        #expect(model.api == .bedrockConverseStream)
        #expect(model.cost == ModelCost(input: 0.2, output: 1.2, cacheRead: 0.02, cacheWrite: 0.25,
            tiers: [ModelCostTier(inputTokensAbove: 272_000, input: 0.4, output: 1.8, cacheRead: 0.04, cacheWrite: 0.5)]))
        var boundary = Usage(input: 272_000, output: 100, cacheRead: 0, cacheWrite: 0, totalTokens: 272_100)
        let baseCost = calculateCost(model: model, usage: &boundary)
        #expect(abs(baseCost.input - 272_000 * 0.2 / 1_000_000) < 1e-12)
        #expect(abs(baseCost.output - 100 * 1.2 / 1_000_000) < 1e-12)
        var above = Usage(input: 272_001, output: 100, cacheRead: 20, cacheWrite: 10, totalTokens: 272_131)
        let tierCost = calculateCost(model: model, usage: &above)
        #expect(abs(tierCost.input - 272_001 * 0.4 / 1_000_000) < 1e-12)
        #expect(abs(tierCost.output - 100 * 1.8 / 1_000_000) < 1e-12)
        #expect(abs(tierCost.cacheRead - 20 * 0.04 / 1_000_000) < 1e-12)
        #expect(abs(tierCost.cacheWrite - 10 * 0.5 / 1_000_000) < 1e-12)
        #expect(above.cost.input == tierCost.input)
        #expect(above.cost.output == tierCost.output)
        #expect(above.cost.cacheRead == tierCost.cacheRead)
        #expect(above.cost.cacheWrite == tierCost.cacheWrite)
        #expect(above.cost.total == tierCost.total)
    }

    @Test func gatewayClaudeDashedID() throws {
        let model = try #require(getModel(provider: "cloudflare-ai-gateway", modelId: "claude-opus-5-5"))
        #expect(model.id == "claude-opus-5-5")
        #expect(model.api == .anthropicMessages)
        #expect(getModel(provider: "cloudflare-ai-gateway", modelId: "claude-opus-5.5") == nil)
        let resolved = resolveCloudflareModel(model,
            env: ["CLOUDFLARE_ACCOUNT_ID": "account-id", "CLOUDFLARE_GATEWAY_ID": "gateway-id"])
        #expect(resolved.baseUrl == "https://gateway.ai.cloudflare.com/v1/account-id/gateway-id/anthropic")
    }

    @Test func generationTimestampAndProviderCount() {
        #expect(builtinModelDataGeneratedAt == 1_791_212_337.999) // v1.0.3 hydration, 2026-10-05T14:58:57.999Z
        #expect(getProviders().count == 40)
    }
}
