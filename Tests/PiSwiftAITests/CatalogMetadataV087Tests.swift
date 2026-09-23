import Foundation
import Testing
@testable import PiSwiftAI

@Test func regeneratedCatalogPreservesImageLimitsAndPromptCache() {
    let openAI = getModel(provider: .openai, modelId: "gpt-4-turbo")
    #expect(openAI.inputLimits?.maxRequestBytes == 536_870_912)
    #expect(openAI.inputLimits?.images?.maxPerRequest == 1_500)
    #expect(openAI.inputLimits?.images?.resize?.maxBytes == 4_718_592)
    #expect(openAI.inputLimits?.images?.resize?.jpegQuality == 80)

    let anthropic = getModel(provider: .anthropic, modelId: "claude-fable-5")
    #expect(anthropic.promptCache?.short == 300)
    #expect(anthropic.promptCache?.long == 3_600)
}

private actor CerebrasRequestClient: ProviderHTTPClient {
    private var body: Data?

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        body = request.httpBody
        let response = "data: {\"id\":\"test\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"gpt-oss-120b\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        return ProviderHTTPResponse(statusCode: 200, body: Data(response.utf8))
    }

    func requestBody() -> Data? { body }
}

@Test func cerebrasCatalogModelOmitsStrictToolFlag() async throws {
    let model = try #require(getModel(provider: "cerebras", modelId: "gpt-oss-120b"))
    let client = CerebrasRequestClient()
    let tool = AITool(name: "ping", description: "Ping", parameters: ["type": AnyCodable("object")])
    let context = normalizeContext(Context(messages: [.user(UserMessage(content: .text("Ping")))], tools: [tool]))
    _ = await streamOpenAICompletions(
        model: model,
        context: context,
        options: OpenAICompletionsOptions(apiKey: "test-key", httpClient: client)
    ).result()
    let body = try #require(await client.requestBody())
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let tools = try #require(json["tools"] as? [[String: Any]])
    let function = try #require(tools.first?["function"] as? [String: Any])
    #expect(function["strict"] == nil)
}
