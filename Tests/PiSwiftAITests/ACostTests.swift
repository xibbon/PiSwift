import Foundation
import Testing
@testable import PiSwiftAI

private func costUsage() -> Usage {
    Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2,
          cost: UsageCost(input: 0.25, output: 0.75, total: 1))
}

@Test("recognizes both the built-in provider and custom providers using OpenRouter's endpoint")
func openRouterCostRecognizesEndpoint() {
    #expect(isOpenRouterModel(provider: "openrouter", baseUrl: "https://example.com"))
    #expect(isOpenRouterModel(provider: "openrouter-work", baseUrl: "https://openrouter.ai/api/v1"))
    #expect(!isOpenRouterModel(provider: "custom", baseUrl: "https://example.com/v1"))
}

@Test("uses OpenRouter's reported cost for non-BYOK requests")
func openRouterCostNonBYOK() {
    var usage = costUsage()
    applyOpenRouterReportedCost(.init(cost: 0, isBYOK: false, costDetails: .init(upstreamInferenceCost: 0)), usage: &usage)
    #expect(usage.cost.total == 0)
    #expect(usage.cost.totalFromProvider == true)
    #expect(usage.cost.input == 0.25)
}

@Test("adds the upstream inference cost for BYOK requests")
func openRouterCostBYOK() {
    var usage = costUsage()
    applyOpenRouterReportedCost(.init(cost: 0.1, isBYOK: true,
        costDetails: .init(upstreamInferenceCost: 0.9, upstreamInferencePromptCost: 0.6,
                           upstreamInferenceCompletionsCost: 0.3)), usage: &usage)
    #expect(usage.cost.total == 1)
    #expect(usage.cost.totalFromProvider == true)
}

@Test("uses upstream cost components when OpenRouter omits their total")
func openRouterCostBYOKComponents() {
    var usage = costUsage()
    applyOpenRouterReportedCost(.init(cost: 0.1, isBYOK: true,
        costDetails: .init(upstreamInferencePromptCost: 0.6, upstreamInferenceCompletionsCost: 0.3)), usage: &usage)
    #expect(abs(usage.cost.total - 1) < 0.0000001)
    #expect(usage.cost.totalFromProvider == true)
}

@Test("keeps the catalog total when OpenRouter's accounting is incomplete")
func openRouterCostIncomplete() {
    var usage = costUsage()
    usage.cost.totalFromProvider = false
    for accounting in [
        OpenRouterUsageAccounting(cost: nil, isBYOK: false, costDetails: nil),
        OpenRouterUsageAccounting(cost: 0.1, isBYOK: true, costDetails: nil),
        OpenRouterUsageAccounting(cost: -1, isBYOK: false, costDetails: nil),
        OpenRouterUsageAccounting(cost: .infinity, isBYOK: false, costDetails: nil),
        OpenRouterUsageAccounting(cost: 0.1, isBYOK: true,
            costDetails: .init(upstreamInferenceCost: -0.9))
    ] {
        applyOpenRouterReportedCost(accounting, usage: &usage)
    }
    #expect(usage.cost.total == 1)
    #expect(usage.cost.totalFromProvider == false)
}

private struct CostCompletionsClient: ProviderHTTPClient {
    let usage: String
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        let frame = #"{"id":"chatcmpl-cost","object":"chat.completion.chunk","created":0,"model":"cost-test","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}],"usage":\#(usage)}"#
        return ProviderHTTPResponse(statusCode: 200, body: Data("data: \(frame)\n\n".utf8))
    }
}

@Test("OpenRouter completion stream applies reported billing after catalog pricing", arguments: [false, true])
func openRouterCompletionBilledUsage(byok: Bool) async {
    let accounting = byok
        ? #"{"prompt_tokens":100,"completion_tokens":50,"cost":0.1,"is_byok":true,"cost_details":{"upstream_inference_cost":0.9,"upstream_inference_prompt_cost":0.6,"upstream_inference_completions_cost":0.3}}"#
        : #"{"prompt_tokens":100,"completion_tokens":50,"cost":0.1,"is_byok":false}"#
    let model = Model(id: "cost-test", name: "Cost", api: .openAICompletions,
        provider: "openrouter", baseUrl: "https://openrouter.ai/api/v1", reasoning: false,
        input: [.text], cost: ModelCost(input: 1, output: 2, cacheRead: 0, cacheWrite: 0),
        contextWindow: 1024, maxTokens: 128)
    let result = await streamOpenAICompletions(model: model,
        context: normalizeContext(Context(messages: [.user(UserMessage(content: .text("Hi")))])),
        options: OpenAICompletionsOptions(apiKey: "secret", httpClient: CostCompletionsClient(usage: accounting))).result()
    #expect(result.stopReason == .stop)
    #expect(result.usage.cost.total == (byok ? 1 : 0.1))
    #expect(result.usage.cost.totalFromProvider == true)
    #expect(abs(result.usage.cost.input - 0.0001) < 0.000000001)
    #expect(abs(result.usage.cost.output - 0.0001) < 0.000000001)
}

@Test("marks catalog-derived totals as not provider-reported")
func catalogCostResetsProvenance() {
    let model = getModel(provider: .openrouter, modelId: "openai/gpt-6.1-sol")
    var usage = costUsage()
    usage.cost.total = 9
    usage.cost.totalFromProvider = nil
    calculateCost(model: model, usage: &usage)
    #expect(usage.cost.totalFromProvider == false)
    let estimate = usage.cost.total
    usage.cost.total = 0.12
    usage.cost.totalFromProvider = true
    // As upstream models.ts:1297-1298: a later calculateCost replaces a billed total by the estimate.
    calculateCost(model: model, usage: &usage)
    #expect(usage.cost.total == estimate)
    #expect(usage.cost.totalFromProvider == false)
    #expect(estimate != 0.12)
}

@Test func usageCostJSONRoundTripAndOldFile() throws {
    var usage = costUsage()
    usage.cost.totalFromProvider = true
    let json = usageToJSONObject(usage)
    let data = try JSONSerialization.data(withJSONObject: json)
    let parsed = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect((parsed["cost"] as? [String: Any])?["totalFromProvider"] as? Bool == true)
    #expect(usageFromJSONObject(parsed).cost.totalFromProvider == true)
    var old = parsed
    var oldCost = try #require(old["cost"] as? [String: Any])
    oldCost.removeValue(forKey: "totalFromProvider")
    old["cost"] = oldCost
    #expect(usageFromJSONObject(old).cost.totalFromProvider == nil)
}

@Test func trustedOAuthHTTPURLVectors() {
    #expect(trustedOAuthHttpURL("https://github.com/login/device") == "https://github.com/login/device")
    #expect(trustedOAuthHttpURL("http://localhost:8080/verify") == "http://localhost:8080/verify")
    #expect(trustedOAuthHttpURL("HTTPS://EXAMPLE.COM:443") == "https://example.com/")
    for value in ["file:///tmp/code", "javascript:alert(1)", "$(id>/tmp/pwned)", "", "custom:action"] {
        #expect(trustedOAuthHttpURL(value) == nil)
    }
    #expect(trustedOAuthHttpURL(7) == nil)
    #expect(trustedOAuthHttpURL("https://github.com/login/\u{1b}]8;;evil") ==
            "https://github.com/login/%1B%5D8;;evil")
    let info = OAuthDeviceCodeInfo(userCode: "ABCD", verificationUri: "https://example.com",
                                   openBrowserOnConfirm: false, copyCodeOnConfirm: false)
    #expect(!info.openBrowserOnConfirm && !info.copyCodeOnConfirm)
    let defaults = OAuthDeviceCodeInfo(userCode: "ABCD", verificationUri: "https://example.com")
    #expect(defaults.openBrowserOnConfirm && defaults.copyCodeOnConfirm)
}

@Test func deviceCodeFlagsReachHostCallbackUnchanged() async {
    let received = LockedState<OAuthDeviceCodeInfo?>(nil)
    let callbacks = OAuthLoginCallbacks(onAuth: { _ in Issue.record("Unexpected auth URL callback") },
        onPrompt: { _ in "" }, onDeviceCode: { info in received.withLock { $0 = info } })
    await notifyDeviceCode(OAuthDeviceCodeInfo(userCode: "ABCD", verificationUri: "https://example.com",
        openBrowserOnConfirm: false, copyCodeOnConfirm: false), callbacks: callbacks)
    #expect(received.withLock { $0?.openBrowserOnConfirm } == false)
    #expect(received.withLock { $0?.copyCodeOnConfirm } == false)
}

@Test("rejects a non-http(s) verification_uri before it reaches onDeviceCode")
func copilotRejectsUntrustedDeviceURL() async throws {
    try await codexRequestLock.withLock {
        MockURLProtocol.allowedHosts.withLock { $0 = ["github.com"] }
        MockURLProtocol.requestHandler.withLock { $0 = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["content-type": "application/json"])!
            return (response, Data(#"{"device_code":"device","user_code":"ABCD","verification_uri":"$(id>/tmp/pwned)","interval":1,"expires_in":60}"#.utf8))
        } }
        URLProtocol.registerClass(MockURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(MockURLProtocol.self)
            MockURLProtocol.allowedHosts.withLock { $0 = [] }
            MockURLProtocol.requestHandler.withLock { $0 = nil }
        }
        let notified = LockedState(false)
        do {
            _ = try await loginGitHubCopilot(OAuthLoginCallbacks(onAuth: { _ in notified.withLock { $0 = true } },
                onPrompt: { _ in "" }, onDeviceCode: { _ in notified.withLock { $0 = true } }))
            Issue.record("Expected the untrusted URL to be rejected")
        } catch {
            #expect(error.localizedDescription.contains("Untrusted verification_uri"))
        }
        #expect(!notified.withLock { $0 })
    }
}

@Test("normalizes verification_uri before it reaches onDeviceCode")
func copilotNormalizesDeviceURL() async throws {
    try await codexRequestLock.withLock {
        MockURLProtocol.allowedHosts.withLock { $0 = ["github.com"] }
        MockURLProtocol.requestHandler.withLock { $0 = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["content-type": "application/json"])!
            return (response, Data(#"{"device_code":"device","user_code":"ABCD","verification_uri":"https://github.com/login/\u001b]8;;evil","interval":1,"expires_in":60}"#.utf8))
        } }
        URLProtocol.registerClass(MockURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(MockURLProtocol.self)
            MockURLProtocol.allowedHosts.withLock { $0 = [] }
            MockURLProtocol.requestHandler.withLock { $0 = nil }
        }
        let signal = CancellationToken()
        let received = LockedState<String?>(nil)
        do {
            _ = try await loginGitHubCopilot(OAuthLoginCallbacks(onAuth: { _ in Issue.record("Unexpected auth URL callback") },
                onPrompt: { _ in "" }, onDeviceCode: { info in
                    received.withLock { $0 = info.verificationUri }
                    signal.cancel()
                }, signal: signal))
        } catch {
            #expect(signal.isCancelled)
        }
        #expect(received.withLock { $0 } == "https://github.com/login/%1B%5D8;;evil")
    }
}

private actor CopilotClassifierClient: ProviderHTTPClient {
    var request: URLRequest?
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        self.request = request
        return ProviderHTTPResponse(statusCode: 200, headers: [:],
            body: Data(#"{"answers":{"approved":{"type":"noul","noul":0.8}}}"#.utf8))
    }
    func captured() -> URLRequest? { request }
}

@Test("adds the System One version prefix to the GitHub Copilot catalog base URL")
func copilotClassifierDirectURL() async throws {
    let model = try #require(getClassifierModel(provider: "github-copilot", modelId: "microsoft-decision-1"))
    let client = CopilotClassifierClient()
    let result = await classify(model: model, context: ClassifierContext(state: [:], questions: [
        "approved": .bool(instructions: "Approved?", trueCriterion: "Yes", falseCriterion: "No")
    ]), options: ClassifierOptions(apiKey: "copilot-token", httpClient: client))
    #expect(result.stopReason == .stop)
    let request = try #require(await client.captured())
    #expect(request.url?.absoluteString == "https://api.individual.githubcopilot.com/v1/systemone")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer copilot-token")
    #expect(request.value(forHTTPHeaderField: "Editor-Version") == "vscode/1.107.0")
}
