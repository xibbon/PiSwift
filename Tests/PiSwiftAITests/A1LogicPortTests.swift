import Foundation
import Testing
@testable import PiSwiftAI

private actor A1HTTPClient: ProviderHTTPClient {
    private var requests: [URLRequest] = []
    private let reply: Data?
    init(reply: String? = nil) { self.reply = reply.map { Data($0.utf8) } }
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        return ProviderHTTPResponse(statusCode: reply == nil ? 500 : 200,
            body: reply ?? Data("captured".utf8))
    }
    func captured() -> [URLRequest] { requests }
}

private func a1Model(_ id: String, api: Api = .anthropicMessages, compat: OpenAICompat? = nil,
                     name: String? = nil, baseUrl: String = "https://example.invalid", reasoning: Bool = true) -> Model {
    Model(id: id, name: name ?? id, api: api, provider: api == .anthropicMessages ? "anthropic" : "amazon-bedrock",
        baseUrl: baseUrl, reasoning: reasoning, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 200_000, maxTokens: 1000, compat: compat)
}
private func a1Tool(_ name: String, description: String? = nil,
                    strict: ConstrainedSamplingStrictness? = nil, rejected: Bool = false) -> AITool {
    let property: [String: Any] = rejected ? ["type": "integer", "minimum": 1] : ["type": "string"]
    return AITool(name: name, description: description ?? name,
        parameters: ["type": AnyCodable("object"), "properties": AnyCodable(["value": property]),
                     "required": AnyCodable(["value"])],
        constrainedSampling: strict.map { .jsonSchema(strict: $0) })
}
private func a1Context(initial: [AITool], added: [AITool] = [], removed: [String] = [], text: String = "") -> TranscriptContext {
    TranscriptContext(messages: [
        .system(SystemMessage(content: .text("Base"), toolsAdded: initial, timestamp: 0)),
        .user(UserMessage(content: .text("before"))),
        .system(SystemMessage(content: .text(text), toolsAdded: added,
            toolsRemoved: removed.map { ToolReference(name: $0) }, timestamp: 2))
    ])
}
private func a1Body(_ client: A1HTTPClient) async throws -> [String: Any] {
    let data = try #require(await client.captured().last?.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
private func a1Blocks(_ body: [String: Any]) throws -> [[String: Any]] {
    try #require((body["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])
}
private func a1Definition(_ block: [String: Any]) throws -> [String: Any] {
    let tool = try #require(block["tool"] as? [String: Any])
    #expect(tool["type"] as? String == "tool_definition")
    return try #require(tool["definition"] as? [String: Any])
}
private func a1JSON(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

@Suite("A1 Anthropic inline tools", .timeLimit(.minutes(1)))
struct A1AnthropicInlineToolTests {
    private var compat: OpenAICompat {
        OpenAICompat(supportsMidConvoSystemMessages: true, supportsMidConvoToolChanges: true,
                     supportsEagerToolInputStreaming: true, supportsStrictTools: true)
    }
    @Test func noInitialToolUsesCurrentToolsAndTextOnly() async throws {
        let client = A1HTTPClient()
        let model = a1Model("claude-opus-4-8", compat: compat)
        let context = a1Context(initial: [], added: [a1Tool("search")], text: "updated guidance")
        _ = await streamAnthropic(model: model, context: context,
            options: AnthropicOptions(apiKey: "test", httpClient: client, maxRetries: 0)).result()
        let body = try await a1Body(client)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["search"])
        #expect(tools[0]["cache_control"] != nil)
        #expect(tools[0]["defer_loading"] == nil)
        #expect(try a1Blocks(body).map { $0["type"] as? String } == ["text"])
        #expect(try a1Blocks(body)[0]["text"] as? String == "updated guidance")
        let beta = await client.captured().last?.value(forHTTPHeaderField: "anthropic-beta")
        #expect(beta?.contains("inline-tools-2026-09-15") != true)
    }
    @Test func initialRequestKeepsPlaceholderAndLastToolCacheControl() async throws {
        let client = A1HTTPClient()
        let context = normalizeContext(Context(systemPrompt: "Base",
            messages: [.user(UserMessage(content: .text("before")))], tools: [a1Tool("read"), a1Tool("write")]))
        _ = await streamAnthropic(model: a1Model("claude-opus-4-8", compat: compat), context: context,
            options: AnthropicOptions(apiKey: "test", httpClient: client, maxRetries: 0)).result()
        let body = try await a1Body(client)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["read", "write", "__pi_deferred_placeholder__"])
        #expect(tools[0]["cache_control"] == nil)
        #expect(tools[1]["cache_control"] != nil)
        #expect(tools[2]["cache_control"] == nil)
        #expect(tools[2]["defer_loading"] as? Bool == true)
        #expect(tools[2]["eager_input_streaming"] == nil)
        let beta = await client.captured().last?.value(forHTTPHeaderField: "anthropic-beta")
        #expect(beta?.contains("inline-tools-2026-09-15") == true)
    }
    @Test func inlineBetaReplacesOldBeta() {
        let model = a1Model("claude-opus-4-8", compat: compat)
        let betas = anthropicBetaFeatures(model: model, context: Context(messages: []),
            options: AnthropicOptions(apiKey: "test"), nativeToolChanges: true) ?? []
        #expect(betas.contains("inline-tools-2026-09-15"))
        #expect(!betas.contains("mid-conversation-tool-changes-2026-07-01"))
    }
    @Test func fineGrainedBetaUsesCurrentToolsAfterAllRemovals() async throws {
        var compat = compat
        compat.supportsEagerToolInputStreaming = false
        let client = A1HTTPClient()
        _ = await streamAnthropic(model: a1Model("claude-opus-4-8", compat: compat),
            context: a1Context(initial: [a1Tool("read")], removed: ["read"]),
            options: AnthropicOptions(apiKey: "test", httpClient: client, maxRetries: 0)).result()
        let beta = try #require(await client.captured().last?.value(forHTTPHeaderField: "anthropic-beta"))
        #expect(beta.contains("inline-tools-2026-09-15"))
        #expect(!beta.contains("fine-grained-tool-streaming-2025-05-14"))
        #expect(try a1Blocks(await a1Body(client)).map { $0["type"] as? String } == ["tool_removal"])
    }
    @Test func oauthDefinitionsUseClaudeCodeNamesAndAdditionOrder() async throws {
        let client = A1HTTPClient()
        _ = await streamAnthropic(model: a1Model("claude-opus-4-8", compat: compat),
            context: a1Context(initial: [a1Tool("read")], added: [a1Tool("bash"), a1Tool("grep")], removed: ["read"]),
            options: AnthropicOptions(apiKey: "sk-ant-oat01-test", httpClient: client, maxRetries: 0)).result()
        let body = try await a1Body(client)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["Read", "__pi_deferred_placeholder__"])
        #expect(tools[0]["cache_control"] != nil)
        #expect(tools[1]["cache_control"] == nil)
        let blocks = try a1Blocks(body)
        #expect(blocks.map { $0["type"] as? String } == ["tool_removal", "tool_addition", "tool_addition"])
        #expect((blocks[0]["tool"] as? [String: Any])?["name"] as? String == "Read")
        let definitions = try blocks.dropFirst().map(a1Definition)
        #expect(definitions.map { $0["name"] as? String } == ["Bash", "Grep"])
        for definition in definitions {
            #expect(definition["eager_input_streaming"] as? Bool == true)
            #expect(definition["cache_control"] == nil)
            #expect(definition["defer_loading"] == nil)
        }
        #expect(blocks[1]["cache_control"] == nil)
        #expect(blocks[2]["cache_control"] != nil)
    }
    @Test func topLevelAndInlineDefinitionsUseSameShape() async throws {
        let client = A1HTTPClient()
        let tool = a1Tool("read", strict: .require)
        _ = await streamAnthropic(model: a1Model("claude-opus-4-8", compat: compat),
            context: a1Context(initial: [tool], added: [tool], removed: ["read"]),
            options: AnthropicOptions(apiKey: "test", httpClient: client, maxRetries: 0)).result()
        let body = try await a1Body(client)
        var initial = try #require((body["tools"] as? [[String: Any]])?.first)
        #expect(initial.removeValue(forKey: "cache_control") != nil)
        let blocks = try a1Blocks(body)
        #expect(blocks.count == 1)
        let definition = try a1Definition(blocks[0])
        #expect(definition["strict"] as? Bool == true)
        #expect(try a1JSON(initial) == a1JSON(definition))
        let schema = try #require(definition["input_schema"] as? [String: Any])
        #expect(schema["additionalProperties"] as? Bool == false)
    }
    @Test(arguments: [false, true])
    func strictResolutionIsPerDefinition(_ initialStrict: Bool) async throws {
        let client = A1HTTPClient()
        let initial = a1Tool("read", description: "old", strict: initialStrict ? .require : nil)
        let replacement = a1Tool("read", description: "new", strict: initialStrict ? .prefer : .require,
                                 rejected: initialStrict)
        _ = await streamAnthropic(model: a1Model("claude-opus-4-8", compat: compat),
            context: a1Context(initial: [initial], added: [replacement], removed: ["read"]),
            options: AnthropicOptions(apiKey: "test", httpClient: client, maxRetries: 0)).result()
        let body = try await a1Body(client)
        let top = try #require((body["tools"] as? [[String: Any]])?.first)
        let blocks = try a1Blocks(body)
        #expect(blocks.count == 1)
        let inline = try a1Definition(blocks[0])
        #expect((top["strict"] as? Bool == true) == initialStrict)
        #expect((inline["strict"] as? Bool == true) == !initialStrict)
        #expect(top["description"] as? String == "old")
        #expect(inline["description"] as? String == "new")
    }
    @Test func rejectedRequiredInlineSchemaFailsBeforeRequest() async {
        let client = A1HTTPClient()
        let result = await streamAnthropic(model: a1Model("claude-opus-4-8", compat: compat),
            context: a1Context(initial: [a1Tool("read")], added: [a1Tool("read", strict: .require, rejected: true)], removed: ["read"]),
            options: AnthropicOptions(apiKey: "test", httpClient: client, maxRetries: 0)).result()
        #expect(result.stopReason == .error)
        #expect(result.errorMessage?.contains("requires JSON-schema constrained sampling") == true)
        #expect(result.errorMessage?.contains("minimum") == true)
        #expect(await client.captured().isEmpty)
    }
    @Test func toolCacheControlCanBeDisabled() async throws {
        var compat = compat
        compat.supportsCacheControlOnTools = false
        let client = A1HTTPClient()
        _ = await streamAnthropic(model: a1Model("claude-opus-4-8", compat: compat),
            context: a1Context(initial: [a1Tool("read")], added: [a1Tool("search")]),
            options: AnthropicOptions(apiKey: "test", httpClient: client, maxRetries: 0)).result()
        let body = try await a1Body(client)
        #expect((body["tools"] as? [[String: Any]])?.allSatisfy { $0["cache_control"] == nil } == true)
        #expect(try a1Blocks(body).last?["cache_control"] != nil)
    }
}

@Suite("A1 Bedrock thinking payload")
struct A1BedrockThinkingTests {
    @Test(arguments: ["opus-4-7", "opus-4-8", "fable-5", "sonnet-5", "opus-5", "opus-5-5", "sonnet-5-5"],
          [ThinkingLevel.high, .xhigh])
    func adaptiveBindingAndEffort(_ modelID: String, _ level: ThinkingLevel) throws {
        let fields = try #require(buildAdditionalModelRequestFields(
            model: a1Model("global.anthropic.claude-" + modelID, api: .bedrockConverseStream),
            options: BedrockOptions(env: [:], reasoning: level)))
        #expect(fields["thinking"] == AnyCodable(["type": "adaptive", "display": "summarized",
            "block_binding": ["prefix_mismatch_behavior": "drop_block"]] as [String: Any]))
        #expect(fields["anthropic_beta"] == AnyCodable(["thinking-binding-controls-2026-08-01"]))
        #expect(fields["output_config"] == AnyCodable(["effort": level.rawValue]))
    }
    @Test(arguments: ["global.anthropic.claude-opus-4-6-v1", "global.anthropic.claude-sonnet-4-6"])
    func models46OmitBinding(_ id: String) throws {
        let fields = try #require(buildAdditionalModelRequestFields(model: a1Model(id, api: .bedrockConverseStream),
            options: BedrockOptions(env: [:], reasoning: .high)))
        #expect(fields["thinking"] == AnyCodable(["type": "adaptive", "display": "summarized"]))
        #expect(fields["anthropic_beta"] == nil)
    }
    @Test(arguments: ["region", "endpoint", "id", "arn"])
    func govCloudOmitsBindingAndDisplay(_ target: String) throws {
        let id = target == "id" ? "us-gov.anthropic.claude-opus-4-8-v1"
            : target == "arn" ? "arn:aws-us-gov:bedrock:us-gov-west-1:123:inference-profile/anthropic.claude-opus-4-8"
            : "global.anthropic.claude-opus-4-8-v1"
        let model = a1Model(id, api: .bedrockConverseStream, baseUrl: target == "endpoint"
            ? "https://bedrock-runtime.us-gov-west-1.amazonaws.com" : "https://example.invalid")
        let fields = try #require(buildAdditionalModelRequestFields(model: model,
            options: BedrockOptions(env: [:], region: target == "region" ? "us-gov-west-1" : nil, reasoning: .high)))
        #expect(fields["thinking"] == AnyCodable(["type": "adaptive"]))
        #expect(fields["output_config"] == AnyCodable(["effort": "high"]))
        #expect(fields["anthropic_beta"] == nil)
    }
    @Test func bindingUsesNormalizedModelName() throws {
        let model = a1Model("arn:aws:bedrock:us-east-1:123:application-inference-profile/custom",
            api: .bedrockConverseStream, name: "Claude Opus 5.5")
        let fields = try #require(buildAdditionalModelRequestFields(model: model,
            options: BedrockOptions(env: [:], reasoning: .xhigh, thinkingDisplay: .omitted)))
        #expect(fields["thinking"] == AnyCodable(["type": "adaptive", "display": "omitted",
            "block_binding": ["prefix_mismatch_behavior": "drop_block"]] as [String: Any]))
        #expect(fields["anthropic_beta"] == AnyCodable(["thinking-binding-controls-2026-08-01"]))
        #expect(fields["output_config"] == AnyCodable(["effort": "xhigh"]))
    }
    @Test func budgetAndDisabledReasoningStayUnchanged() throws {
        let budget = a1Model("us-gov.anthropic.claude-sonnet-4-5-20250929-v1:0", api: .bedrockConverseStream)
        let fields = try #require(buildAdditionalModelRequestFields(model: budget, options: BedrockOptions(env: [:], reasoning: .high)))
        #expect(fields["thinking"] == AnyCodable(["type": "enabled", "budget_tokens": 16384] as [String: Any]))
        #expect(fields["anthropic_beta"] == AnyCodable(["interleaved-thinking-2025-05-14"]))
        let adaptive = a1Model("global.anthropic.claude-opus-5", api: .bedrockConverseStream)
        #expect(buildAdditionalModelRequestFields(model: adaptive, options: BedrockOptions(env: [:])) == nil)
        let disabled = a1Model("global.anthropic.claude-opus-5", api: .bedrockConverseStream, reasoning: false)
        #expect(buildAdditionalModelRequestFields(model: disabled, options: BedrockOptions(env: [:], reasoning: .high)) == nil)
    }
}

@Suite("A1 retry and Cloudflare direct output", .timeLimit(.minutes(1)))
struct A1RetryAndCloudflareTests {
    @Test func selectedModelAtCapacityIsRetryable() {
        let message = AssistantMessage(content: [], api: .openAIResponses, provider: "openai", model: "test",
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .error,
            errorMessage: "Selected model is at capacity")
        #expect(isRetryableAssistantError(message))
    }
    @Test(arguments: ["@cf/cloudflare/clef", "@cf/cloudflare/clef-flash"])
    func clefDirectOutput(_ id: String) async throws {
        let price = id.hasSuffix("-flash") ? 0.09 : 0.24
        let model = ClassifierModel(id: id, name: id, api: .cloudflareWorkersAISystemOne,
            provider: "cloudflare-workers-ai", baseUrl: "https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/ai",
            input: [.text], cost: ModelCost(input: price, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 65536)
        let context = ClassifierContext(state: ["text": AnyCodable("The app crashes when I open settings. Please help today.")], questions: [
            "is_urgent": .bool(instructions: "Is this urgent?", trueCriterion: "Urgent", falseCriterion: "Not urgent"),
            "department": .choice(instructions: "Which department?", criteria: ["billing": "Billing", "technical": "Technical"])
        ])
        // Upstream cloudflare-workers-ai-system-one.test.ts:50–63.
        let client = A1HTTPClient(reply: #"{"result":{"model":"clef","answers":{"is_urgent":{"type":"noul","noul":0.9912},"department":{"type":"choice","choice":"technical","probabilities":{"billing":0.1632,"technical":0.8368},"confidence":0.4538}},"usage":{"input_tokens":222,"output_tokens":0}},"success":true,"errors":[],"messages":[]}"#)
        let result = await classify(model: model, context: context,
            options: ClassifierOptions(apiKey: "token", httpClient: client, env: ["CLOUDFLARE_ACCOUNT_ID": "account-id"]))
        #expect(result.stopReason == .stop)
        if case .bool(let probability)? = result.answers["is_urgent"] { #expect(probability == 0.9912) }
        else { Issue.record("Missing bool answer") }
        if case .choice(let choice, let probabilities, let confidence)? = result.answers["department"] {
            #expect(choice == "technical")
            #expect(probabilities == ["billing": 0.1632, "technical": 0.8368])
            #expect(confidence == 0.4538)
        } else { Issue.record("Missing choice answer") }
        #expect(result.usage?.input == 222)
        #expect(result.usage?.output == 0)
        #expect(result.usage?.totalTokens == 222)
        #expect(abs((result.usage?.cost.input ?? 0) - 222 * price / 1_000_000) < 1e-12)
        let request = try #require(await client.captured().first)
        #expect(request.url?.absoluteString == "https://api.cloudflare.com/client/v4/accounts/account-id/ai/run")
        let body = try await a1Body(client)
        #expect(body["model"] as? String == id)
        let input = try #require(body["input"] as? [String: Any])
        #expect(try a1JSON(try #require(input["state"])) == a1JSON(context.state.mapValues(\.value)))
        #expect(((input["questions"] as? [String: Any])?["is_urgent"] as? [String: Any])?["type"] as? String == "noul")
    }
    @Test func nullAnswersStillSelectsDirectOutputBeforeState() async {
        let model = ClassifierModel(id: "custom", name: "Custom", api: .cloudflareWorkersAISystemOne,
            provider: "cloudflare-workers-ai", baseUrl: "https://example.invalid/ai", input: [.text],
            cost: ModelCost(input: 0.24, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 65536)
        let client = A1HTTPClient(reply: #"{"success":true,"result":{"answers":null,"state":"Queued","usage":{"input_tokens":222,"output_tokens":0}}}"#)
        let result = await classify(model: model, context: ClassifierContext(state: [:], questions: [:]),
            options: ClassifierOptions(apiKey: "token", httpClient: client))
        #expect(result.stopReason == .error)
        #expect(result.errorMessage?.contains("state: Queued") != true)
        #expect(result.usage?.input == 222)
    }
}
