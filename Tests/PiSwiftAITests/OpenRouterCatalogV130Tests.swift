import Foundation
import Testing
@testable import PiSwiftAI

private actor OpenRouter130Client: ProviderHTTPClient {
    var requests: [URLRequest] = []
    let response: ProviderHTTPResponse
    init(_ json: String = "", status: Int = 200) {
        response = ProviderHTTPResponse(statusCode: status, body: Data(json.utf8))
    }
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        return response
    }
}

private actor OpenRouter130BlockedClient: ProviderHTTPClient {
    var started = false
    var startWaiter: CheckedContinuation<Void, Never>?
    var releaseWaiter: CheckedContinuation<Void, Never>?
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
        return ProviderHTTPResponse(statusCode: 200, body: Data(#"{"data":[]}"#.utf8))
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

private func openRouter130Chat(_ id: String) -> AnyModel {
    .chat(Model(id: id, name: id, api: .openAICompletions, provider: "openrouter",
        baseUrl: "https://openrouter.ai/api/v1", reasoning: false, input: [.text],
        cost: ModelCost(input: 1, output: 2, cacheRead: 0.1, cacheWrite: 0),
        contextWindow: 200_000, maxTokens: 50_000,
        samplingParams: ["temperature": AnyCodable(0.2)],
        headers: ["x-test": "kept"], compat: OpenAICompat(supportsStore: true),
        promptCache: ModelPromptCache(short: 300, long: 3600)))
}

@Test func openRouter130KeepsAllowedChatsWithKeyLimitsAndPrices() async throws {
    let client = OpenRouter130Client(#"""
    {"data":[
      {"id":"listed","context_length":1000000,"top_provider":{"context_length":262144,"max_completion_tokens":32768},"pricing":{"prompt":"0.000003","completion":"0.000015"}},
      {"id":"no-limits","context_length":0,"top_provider":{"context_length":null,"max_completion_tokens":null}},
      {"id":"router","pricing":{"prompt":"-1","completion":"-1"}}
    ]}
    """#)
    let zero = ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
    let image = AnyModel.image(ImageModel(id: "image", name: "image", api: .openrouterImages,
        provider: "openrouter", baseUrl: "https://openrouter.ai/api/v1", input: [.text], output: [.image], cost: zero))
    let classifier = AnyModel.classifier(ClassifierModel(id: "classifier", name: "classifier", api: .typesafeSystemOne,
        provider: "openrouter", baseUrl: "https://openrouter.ai/api/v1", input: [.text], cost: zero, contextWindow: 64_000))
    let result = try await personalizeOpenRouterCatalog([
        openRouter130Chat("listed"), openRouter130Chat("no-limits"), openRouter130Chat("router"),
        openRouter130Chat("blocked"), image, classifier
    ], credential: "sk-or-test", client: client)
    #expect(result.map(\.id) == ["listed", "no-limits", "router", "image", "classifier"])
    let listed = try #require(result.first)
    guard case .chat(let model) = listed else { Issue.record("Expected chat"); return }
    #expect(model.contextWindow == 262_144)
    #expect(model.maxTokens == 32_768)
    #expect(model.cost == ModelCost(input: 3, output: 15, cacheRead: 0, cacheWrite: 0))
    #expect(model.compat?.supportsStore == true)
    #expect(model.promptCache?.long == 3600)
    #expect(model.samplingParams?["temperature"] == AnyCodable(0.2))
    guard case .chat(let noLimits) = result[1] else { Issue.record("Expected chat"); return }
    #expect(noLimits.contextWindow == 200_000)
    #expect(noLimits.maxTokens == 50_000)
    #expect(noLimits.cost == ModelCost(input: 1, output: 2, cacheRead: 0.1, cacheWrite: 0))
    #expect(result[2].catalog.cost == zero)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(try encoder.encode(result[3]) == encoder.encode(image))
    #expect(try encoder.encode(result[4]) == encoder.encode(classifier))
    let request = try #require(await client.requests.first)
    #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/models/user")
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "accept") == "application/json")
    #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer sk-or-test")
    #expect(request.timeoutInterval == 15)
    #expect(OpenRouterCatalogError.timedOut(milliseconds: 15_000).errorDescription ==
        "OpenRouter model list request timed out after 15000ms")
}

@Test(arguments: [401, 403, 404]) func openRouter130RejectedOrMissingEndpointKeepsCatalog(status: Int) async throws {
    let result = try await personalizeOpenRouterCatalog([openRouter130Chat("a")], credential: "key",
        client: OpenRouter130Client(status: status))
    #expect(result.map(\.id) == ["a"])
    #expect(result[0].catalog.cost.input == 1)
}

@Test(arguments: [nil, ""] as [String?]) func openRouter130MissingKeyDoesNotRequest(key: String?) async throws {
    let client = OpenRouter130Client()
    let token = CancellationToken()
    token.cancel()
    let result = try await personalizeOpenRouterCatalog([openRouter130Chat("a")], credential: key, client: client, signal: token)
    #expect(result.map(\.id) == ["a"])
    #expect(await client.requests.isEmpty)
}

@Test func openRouter130UsesRegionalURLAndLastDuplicate() async throws {
    let client = OpenRouter130Client(#"{"data":[null,3,{"id":2},{"id":"a","context_length":5},{"id":"a","context_length":900,"top_provider":{"context_length":0,"max_completion_tokens":0},"pricing":false}]}"#)
    let result = try await personalizeOpenRouterCatalog([openRouter130Chat("a"), openRouter130Chat("b")],
        credential: "oauth-access", baseUrl: "https://us.openrouter.ai/api/v1///", client: client)
    #expect(result.map(\.id) == ["a"])
    guard case .chat(let model) = result[0] else { Issue.record("Expected chat"); return }
    #expect(model.contextWindow == 900)
    #expect(model.maxTokens == 50_000)
    #expect(model.cost.input == 1)
    let request = try #require(await client.requests.first)
    #expect(request.url?.absoluteString == "https://us.openrouter.ai/api/v1/models/user")
    #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer oauth-access")
}

@Test(arguments: [400, 429, 500]) func openRouter130HTTPFailureHasExactMessage(status: Int) async {
    do {
        _ = try await personalizeOpenRouterCatalog([], credential: "key", client: OpenRouter130Client(status: status))
        Issue.record("Expected failure")
    } catch {
        #expect(error as? OpenRouterCatalogError == .requestFailed(status))
        #expect(error.localizedDescription == "OpenRouter model list request failed: \(status)")
    }
}

@Test(arguments: ["null", "[]", "{}", #"{"data":{}}"#, #"{"data":null}"#])
func openRouter130BadShapeHasExactMessage(json: String) async {
    do {
        _ = try await personalizeOpenRouterCatalog([], credential: "key", client: OpenRouter130Client(json))
        Issue.record("Expected failure")
    } catch {
        #expect(error as? OpenRouterCatalogError == .invalidResponse)
        #expect(error.localizedDescription == "Invalid OpenRouter model list response")
    }
}

@Test func openRouter130MalformedJSONThrowsParserError() async {
    do {
        _ = try await personalizeOpenRouterCatalog([], credential: "key", client: OpenRouter130Client("{"))
        Issue.record("Expected failure")
    } catch { #expect(!(error is OpenRouterCatalogError)) }
}

@Test(.timeLimit(.minutes(1))) func openRouter130SignalCancellationDoesNotWaitForClient() async throws {
    let client = OpenRouter130BlockedClient()
    let signal = CancellationToken()
    let operation = Task { try await personalizeOpenRouterCatalog([], credential: "key", client: client, signal: signal) }
    await client.waitUntilStarted()
    signal.cancel()
    do { _ = try await operation.value; Issue.record("Expected cancellation") }
    catch {
        guard let streamError = error as? StreamError, case .requestAborted = streamError else {
            Issue.record("Expected requestAborted, got \(error)"); await client.release(); return
        }
    }
    await client.release()
}

@Test(.timeLimit(.minutes(1))) func openRouter130TaskCancellationDoesNotWaitForClient() async throws {
    let client = OpenRouter130BlockedClient()
    let operation = Task { try await personalizeOpenRouterCatalog([], credential: "key", client: client) }
    await client.waitUntilStarted()
    operation.cancel()
    do { _ = try await operation.value; Issue.record("Expected cancellation") }
    catch { #expect(error is CancellationError) }
    await client.release()
}

@Test func openRouter130PriceParsingAndRounding() {
    let vectors: [(String?, Double)] = [
        (nil, 0), ("", 0), ("\u{0085}1", 0), ("\u{FEFF}1e-6", 1), ("bad", 0), ("NaN", 0), ("-1", 0), ("-Infinity", 0),
        ("0", 0), ("-0", 0), ("0.000003", 3), ("  +.000003tail", 3),
        ("1e-6text", 1), ("1e", 1_000_000), ("0x10", 0),
        ("0.0000001234567", 0.123457), ("0.0000000078125", 0.007813),
        ("Infinity", .infinity), ("1e999", .infinity)
    ]
    for (text, expected) in vectors {
        #expect(openRouterCost(OpenRouterPricing(prompt: text)).input == expected)
    }
    #expect(openRouterCost(nil) == ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0))
}

@Test func openRouter130PriceTiersKeepBaseAndSkipTimeConditions() {
    let cost = openRouterCost(OpenRouterPricing(prompt: "0.000003", completion: "0.000015",
        inputCacheRead: "0.0000003", inputCacheWrite: "0.000004", overrides: [
            .init(minPromptTokens: 100_000, prompt: "0.000006", completion: "-1", inputCacheRead: "bad"),
            .init(minPromptTokens: 0, prompt: "0", inputCacheWrite: "0"),
            .init(prompt: "5"),
            .init(minPromptTokens: 1, utcStart: 0, prompt: "5"),
            .init(minPromptTokens: 1, utcEnd: 0, prompt: "5"),
            .init(minPromptTokens: 1, utcDays: [], prompt: "5")
        ]))
    #expect(cost.tiers == [
        ModelCostTier(inputTokensAbove: 100_000, input: 6, output: 15, cacheRead: 0.3, cacheWrite: 4),
        ModelCostTier(inputTokensAbove: 0, input: 0, output: 15, cacheRead: 0.3, cacheWrite: 0)
    ])
    #expect(openRouterCost(OpenRouterPricing(overrides: [.init(utcStart: 1)])).tiers == nil)
}


@Test(.timeLimit(.minutes(1))) func openRouter130DeadlineDoesNotWaitForClient() async throws {
    let client = OpenRouter130BlockedClient()
    let operation = Task {
        try await personalizeOpenRouterCatalog([], credential: "key", client: client, timeout: .milliseconds(50))
    }
    await client.waitUntilStarted()
    do { _ = try await operation.value; Issue.record("Expected timeout") }
    catch { #expect(error as? OpenRouterCatalogError == .timedOut(milliseconds: 50)) }
    await client.release()
}

@Test func openRouter130PreCancelledSignalDoesNotRequest() async throws {
    let client = OpenRouter130Client(#"{"data":[]}"#)
    let signal = CancellationToken()
    signal.cancel()
    do {
        _ = try await personalizeOpenRouterCatalog([], credential: "key", client: client, signal: signal)
        Issue.record("Expected cancellation")
    } catch {
        guard let streamError = error as? StreamError, case .requestAborted = streamError else {
            Issue.record("Expected requestAborted, got \(error)"); return
        }
    }
    #expect(await client.requests.isEmpty)
}

@Test func openRouter130MissingNullZeroLimitsKeepCatalogValues() async throws {
    for fields in [
        #""top_provider":{}"#,
        #""context_length":null,"top_provider":{"context_length":null,"max_completion_tokens":null}"#,
        #""context_length":0,"top_provider":{"context_length":0,"max_completion_tokens":0}"#
    ] {
        let json = "{\"data\":[{\"id\":\"a\",\(fields)}]}"
        let result = try await personalizeOpenRouterCatalog([openRouter130Chat("a")], credential: "key",
            client: OpenRouter130Client(json))
        guard case .chat(let model) = result[0] else { Issue.record("Expected chat"); continue }
        #expect(model.contextWindow == 200_000)
        #expect(model.maxTokens == 50_000)
    }
}

private actor OpenRouter130BodyGate {
    var started = false
    var startWaiter: CheckedContinuation<Void, Never>?
    var releaseWaiter: CheckedContinuation<Data?, Never>?
    func next() async -> Data? {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        return await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(returning: nil); releaseWaiter = nil }
}

private struct OpenRouter130BodyClient: ProviderHTTPClient {
    let gate: OpenRouter130BodyGate
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        ProviderHTTPResponse(statusCode: 200, body: AsyncThrowingStream(unfolding: { await gate.next() }))
    }
}

@Test(.timeLimit(.minutes(1))) func openRouter130CancellationStopsWaitingForBody() async throws {
    let gate = OpenRouter130BodyGate()
    let signal = CancellationToken()
    let operation = Task {
        try await personalizeOpenRouterCatalog([], credential: "key", client: OpenRouter130BodyClient(gate: gate), signal: signal)
    }
    await gate.waitUntilStarted()
    signal.cancel()
    do { _ = try await operation.value; Issue.record("Expected cancellation") }
    catch {
        guard let streamError = error as? StreamError, case .requestAborted = streamError else {
            Issue.record("Expected requestAborted, got \(error)"); await gate.release(); return
        }
    }
    await gate.release()
}

@Test func openRouter130WireTiersSkipPresentNullTimeConditions() async throws {
    let client = OpenRouter130Client(#"{"data":[{"id":"a","pricing":{"prompt":"0.000002","overrides":[{"min_prompt_tokens":100,"completion":"0.000004"},{"min_prompt_tokens":200,"utc_start":null,"prompt":"9"},{"min_prompt_tokens":300,"utc_end":null,"prompt":"9"},{"min_prompt_tokens":400,"utc_days":null,"prompt":"9"}]}}]}"#)
    let result = try await personalizeOpenRouterCatalog([openRouter130Chat("a")], credential: "key", client: client)
    #expect(result[0].catalog.cost.tiers == [
        ModelCostTier(inputTokensAbove: 100, input: 2, output: 4, cacheRead: 0, cacheWrite: 0)
    ])
}
