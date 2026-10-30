import Foundation
import Testing
@testable import PiSwiftAI

private let strictGrammarError = "The compiled grammar is too large, which would cause performance issues. Simplify your tool schemas or reduce the number of strict tools."

private func fallbackModel(native: Bool = false) -> Model {
    Model(id: "claude-haiku-4-5", name: "Test Claude", api: .anthropicMessages,
        provider: "anthropic", baseUrl: "https://anthropic.invalid", reasoning: false, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 200_000, maxTokens: 100,
        compat: OpenAICompat(supportsMidConvoSystemMessages: native, supportsMidConvoToolChanges: native,
            supportsStrictTools: true))
}

private func fallbackTool(_ name: String, strict: ConstrainedSamplingStrictness? = nil, unsupported: Bool = false) -> AITool {
    let valueSchema: [String: Any] = unsupported ? ["type": "number", "minimum": 1] : ["type": "string"]
    let parameters: [String: Any] = ["type": "object", "properties": [
        "value": valueSchema, "optional": ["type": "number"],
    ], "required": ["value"]]
    return AITool(name: name, description: "Look up a value", parameters: parameters.mapValues(AnyCodable.init),
        constrainedSampling: strict.map { .jsonSchema(strict: $0) })
}

private func fallbackContext(_ tools: [AITool]) -> TranscriptContext {
    normalizeContext(Context(messages: [.user(UserMessage(content: .text("Hello"), timestamp: 1))], tools: tools))
}

private func fallbackSuccess() -> ProviderHTTPResponse {
    let text = #"{"type":"message_start","message":{"id":"msg_test","type":"message","role":"assistant","content":[],"model":"claude-haiku-4-5","usage":{"input_tokens":10,"output_tokens":0}}}"#
    let delta = #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#
    return ProviderHTTPResponse(statusCode: 200, body: Data("event: message_start\ndata: \(text)\n\nevent: message_delta\ndata: \(delta)\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n".utf8))
}

private func fallbackRejection(_ message: String = strictGrammarError, status: Int = 400,
    type: String = "invalid_request_error") throws -> ProviderHTTPResponse {
    ProviderHTTPResponse(statusCode: status, body: try JSONSerialization.data(withJSONObject: [
        "type": "error", "error": ["type": type, "message": message],
    ]))
}

private actor StrictFallbackHTTPClient: ProviderHTTPClient {
    private let respond: @Sendable (Int) throws -> ProviderHTTPResponse
    private(set) var bodies: [Data] = []
    init(_ respond: @escaping @Sendable (Int) throws -> ProviderHTTPResponse) { self.respond = respond }
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        bodies.append(request.httpBody ?? Data())
        return try respond(bodies.count)
    }
}

private func fallbackPayloads(_ client: StrictFallbackHTTPClient) async throws -> [[String: Any]] {
    try await client.bodies.map { try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
}

private func fallbackOptions(_ client: StrictFallbackHTTPClient, signal: CancellationToken? = nil) -> AnthropicOptions {
    AnthropicOptions(signal: signal, apiKey: "test-key", httpClient: client, cacheRetention: .long, maxRetries: 0)
}

@Suite("Anthropic preferred strict fallback v1.3.0")
struct A2AnthropicStrictFallbackTests {
    @Test(arguments: [
        strictGrammarError,
        "Too many strict tools (32). The maximum number of strict tools supported is 20.",
        "Schemas contains too many parameters with union types (480 parameters with type arrays or anyOf).",
    ])
    func restoresOriginalSchemasAndKeepsRequired(_ message: String) async throws {
        let preferred = fallbackTool("preferred", strict: .prefer)
        let required = fallbackTool("required", strict: .require)
        let ordinary = fallbackTool("ordinary")
        let context = fallbackContext([preferred, required, ordinary])
        let client = StrictFallbackHTTPClient { try $0 == 1 ? fallbackRejection(message) : fallbackSuccess() }
        let payloadCalls = LockedState(0)
        let responseCalls = LockedState(0)
        var options = fallbackOptions(client)
        options.onPayload = { _ in payloadCalls.withLock { $0 += 1 }; return nil }
        options.onResponse = { _ in responseCalls.withLock { $0 += 1 } }
        let stream = streamAnthropic(model: fallbackModel(), context: context, options: options)
        var eventTypes: [String] = []
        for await event in stream {
            switch event {
            case .start: eventTypes.append("start")
            case .done: eventTypes.append("done")
            default: eventTypes.append("other")
            }
        }
        let result = await stream.result()
        #expect(result.stopReason == .stop)
        #expect(eventTypes == ["start", "done"])
        #expect(payloadCalls.withLock { $0 } == 2)
        #expect(responseCalls.withLock { $0 } == 1)
        let payloads = try await fallbackPayloads(client)
        #expect(payloads.count == 2)
        let first = try #require(payloads.first?["tools"] as? [[String: Any]])
        let second = try #require(payloads.last?["tools"] as? [[String: Any]])
        #expect(first[0]["strict"] as? Bool == true)
        let strictSchema = try #require(first[0]["input_schema"] as? [String: Any])
        // The Swift schema converter sorts dictionary keys.
        #expect(Set(strictSchema["required"] as? [String] ?? []) == Set(["value", "optional"]))
        let strictProperties = try #require(strictSchema["properties"] as? [String: Any])
        let optional = try #require(strictProperties["optional"] as? [String: Any])
        #expect((optional["anyOf"] as? [[String: Any]])?.count == 2)
        #expect(second[0]["strict"] == nil)
        let expected: [String: Any] = ["type": "object", "properties": ["value": ["type": "string"], "optional": ["type": "number"]], "required": ["value"]]
        #expect(NSDictionary(dictionary: try #require(second[0]["input_schema"] as? [String: Any])).isEqual(to: expected))
        #expect(NSDictionary(dictionary: second[1]).isEqual(to: first[1]))
        #expect(second[1]["strict"] as? Bool == true)
        #expect(NSDictionary(dictionary: second[2]).isEqual(to: first[2]))
        // The test URL is not api.anthropic.com, so long retention has no native TTL.
        #expect(second[2]["cache_control"] as? [String: String] == ["type": "ephemeral"])
        #expect(payloads.allSatisfy { $0["stream"] as? Bool == true })
        let diagnostic = try #require(result.diagnostics?.first)
        #expect(diagnostic.type == "anthropic_strict_tools_fallback")
        #expect(diagnostic.details == ["reason": AnyCodable("strict_tool_limits_exceeded")])
        #expect(diagnostic.error?.message == message)
        let tools = getCurrentTools(context.messages)
        if case .jsonSchema(strict: .prefer) = tools[0].constrainedSampling {} else { Issue.record("Preferred strictness changed") }
        #expect(tools[0].parameters == preferred.parameters)
        #expect(tools[1].parameters == required.parameters)
    }

    @Test func downgradesInlineRedefinitionsByValue() async throws {
        let base = fallbackContext([fallbackTool("lookup", strict: .require)])
        let context = TranscriptContext(messages: base.messages + [
            .system(SystemMessage(content: .text(""), toolsAdded: [fallbackTool("lookup", strict: .prefer)], timestamp: 2)),
            .system(SystemMessage(content: .text(""), toolsAdded: [fallbackTool("lookup", strict: .require)], timestamp: 3)),
        ])
        let client = StrictFallbackHTTPClient { try $0 == 1 ? fallbackRejection() : fallbackSuccess() }
        var options = fallbackOptions(client)
        options.apiKey = "sk-ant-oat-test"
        let result = await streamAnthropic(model: fallbackModel(native: true), context: context, options: options).result()
        #expect(result.stopReason == .stop)
        let payloads = try await fallbackPayloads(client)
        #expect(payloads.count == 2)
        let first = try #require(payloads.first)
        let second = try #require(payloads.last)
        #expect(NSArray(array: first["tools"] as? [Any] ?? []).isEqual(to: second["tools"] as? [Any] ?? []))
        func additions(_ payload: [String: Any]) -> [[String: Any]] {
            (payload["messages"] as? [[String: Any]] ?? []).flatMap { message in
                (message["content"] as? [[String: Any]] ?? []).compactMap { block in
                    guard block["type"] as? String == "tool_addition", let tool = block["tool"] as? [String: Any] else { return nil }
                    return tool["definition"] as? [String: Any]
                }
            }
        }
        let before = additions(first), after = additions(second)
        #expect(before.count == 2)
        #expect(after.count == 2)
        #expect(before.allSatisfy { $0["strict"] as? Bool == true })
        #expect(after[0]["strict"] == nil)
        #expect((after[0]["input_schema"] as? [String: Any])?["required"] as? [String] == ["value"])
        #expect(NSDictionary(dictionary: after[1]).isEqual(to: before[1]))
    }

    @Test(arguments: ["required", "ordinary", "locally unsupported prefer"])
    func doesNotRetryWithoutPreferredStrictDefinitions(_ kind: String) async throws {
        let tool = fallbackTool("lookup", strict: kind == "required" ? .require : kind == "ordinary" ? nil : .prefer,
            unsupported: kind == "locally unsupported prefer")
        let client = StrictFallbackHTTPClient { _ in try fallbackRejection() }
        let result = await streamAnthropic(model: fallbackModel(), context: fallbackContext([tool]), options: fallbackOptions(client)).result()
        #expect(result.stopReason == .error)
        #expect(result.errorMessage?.contains(strictGrammarError) == true)
        #expect(await client.bodies.count == 1)
        #expect(result.diagnostics == nil)
    }

    @Test(arguments: ["unrelated 400", "wrong error type", "wrong HTTP status"])
    func doesNotDowngradeOtherRejections(_ kind: String) async throws {
        let client = StrictFallbackHTTPClient { _ in
            try fallbackRejection(kind == "unrelated 400" ? "Invalid tool schema" : strictGrammarError,
                status: kind == "wrong HTTP status" ? 500 : 400,
                type: kind == "wrong error type" ? "authentication_error" : "invalid_request_error")
        }
        let result = await streamAnthropic(model: fallbackModel(), context: fallbackContext([fallbackTool("lookup", strict: .prefer)]), options: fallbackOptions(client)).result()
        #expect(result.stopReason == .error)
        #expect(await client.bodies.count == 1)
        #expect(result.diagnostics == nil)
    }

    @Test func surfacesSecondRejection() async throws {
        let client = StrictFallbackHTTPClient { attempt in
            try fallbackRejection(attempt == 1 ? strictGrammarError : "Required grammar is still too large")
        }
        let result = await streamAnthropic(model: fallbackModel(), context: fallbackContext([
            fallbackTool("lookup", strict: .prefer), fallbackTool("required", strict: .require),
        ]), options: fallbackOptions(client)).result()
        #expect(result.stopReason == .error)
        #expect(result.errorMessage?.contains("Required grammar is still too large") == true)
        let payloads = try await fallbackPayloads(client)
        #expect(payloads.count == 2)
        #expect((payloads.last?["tools"] as? [[String: Any]])?.last?["strict"] as? Bool == true)
    }

    @Test func honorsCancellationBeforeFallback() async throws {
        let signal = CancellationToken()
        let client = StrictFallbackHTTPClient { _ in signal.cancel(); return try fallbackRejection() }
        let result = await streamAnthropic(model: fallbackModel(), context: fallbackContext([fallbackTool("lookup", strict: .prefer)]), options: fallbackOptions(client, signal: signal)).result()
        #expect(result.stopReason == .aborted)
        #expect(await client.bodies.count == 1)
        #expect(result.diagnostics == nil)
    }

    @Test func doesNotRetryStreamErrors() async throws {
        let client = StrictFallbackHTTPClient { _ in
            let body = try JSONSerialization.data(withJSONObject: ["type": "error", "error": ["type": "invalid_request_error", "message": strictGrammarError]])
            return ProviderHTTPResponse(statusCode: 200, body: Data("event: error\ndata: \(String(decoding: body, as: UTF8.self))\n\n".utf8))
        }
        let result = await streamAnthropic(model: fallbackModel(), context: fallbackContext([fallbackTool("lookup", strict: .prefer)]), options: fallbackOptions(client)).result()
        #expect(result.stopReason == .error)
        #expect(await client.bodies.count == 1)
        #expect(result.diagnostics == nil)
    }

    @Test func laterRequestsStartStrict() async throws {
        let client = StrictFallbackHTTPClient { try $0 == 1 ? fallbackRejection() : fallbackSuccess() }
        let context = fallbackContext([fallbackTool("lookup", strict: .prefer)])
        for _ in 0..<2 {
            let result = await streamAnthropic(model: fallbackModel(), context: context, options: fallbackOptions(client)).result()
            #expect(result.stopReason == .stop)
        }
        let payloads = try await fallbackPayloads(client)
        #expect(payloads.count == 3)
        let strict = payloads.map { ($0["tools"] as? [[String: Any]])?.first?["strict"] as? Bool }
        #expect(strict == [true, nil, true])
    }

    @Test func publicToolDeclarationsKeepPreferredStrictness() throws {
        // Swift has no pi-messages gateway API. Its equivalent public declaration must retain prefer.
        let tool = toToolDeclaration(fallbackTool("lookup", strict: .prefer))
        if case .jsonSchema(strict: .prefer) = tool.constrainedSampling {} else { Issue.record("Preferred strictness was lost") }
    }

    @Test(arguments: [DiagnosticErrorCode.string("limit"), .number(400)])
    func diagnosticErrorRoundTrip(_ code: DiagnosticErrorCode) throws {
        var message = AssistantMessage(content: [], api: .anthropicMessages, provider: "anthropic", model: "test",
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
        message.diagnostics = [AssistantMessageDiagnostic(type: "anthropic_strict_tools_fallback", timestamp: 123,
            details: ["reason": AnyCodable("strict_tool_limits_exceeded")],
            error: DiagnosticErrorInfo(name: "APIError", message: strictGrammarError, stack: "test stack", code: code))]
        let data = try JSONSerialization.data(withJSONObject: assistantMessageToJSONObject(message))
        let decoded = assistantMessageFromJSONObject(try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]))
        #expect(decoded.diagnostics == message.diagnostics)
        #expect((assistantMessageToJSONObject(decoded)["diagnostics"] as? [[String: Any]])?.first?["error"] != nil)
        let legacy = AssistantMessageDiagnostic(type: "legacy", details: [:])
        #expect(legacy.error == nil)
    }
}
