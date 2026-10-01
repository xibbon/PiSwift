import Foundation
import Testing
@testable import PiSwiftAI

private struct A3ResponsesClient: ProviderHTTPClient {
    let body: Data

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        ProviderHTTPResponse(statusCode: 200, body: body)
    }
}

private func a3ResponsesModel(id: String = "gpt-5.5", api: Api = .openAIResponses) -> Model {
    Model(
        id: id, name: id, api: api, provider: "openai", baseUrl: "https://example.test/v1",
        reasoning: true, input: [.text], cost: ModelCost(input: 10, output: 20, cacheRead: 2, cacheWrite: 3),
        contextWindow: 128_000, maxTokens: 4_096
    )
}

private func a3ResponsesSSE(_ events: [[String: Any]]) throws -> Data {
    let frames = try events.map { event in
        "data: " + String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self) + "\n\n"
    }.joined()
    return Data(frames.utf8)
}

// Port of openai-responses-terminal-event.test.ts: incomplete tool calls are never runnable.
@Test(.timeLimit(.minutes(1))) func a3ResponsesRejectsToolCallWithoutOutputItemDone() async throws {
    let events: [[String: Any]] = [
        ["type": "response.output_item.added", "output_index": 0,
         "item": ["type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "bash", "arguments": ""]],
        ["type": "response.function_call_arguments.delta", "output_index": 0,
         "delta": #"{"command":"rm -rf /tmp/build"#],
        ["type": "response.completed", "response": ["id": "resp_unfinished", "status": "completed"]],
    ]
    let result = await streamOpenAIResponses(
        model: a3ResponsesModel(), context: normalizeContext(Context(messages: [])),
        options: OpenAIResponsesOptions(apiKey: "test", httpClient: A3ResponsesClient(body: try a3ResponsesSSE(events)))
    ).result()
    #expect(result.stopReason == .error)
    #expect(result.errorMessage?.contains("OpenAI Responses stream completed with an unfinished tool call: bash (call_1|fc_1)") == true)
}

// Port of #9974's parallel tool calls without output_index case.
@Test(.timeLimit(.minutes(1))) func a3ResponsesRejectsParallelCallsWithoutOutputIndex() async throws {
    let call: (String) -> [String: Any] = { suffix in
        ["type": "function_call", "id": "fc_\(suffix)", "call_id": "call_\(suffix)", "name": "bash", "arguments": ""]
    }
    let events: [[String: Any]] = [
        ["type": "response.output_item.added", "item": call("a")],
        ["type": "response.function_call_arguments.delta", "item_id": "fc_a", "delta": #"{"command":"echo a"}"#],
        ["type": "response.output_item.added", "item": call("b")],
        ["type": "response.function_call_arguments.delta", "item_id": "fc_b", "delta": #"{"command":"echo b"}"#],
        ["type": "response.output_item.done", "item": call("a")],
        ["type": "response.output_item.done", "item": call("b")],
        ["type": "response.completed", "response": ["id": "resp_parallel", "status": "completed"]],
    ]
    let result = await streamOpenAIResponses(
        model: a3ResponsesModel(), context: normalizeContext(Context(messages: [])),
        options: OpenAIResponsesOptions(apiKey: "test", httpClient: A3ResponsesClient(body: try a3ResponsesSSE(events)))
    ).result()
    #expect(result.stopReason == .error)
    #expect(result.errorMessage?.contains("OpenAI Responses stream completed with an unfinished tool call: bash (call_a|fc_a)") == true)
}

// Port of #10034: actual response tier wins over the requested tier, including fast.
@Test(.timeLimit(.minutes(1))) func a3ResponsesUsesActualFastTierForPricing() async throws {
    let events: [[String: Any]] = [[
        "type": "response.completed",
        "response": ["id": "resp_fast", "status": "completed", "service_tier": "fast",
                     "usage": ["input_tokens": 100, "output_tokens": 20, "total_tokens": 120,
                               "input_tokens_details": ["cached_tokens": 0],
                               "output_tokens_details": ["reasoning_tokens": 0]]],
    ]]
    let result = await streamOpenAIResponses(
        model: a3ResponsesModel(), context: normalizeContext(Context(messages: [])),
        options: OpenAIResponsesOptions(apiKey: "test", httpClient: A3ResponsesClient(body: try a3ResponsesSSE(events)), serviceTier: .flex)
    ).result()
    #expect(result.stopReason == .stop)
    #expect(result.usage.cost.input == 0.0025)
    #expect(result.usage.cost.output == 0.001)
}

@Test func a3ResponsesPriorityRateUsesExactGPT55ID() {
    var exact = Usage(input: 100, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 100)
    var variant = exact
    let exactModel = a3ResponsesModel(id: "gpt-5.5")
    let variantModel = a3ResponsesModel(id: "gpt-5.5-preview")
    calculateCost(model: exactModel, usage: &exact)
    calculateCost(model: variantModel, usage: &variant)
    applyServiceTierPricing(&exact, serviceTier: .priority, model: exactModel)
    applyServiceTierPricing(&variant, serviceTier: .priority, model: variantModel)
    #expect(exact.cost.input == 0.0025)
    #expect(variant.cost.input == 0.002)
}

@Test(.timeLimit(.minutes(1))) func a3ResponsesSendsFastTierOnWire() async throws {
    let captured = LockedState<String?>(nil)
    let events: [[String: Any]] = [[
        "type": "response.completed", "response": ["status": "completed", "service_tier": "fast"]
    ]]
    let result = await streamOpenAIResponses(
        model: a3ResponsesModel(), context: normalizeContext(Context(messages: [])),
        options: OpenAIResponsesOptions(
            apiKey: "test", httpClient: A3ResponsesClient(body: try a3ResponsesSSE(events)),
            serviceTier: .fast, onPayload: { payload in captured.withLock { $0 = payload.json } }
        )
    ).result()
    #expect(result.stopReason == .stop)
    let json = try #require(captured.withLock { $0 })
    let payload = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(payload["service_tier"] as? String == "fast")
}

@Test(.timeLimit(.minutes(1))) func a3AzureResponsesRejectsUnfinishedToolCall() async throws {
    let events: [[String: Any]] = [
        ["type": "response.output_item.added", "output_index": 0,
         "item": ["type": "function_call", "id": "fc_azure", "call_id": "call_azure", "name": "bash", "arguments": ""]],
        ["type": "response.completed", "response": ["status": "completed"]],
    ]
    let model = a3ResponsesModel(api: .azureOpenAIResponses)
    let result = await streamAzureOpenAIResponses(
        model: model, context: normalizeContext(Context(messages: [])),
        options: AzureOpenAIResponsesOptions(
            apiKey: "test", httpClient: A3ResponsesClient(body: try a3ResponsesSSE(events)),
            azureBaseUrl: "https://example.test/v1"
        )
    ).result()
    #expect(result.stopReason == .error)
    #expect(result.errorMessage?.contains("OpenAI Responses stream completed with an unfinished tool call: bash (call_azure|fc_azure)") == true)
}

@Test(.timeLimit(.minutes(1))) func a3CodexResponsesRejectsUnfinishedToolCall() async throws {
    let events: [[String: Any]] = [
        ["type": "response.output_item.added",
         "item": ["type": "function_call", "id": "fc_codex", "call_id": "call_codex", "name": "bash", "arguments": ""]],
        ["type": "response.completed", "response": ["status": "completed"]],
    ]
    let payload = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"acc_test"}}"#.utf8).base64EncodedString()
    let model = Model(
        id: "gpt-5.5", name: "gpt-5.5", api: .openAICodexResponses, provider: "openai-codex",
        baseUrl: "https://example.test/backend-api", reasoning: true, input: [.text],
        cost: ModelCost(input: 10, output: 20, cacheRead: 2, cacheWrite: 3), contextWindow: 128_000, maxTokens: 4_096
    )
    let result = await streamOpenAICodexResponses(
        model: model, context: normalizeContext(Context(messages: [])),
        options: OpenAICodexResponsesOptions(
            apiKey: "e30.\(payload).sig", httpClient: A3ResponsesClient(body: try a3ResponsesSSE(events)),
            transport: .sse
        )
    ).result()
    #expect(result.stopReason == .error)
    #expect(result.errorMessage?.contains("OpenAI Responses stream completed with an unfinished tool call: bash (call_codex|fc_codex)") == true)
}

@Test(.timeLimit(.minutes(1))) func a3CodexUsesReportedTierAndHonorsDefaultEcho() async throws {
    let payload = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"acc_test"}}"#.utf8).base64EncodedString()
    let model = Model(
        id: "gpt-5.5", name: "gpt-5.5", api: .openAICodexResponses, provider: "openai-codex",
        baseUrl: "https://example.test/backend-api", reasoning: true, input: [.text],
        cost: ModelCost(input: 10, output: 20, cacheRead: 2, cacheWrite: 3), contextWindow: 128_000, maxTokens: 4_096
    )
    for (reported, expected) in [("priority", 0.0025), ("default", 0.0005)] {
        let events: [[String: Any]] = [[
            "type": "response.completed",
            "response": ["status": "completed", "service_tier": reported,
                         "usage": ["input_tokens": 100, "output_tokens": 0, "total_tokens": 100,
                                   "input_tokens_details": ["cached_tokens": 0]]],
        ]]
        let result = await streamOpenAICodexResponses(
            model: model, context: normalizeContext(Context(messages: [])),
            options: OpenAICodexResponsesOptions(
                apiKey: "e30.\(payload).sig", httpClient: A3ResponsesClient(body: try a3ResponsesSSE(events)),
                transport: .sse, serviceTier: .flex
            )
        ).result()
        #expect(result.stopReason == .stop)
        #expect(result.usage.cost.input == expected)
    }
}
