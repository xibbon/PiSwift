import Foundation
import Testing
@testable import PiSwiftAI

private actor K2CaptureClient: ProviderHTTPClient {
    private var data: Data?

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        data = request.httpBody
        return ProviderHTTPResponse(statusCode: 400, body: Data("captured".utf8))
    }

    func body() -> Data? { data }
}

private func k2Tool() -> AITool {
    AITool(name: "ping", description: "Ping", parameters: [
        "type": AnyCodable("object"),
        "properties": AnyCodable(["value": ["type": "string"]]),
        "required": AnyCodable(["value"]),
    ])
}

private func k2Request(model: Model, context: Context, choice: OpenAIToolChoice? = nil) async throws -> [String: Any] {
    let client = K2CaptureClient()
    _ = await streamOpenAIResponses(model: model, context: normalizeContext(context),
        options: OpenAIResponsesOptions(apiKey: "sk-test", httpClient: client,
            maxRetries: 0, toolChoice: choice)).result()
    let body = try #require(await client.body())
    return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

private func k2ExpectTopLevelTools(_ body: [String: Any]) throws -> [[String: Any]] {
    let tools = try #require(body["tools"] as? [[String: Any]])
    #expect(tools.count == 1)
    #expect(tools.first?["type"] as? String == "function")
    #expect(tools.first?["name"] as? String == "ping")
    let input = try #require(body["input"] as? [[String: Any]])
    #expect(!input.contains { $0["type"] as? String == "additional_tools" })
    #expect(!input.contains { ["tool_search_call", "tool_search_output"].contains($0["type"] as? String ?? "") })
    return input
}

@Suite("K2 top-level OpenAI tools", .timeLimit(.minutes(1)))
struct K2TopLevelToolsTests {
    @Test(arguments: ["openai", "opencode"], ["gpt-5.4", "gpt-5.4-mini", "gpt-5.4-pro", "gpt-5.5"])
    func catalogDisablesDynamicToolLoading(_ provider: String, _ id: String) throws {
        let model = try #require(getModel(provider: provider, modelId: id))
        #expect(model.api == .openAIResponses)
        #expect(model.compat?.supportsAdditionalTools == nil)
        #expect(model.compat?.supportsToolSearch == nil)
        #expect(model.compat?.supportsMidConvoSystemMessages == true)
        #expect(model.compat?.supportsOpenAIGrammarTools == true)
        #expect(model.compat?.supportsStrictMode == (provider == "openai" ? true : nil))
        #expect(model.compat?.sessionAffinityFormat == (provider == "opencode" ? .openaiNosession : nil))
        #expect(getResponsesToolSupport(model) == .none)
    }

    @Test(arguments: ["openai", "opencode"])
    func lunaKeepsDynamicToolLoading(_ provider: String) throws {
        let model = try #require(getModel(provider: provider, modelId: "gpt-5.6-luna"))
        #expect(model.compat?.supportsAdditionalTools == true)
        #expect(model.compat?.supportsMidConvoSystemMessages == true)
        #expect(model.compat?.supportsToolSearch == (provider == "openai" ? true : nil))
        #expect(getResponsesToolSupport(model) == .changes)
    }

    @Test(arguments: [("openai", "gpt-5.5"), ("opencode", "gpt-5.4")])
    func requestKeepsToolsAtTopLevelAndSystemMessageInPlace(_ provider: String, _ id: String) async throws {
        let model = try #require(getModel(provider: provider, modelId: id))
        let body = try await k2Request(model: model, context: Context(messages: [
            .system(SystemMessage(content: .text("Base guidance"))),
            .user(UserMessage(content: .text("First request"))),
            .system(SystemMessage(content: .text("Later guidance"))),
            .user(UserMessage(content: .text("Call ping"))),
        ], tools: [k2Tool()]))
        let input = try k2ExpectTopLevelTools(body)
        #expect(body["model"] as? String == id)
        #expect(input.compactMap { $0["role"] as? String } == ["developer", "user", "developer", "user"])
        #expect(input[2]["content"] as? String == "Later guidance")
    }

    // #11415: replay calls from another model without a namespace (81d6759fc).
    @Test(arguments: [false, true])
    func replayFromAnotherModelUsesTopLevelTools(_ hasForeignNamespace: Bool) async throws {
        let model = try #require(getModel(provider: "openai", modelId: "gpt-5.5"))
        let assistant = AssistantMessage(content: [.toolCall(ToolCall(id: "call_ping|fc_source", name: "ping",
            arguments: ["value": AnyCodable("hello")], namespace: hasForeignNamespace ? "dynamic_tools" : nil))],
            api: .openAIResponses, provider: "openai", model: "gpt-5.6-luna",
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse)
        let body = try await k2Request(model: model, context: Context(messages: [
            .user(UserMessage(content: .text("Call ping"))),
            .assistant(assistant),
            .toolResult(ToolResultMessage(toolCallId: "call_ping|fc_source", toolName: "ping",
                content: [.text(TextContent(text: "pong"))], isError: false)),
            .user(UserMessage(content: .text("Continue"))),
        ], tools: [k2Tool()]))
        let input = try k2ExpectTopLevelTools(body)
        let calls = input.filter { $0["type"] as? String == "function_call" }
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call["name"] as? String == "ping")
        #expect(call["namespace"] == nil)
        let arguments = try #require(call["arguments"] as? String)
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: String])
        #expect(decoded == ["value": "hello"])
        let result = try #require(input.first { $0["type"] as? String == "function_call_output" })
        #expect(result["call_id"] as? String == call["call_id"] as? String)
        #expect(result["output"] as? String == "pong")
    }

    // Port of openai-responses-compat.test.ts:111-156 at 81d6759fc.
    // GPT-5.6 Luna still uses additional_tools with required tool choice.
    @Test func lunaForwardsRequiredToolChoiceWithAdditionalTools() async throws {
        let model = try #require(getModel(provider: "openai", modelId: "gpt-5.6-luna"))
        let body = try await k2Request(model: model, context: Context(messages: [
            .user(UserMessage(content: .text("Do not call ping. Respond with text instead."))),
        ], tools: [k2Tool()]), choice: .required)
        #expect(body["tool_choice"] as? String == "required")
        #expect(body["tools"] == nil)
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.count == 2)
        #expect(input.first?["type"] as? String == "additional_tools")
        let tools = try #require(input.first?["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools.first?["name"] as? String == "ping")
    }

    #if os(macOS) || os(Linux)
    @Test func generatorOverrideChangesOnlyEightRecordsAndIsIdempotent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = #"""
        const assert = require("node:assert/strict");
        const fs = require("node:fs");
        const { applyOpenAITopLevelToolsOverride: apply } = require(process.argv[1]);
        const fixed = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
        const tag = structuredClone(fixed);
        const ids = ["gpt-5.4", "gpt-5.4-mini", "gpt-5.4-pro", "gpt-5.5"];
        for (const provider of ["openai", "opencode"]) {
          for (const id of ids) {
            const record = tag[provider][id];
            record.compat.supportsAdditionalTools = true;
            if (provider === "openai") record.compat.supportsToolSearch = true;
          }
        }
        let changes = 0;
        for (const models of Object.values(tag)) {
          for (const record of Object.values(models)) {
            const before = structuredClone(record);
            assert.equal(apply(record), record);
            if (JSON.stringify(before) !== JSON.stringify(record)) changes++;
          }
        }
        assert.equal(changes, 8);
        assert.deepEqual(tag, fixed);
        for (const models of Object.values(tag)) {
          for (const record of Object.values(models)) apply(record);
        }
        assert.deepEqual(tag, fixed);
        const base = { ...structuredClone(fixed.openai[ids[0]]),
          compat: { supportsAdditionalTools: true, supportsToolSearch: true } };
        for (const patch of [
          ...["opencode-go", "github-copilot", "openai-codex", "openrouter", "vercel-ai-gateway"].map(provider => ({ provider })),
          { api: "openai-completions" }, { type: "classifier" }, { id: "gpt-5.6-luna" }, { id: "gpt-5.4-nano" },
        ]) {
          const record = { ...structuredClone(base), ...patch };
          const before = structuredClone(record);
          apply(record);
          assert.deepEqual(record, before);
        }
        const noCompat = structuredClone(fixed.openai[ids[0]]);
        delete noCompat.compat;
        assert.deepEqual(apply(structuredClone(noCompat)), noCompat);
        """#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", script,
            root.appendingPathComponent("Scripts/generate-ai-catalogs.js").path,
            root.appendingPathComponent("Tests/PiSwiftAITests/Resources/upstream-models.generated.json").path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, Comment(rawValue: String(decoding: data, as: UTF8.self)))
    }
    #endif
}
