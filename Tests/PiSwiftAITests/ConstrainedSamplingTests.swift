import Foundation
import Testing
@testable import PiSwiftAI

private func constrainedTool(_ sampling: ConstrainedSampling?) -> AITool {
    AITool(
        name: "write",
        description: "Write text",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable(["value": ["type": "string"]] as [String: Any]),
            "required": AnyCodable(["value"]),
        ],
        constrainedSampling: sampling
    )
}

private func encodedJSONObject<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
}

private func applyResponsesMiddleware(
    tool: AITool,
    supportsStrictMode: Bool,
    supportsGrammar: Bool
) throws -> [String: Any] {
    let middleware = try makeOpenAIResponsesConstrainedSamplingMiddleware(
        tools: [tool],
        supportsStrictMode: supportsStrictMode,
        supportsOpenAIGrammarTools: supportsGrammar
    )
    var request = URLRequest(url: URL(string: "https://example.com/v1/responses")!)
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "tools": [[
            "type": "function",
            "name": tool.name,
            "description": tool.description,
            "parameters": tool.parameters.mapValues(\.value),
            "strict": false,
        ]],
    ])
    let updated = middleware.intercept(request: request)
    return try #require(JSONSerialization.jsonObject(with: updated.httpBody ?? Data()) as? [String: Any])
}

@Test func requiredStrictSamplingRejectsUnsupportedModel() {
    let tool = constrainedTool(.jsonSchema(strict: .require))
    #expect(throws: ValidationError.self) {
        _ = try resolveJsonSchemaStrictSampling(tool: tool, supportsStrictMode: false)
    }
}

@Test func preferredStrictSamplingFallsBackWithoutStrictField() throws {
    let tool = constrainedTool(.jsonSchema(strict: .prefer))
    #expect(try resolveJsonSchemaStrictSampling(tool: tool, supportsStrictMode: false) == nil)

    let payload = try applyResponsesMiddleware(tool: tool, supportsStrictMode: false, supportsGrammar: false)
    let tools = try #require(payload["tools"] as? [[String: Any]])
    #expect(tools[0]["strict"] == nil)
}

@Test func requiredStrictSamplingEmitsTrueForSupportedModel() throws {
    let tool = constrainedTool(.jsonSchema(strict: .require))
    let tools = try #require(try responsesToolsPayload([tool], supportsStrictMode: true))
    let encoded = try #require(try encodedJSONObject(tools) as? [[String: Any]])
    #expect(encoded[0]["strict"] as? Bool == true)
}

@Test func disabledSamplingNeverEnablesStrictOrGrammar() throws {
    let tool = constrainedTool(.disabled)
    #expect(try resolveJsonSchemaStrictSampling(tool: tool, supportsStrictMode: true) == nil)
    #expect(try resolveGrammarConstrainedSampling(tool: tool, supportsOpenAIGrammarTools: true) == nil)

    let payload = try applyResponsesMiddleware(tool: tool, supportsStrictMode: true, supportsGrammar: true)
    let tools = try #require(payload["tools"] as? [[String: Any]])
    #expect(tools[0]["type"] as? String == "function")
    #expect(tools[0]["strict"] as? Bool == false)
}

@Test func unspecifiedSamplingKeepsResponsesDefaultStrictFalse() throws {
    let tool = constrainedTool(nil)
    let tools = try #require(try responsesToolsPayload([tool], supportsStrictMode: true))
    let encoded = try #require(try encodedJSONObject(tools) as? [[String: Any]])
    #expect(encoded[0]["strict"] as? Bool == false)
}

@Test func grammarSamplingUsesCustomToolOnlyWhenSupported() throws {
    let tool = constrainedTool(.grammar(variants: [.openAILark: "start: /[a-z]+/"]))

    let supported = try applyResponsesMiddleware(tool: tool, supportsStrictMode: true, supportsGrammar: true)
    let supportedTools = try #require(supported["tools"] as? [[String: Any]])
    #expect(supportedTools[0]["type"] as? String == "custom")
    let format = try #require(supportedTools[0]["format"] as? [String: Any])
    #expect(format["type"] as? String == "grammar")
    #expect(format["syntax"] as? String == "lark")

    let unsupported = try applyResponsesMiddleware(tool: tool, supportsStrictMode: true, supportsGrammar: false)
    let unsupportedTools = try #require(unsupported["tools"] as? [[String: Any]])
    #expect(unsupportedTools[0]["type"] as? String == "function")
}

@Test func grammarInputBufferWrapsDeltasAndRejectsMalformedReplay() throws {
    var buffer = GrammarToolInputJsonBuffer()
    #expect(try appendGrammarToolInputJsonDelta(
        buffer: &buffer,
        inputProperty: "value",
        nextInput: "hello",
        close: false
    ) == #"{"value":"hello"#)
    #expect(try appendGrammarToolInputJsonDelta(
        buffer: &buffer,
        inputProperty: "value",
        nextInput: "hello world",
        close: false
    ) == " world")
    #expect(try appendGrammarToolInputJsonDelta(
        buffer: &buffer,
        inputProperty: "value",
        nextInput: "hello world",
        close: true
    ) == "\"}")

    #expect(throws: ValidationError.self) {
        _ = try appendGrammarToolInputJsonDelta(
            buffer: &buffer,
            inputProperty: "value",
            nextInput: "changed",
            close: false
        )
    }

    var nonMonotonic = GrammarToolInputJsonBuffer(input: "prefix", started: true, closed: false)
    #expect(throws: ValidationError.self) {
        _ = try appendGrammarToolInputJsonDelta(
            buffer: &nonMonotonic,
            inputProperty: "value",
            nextInput: "other",
            close: false
        )
    }
}

@Test func openAIResponsesStreamsGrammarInputThroughSyntheticProperty() async throws {
    await codexRequestLock.withLock {
        let capturedPayload = LockedState<String?>(nil)
        OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = ["grammar.example"] }
        OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = { request in
            let data = try openAITestSseData([
                [
                    "type": "response.output_item.added",
                    "output_index": 0,
                    "item": [
                        "type": "custom_tool_call",
                        "id": "ctc_1",
                        "call_id": "call_1",
                        "name": "write",
                        "input": "",
                    ],
                ],
                [
                    "type": "response.custom_tool_call_input.delta",
                    "output_index": 0,
                    "delta": "hel",
                ],
                [
                    "type": "response.custom_tool_call_input.delta",
                    "output_index": 0,
                    "delta": "lo",
                ],
                [
                    "type": "response.custom_tool_call_input.done",
                    "output_index": 0,
                    "input": "hello",
                ],
                [
                    "type": "response.output_item.done",
                    "output_index": 0,
                    "item": [
                        "type": "custom_tool_call",
                        "id": "ctc_1",
                        "call_id": "call_1",
                        "name": "write",
                        "input": "hello",
                    ],
                ],
                [
                    "type": "response.completed",
                    "response": [
                        "id": "resp_1",
                        "status": "completed",
                        "usage": [
                            "input_tokens": 1,
                            "output_tokens": 1,
                            "total_tokens": 2,
                            "input_tokens_details": ["cached_tokens": 0],
                            "output_tokens_details": ["reasoning_tokens": 0],
                        ],
                    ],
                ],
            ])
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, data)
        } }
        URLProtocol.registerClass(OpenAICompletionsMockURLProtocol.self)
        defer {
            OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = nil }
            OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = [] }
            URLProtocol.unregisterClass(OpenAICompletionsMockURLProtocol.self)
        }

        let model = Model(
            id: "grammar-model",
            name: "Grammar Model",
            api: .openAIResponses,
            provider: "openai",
            baseUrl: "https://grammar.example/v1",
            reasoning: false,
            input: [.text],
            cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 8_192,
            maxTokens: 1_024,
            compat: OpenAICompat(
                supportsOpenAIGrammarTools: true,
                supportsStrictMode: true
            )
        )
        let context = Context(
            messages: [.user(UserMessage(content: .text("Write hello")))],
            tools: [constrainedTool(.grammar(variants: [.openAILark: "start: /[a-z]+/"]))]
        )
        let eventStream = streamOpenAIResponses(
            model: model,
            context: context,
            options: OpenAIResponsesOptions(
                apiKey: "test-key",
                onPayload: { snapshot in
                    capturedPayload.withLock { $0 = snapshot.json }
                }
            )
        )

        var deltas: [String] = []
        for await event in eventStream {
            if case .toolCallDelta(_, let delta, _) = event { deltas.append(delta) }
        }
        let message = await eventStream.result()
        let call = message.content.compactMap { block -> ToolCall? in
            if case .toolCall(let call) = block { return call }
            return nil
        }.first

        #expect(message.stopReason == .toolUse)
        #expect(call?.arguments["value"]?.value as? String == "hello")
        #expect(deltas == [#"{"value":"hel"#, "lo", "\"}"])
        let payload = capturedPayload.withLock { $0 }.flatMap { json -> [String: Any]? in
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        let tools = payload?["tools"] as? [[String: Any]]
        #expect(tools?.first?["type"] as? String == "custom")
    }
}
