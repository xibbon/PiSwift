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

// constrained-sampling.test.ts: "keeps strict mode for enum-only schemas"
@Test func keepsStrictModeForEnumOnlySchemas() throws {
    var tool = constrainedTool(.jsonSchema(strict: .prefer))
    tool.parameters["properties"] = AnyCodable(["level": ["enum": ["low", "high"]]] as [String: Any])
    tool.parameters["required"] = AnyCodable(["level"])
    #expect(try resolveJsonSchemaStrictSampling(tool: tool, supportsStrictMode: true) == true)
    let tools = try #require(try responsesToolsPayload([tool], supportsStrictMode: true))
    let encoded = try #require(try encodedJSONObject(tools) as? [[String: Any]])
    #expect(encoded[0]["strict"] as? Bool == true)
}

// constrained-sampling.test.ts: "falls back or rejects schemas that cannot be safely converted"
@Test(arguments: ["array item", "unknown value", "bare const", "empty object"])
func untypedStrictNodesFallBackOrReject(kind: String) throws {
    let properties: [String: [String: Any]]
    switch kind {
    case "array item": properties = ["commandArguments": ["type": "array", "items": [String: Any]()]]
    case "unknown value": properties = ["value": ["description": "Any JSON value"]]
    case "empty object": properties = ["value": [:]]
    default: properties = ["mode": ["const": "fast"]]
    }
    var preferred = constrainedTool(.jsonSchema(strict: .prefer))
    preferred.parameters["properties"] = AnyCodable(properties)
    preferred.parameters["required"] = AnyCodable(Array(properties.keys))
    #expect(try resolveJsonSchemaStrictSampling(tool: preferred, supportsStrictMode: true) == nil)
    var required = preferred
    required.constrainedSampling = .jsonSchema(strict: .require)
    do {
        _ = try resolveJsonSchemaStrictSampling(tool: required, supportsStrictMode: true)
        Issue.record("Expected strict schema rejection")
    } catch {
        #expect(error.localizedDescription == "Tool \"write\" requires JSON-schema constrained sampling, but schemas without a type are unsupported.")
    }
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

// openai-responses-compat.test.ts:161-170: Copilot, MAI and Grok tools carry explicit strict values.
@Test("sets strict mode explicitly for Responses tools", arguments: [
    ("cloudflare-ai-gateway", "gpt-5.6-sol"),
    ("github-copilot", "gpt-5.3-codex"),
    ("github-copilot", "mai-code-2"),
    ("github-copilot", "grok-4.7"),
])
func copilotResponsesExplicitStrict(_ provider: String, _ id: String) throws {
    let model = try #require(getModel(provider: provider, modelId: id))
    #expect(model.compat?.supportsStrictMode == true)
    let ordinary = constrainedTool(nil)
    let constrained = constrainedTool(.jsonSchema(strict: .prefer))
    let query = try buildResponsesQuery(model: model,
        context: Context(messages: [], tools: [ordinary, constrained]),
        options: OpenAIResponsesOptions(cacheRetention: .short))
    let payload = try #require(encodedJSONObject(query) as? [String: Any])
    let tools = try #require(payload["tools"] as? [[String: Any]])
    #expect(tools.map { $0["strict"] as? Bool } == [false, true])
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
    // v1.5.2 A-STR: append a delta, then close with the complete input.
    #expect(try appendGrammarToolInputJsonDelta(
        buffer: &buffer,
        inputProperty: "value",
        inputDelta: "hello"
    ) == #"{"value":"hello"#)
    #expect(try appendGrammarToolInputJsonDelta(
        buffer: &buffer,
        inputProperty: "value",
        inputDelta: " world"
    ) == " world")
    #expect(try closeGrammarToolInputJson(
        buffer: &buffer,
        inputProperty: "value",
        finalInput: "hello world"
    ) == "\"}")

    #expect(throws: ValidationError.self) {
        _ = try appendGrammarToolInputJsonDelta(
            buffer: &buffer,
            inputProperty: "value",
            inputDelta: "changed"
        )
    }

    var nonMonotonic = GrammarToolInputJsonBuffer(input: "prefix", started: true, closed: false)
    #expect(throws: ValidationError.self) {
        _ = try closeGrammarToolInputJson(
            buffer: &nonMonotonic,
            inputProperty: "value",
            finalInput: "other"
        )
    }
}

@Test(.timeLimit(.minutes(1))) func openAIResponsesStreamsGrammarInputThroughSyntheticProperty() async throws {
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
            context: normalizeContext(context),
            options: OpenAIResponsesOptions(
                apiKey: "test-key",
                onPayload: { snapshot in
                    capturedPayload.withLock { $0 = snapshot.json }
                    return nil
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

// v1.5.2 A-STR: upstream's append-only and close assertions.
@Test("keeps grammar input JSON deltas append-only")
func grammarInputDeltasAreAppendOnly() throws {
    var buffer = GrammarToolInputJsonBuffer()
    let first = try appendGrammarToolInputJsonDelta(buffer: &buffer, inputProperty: "payload", inputDelta: "a\"") ?? ""
    let second = try closeGrammarToolInputJson(buffer: &buffer, inputProperty: "payload", finalInput: "a\"\nb") ?? ""
    let parsed = try JSONSerialization.jsonObject(with: Data((first + second).utf8)) as? [String: String]
    #expect(parsed?["payload"] == "a\"\nb")
    #expect(try closeGrammarToolInputJson(buffer: &buffer, inputProperty: "payload", finalInput: "a\"\nb") == nil)
    do {
        _ = try closeGrammarToolInputJson(buffer: &buffer, inputProperty: "payload", finalInput: "changed")
        Issue.record("Expected closed-input error")
    } catch let error as ValidationError {
        #expect(error.errorDescription == "grammar tool input for property \"payload\" changed after it was closed")
    }
    do {
        _ = try appendGrammarToolInputJsonDelta(buffer: &buffer, inputProperty: "payload", inputDelta: "x")
        Issue.record("Expected append-after-close error")
    } catch let error as ValidationError {
        #expect(error.errorDescription == "grammar tool input for property \"payload\" changed after it was closed")
    }
}

@Test("rejects a final grammar input that does not continue the streamed input")
func grammarFinalInputRejectsNonMonotonicText() throws {
    var buffer = GrammarToolInputJsonBuffer()
    _ = try appendGrammarToolInputJsonDelta(buffer: &buffer, inputProperty: "payload", inputDelta: "abc")
    do {
        _ = try closeGrammarToolInputJson(buffer: &buffer, inputProperty: "payload", finalInput: "abd")
        Issue.record("Expected non-monotonic error")
    } catch let error as ValidationError {
        #expect(error.errorDescription == "grammar tool input for property \"payload\" changed non-monotonically")
    }
}
