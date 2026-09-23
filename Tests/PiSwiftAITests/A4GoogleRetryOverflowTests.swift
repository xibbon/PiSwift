import Foundation
import Testing
@testable import PiSwiftAI

private func a4Error(_ text: String, provider: String = "test") -> AssistantMessage {
    AssistantMessage(content: [], api: .openAICompletions, provider: provider, model: "test",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .error, errorMessage: text)
}

@Test func a4RetryClassifiesCloudflareAndAzureLoad() {
    #expect(isRetryableAssistantError(a4Error("520 status code (no body)")))
    #expect(isRetryableAssistantError(a4Error("The system is currently experiencing high demand and cannot process your request")))
    #expect(!isRetryableAssistantError(a4Error("429 quota exceeded")))
}

@Test func a4OverflowScopesBodylessCodesToCerebras() {
    #expect(isContextOverflow(a4Error("400 {\"code\":\"1261\",\"message\":\"Prompt too long\"}", provider: "zai")))
    for code in ["400", "413"] {
        #expect(isContextOverflow(a4Error("\(code) status code (no body)", provider: "cerebras")))
        #expect(!isContextOverflow(a4Error("\(code) status code (no body)", provider: "openai")))
    }
}

@Test func a4AgentRetryDelayCapsAndClamps() {
    #expect(retryDelayMs(policy: RetryPolicy(enabled: true, maxRetries: 6, baseDelayMs: 2_000), attempt: 6) == 60_000)
    #expect(retryDelayMs(policy: RetryPolicy(enabled: true, maxRetries: 6, baseDelayMs: 2_000, maxAgentDelayMs: 5_000), attempt: 5) == 5_000)
    #expect(retryDelayMs(policy: RetryPolicy(enabled: true, maxRetries: 6, baseDelayMs: 2_000, maxAgentDelayMs: 0), attempt: 5) == 0)
    #expect(retryDelayMs(policy: RetryPolicy(enabled: true, maxRetries: 100, baseDelayMs: .greatestFiniteMagnitude,
        maxAgentDelayMs: .greatestFiniteMagnitude), attempt: 100) == 9_007_199_254_740_991)
}

@Test func a4AssistantRetrySchedulesCappedDelay() async {
    let signal = CancellationToken()
    let scheduled = LockedState<Double?>(nil)
    let response = await retryAssistantCall(
        produce: { a4Error("503 service unavailable") },
        policy: RetryPolicy(enabled: true, maxRetries: 1, baseDelayMs: 100_000, maxAgentDelayMs: 5_000),
        signal: signal,
        callbacks: RetryCallbacks(onRetryScheduled: { _, _, delay, _ in
            scheduled.withLock { $0 = delay }
            signal.cancel()
        })
    )
    #expect(scheduled.withLock { $0 } == 5_000)
    #expect(response.stopReason == .aborted)
}

@Test(arguments: [false, true])
func a4GoogleDisabledThinkingUsesSupportedMap(_ vertex: Bool) throws {
    let api: Api = vertex ? .googleVertex : .googleGenerativeAI
    let model = Model(id: "gemini-3.8-flash", name: "Gemini", api: api, provider: "test",
        baseUrl: "https://example.invalid", reasoning: true, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 128_000, maxTokens: 4_096,
        thinkingLevelMap: [.off: nil, .minimal: nil, .low: "low", .medium: "medium", .high: "high", .xhigh: nil, .max: nil])
    let thinking = try buildGoogleThinkingConfigValidated(model: model, options: nil)
    #expect(thinking?.enabled == false)
    #expect(try googleDisabledThinkingConfig(model: model)["thinkingLevel"] as? String == "LOW")
    let medium = try buildGoogleThinkingConfigValidated(model: model,
        options: SimpleStreamOptions(reasoning: .medium))
    #expect(medium?.level == .medium)
    let budgetModel = Model(id: "gemini-2.5-flash", name: "Gemini", api: api, provider: "test",
        baseUrl: "https://example.invalid", reasoning: true, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 128_000, maxTokens: 4_096)
    #expect(try googleDisabledThinkingConfig(model: budgetModel)["thinkingBudget"] as? Int == 0)
}
