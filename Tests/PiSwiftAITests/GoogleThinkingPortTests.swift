import Foundation
import Testing
@testable import PiSwiftAI

private func googlePortModel(id: String = "gemini-3.7-flash", map: ThinkingLevelMap = [:], vertex: Bool = false) -> Model {
    Model(id: id, name: id, api: vertex ? .googleVertex : .googleGenerativeAI,
        provider: vertex ? "test-vertex" : "test-google", baseUrl: "https://example.invalid/v1beta",
        reasoning: true, input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 128000, maxTokens: 4096, thinkingLevelMap: map)
}

@Test func googleThinkingDefaultLogicalLevels() throws {
    let expected: [(ModelThinkingLevel, ResolvedGoogleThinkingLevel)] = [(.off, .high), (.minimal, .minimal), (.low, .low), (.medium, .medium), (.high, .high)]
    for (level, value) in expected {
        #expect(try resolveGoogleThinkingLevel(model: googlePortModel(), level: level) == value)
    }
}

@Test(arguments: ["minimal", "low", "medium", "high", "MINIMAL", "LOW", "MEDIUM", "HIGH"])
func googleThinkingAcceptsEveryProviderCase(_ mapped: String) throws {
    let model = googlePortModel(map: [.high: mapped, .xhigh: mapped, .max: mapped])
    let levels: [ModelThinkingLevel] = [.high, .xhigh, .max]
    for level in levels {
        #expect(try resolveGoogleThinkingLevel(model: model, level: level).rawValue == mapped.lowercased())
    }
}

@Test func googleThinkingRejectsInvalidAndMissingExtendedMap() {
    for (model, level, expected) in [
        (googlePortModel(map: [.xhigh: "extreme"]), ModelThinkingLevel.xhigh, "xhigh -> extreme"),
        (googlePortModel(), ModelThinkingLevel.max, "max -> undefined"),
    ] {
        do {
            _ = try resolveGoogleThinkingLevel(model: model, level: level)
            Issue.record("Invalid Google thinking map was accepted")
        } catch {
            #expect(error.localizedDescription == "Unsupported Google thinking level mapping for test-google/gemini-3.7-flash: \(expected)")
        }
    }
}

@Test(arguments: [ThinkingLevel.xhigh, .max])
func googleExtendedLevelsMapForBothAdapters(_ reasoning: ThinkingLevel) throws {
    let map: ThinkingLevelMap = [.xhigh: "high", .max: "high"]
    let simple = SimpleStreamOptions(reasoning: reasoning)
    let direct = try mapGoogleSimpleOptionsValidated(model: googlePortModel(map: map), options: simple, apiKey: "test")
    let vertex = try mapGoogleVertexSimpleOptionsValidated(model: googlePortModel(map: map, vertex: true), options: simple, apiKey: "test")
    #expect(direct.thinking?.enabled == true)
    #expect(direct.thinking?.level == .high)
    #expect(direct.thinking?.budgetTokens == nil)
    #expect(vertex.thinking?.enabled == true)
    #expect(vertex.thinking?.level == .high)
    #expect(vertex.thinking?.budgetTokens == nil)
}

@Test func googleUppercaseStandardMapIsApplied() throws {
    let options = try mapGoogleSimpleOptionsValidated(model: googlePortModel(map: [.high: "LOW"]), options: SimpleStreamOptions(reasoning: .high), apiKey: "test")
    #expect(options.thinking?.level == .low)
}

@Test func googleMappedLevelsSelectCustomBudgets() throws {
    let direct = try mapGoogleSimpleOptionsValidated(model: googlePortModel(id: "gemini-2.5-flash", map: [.xhigh: "high"]),
        options: SimpleStreamOptions(reasoning: .xhigh, thinkingBudgets: [.high: 1234]), apiKey: "test")
    let vertex = try mapGoogleVertexSimpleOptionsValidated(model: googlePortModel(id: "gemini-2.5-flash", map: [.max: "high"], vertex: true),
        options: SimpleStreamOptions(reasoning: .max, thinkingBudgets: [.high: 4321]), apiKey: "test")
    #expect(direct.thinking?.budgetTokens == 1234)
    #expect(direct.thinking?.level == nil)
    #expect(vertex.thinking?.budgetTokens == 4321)
    #expect(vertex.thinking?.level == nil)
}

private actor GooglePortHTTP: ProviderHTTPClient {
    let responseBody: Data
    var request: URLRequest?
    init(finish: String = "STOP", tool: Bool = false, includeParts: Bool = true) throws {
        var candidate: [String: Any] = ["finishReason": finish]
        if includeParts {
            let parts: [[String: Any]] = tool
                ? [["functionCall": ["id": "call-1", "name": "echo", "args": ["value": "truncated"]]]]
                : [["text": "done"]]
            candidate["content"] = ["parts": parts]
        }
        let event: [String: Any] = ["responseId": "google-response-id", "candidates": [candidate],
            "usageMetadata": ["promptTokenCount": 1, "candidatesTokenCount": 0, "totalTokenCount": 1]]
        let json = String(data: try JSONSerialization.data(withJSONObject: event), encoding: .utf8)!
        responseBody = Data("data: \(json)\n\n".utf8)
    }
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        self.request = request
        return ProviderHTTPResponse(statusCode: 200, body: responseBody)
    }
}

private func googlePortResult(client: GooglePortHTTP, vertex: Bool, headers: ProviderHeaders? = nil) async -> AssistantMessage {
    let context = Context(messages: [.user(UserMessage(content: .text("hello")))])
    if vertex {
        return await streamGoogleVertex(model: googlePortModel(vertex: true), context: context,
            options: GoogleVertexOptions(apiKey: "test", httpClient: client, headers: headers, project: "test-project", location: "us-central1")).result()
    }
    return await streamGoogle(model: googlePortModel(), context: context,
        options: GoogleOptions(apiKey: "test", httpClient: client, headers: headers)).result()
}

@Test(arguments: [false, true])
func googleRawErrorReasonsWithoutContent(_ vertex: Bool) async throws {
    let reason = vertex ? "SAFETY" : "MALFORMED_FUNCTION_CALL"
    let client = try GooglePortHTTP(finish: reason, includeParts: false)
    let result = await googlePortResult(client: client, vertex: vertex)
    #expect(result.stopReason == .error)
    #expect(result.rawStopReason == reason)
    #expect(result.errorMessage == "Provider stopped with: \(reason)")
}

@Test(arguments: [false, true], ["MAX_TOKENS", "STOP"])
func googleToolCallsPreserveRawStopAndLength(_ vertex: Bool, _ reason: String) async throws {
    let client = try GooglePortHTTP(finish: reason, tool: true)
    let result = await googlePortResult(client: client, vertex: vertex)
    #expect(result.rawStopReason == reason)
    #expect(result.stopReason == (reason == "STOP" ? .toolUse : .length))
    #expect(result.content.contains { if case .toolCall = $0 { return true }; return false })
}

@Test func googlePayloadContainsMappedNativeThinkingLevel() async throws {
    let client = try GooglePortHTTP()
    let model = googlePortModel(map: [.max: "high"])
    let options = try mapGoogleSimpleOptionsValidated(model: model, options: SimpleStreamOptions(httpClient: client, reasoning: .max), apiKey: "test")
    let result = await streamGoogle(model: model, context: Context(messages: [.user(UserMessage(content: .text("hello")))]), options: options).result()
    #expect(result.stopReason == .stop)
    let request = try #require(await client.request)
    let data = try #require(request.httpBody)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let config = try #require((payload["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: Any])
    #expect(config["includeThoughts"] as? Bool == true)
    #expect(config["thinkingLevel"] as? String == "HIGH")
}

@Test func googleUserAgentDefaultAndExplicitOverride() async throws {
    let defaultClient = try GooglePortHTTP()
    _ = await googlePortResult(client: defaultClient, vertex: false)
    #expect(await defaultClient.request?.value(forHTTPHeaderField: "User-Agent") == getPiUserAgent())
    let customClient = try GooglePortHTTP()
    _ = await googlePortResult(client: customClient, vertex: false, headers: ["User-Agent": "custom-agent"])
    #expect(await customClient.request?.value(forHTTPHeaderField: "User-Agent") == "custom-agent")
}
