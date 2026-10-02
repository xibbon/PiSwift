import Foundation
import Testing
@testable import PiSwiftAI

private enum StrictKeywordCaptureError: Error {
    case captured
}

private actor StrictKeywordHTTPClient: ProviderHTTPClient {
    var requestBody: Data?

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requestBody = request.httpBody
        throw StrictKeywordCaptureError.captured
    }
}

private func captureStrictKeywordTool(_ parameters: [String: Any]) async throws -> [String: Any] {
    let client = StrictKeywordHTTPClient()
    let model = Model(
        id: "claude-opus-4-8", name: "Claude Opus 4.8", api: .anthropicMessages,
        provider: "test-anthropic", baseUrl: "https://strict-keyword.invalid",
        reasoning: true, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 200_000, maxTokens: 32_000,
        compat: OpenAICompat(supportsStrictTools: true, forceAdaptiveThinking: true)
    )
    let tool = AITool(
        name: "lookup", description: "Look up a value", parameters: parameters.mapValues(AnyCodable.init),
        constrainedSampling: .jsonSchema(strict: .prefer)
    )
    let context = Context(messages: [.user(UserMessage(content: .text("Use the tool")))], tools: [tool])
    _ = await streamAnthropic(
        model: model, context: normalizeContext(context),
        options: AnthropicOptions(apiKey: "test-key", httpClient: client, cacheRetention: CacheRetention.none, maxRetries: 0)
    ).result()
    let body = try #require(await client.requestBody)
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    return try #require((payload["tools"] as? [[String: Any]])?.first)
}

@Suite("Anthropic strict schema keywords")
struct AnthropicStrictKeywordTests {
    // https://github.com/earendil-works/pi/issues/9953
    @Test(.timeLimit(.minutes(1)))
    func preferToolsUseNonStrictModeForRejectedKeywords() async throws {
        let unsupported: [[String: Any]] = [
            ["type": "object", "properties": [
                "timeoutMs": ["type": "integer", "minimum": 1, "maximum": 300_000],
            ]],
            ["type": "object", "required": ["options"], "properties": [
                "options": ["type": "object", "required": ["tags"], "properties": [
                    "tags": ["type": "array", "items": ["type": "string"], "minItems": 2],
                ]],
            ]],
            ["type": "object", "required": ["expression"], "properties": [
                "expression": ["type": "string", "format": "regex"],
            ]],
        ]
        for parameters in unsupported {
            let tool = try await captureStrictKeywordTool(parameters)
            #expect(tool["strict"] == nil)
        }

        let supported: [String: Any] = [
            "type": "object", "required": ["code", "url", "tags"], "properties": [
                "code": ["type": "string", "minLength": 1, "maxLength": 1_000, "pattern": "^[a-z]+$"],
                "url": ["type": "string", "format": "uri"],
                "tags": ["type": "array", "items": ["type": "string"], "minItems": 1],
            ],
        ]
        let tool = try await captureStrictKeywordTool(supported)
        #expect(tool["strict"] as? Bool == true)
    }
}
