import Foundation
import Synchronization
import Testing
@testable import PiSwiftAI

private actor R1CaptureClient: ProviderHTTPClient {
    private var data: Data?
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        data = request.httpBody
        return ProviderHTTPResponse(statusCode: 400, body: Data("captured".utf8))
    }
    func body() -> Data? { data }
}
private func r1Tool(_ name: String, description: String? = nil) -> AITool {
    AITool(name: name, description: description ?? "\(name) tool",
           parameters: ["type": AnyCodable("object"), "properties": AnyCodable([String: Any]())])
}
private func r1System(_ text: String = "", added: [AITool]? = nil, removed: [String] = []) -> Message {
    .system(SystemMessage(content: .text(text), toolsAdded: added,
                          toolsRemoved: removed.isEmpty ? nil : removed.map { ToolReference(name: $0) }))
}
private func r1User(_ text: String) -> Message { .user(UserMessage(content: .text(text))) }
private let r1Changes = OpenAICompat(supportsMidConvoSystemMessages: true, supportsAdditionalTools: true)
private let r1Incremental = "This is an incremental tools update. Previously declared tools remain available unless explicitly marked unavailable. A tool declared again here is available again, and its latest definition replaces the earlier one."
private let r1Removal = "The following tools are no longer available. Do not call them:\n- drop_tool"
private func r1Model(_ api: Api, compat: OpenAICompat) -> Model {
    Model(id: "r1-test", name: "R1", api: api, provider: api == .azureOpenAIResponses ? "azure" : "openai",
          baseUrl: "https://example.invalid/v1", reasoning: true, input: [.text],
          cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
          contextWindow: 100_000, maxTokens: 1000, compat: compat)
}
private func r1JSON(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}
private func r1Capture(_ api: Api = .openAIResponses, compat: OpenAICompat = r1Changes,
                       messages: [Message], choice: OpenAIToolChoice? = nil) async throws -> [String: Any] {
    let client = R1CaptureClient()
    let snapshot = Mutex<String?>(nil)
    let callback: PayloadHandler = { value in snapshot.withLock { $0 = value.json }; return nil }
    let context = normalizeContext(Context(messages: messages))
    let model = r1Model(api, compat: compat)
    switch api {
    case .openAIResponses:
        _ = await streamOpenAIResponses(model: model, context: context,
            options: OpenAIResponsesOptions(apiKey: "test", httpClient: client, cacheRetention: .short,
                onPayload: callback, maxRetries: 0, toolChoice: choice)).result()
    case .azureOpenAIResponses:
        _ = await streamAzureOpenAIResponses(model: model, context: context,
            options: AzureOpenAIResponsesOptions(apiKey: "test", httpClient: client,
                onPayload: callback, maxRetries: 0, toolChoice: choice)).result()
    case .openAICodexResponses:
        let payload = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"r1"}}"#.utf8)
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
        _ = await streamOpenAICodexResponses(model: model, context: context,
            options: OpenAICodexResponsesOptions(apiKey: "a.\(payload).z", httpClient: client,
                cacheRetention: .short, onPayload: callback, maxRetries: 0, toolChoice: choice)).result()
    case .openAICompletions:
        _ = await streamOpenAICompletions(model: model, context: context,
            options: OpenAICompletionsOptions(apiKey: "test", httpClient: client, toolChoice: choice, cacheRetention: .short,
                onPayload: callback, maxRetries: 0)).result()
    default:
        Issue.record("Unexpected R1 API")
    }
    let body = try #require(await client.body())
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let seen = try #require(snapshot.withLock { $0 })
    #expect(try r1JSON(JSONSerialization.jsonObject(with: Data(seen.utf8))) == r1JSON(object))
    return object
}
private func r1Input(_ payload: [String: Any], api: Api = .openAIResponses) throws -> [[String: Any]] {
    try #require(payload[api == .openAICompletions ? "messages" : "input"] as? [[String: Any]])
}
private func r1Batches(_ input: [[String: Any]]) -> [[String]] {
    input.filter { $0["type"] as? String == "additional_tools" }.map {
        ($0["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }
}
private func r1History(_ api: Api, compat: OpenAICompat) async throws -> [[String: Any]] {
    var messages = [r1System("base prompt", added: [r1Tool("base_tool"), r1Tool("drop_tool")])]
    let steps = [
        [r1User("first")],
        [r1System(removed: ["drop_tool"]), r1User("after removal")],
        [r1System(added: [r1Tool("late_tool")]), r1User("after first load")],
        [r1System(added: [r1Tool("later_tool")]), r1User("after second load")],
    ]
    var result: [[String: Any]] = []
    for step in steps {
        messages += step
        result.append(try await r1Capture(api, compat: compat, messages: messages))
    }
    return result
}
private func r1ExpectPrefixes(_ payloads: [[String: Any]], api: Api) throws {
    for index in 1..<payloads.count {
        let previous = try r1Input(payloads[index - 1], api: api)
        let current = try r1Input(payloads[index], api: api)
        #expect(try r1JSON(Array(current.prefix(previous.count))) == r1JSON(previous))
    }
}

// Upstream transcript-tool-changes.test.ts:290,349 and openai-responses-compat.test.ts:152.
@Test(.timeLimit(.minutes(1)), arguments: [Api.openAIResponses, .azureOpenAIResponses, .openAICodexResponses])
func r1DeclaresEveryResponsesBatchAndPreservesRequiredChoice(_ api: Api) async throws {
    let body = try await r1Capture(api, messages: [
        r1System("base prompt", added: [r1Tool("base_tool")]), r1User("before"),
        r1System("updated guidance", added: [r1Tool("late_tool")], removed: ["base_tool"])
    ], choice: .required)
    #expect(body["tools"] == nil)
    #expect(body["tool_choice"] as? String == "required")
    let input = try r1Input(body)
    #expect(r1Batches(input) == [["base_tool"], ["late_tool"]])
    #expect(input.first?["type"] as? String == "additional_tools")
    #expect(input.first?["role"] as? String == "developer")
    let noticeIndex = try #require(input.firstIndex { $0["content"] as? String == r1Incremental })
    #expect(input[noticeIndex + 1]["type"] as? String == "additional_tools")
    #expect(input.last?["content"] as? String == "updated guidance\n\nThe following tools are no longer available. Do not call them:\n- base_tool")
    if api == .openAICodexResponses {
        #expect(body["instructions"] as? String == "base prompt")
        #expect(!input.contains { $0["content"] as? String == "base prompt" })
    } else {
        #expect(input[1]["content"] as? String == "base prompt")
    }
}

// Upstream transcript-tool-changes.test.ts:361.
@Test(.timeLimit(.minutes(1))) func r1RedefinitionHasNoRemovalNotice() async throws {
    let body = try await r1Capture(messages: [
        r1System("base prompt", added: [r1Tool("base_tool")]), r1User("before"),
        r1System(added: [r1Tool("base_tool", description: "changed")], removed: ["base_tool"])
    ])
    let input = try r1Input(body)
    #expect(body["tools"] == nil)
    #expect(input.count == 5)
    #expect(input[3]["content"] as? String == r1Incremental)
    let replacement = try #require((input[4]["tools"] as? [[String: Any]])?.first)
    #expect(replacement["name"] as? String == "base_tool")
    #expect(replacement["description"] as? String == "changed")
}

// Upstream transcript-tool-changes.test.ts:388,409,425; compare the whole prior input.
@Test(.timeLimit(.minutes(1)), arguments: [Api.openAIResponses, .azureOpenAIResponses, .openAICodexResponses])
func r1ResponsesPrefixSurvivesRemovalAndLoads(_ api: Api) async throws {
    let payloads = try await r1History(api, compat: r1Changes)
    for body in payloads { #expect(body["tools"] == nil) }
    try r1ExpectPrefixes(payloads, api: api)
    let input = try r1Input(try #require(payloads.last))
    #expect(r1Batches(input) == [["base_tool", "drop_tool"], ["late_tool"], ["later_tool"]])
    #expect(input.contains { $0["content"] as? String == r1Removal })
    #expect(input.compactMap { $0["content"] as? String }.filter { $0.contains("incremental tools update") }
        == [r1Incremental + "\nStill unavailable: drop_tool.", r1Incremental + "\nStill unavailable: drop_tool."])
}
@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func r1RemovalNoticeOrderAndRedeclaration(_ redeclare: Bool) async throws {
    let first = r1System("base prompt", added: [r1Tool("base_tool"), r1Tool("drop_tool")])
    let changes = redeclare
        ? [r1System(removed: ["drop_tool"]), r1System(added: [r1Tool("drop_tool")])]
        : [r1System(added: [r1Tool("late_tool")], removed: ["drop_tool"])]
    let input = try r1Input(await r1Capture(messages: [first] + changes + [r1User("go")]))
    let noticeIndex = try #require(input.firstIndex { ($0["content"] as? String)?.contains("incremental tools update") == true })
    #expect(input[noticeIndex]["content"] as? String == r1Incremental)
    #expect(input[noticeIndex + 1]["type"] as? String == "additional_tools")
    if !redeclare { #expect(input[noticeIndex + 2]["content"] as? String == r1Removal) }
}

// Upstream transcript-tool-changes.test.ts:452,531.
@Test(.timeLimit(.minutes(1)), arguments: [Api.openAIResponses, .openAICompletions])
func r1AdditionOnlyPrefixSurvivesLoadsAfterRemoval(_ api: Api) async throws {
    let compat = OpenAICompat(supportsMidConvoSystemMessages: true,
        supportsMidConvoToolAdditions: api == .openAICompletions, supportsToolSearch: api == .openAIResponses)
    let payloads = try await r1History(api, compat: compat)
    func names(_ body: [String: Any]) -> [String] {
        (body["tools"] as? [[String: Any]] ?? []).compactMap {
            api == .openAICompletions ? ($0["function"] as? [String: Any])?["name"] as? String : $0["name"] as? String
        }
    }
    #expect(names(payloads[0]) == ["base_tool", "drop_tool"])
    for body in payloads.dropFirst() { #expect(names(body) == ["base_tool"]) }
    try r1ExpectPrefixes(Array(payloads.dropFirst()), api: api)
    let input = try r1Input(try #require(payloads.last), api: api)
    let additions = input.filter { api == .openAICompletions ? $0["tools"] != nil : $0["type"] as? String == "tool_search_output" }
    #expect(additions.count == 2)
    let loaded = additions.compactMap { item -> String? in
        let tool = (item["tools"] as? [[String: Any]])?.first
        return api == .openAICompletions ? (tool?["function"] as? [String: Any])?["name"] as? String : tool?["name"] as? String
    }
    #expect(loaded == ["late_tool", "later_tool"])
}

// Upstream transcript-tool-changes.test.ts:471; user turns do not count as system messages.
@Test func r1TransportBoundaryCountsSystemsAndRepeatedNamesAfterRemoval() {
    let messages = [
        r1System("base", added: [r1Tool("base_tool"), r1Tool("drop_tool")]), r1User("one"),
        r1System(removed: ["drop_tool"]), r1User("two"),
        r1System(added: [r1Tool("drop_tool")]),
        r1System(added: [r1Tool("late_tool", description: "x")]),
        r1System(added: [r1Tool("late_tool", description: "y")]),
    ]
    let removed = resolveTranscriptTools(Array(messages.prefix(4)), support: .additions)
    #expect(removed.foldedSystemMessages == 2)
    #expect(removed.requestTools.map(\.name) == ["base_tool"])
    let readded = resolveTranscriptTools(Array(messages.prefix(6)), support: .additions)
    #expect(readded.foldedSystemMessages == 3)
    #expect(readded.requestTools.map(\.name) == ["base_tool", "drop_tool"])
    let replaced = resolveTranscriptTools(messages, support: .additions)
    #expect(replaced.foldedSystemMessages == 5)
    #expect(replaced.requestTools.map(\.name) == ["base_tool", "drop_tool", "late_tool"])
    #expect(replaced.requestTools.last?.description == "y")
    #expect(resolveTranscriptTools(messages, support: .changes).foldedSystemMessages == 0)
    #expect(resolveTranscriptTools(messages, support: .changes).requestTools.isEmpty)
    #expect(resolveTranscriptTools(messages, support: .none).foldedSystemMessages == 5)
    #expect(resolveTranscriptTools(messages, support: .none).requestTools.last?.description == "y")
    let equalRepeat = [r1System(added: [r1Tool("same")]), r1User("turn"), r1System(added: [r1Tool("same")])]
    #expect(resolveTranscriptTools(equalRepeat, support: .additions).foldedSystemMessages == 2)
    let noInitial = [r1User("first"), r1System(added: [r1Tool("late")])]
    #expect(resolveTranscriptTools(noInitial, support: .additions).foldedSystemMessages == 0)
    #expect(resolveTranscriptTools(noInitial, support: .additions).requestTools.isEmpty)
}

@Test func r1ResponsesCapabilitiesSelectTransportSupport() {
    #expect(getResponsesToolSupport(r1Model(.openAIResponses, compat: r1Changes)) == .changes)
    #expect(getResponsesToolSupport(r1Model(.openAIResponses, compat: OpenAICompat(supportsAdditionalTools: true))) == .none)
    #expect(getResponsesToolSupport(r1Model(.openAIResponses, compat: OpenAICompat(supportsToolSearch: true))) == .additions)
    #expect(getResponsesToolSupport(r1Model(.openAIResponses, compat: OpenAICompat(supportsMidConvoSystemMessages: true))) == .none)
}

@Test(.timeLimit(.minutes(1)), arguments: [Api.openAIResponses, .azureOpenAIResponses, .openAICodexResponses])
func r1InitialBatchesPreserveStrictAndGrammarTools(_ api: Api) async throws {
    let strict = AITool(name: "strict_tool", description: "Strict", parameters: [
        "type": AnyCodable("object"), "properties": AnyCodable(["value": ["type": "string"]]),
        "required": AnyCodable(["value"])
    ], constrainedSampling: .jsonSchema(strict: .require))
    let grammar = AITool(name: "grammar_tool", description: "Grammar", parameters: [
        "type": AnyCodable("object"), "properties": AnyCodable(["input": ["type": "string"]]),
        "required": AnyCodable(["input"])
    ], constrainedSampling: .grammar(variants: [.openAILark: "start: /[a-z]+/"]))
    let compat = OpenAICompat(supportsOpenAIGrammarTools: true,
        supportsMidConvoSystemMessages: true, supportsStrictMode: true, supportsAdditionalTools: true)
    let model = r1Model(api, compat: compat)
    let assistant = AssistantMessage(content: [.toolCall(ToolCall(id: "call|fc_item", name: "grammar_tool",
        arguments: ["input": AnyCodable("hello")]))], api: api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse)
    let body = try await r1Capture(api, compat: compat, messages: [
        r1System(added: [strict, grammar]), r1User("go"), .assistant(assistant),
        .toolResult(ToolResultMessage(toolCallId: "call|fc_item", toolName: "grammar_tool",
            content: [.text(TextContent(text: "done"))], isError: false))
    ])
    #expect(body["tools"] == nil)
    let input = try r1Input(body)
    let tools = try #require(input.first?["tools"] as? [[String: Any]])
    #expect(tools[0]["strict"] as? Bool == true)
    #expect(tools[1]["type"] as? String == "custom")
    #expect((tools[1]["format"] as? [String: Any])?["definition"] as? String == "start: /[a-z]+/")
    let call = try #require(input.first { $0["type"] as? String == "custom_tool_call" })
    #expect(call["input"] as? String == "hello")
    #expect(input.contains { $0["type"] as? String == "custom_tool_call_output" })
}

@Test func r1DeprecatedBooleanAPIKeepsItsCompatibilityFlag() {
    let additive = [r1System(added: [r1Tool("first")]), r1System(added: [r1Tool("second")])]
    #expect(resolveTranscriptTools(additive, supportsToolAdditions: true).anchorsAdditions)
    let removed = additive + [r1System(removed: ["first"]), r1System(added: [r1Tool("later")])]
    let plan = resolveTranscriptTools(removed, supportsToolAdditions: true)
    #expect(!plan.anchorsAdditions)
    #expect(plan.foldedSystemMessages == 3)
    #expect(plan.requestTools.map(\.name) == ["second"])
}

// Shared Responses msgIndex skips messages that have no wire output (:319, :400).
@Test(.timeLimit(.minutes(1))) func r1SearchSeedSkipsEmptyConvertedMessages() async throws {
    let compat = OpenAICompat(supportsMidConvoSystemMessages: true, supportsToolSearch: true)
    let model = r1Model(.openAIResponses, compat: compat)
    let emptyAssistant = AssistantMessage(content: [.thinking(ThinkingContent(thinking: "internal"))],
        api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
    let body = try await r1Capture(compat: compat, messages: [
        r1System("base", added: [r1Tool("base_tool")]), .user(UserMessage(content: .blocks([]))),
        .assistant(emptyAssistant), r1User("before"), r1System(added: [r1Tool("late_tool")])
    ])
    let input = try r1Input(body)
    let expected = "pi_tool_load_\(openAIResponsesShortHash("system:1:late_tool"))"
    #expect(input.first { $0["type"] as? String == "tool_search_call" }?["call_id"] as? String == expected)
    #expect(input.first { $0["type"] as? String == "tool_search_output" }?["call_id"] as? String == expected)
}

// Shared Responses handles initial additions before it skips Codex system text (:282-292).
@Test(.timeLimit(.minutes(1))) func r1CodexInitialRemovalIsNotRecordedWithoutNotice() async throws {
    let body = try await r1Capture(.openAICodexResponses, messages: [
        r1System("base", added: [r1Tool("base_tool")], removed: ["never_announced"]),
        r1User("before"), r1System(added: [r1Tool("late_tool")])
    ])
    let input = try r1Input(body)
    #expect(r1Batches(input) == [["base_tool"], ["late_tool"]])
    #expect(input.compactMap { $0["content"] as? String }.filter { $0.contains("incremental tools update") } == [r1Incremental])
    #expect(!input.compactMap { $0["content"] as? String }.contains { $0.contains("never_announced") })
}
