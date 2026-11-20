import Foundation
import Testing
@testable import PiSwiftAI

private actor A2ResponseFixture: ProviderHTTPClient {
    let body: Data
    private var requests: [Data] = []

    init(body: Data) { self.body = body }

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        if let data = request.httpBody { requests.append(data) }
        return ProviderHTTPResponse(statusCode: 200, body: body)
    }

    func captured() -> [Data] { requests }
}

private func a2SSE(_ events: [[String: Any]]) throws -> Data {
    Data(try events.map { event in
        "data: " + String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self) + "\n\n"
    }.joined().utf8)
}

private func a2Model(id: String = "gpt-6.2-sol", api: Api = .openAIResponses, compat: OpenAICompat? = nil,
                     thinkingLevelMap: ThinkingLevelMap? = nil) -> Model {
    let codex = api == .openAICodexResponses
    return Model(id: id, name: id, api: api,
        provider: codex ? "openai-codex" : "openai",
        baseUrl: codex ? "https://chatgpt.com/backend-api" : "https://api.openai.com/v1",
        reasoning: true, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 272_000, maxTokens: 128_000,
        compat: compat, thinkingLevelMap: thinkingLevelMap)
}

private func a2Token() throws -> String {
    let data = try JSONSerialization.data(withJSONObject: [
        "https://api.openai.com/auth": ["chatgpt_account_id": "a2-account"]
    ])
    let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "header.\(encoded).signature"
}

private func a2User(_ text: String) -> Message {
    .user(UserMessage(content: .text(text), timestamp: 0))
}

private func a2Terminal(_ transformations: Any? = nil, status: String = "completed",
                        type: String = "response.completed") -> [String: Any] {
    var response: [String: Any] = ["id": "resp_a2", "status": status]
    if let transformations { response["input_transformations"] = transformations }
    if status == "incomplete" { response["incomplete_details"] = ["reason": "max_output_tokens"] }
    return ["type": type, "response": response]
}

private func a2CodexRun(_ messages: [Message], model: Model = a2Model(api: .openAICodexResponses),
                        prompt: String? = nil, effort: ThinkingLevel? = nil,
                        maxTokens: Int? = nil, events: [[String: Any]]? = nil)
async throws -> (AssistantMessage, [String: Any]) {
    let item: [String: Any] = ["type": "message", "id": "msg_a2", "role": "assistant",
        "content": [["type": "output_text", "text": "OK"]]]
    let defaultEvents: [[String: Any]] = [
        ["type": "response.output_item.added", "item": item],
        ["type": "response.output_item.done", "item": item],
        a2Terminal(type: "response.done"),
    ]
    let fixture = A2ResponseFixture(body: try a2SSE(events ?? defaultEvents))
    let context = normalizeContext(Context(systemPrompt: prompt, messages: messages))
    let result = await streamOpenAICodexResponses(model: model, context: context,
        options: OpenAICodexResponsesOptions(maxTokens: maxTokens, apiKey: try a2Token(),
            httpClient: fixture, reasoningEffort: effort, transport: .sse, maxRetries: 0)).result()
    let data = try #require(await fixture.captured().first)
    return (result, try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]))
}

private var a2Prefix: [String: Any] { ["type": "reasoning", "id": "rs_edited",
    "action": "removed", "reason": "prefix_mismatch"] }
private var a2Boundary: [String: Any] { ["type": "reasoning", "id": "rs_old_turn",
    "action": "removed", "reason": "turn_boundary"] }
private var a2Organization: [String: Any] { ["type": "reasoning", "id": "rs_org",
    "action": "removed", "reason": "organization_mismatch"] }

private func a2OpenAIResult(_ transformations: Any? = nil, status: String = "completed") async throws -> AssistantMessage {
    let fixture = A2ResponseFixture(body: try a2SSE([a2Terminal(transformations, status: status,
        type: status == "incomplete" ? "response.incomplete" : "response.completed")]))
    return await streamOpenAIResponses(model: a2Model(), context: normalizeContext(Context(messages: [a2User("Hello")])),
        options: OpenAIResponsesOptions(apiKey: "sk-test", httpClient: fixture, maxRetries: 0)).result()
}

// openai-responses-input-transformations.test.ts:75.
@Test func a2RecordsRemovedReasoningItemsWithTheirReasons() async throws {
    let result = try await a2OpenAIResult([a2Prefix.merging(["ignored": "extra"]) { _, new in new },
        a2Boundary, a2Organization])
    #expect(result.stopReason == .stop)
    let diagnostic = try #require(result.diagnostics?.only)
    #expect(diagnostic.type == "openai_input_transformations")
    #expect(diagnostic.timestamp > 0)
    let rows = try #require(diagnostic.details["transformations"]?.value as? [[String: Any]])
    #expect(rows.count == 2)
    #expect(rows[0] as NSDictionary == a2Prefix as NSDictionary)
    #expect(rows[1] as NSDictionary == a2Organization as NSDictionary)
}

// openai-responses-input-transformations.test.ts:88,95.
@Test(arguments: [("incomplete", "prefix_mismatch"), ("completed", "future_reason")])
func a2RecordsIncompleteAndFutureReasons(_ status: String, _ reason: String) async throws {
    var report = a2Prefix
    report["reason"] = reason
    let result = try await a2OpenAIResult([report], status: status)
    #expect(result.stopReason == (status == "incomplete" ? .length : .stop))
    let rows = try #require(result.diagnostics?.only?.details["transformations"]?.value as? [[String: Any]])
    #expect(rows.first?["reason"] as? String == reason)
}

// openai-responses-input-transformations.test.ts:102.
@Test func a2IgnoresOtherAndMalformedTransformationReports() async throws {
    let reports: [Any?] = [nil, NSNull(), [], [a2Boundary, a2Boundary],
        ["malformed": true], [NSNull(), "rs_text", ["type": "message", "action": "removed", "reason": "prefix_mismatch"]],
        [["type": "reasoning", "action": "changed", "reason": "prefix_mismatch"]]]
    for report in reports {
        let result = try await a2OpenAIResult(report)
        #expect(result.stopReason == .stop)
        #expect(result.diagnostics == nil)
    }
}

// openai-responses-input-transformations.test.ts:120.
@Test func a2CodexResponseDoneRecordsReasoningRemoval() async throws {
    let (result, _) = try await a2CodexRun([a2User("Hello")],
        events: [a2Terminal([a2Prefix, a2Boundary], type: "response.done")])
    #expect(result.stopReason == .stop)
    let rows = try #require(result.diagnostics?.only?.details["transformations"]?.value as? [[String: Any]])
    #expect(rows.count == 1)
    #expect(rows[0] as NSDictionary == a2Prefix as NSDictionary)
}

@Test func a2AzureResponsesRecordsReasoningRemoval() async throws {
    let fixture = A2ResponseFixture(body: try a2SSE([a2Terminal([a2Prefix, a2Boundary])]))
    let result = await streamAzureOpenAIResponses(model: a2Model(api: .azureOpenAIResponses),
        context: normalizeContext(Context(messages: [a2User("Hello")])),
        options: AzureOpenAIResponsesOptions(apiKey: "test", httpClient: fixture,
            azureBaseUrl: "https://example.invalid/v1", maxRetries: 0)).result()
    #expect(result.stopReason == .stop)
    let rows = try #require(result.diagnostics?.only?.details["transformations"]?.value as? [[String: Any]])
    #expect(rows.count == 1)
    #expect(rows[0] as NSDictionary == a2Prefix as NSDictionary)
}

@Test func a2DiagnosticMessageAndSessionFileRoundTrip() async throws {
    let result = try await a2OpenAIResult([a2Prefix])
    let json = messageToJSONObject(.assistant(result))
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("a2-session-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: file) }
    let data = try JSONSerialization.data(withJSONObject: json)
    try (data + Data("\n".utf8)).write(to: file)
    let saved = try Data(contentsOf: file)
    let object = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
    let decoded = try #require(messageFromJSONObject(object))
    guard case .assistant(let restored) = decoded else { Issue.record("Expected assistant"); return }
    #expect(restored.diagnostics == result.diagnostics)
    let old = try #require(messageFromJSONObject(json.filter { $0.key != "diagnostics" }))
    guard case .assistant(let oldAssistant) = old else { Issue.record("Expected assistant"); return }
    #expect(oldAssistant.diagnostics == nil)
}

// openai-reasoning-replay-e2e.test.ts:75. This fixture models the tagged replay sequence without network access.
@Test func a2ReasoningReplayReportsOnlyTheEditedPrefix() async throws {
    let item: [String: Any] = ["type": "reasoning", "id": "rs_1",
        "summary": [["type": "summary_text", "text": "Think"]],
        "encrypted_content": "ciphertext"]
    let firstFixture = A2ResponseFixture(body: try a2SSE([
        ["type": "response.output_item.added", "output_index": 0, "item": item],
        ["type": "response.output_item.done", "output_index": 0, "item": item],
        a2Terminal(),
    ]))
    let first = await streamOpenAIResponses(model: a2Model(),
        context: normalizeContext(Context(messages: [a2User("Original")])),
        options: OpenAIResponsesOptions(apiKey: "sk-test", httpClient: firstFixture, maxRetries: 0)).result()
    #expect(first.stopReason == .stop)
    #expect(first.content.contains { if case .thinking(let thinking) = $0 {
        thinking.thinkingSignature != nil } else { false } })

    let unchangedFixture = A2ResponseFixture(body: try a2SSE([a2Terminal([a2Boundary])]))
    let unchanged = await streamOpenAIResponses(model: a2Model(),
        context: normalizeContext(Context(messages: [a2User("Original"), .assistant(first), a2User("Next")])),
        options: OpenAIResponsesOptions(apiKey: "sk-test", httpClient: unchangedFixture, maxRetries: 0)).result()
    #expect(unchanged.diagnostics == nil)
    let unchangedRequest = try #require(await unchangedFixture.captured().first)
    let unchangedBody = try #require(JSONSerialization.jsonObject(with: unchangedRequest) as? [String: Any])
    let unchangedInput = try #require(unchangedBody["input"] as? [[String: Any]])
    #expect(unchangedInput.contains { $0["type"] as? String == "reasoning" })

    let editedFixture = A2ResponseFixture(body: try a2SSE([a2Terminal([a2Prefix, a2Boundary])]))
    let edited = await streamOpenAIResponses(model: a2Model(),
        context: normalizeContext(Context(messages: [a2User("Edited"), .assistant(first), a2User("Next")])),
        options: OpenAIResponsesOptions(apiKey: "sk-test", httpClient: editedFixture, maxRetries: 0)).result()
    let editedRequest = try #require(await editedFixture.captured().first)
    let editedBody = try #require(JSONSerialization.jsonObject(with: editedRequest) as? [String: Any])
    let editedInput = try #require(editedBody["input"] as? [[String: Any]])
    #expect(editedInput.contains { $0["type"] as? String == "reasoning" })
    let rows = try #require(edited.diagnostics?.only?.details["transformations"]?.value as? [[String: Any]])
    #expect(rows.count == 1)
    #expect(rows[0] as NSDictionary == a2Prefix as NSDictionary)
}

// openai-codex-stream.test.ts:1076.
@Test func a2CodexSystemPromptIsLeadingInputItem() async throws {
    let (_, withPrompt) = try await a2CodexRun([a2User("Say hello")], prompt: "Be terse.")
    let (_, absent) = try await a2CodexRun([a2User("Say hello")])
    #expect(withPrompt["instructions"] == nil)
    #expect(absent["instructions"] == nil)
    let first = try #require(withPrompt["input"] as? [[String: Any]])
    let second = try #require(absent["input"] as? [[String: Any]])
    #expect(first.count == 2)
    #expect(first[0]["role"] as? String == "developer")
    #expect(first[0]["content"] as? String == "Be terse.")
    #expect(first[1] as NSDictionary == second[0] as NSDictionary)
    #expect(second.count == 1)
}

// openai-codex-stream.test.ts:1103,1132,1145.
@Test func a2CodexThinkingChangesUseConfigurationUpdates() async throws {
    let model = a2Model(api: .openAICodexResponses,
        compat: OpenAICompat(supportsMidConvoEffort: true))
    let first = try await a2CodexRun([a2User("Say hello")], model: model, effort: .low)
    let second = try await a2CodexRun([a2User("Say hello"), .assistant(first.0), a2User("Again")],
        model: model, effort: .high)
    #expect(first.0.providerThinkingLevel == "low")
    #expect(second.0.providerThinkingLevel == "high")
    for body in [first.1, second.1] {
        let reasoning = try #require(body["reasoning"] as? [String: String])
        #expect(reasoning == ["effort": "medium", "summary": "auto"])
    }
    let firstInput = try #require(first.1["input"] as? [[String: Any]])
    let secondInput = try #require(second.1["input"] as? [[String: Any]])
    #expect(firstInput.map { $0["type"] as? String ?? $0["role"] as? String } == ["user", "configuration_update"])
    #expect((firstInput.last?["reasoning"] as? [String: String]) == ["effort": "low"])
    #expect(secondInput.map { $0["type"] as? String ?? $0["role"] as? String } ==
        ["user", "configuration_update", "message", "user", "configuration_update"])
    #expect((secondInput[1]["reasoning"] as? [String: String]) == ["effort": "low"])
    #expect((secondInput.last?["reasoning"] as? [String: String]) == ["effort": "high"])
    let off = try await a2CodexRun([a2User("Say hello")], model: model)
    #expect(off.0.providerThinkingLevel == "none")
    #expect((off.1["reasoning"] as? [String: String]) == ["effort": "medium", "summary": "auto"])
    let offInput = try #require(off.1["input"] as? [[String: Any]])
    #expect((offInput.last?["reasoning"] as? [String: String]) == ["effort": "none"])
    let legacy = try await a2CodexRun([a2User("Say hello")], effort: .high)
    #expect(legacy.0.providerThinkingLevel == nil)
    #expect((legacy.1["reasoning"] as? [String: String]) == ["effort": "high", "summary": "auto"])
    #expect((legacy.1["input"] as? [[String: Any]])?.count == 1)
}

// openai-codex-stream.test.ts:1188.
@Test func a2CodexMaxTokensClampAndCompatOptOut() async throws {
    let regular = try await a2CodexRun([a2User("Say hello")], maxTokens: 5000)
    let low = try await a2CodexRun([a2User("Say hello")], maxTokens: 4)
    let disabled = try await a2CodexRun([a2User("Say hello")],
        model: a2Model(api: .openAICodexResponses, compat: OpenAICompat(supportsMaxOutputTokens: false)),
        maxTokens: 5000)
    let zero = try await a2CodexRun([a2User("Say hello")], maxTokens: 0)
    let negative = try await a2CodexRun([a2User("Say hello")], maxTokens: -4)
    #expect(regular.1["max_output_tokens"] as? Int == 5000)
    #expect(low.1["max_output_tokens"] as? Int == 16)
    #expect(disabled.1["max_output_tokens"] == nil)
    #expect(zero.1["max_output_tokens"] == nil)
    #expect(negative.1["max_output_tokens"] as? Int == 16)
}

// max-thinking.test.ts:88–106. Catalog metadata is supplied here until A4 regenerates it.
@Test(arguments: ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-6.1-sol",
                  "gpt-6.1-terra", "gpt-6.2-astra", "gpt-6.2-sol"])
func a2CodexSendsMaxAsConfigurationUpdateForSupportedModels(_ id: String) async throws {
    let model = a2Model(id: id, api: .openAICodexResponses,
        compat: OpenAICompat(supportsMidConvoEffort: true),
        thinkingLevelMap: [.off: "none", .max: "max"])
    let (_, body) = try await a2CodexRun([a2User("Hello")], model: model,
        prompt: "You are a helpful assistant.", effort: .max)
    #expect((body["reasoning"] as? [String: String]) == ["effort": "medium", "summary": "auto"])
    let input = try #require(body["input"] as? [[String: Any]])
    #expect(input.first?["content"] as? String == "You are a helpful assistant.")
    #expect((input.last?["reasoning"] as? [String: String]) == ["effort": "max"])
}

@Test func a2CodexSendsMaxAsRequestEffortWithoutCompat() async throws {
    let model = a2Model(id: "gpt-5.6-sol", api: .openAICodexResponses,
        thinkingLevelMap: [.off: "none", .max: "max"])
    let (_, body) = try await a2CodexRun([a2User("Hello")], model: model, effort: .max)
    #expect((body["reasoning"] as? [String: String]) == ["effort": "max", "summary": "auto"])
    let input = try #require(body["input"] as? [[String: Any]])
    #expect(!input.contains { $0["type"] as? String == "configuration_update" })
}

// openai-codex-stream.test.ts:2423. A clock boundary test avoids a live socket.
@Test func a2CodexRotatesCachedSocketAtFortyFiveMinutes() {
    let started = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(!codexWebSocketShouldRotate(createdAt: started, now: started.addingTimeInterval(44 * 60)))
    #expect(codexWebSocketShouldRotate(createdAt: started, now: started.addingTimeInterval(45 * 60)))
    #expect(codexWebSocketShouldRotate(createdAt: started, now: started.addingTimeInterval(46 * 60)))
}

// openai-codex-stream.test.ts:2442. The leading developer item and old update are part of the exact prefix.
@Test func a2CodexCachedDeltaKeepsSystemAndEffortPrefix() throws {
    let system: [String: Any] = ["role": "developer", "content": "Be terse."]
    let user: [String: Any] = ["role": "user", "content": [["type": "input_text", "text": "One"]]]
    let low = responsesConfigurationUpdateItem("low")
    let high = responsesConfigurationUpdateItem("high")
    let responseItem: [String: Any] = ["type": "message", "role": "assistant",
        "content": [["type": "output_text", "text": "OK"]], "status": "completed"]
    let next: [String: Any] = ["role": "user", "content": [["type": "input_text", "text": "Two"]]]
    let firstBody: [String: Any] = ["model": "gpt-6.2-sol", "store": false,
        "reasoning": ["effort": "medium", "summary": "auto"], "input": [system, user, low]]
    let continuation = CodexWebSocketContinuation(
        lastRequestBody: try JSONSerialization.data(withJSONObject: firstBody),
        lastResponseId: "resp_1",
        lastResponseItems: try JSONSerialization.data(withJSONObject: [responseItem]))
    var nextBody = firstBody
    nextBody["input"] = [system, user, low, responseItem, next, high]
    let delta = try #require(codexCachedDeltaBody(fullBody: nextBody, continuation: continuation))
    #expect(delta["previous_response_id"] as? String == "resp_1")
    let deltaInput = try #require(delta["input"] as? [[String: Any]])
    #expect(deltaInput.count == 2)
    #expect(deltaInput[0] as NSDictionary == next as NSDictionary)
    #expect(deltaInput[1] as NSDictionary == high as NSDictionary)
    nextBody["input"] = [user, low, responseItem, next, high]
    #expect(codexCachedDeltaBody(fullBody: nextBody, continuation: continuation) == nil)
    nextBody["input"] = [system, user, low, responseItem, next, high]
    nextBody["reasoning"] = ["effort": "high", "summary": "auto"]
    #expect(codexCachedDeltaBody(fullBody: nextBody, continuation: continuation) == nil)
}

private actor A2RetryFixture: ProviderHTTPClient {
    private var count = 0
    let first: Data
    let second: Data

    init(first: Data, second: Data) { self.first = first; self.second = second }

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        count += 1
        return ProviderHTTPResponse(statusCode: 200, body: count == 1 ? first : second)
    }

    func attempts() -> Int { count }
}

private actor A2ScriptedWebSocketIO: CodexWebSocketIO {
    private let scripts: [[Data]]
    private var sent: [Data] = []
    private var pending: [ObjectIdentifier: [Data]] = [:]

    init(scripts: [[Data]]) { self.scripts = scripts }

    func send(task: URLSessionWebSocketTask, text: String) async throws {
        let index = sent.count
        sent.append(Data(text.utf8))
        pending[ObjectIdentifier(task)] = index < scripts.count ? scripts[index] : []
    }

    func receive(task: URLSessionWebSocketTask) async throws -> URLSessionWebSocketTask.Message {
        let key = ObjectIdentifier(task)
        guard var queue = pending[key], !queue.isEmpty else { throw CancellationError() }
        let data = queue.removeFirst()
        pending[key] = queue
        return .string(String(decoding: data, as: UTF8.self))
    }

    func sentBodies() -> [Data] { sent }
}

private func a2WebSocketScript(_ events: [[String: Any]]) throws -> [Data] {
    try events.map { try JSONSerialization.data(withJSONObject: $0) }
}

private func a2WebSocketSuccess(_ id: String, text: String = "Recovered") -> [[String: Any]] {
    let item: [String: Any] = ["type": "message", "id": "msg_\(id)", "role": "assistant",
        "content": [["type": "output_text", "text": text]]]
    return [
        ["type": "response.created", "response": ["id": id]],
        ["type": "response.output_item.added", "item": item],
        ["type": "response.output_item.done", "item": item],
        ["type": "response.completed", "response": ["id": id, "status": "completed"]],
    ]
}

// openai-codex-stream.test.ts:2024–2151, all three provider-start cases.
@Suite("Codex WebSocket lifetime v1.6.0", .serialized)
struct A2CodexWebSocketLifetimeTests {
    // openai-codex-stream.test.ts:2909, cached response ID rejection restarts with the full prompt.
    @Test func resendsFullPromptAfterMissingCachedResponse() async throws {
        let missing: [[String: Any]] = [
            ["type": "codex.rate_limits", "rate_limits": ["allowed": true]],
            ["type": "error", "error": ["code": "previous_response_not_found",
                "message": "Previous response with id 'resp_1' not found."]],
        ]
        let io = A2ScriptedWebSocketIO(scripts: try [
            a2WebSocketScript(a2WebSocketSuccess("resp_1", text: "Hello")),
            a2WebSocketScript(missing),
            a2WebSocketScript(a2WebSocketSuccess("resp_2")),
        ])
        let created = LockedState(0)
        let cache = CodexWebSocketCache(connectionFactory: {
            created.withLock { $0 += 1 }
            return URLSession.shared.webSocketTask(with: URL(string: "wss://example.invalid/codex")!)
        }, isReusable: { _ in true })
        let model = a2Model(api: .openAICodexResponses)
        let token = try a2Token()
        let replies = await CodexWebSocketEnvironment.$current.withValue(
            CodexWebSocketEnvironment(cache: cache, io: io)) {
            let first = await streamOpenAICodexResponses(model: model,
                context: normalizeContext(Context(systemPrompt: "You are a helpful assistant.",
                    messages: [a2User("Say hello")])),
                options: OpenAICodexResponsesOptions(apiKey: token, sessionId: "a2-missing",
                    transport: .websocketCached, maxRetries: 0)).result()
            let second = await streamOpenAICodexResponses(model: model,
                context: normalizeContext(Context(systemPrompt: "You are a helpful assistant.",
                    messages: [a2User("Say hello"), .assistant(first), a2User("Now finish")])),
                options: OpenAICodexResponsesOptions(apiKey: token, sessionId: "a2-missing",
                    transport: .websocketCached, maxRetries: 0)).result()
            return [first, second]
        }
        #expect(replies.map(\.stopReason) == [.stop, .stop])
        #expect(created.withLock { $0 } == 2)
        let bodies = try await io.sentBodies().map { data in
            try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(bodies.count == 3)
        #expect(bodies[1]["previous_response_id"] as? String == "resp_1")
        #expect(bodies[2]["previous_response_id"] == nil)
        let delta = try #require(bodies[1]["input"] as? [[String: Any]])
        let full = try #require(bodies[2]["input"] as? [[String: Any]])
        #expect(delta.count == 1)
        #expect(full.count == 4)
        #expect(full[0]["content"] as? String == "You are a helpful assistant.")
        #expect(full.last?["role"] as? String == "user")
        cache.close(sessionId: nil)
    }

    // openai-codex-stream.test.ts:2909, SSE fallback also uses the full request after a lost continuation.
    @Test func sseFallbackKeepsFullPromptAfterMissingCachedResponse() async throws {
        let missing: [[String: Any]] = [
            ["type": "codex.rate_limits", "rate_limits": ["allowed": true]],
            ["type": "error", "error": ["code": "previous_response_not_found",
                "message": "Previous response with id 'resp_1' not found."]],
        ]
        let io = A2ScriptedWebSocketIO(scripts: try [
            a2WebSocketScript(a2WebSocketSuccess("resp_1", text: "Hello")),
            a2WebSocketScript(missing),
            [],
        ])
        let sse = A2ResponseFixture(body: try a2SSE(a2WebSocketSuccess("resp_2", text: "Hello")))
        let cache = CodexWebSocketCache(connectionFactory: {
            URLSession.shared.webSocketTask(with: URL(string: "wss://example.invalid/codex")!)
        }, isReusable: { _ in true })
        let model = a2Model(api: .openAICodexResponses)
        let token = try a2Token()
        let replies = await CodexWebSocketEnvironment.$current.withValue(
            CodexWebSocketEnvironment(cache: cache, io: io, sseClient: sse)) {
            let first = await streamOpenAICodexResponses(model: model,
                context: normalizeContext(Context(systemPrompt: "You are a helpful assistant.",
                    messages: [a2User("Say hello")])),
                options: OpenAICodexResponsesOptions(apiKey: token, sessionId: "a2-sse-fallback",
                    transport: .websocketCached, maxRetries: 0)).result()
            let second = await streamOpenAICodexResponses(model: model,
                context: normalizeContext(Context(systemPrompt: "You are a helpful assistant.",
                    messages: [a2User("Say hello"), .assistant(first), a2User("Now finish")])),
                options: OpenAICodexResponsesOptions(apiKey: token, sessionId: "a2-sse-fallback",
                    transport: .websocketCached, maxRetries: 0)).result()
            return [first, second]
        }
        #expect(replies.map(\.stopReason) == [.stop, .stop])
        let sent = try await io.sentBodies().map { data in
            try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(sent.count == 3)
        #expect(sent[1]["previous_response_id"] as? String == "resp_1")
        #expect(sent[2]["previous_response_id"] == nil)
        #expect((sent[2]["input"] as? [[String: Any]])?.count == 4)
        let sseRequest = try #require(await sse.captured().first)
        let sseBody = try #require(JSONSerialization.jsonObject(with: sseRequest) as? [String: Any])
        #expect(sseBody["previous_response_id"] == nil)
        #expect((sseBody["input"] as? [[String: Any]])?.count == 4)
        cache.close(sessionId: nil)
    }

    // openai-codex-stream.test.ts:2687, retained prompt and a custom tool result in a cached turn.
    @Test func keepsLeadingPromptBeforeCachedCustomToolDelta() async throws {
        let tool = AITool(name: "sample_tool", description: "Sample", parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable(["payload": ["type": "string"]]),
            "required": AnyCodable(["payload"]),
        ], constrainedSampling: .grammar(variants: [.openAILark: "start: /[a-z]+/"]))
        let call: [String: Any] = ["type": "custom_tool_call", "id": "ctc_1", "call_id": "call_1",
            "name": "sample_tool", "input": "abc"]
        let io = A2ScriptedWebSocketIO(scripts: try [
            a2WebSocketScript([
                ["type": "response.created", "response": ["id": "resp_1"]],
                ["type": "response.output_item.added", "item": call],
                ["type": "response.output_item.done", "item": call],
                ["type": "response.completed", "response": ["id": "resp_1", "status": "completed"]],
            ]),
            a2WebSocketScript(a2WebSocketSuccess("resp_2")),
        ])
        let cache = CodexWebSocketCache(connectionFactory: {
            URLSession.shared.webSocketTask(with: URL(string: "wss://example.invalid/codex")!)
        }, isReusable: { _ in true })
        let model = a2Model(api: .openAICodexResponses,
            compat: OpenAICompat(supportsOpenAIGrammarTools: true))
        let token = try a2Token()
        let replies = await CodexWebSocketEnvironment.$current.withValue(
            CodexWebSocketEnvironment(cache: cache, io: io)) {
            let first = await streamOpenAICodexResponses(model: model,
                context: normalizeContext(Context(systemPrompt: "You are a helpful assistant.",
                    messages: [a2User("Use the tool")], tools: [tool])),
                options: OpenAICodexResponsesOptions(apiKey: token, sessionId: "a2-custom",
                    transport: .websocketCached, maxRetries: 0)).result()
            let toolResult = Message.toolResult(ToolResultMessage(toolCallId: "call_1|ctc_1",
                toolName: "sample_tool", content: [.text(TextContent(text: "real result"))],
                isError: false))
            let second = await streamOpenAICodexResponses(model: model,
                context: normalizeContext(Context(systemPrompt: "You are a helpful assistant.",
                    messages: [a2User("Use the tool"), .assistant(first), toolResult, a2User("Now finish")],
                    tools: [tool])),
                options: OpenAICodexResponsesOptions(apiKey: token, sessionId: "a2-custom",
                    transport: .websocketCached, maxRetries: 0)).result()
            return [first, second]
        }
        #expect(replies.map(\.stopReason) == [.toolUse, .stop])
        let bodies = try await io.sentBodies().map { data in
            try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(bodies.count == 2)
        let firstInput = try #require(bodies[0]["input"] as? [[String: Any]])
        #expect(firstInput.count == 2)
        #expect(firstInput[0]["role"] as? String == "developer")
        #expect(firstInput[0]["content"] as? String == "You are a helpful assistant.")
        #expect(bodies[1]["previous_response_id"] as? String == "resp_1")
        let delta = try #require(bodies[1]["input"] as? [[String: Any]])
        #expect(delta.count == 2)
        #expect(delta[0]["type"] as? String == "custom_tool_call_output")
        #expect(delta[0]["output"] as? String == "real result")
        #expect(delta[1]["role"] as? String == "user")
        cache.close(sessionId: nil)
    }

    @Test func retriesConnectionLimitBeforeFirstEvent() async throws {
        let limit: [String: Any] = ["type": "error", "error": [
            "code": "websocket_connection_limit_reached", "message": "connection limit reached"]]
        let io = A2ScriptedWebSocketIO(scripts: try [
            a2WebSocketScript([limit]), a2WebSocketScript(a2WebSocketSuccess("resp_2"))
        ])
        let created = LockedState(0)
        let cache = CodexWebSocketCache(connectionFactory: {
            created.withLock { $0 += 1 }
            return URLSession.shared.webSocketTask(with: URL(string: "wss://example.invalid/codex")!)
        }, isReusable: { _ in true })
        let model = a2Model(api: .openAICodexResponses)
        let token = try a2Token()
        let result = await CodexWebSocketEnvironment.$current.withValue(
            CodexWebSocketEnvironment(cache: cache, io: io)) {
            await streamOpenAICodexResponses(model: model,
                context: normalizeContext(Context(messages: [a2User("Hello")])),
                options: OpenAICodexResponsesOptions(apiKey: token, sessionId: "a2-first-error",
                    transport: .websocketCached, maxRetries: 0)).result()
        }
        #expect(result.stopReason == .stop)
        #expect(created.withLock { $0 } == 2)
        let bodies = try await io.sentBodies().map { data in
            try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(bodies.count == 2)
        #expect(bodies[1]["previous_response_id"] == nil)
        cache.close(sessionId: nil)
    }

    // openai-codex-stream.test.ts:2423. The cached task is retired before its 60-minute server limit.
    @Test func rotatesCachedConnectionAfterFortySixMinutes() async throws {
        let io = A2ScriptedWebSocketIO(scripts: try [
            a2WebSocketScript(a2WebSocketSuccess("resp_1", text: "One")),
            a2WebSocketScript(a2WebSocketSuccess("resp_2", text: "Two")),
        ])
        let clock = LockedState(Date(timeIntervalSince1970: 1_700_000_000))
        let created = LockedState(0)
        let cache = CodexWebSocketCache(now: { clock.withLock { $0 } }, connectionFactory: {
            created.withLock { $0 += 1 }
            return URLSession.shared.webSocketTask(with: URL(string: "wss://example.invalid/codex")!)
        }, isReusable: { _ in true })
        let environment = CodexWebSocketEnvironment(cache: cache, io: io)
        let model = a2Model(api: .openAICodexResponses)
        let token = try a2Token()
        let replies = await CodexWebSocketEnvironment.$current.withValue(environment) {
            let first = await streamOpenAICodexResponses(model: model,
                context: normalizeContext(Context(messages: [a2User("One")])),
                options: OpenAICodexResponsesOptions(apiKey: token, sessionId: "a2-age",
                    transport: .websocketCached, maxRetries: 0)).result()
            clock.withLock { $0 = $0.addingTimeInterval(46 * 60) }
            let second = await streamOpenAICodexResponses(model: model,
                context: normalizeContext(Context(messages: [a2User("One"), .assistant(first), a2User("Two")])),
                options: OpenAICodexResponsesOptions(apiKey: token, sessionId: "a2-age",
                    transport: .websocketCached, maxRetries: 0)).result()
            return [first, second]
        }
        #expect(replies.map(\.stopReason) == [.stop, .stop])
        #expect(created.withLock { $0 } == 2)
        let bodies = try await io.sentBodies().map { data in
            try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(bodies.count == 2)
        #expect(bodies[1]["previous_response_id"] == nil)
        cache.close(sessionId: nil)
    }

    @Test(arguments: ["response metadata", "rate-limit metadata", "partial thinking"])
    func retriesConnectionLimitOnFreshSocket(_ scenario: String) async throws {
        var failedEvents: [[String: Any]] = []
        switch scenario {
        case "response metadata":
            failedEvents = [["type": "response.created", "response": ["id": "resp_expired"]]]
        case "rate-limit metadata":
            failedEvents = [["type": "codex.rate_limits", "rate_limits": ["allowed": true]]]
        default:
            failedEvents = [
                ["type": "response.created", "response": ["id": "resp_expired"]],
                ["type": "response.output_item.added", "item": ["type": "reasoning", "id": "rs_1"]],
                ["type": "response.reasoning_summary_text.delta", "delta": "unfinished thinking"],
            ]
        }
        failedEvents.append(["type": "error", "error": [
            "code": "websocket_connection_limit_reached",
            "message": scenario == "rate-limit metadata" ? "session expired"
                : "Responses websocket connection limit reached (60 minutes). Create a new websocket connection to continue."]])
        let io = A2ScriptedWebSocketIO(scripts: try [
            a2WebSocketScript(failedEvents), a2WebSocketScript(a2WebSocketSuccess("resp_2"))
        ])
        let created = LockedState<[URLSessionWebSocketTask]>([])
        let cache = CodexWebSocketCache(connectionFactory: {
            let task = URLSession.shared.webSocketTask(with: URL(string: "wss://example.invalid/codex")!)
            created.withLock { $0.append(task) }
            return task
        }, isReusable: { _ in true })
        let environment = CodexWebSocketEnvironment(cache: cache, io: io)
        let attempts = LockedState<[AssistantMessage]>([])
        let model = a2Model(api: .openAICodexResponses)
        let token = try a2Token()
        let result = await CodexWebSocketEnvironment.$current.withValue(environment) {
            await retryAssistantCall(produce: {
                let reply = await streamOpenAICodexResponses(model: model,
                    context: normalizeContext(Context(messages: [a2User("Hello")])),
                    options: OpenAICodexResponsesOptions(apiKey: token,
                        sessionId: "a2-limit-\(scenario)", transport: .websocketCached,
                        maxRetries: 0)).result()
                attempts.withLock { $0.append(reply) }
                return reply
            }, policy: RetryPolicy(enabled: true, maxRetries: 1, baseDelayMs: 0))
        }
        #expect(result.stopReason == .stop)
        #expect(result.content.contains { if case .text(let text) = $0 {
            text.text == "Recovered" } else { false } })
        let replies = attempts.withLock { $0 }
        #expect(replies.count == 2)
        #expect(replies[0].stopReason == .error)
        #expect(isRetryableAssistantError(replies[0]))
        if scenario == "partial thinking" {
            #expect(replies[0].content.contains { if case .thinking(let thinking) = $0 {
                thinking.thinking == "unfinished thinking" } else { false } })
        }
        #expect(created.withLock { $0.count } == 2)
        let sent = try await io.sentBodies().map { data in
            try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(sent.count == 2)
        #expect(sent[0]["previous_response_id"] == nil)
        #expect(sent[1]["previous_response_id"] == nil)
        cache.close(sessionId: nil)
    }

    // openai-codex-stream.test.ts:2442, real provider cached delta path with a fixed effort.
    @Test func sendsCachedEffortDeltasWithLeadingPrompt() async throws {
        let io = A2ScriptedWebSocketIO(scripts: try [
            a2WebSocketScript(a2WebSocketSuccess("resp_1", text: "One")),
            a2WebSocketScript(a2WebSocketSuccess("resp_2", text: "Two")),
            a2WebSocketScript(a2WebSocketSuccess("resp_3", text: "Three")),
        ])
        let created = LockedState(0)
        let cache = CodexWebSocketCache(connectionFactory: {
            created.withLock { $0 += 1 }
            return URLSession.shared.webSocketTask(with: URL(string: "wss://example.invalid/codex")!)
        }, isReusable: { _ in true })
        let environment = CodexWebSocketEnvironment(cache: cache, io: io)
        let model = a2Model(api: .openAICodexResponses,
            compat: OpenAICompat(supportsMidConvoEffort: true))
        let token = try a2Token()
        let snapshots = LockedState<[String]>([])
        let sent = await CodexWebSocketEnvironment.$current.withValue(environment) {
            var messages: [Message] = []
            var replies: [AssistantMessage] = []
            for (index, effort) in [ThinkingLevel.low, .high, .high].enumerated() {
                messages.append(a2User("Turn \(index + 1)"))
                let reply = await streamOpenAICodexResponses(model: model,
                    context: normalizeContext(Context(systemPrompt: "Be terse.", messages: messages)),
                    options: OpenAICodexResponsesOptions(apiKey: token,
                        reasoningEffort: effort, sessionId: "a2-effort",
                        transport: .websocketCached,
                        onPayload: { snapshot in
                            snapshots.withLock { $0.append(snapshot.json) }
                            return nil
                        }, maxRetries: 0)).result()
                replies.append(reply)
                messages.append(.assistant(reply))
            }
            return replies
        }
        #expect(sent.map(\.stopReason) == [.stop, .stop, .stop])
        #expect(sent.map(\.providerThinkingLevel) == ["low", "high", "high"])
        #expect(created.withLock { $0 } == 1)
        let bodies = try await io.sentBodies().map { data in
            try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(bodies.count == 3)
        let snapshotInputs = try snapshots.withLock { $0 }.map { json -> Int in
            let body = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            return (body["input"] as? [[String: Any]])?.count ?? -1
        }
        #expect(snapshotInputs == [3, 6, 9])
        #expect(bodies[0]["previous_response_id"] == nil)
        #expect(bodies[1]["previous_response_id"] as? String == "resp_1")
        #expect(bodies[2]["previous_response_id"] as? String == "resp_2")
        for body in bodies {
            #expect((body["reasoning"] as? [String: String]) == ["effort": "medium", "summary": "auto"])
        }
        let first = try #require(bodies[0]["input"] as? [[String: Any]])
        #expect(first.first?["role"] as? String == "developer")
        #expect(first.first?["content"] as? String == "Be terse.")
        #expect(first.last?["type"] as? String == "configuration_update")
        let second = try #require(bodies[1]["input"] as? [[String: Any]])
        let third = try #require(bodies[2]["input"] as? [[String: Any]])
        #expect(second.count == 2)
        #expect(third.count == 2)
        #expect((second.last?["reasoning"] as? [String: String]) == ["effort": "high"])
        #expect((third.last?["reasoning"] as? [String: String]) == ["effort": "high"])
        cache.close(sessionId: nil)
    }
}

// openai-codex-stream.test.ts:2024–2151: preserve a partial failed reply and retry the provider error.
@Test func a2CodexLifetimeErrorAfterPartialThinkingIsRetryable() async throws {
    let failed = try a2SSE([
        ["type": "response.created", "response": ["id": "resp_expired"]],
        ["type": "response.output_item.added", "item": ["type": "reasoning", "id": "rs_1"]],
        ["type": "response.reasoning_summary_text.delta", "delta": "unfinished thinking"],
        ["type": "error", "error": ["code": "websocket_connection_limit_reached",
            "message": "Responses websocket connection limit reached (60 minutes). Create a new websocket connection to continue."]],
    ])
    let item: [String: Any] = ["type": "message", "id": "msg_2", "role": "assistant",
        "content": [["type": "output_text", "text": "Recovered"]]]
    let succeeded = try a2SSE([
        ["type": "response.output_item.added", "item": item],
        ["type": "response.output_item.done", "item": item],
        a2Terminal(type: "response.done"),
    ])
    let fixture = A2RetryFixture(first: failed, second: succeeded)
    let attempts = LockedState<[AssistantMessage]>([])
    let model = a2Model(api: .openAICodexResponses)
    let token = try a2Token()
    let result = await retryAssistantCall(produce: {
        let message = await streamOpenAICodexResponses(model: model,
            context: normalizeContext(Context(messages: [a2User("Hello")])),
            options: OpenAICodexResponsesOptions(apiKey: token, httpClient: fixture,
                transport: .sse, maxRetries: 0)).result()
        attempts.withLock { $0.append(message) }
        return message
    }, policy: RetryPolicy(enabled: true, maxRetries: 1, baseDelayMs: 0))
    #expect(result.stopReason == .stop)
    #expect(result.content.contains { if case .text(let text) = $0 { text.text == "Recovered" } else { false } })
    #expect(await fixture.attempts() == 2)
    let replies = attempts.withLock { $0 }
    #expect(replies.count == 2)
    #expect(replies[0].stopReason == .error)
    #expect(replies[0].responseId == "resp_expired")
    #expect(replies[0].content.contains { if case .thinking(let content) = $0 {
        content.thinking == "unfinished thinking" } else { false } })
    #expect(isRetryableAssistantError(replies[0]))
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
