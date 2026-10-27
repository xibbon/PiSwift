import Foundation
import Testing
@testable import PiSwiftAI

private func f2Model(_ api: Api, images: Bool = false, id: String = "test") -> Model {
    Model(id: id, name: id, api: api, provider: "test", baseUrl: "https://example.invalid/v1",
          reasoning: false, input: images ? [.text, .image] : [.text],
          cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
          contextWindow: 8192, maxTokens: 1024)
}

private func f2Context(_ text: String, model: Model, image: Bool = false) -> Context {
    let assistant = AssistantMessage(content: [.toolCall(ToolCall(id: "call", name: "read", arguments: ["input": AnyCodable("file")]))],
        api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse)
    var content: [ContentBlock] = [.text(TextContent(text: text))]
    if image { content.append(.image(ImageContent(data: "AAAA", mimeType: "image/png"))) }
    return Context(messages: [.assistant(assistant), .toolResult(ToolResultMessage(toolCallId: "call", toolName: "read", content: content, isError: false))])
}

private func f2JSON<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
}

private func f2StoredText(_ context: Context) throws -> String {
    guard case .toolResult(let result) = context.messages.last,
          case .text(let text) = result.content.first else {
        throw F2FixtureError.missingResult
    }
    return text.text
}

private enum F2FixtureError: Error { case missingResult }

private actor F2CaptureClient: ProviderHTTPClient {
    var request: URLRequest?
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        self.request = request
        return ProviderHTTPResponse(statusCode: 400, body: Data("fixture captured".utf8))
    }
}

// Upstream v1.4.0 openai-completions-tool-result-images.test.ts:148 expands the empty result to three values.
@Test(.timeLimit(.minutes(1)), arguments: ["", "\r\n", " \n\t", " \nbeta text\t"])
func f2CompletionsToolTextPresence(_ text: String) async throws {
    for image in [false, true] {
        let model = f2Model(.openAICompletions, images: true)
        let context = f2Context(text, model: model, image: image)
        let client = F2CaptureClient()
        _ = await streamOpenAICompletions(model: model, context: normalizeContext(context),
            options: OpenAICompletionsOptions(apiKey: "test", httpClient: client, maxRetries: 0)).result()
        let request = try #require(await client.request)
        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(payload["messages"] as? [[String: Any]])
        let result = try #require(messages.first { $0["role"] as? String == "tool" })
        let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        #expect(result["content"] as? String == (blank ? (image ? "(see attached image)" : "(no tool output)") : text))
        #expect(try f2StoredText(context) == text)
    }
}

// Upstream v1.4.0 openai-responses-empty-tool-result.test.ts:28 and shared image routing.
@Test(arguments: ["", "\r\n", " \n\t", " \nbeta text\t"])
func f2ResponsesAndAzureToolTextPresence(_ text: String) throws {
    for azure in [false, true] {
        for acceptsImages in [false, true] {
            for image in [false, true] {
                let model = f2Model(azure ? .azureOpenAIResponses : .openAIResponses, images: acceptsImages)
                let context = f2Context(text, model: model, image: image)
                let payload: [String: Any]
                if azure {
                    payload = try #require(f2JSON(buildAzureResponsesQuery(model: model, context: context,
                        options: AzureOpenAIResponsesOptions(), deploymentName: "test")) as? [String: Any])
                } else {
                    payload = ["input": try f2JSON(convertResponsesMessages(model: model, context: context, allowedToolCallProviders: []))]
                }
                var request = URLRequest(url: URL(string: "https://example.invalid/responses")!)
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                let updated = OpenAIResponsesInlineImagesMiddleware().intercept(request: request)
                let body = try #require(updated.httpBody)
                let rewritten = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let input = try #require(rewritten["input"] as? [[String: Any]])
                let result = try #require(input.first { $0["type"] as? String == "function_call_output" })
                let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if acceptsImages && image {
                    let parts = try #require(result["output"] as? [[String: Any]])
                    #expect(parts.filter { $0["type"] as? String == "input_image" }.count == 1)
                    #expect(parts.compactMap { $0["text"] as? String } == (blank ? [] : [text]))
                } else {
                    #expect(result["output"] as? String == (blank ? (image ? "(see attached image)" : "(no tool output)") : text))
                }
                #expect(try f2StoredText(context) == text)
            }
        }
    }
}

@Test(arguments: ["", "\r\n", " \n\t", " \nbeta text\t"])
func f2CodexFunctionAndCustomToolTextPresence(_ text: String) throws {
    for grammar in [false, true] {
        for image in [false, true] {
            let model = f2Model(.openAICodexResponses, images: true)
            let context = f2Context(text, model: model, image: image)
            let input = try #require(convertCodexMessages(model: model, context: context,
                grammarToolInputProperties: grammar ? ["read": "input"] : [:]) as? [[String: Any]])
            let result = try #require(input.first { $0["type"] as? String == (grammar ? "custom_tool_call_output" : "function_call_output") })
            let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            #expect(result["output"] as? String == (blank ? (image ? "(see attached image)" : "(no tool output)") : text))
            // Codex keeps the existing separate user message for images (intake §5, item 3).
            #expect(input.filter { $0["role"] as? String == "user" }.count == (image ? 1 : 0))
            #expect(try f2StoredText(context) == text)
        }
    }
}

@Test(arguments: ["", "\r\n", " \n\t", " \nbeta text\t"])
func f2ResponsesCustomToolTextPresence(_ text: String) throws {
    let model = f2Model(.openAIResponses, images: true)
    for image in [false, true] {
        let context = f2Context(text, model: model, image: image)
        let items = convertResponsesMessages(model: model, context: context, allowedToolCallProviders: [], grammarToolInputProperties: ["read": "input"])
        var request = URLRequest(url: URL(string: "https://example.invalid/responses")!)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["input": f2JSON(items)])
        request = OpenAIResponsesInlineImagesMiddleware().intercept(request: request)
        request = OpenAIResponsesConstrainedSamplingMiddleware(supportsStrictMode: true, grammarTools: [:], grammarToolInputProperties: ["read": "input"]).intercept(request: request)
        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try #require(payload["input"] as? [[String: Any]])
        let result = try #require(input.first { $0["type"] as? String == "custom_tool_call_output" })
        let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if image {
            let parts = try #require(result["output"] as? [[String: Any]])
            #expect(parts.compactMap { $0["text"] as? String } == (blank ? [] : [text]))
            #expect(parts.filter { $0["type"] as? String == "input_image" }.count == 1)
        } else {
            #expect(result["output"] as? String == (blank ? "(no tool output)" : text))
        }
        #expect(try f2StoredText(context) == text)
    }
}

// Upstream v1.4.0 google-shared-image-tool-result-routing.test.ts:104.
@Test(arguments: ["", "\r\n", " \n\t", " \nbeta text\t"])
func f2GoogleToolTextAndImageRouting(_ text: String) throws {
    for id in ["gemini-2.5-pro", "gemini-3-pro"] {
        for acceptsImages in [false, true] {
            for image in [false, true] {
                let model = f2Model(.googleGenerativeAI, images: acceptsImages, id: id)
                let context = f2Context(text, model: model, image: image)
                let contents = convertGoogleMessages(model: model, context: context)
                let parts = contents.flatMap { $0["parts"] as? [[String: Any]] ?? [] }
                let response = try #require(parts.compactMap { $0["functionResponse"] as? [String: Any] }.first)
                let output = try #require(response["response"] as? [String: Any])
                let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                #expect(output["output"] as? String == (blank ? (acceptsImages && image ? "(see attached image)" : "") : text))
                let nested = response["parts"] as? [[String: Any]] ?? []
                #expect(nested.count == (id == "gemini-3-pro" && acceptsImages && image ? 1 : 0))
                #expect(parts.filter { $0["inlineData"] != nil }.count == (id == "gemini-2.5-pro" && acceptsImages && image ? 1 : 0))
                #expect(try f2StoredText(context) == text)
            }
        }
    }
}
