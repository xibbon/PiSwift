import Foundation
import Testing
@testable import PiSwiftAI

@Test func copilotCatalogSelectsOnlyAccountPolicies() throws {
    let ids = getModels(provider: .githubCopilot).map(\.id).sorted()
    #expect(ids.count >= 3)
    let catalog = try parseGitHubCopilotModelCatalog(["data": [
        ["id": ids[0], "model_picker_enabled": true, "policy": ["state": "enabled"]],
        ["id": ids[1], "model_picker_enabled": true, "policy": ["state": "unconfigured"]],
        ["id": "remote-only", "model_picker_enabled": true, "policy": ["state": "unconfigured"]],
        ["id": ids[2], "model_picker_enabled": true, "policy": ["state": "unconfigured"], "capabilities": ["supports": ["tool_calls": false]]],
        ["id": "disabled", "model_picker_enabled": true, "policy": ["state": "disabled"]],
    ]], allowPolicyFallback: true)
    #expect(catalog.availableModelIds == [ids[0], ids[1], "remote-only"])
    #expect(catalog.policyModelIds == [ids[1]])
}

@Test(arguments: [true, false])
func copilotCatalogFallbackIsIndividualOnly(_ individual: Bool) throws {
    let known = try #require(getModels(provider: .githubCopilot).first?.id)
    let catalog = try parseGitHubCopilotModelCatalog(["data": [
        ["id": "enabled", "model_picker_enabled": false, "policy": ["state": "enabled"]],
        ["id": known, "model_picker_enabled": false, "policy": ["state": "unconfigured"]],
    ]], allowPolicyFallback: individual)
    #expect(catalog.availableModelIds == (individual ? ["enabled"] : []))
    #expect(catalog.policyModelIds == (individual ? [known] : []))
}

private actor CopilotRetryState {
    var attempts = 0
    var delays: [Double] = []
    var timeouts: [Int] = []
    var modelIds: [String] = []
    func response(timeout: Int, successAfter: Int, retryAfter: String? = nil, status: Int = 429) -> OAuthNetworkResponse {
        attempts += 1
        timeouts.append(timeout)
        return OAuthNetworkResponse(data: Data(), status: attempts >= successAfter ? 200 : status,
            headers: retryAfter.map { ["Retry-After": $0] } ?? [:])
    }
    func sleep(_ delay: Double) { delays.append(delay) }
    func enable(_ id: String, throwsOn: String? = nil, failsOn: String? = nil) throws -> Bool {
        modelIds.append(id)
        if id == throwsOn { throw OAuthError.refreshFailed("429") }
        return id != failsOn
    }
}

@Test func copilotRefreshDoesNotRetryCatalogThrottle() async throws {
    let state = CopilotRetryState()
    let response = try await copilotRateLimitRetry(signal: nil, maxRetries: 0, maxElapsedMs: 0,
        sleep: { delay, _ in await state.sleep(delay) },
        request: { await state.response(timeout: $0, successAfter: 99, retryAfter: "0") })
    #expect(response.status == 429)
    #expect(await state.attempts == 1)
    #expect(await state.delays == [])
    #expect(await state.timeouts == [5000])
}

@Test func copilotPolicyRetriesAfterServerDelay() async throws {
    let state = CopilotRetryState()
    let response = try await copilotRateLimitRetry(signal: nil, maxRetries: 2, maxElapsedMs: 5000,
        now: { 0 }, sleep: { delay, _ in await state.sleep(delay) },
        request: { await state.response(timeout: $0, successAfter: 2, retryAfter: "1") })
    #expect(response.status == 200)
    #expect(await state.attempts == 2)
    #expect(await state.delays == [1000])
}

@Test func copilotStopsWhenRetryExceedsBudget() async throws {
    let state = CopilotRetryState()
    let response = try await copilotRateLimitRetry(signal: nil, maxRetries: 2, maxElapsedMs: 5000,
        now: { 0 }, sleep: { delay, _ in await state.sleep(delay) },
        request: { await state.response(timeout: $0, successAfter: 99, retryAfter: "5") })
    #expect(response.status == 429)
    #expect(await state.attempts == 1)
    #expect(await state.delays == [])
}

@Test func copilotLimitsRetriesAndUsesExponentialDelay() async throws {
    let state = CopilotRetryState()
    let response = try await copilotRateLimitRetry(signal: nil, maxRetries: 2, maxElapsedMs: 5000,
        now: { 0 }, sleep: { delay, _ in await state.sleep(delay) },
        request: { await state.response(timeout: $0, successAfter: 99) })
    #expect(response.status == 429)
    #expect(await state.attempts == 3)
    #expect(await state.delays == [500, 1000])
}

@Test func copilotDoesNotRetryOtherStatuses() async throws {
    let state = CopilotRetryState()
    let response = try await copilotRateLimitRetry(signal: nil, maxRetries: 2, maxElapsedMs: 5000,
        request: { await state.response(timeout: $0, successAfter: 99, status: 500) })
    #expect(response.status == 500)
    #expect(await state.attempts == 1)
}

@Test func copilotPolicyBatchIsSequentialAndStopsOnRateLimit() async throws {
    let state = CopilotRetryState()
    let enabled = try await enableGitHubCopilotModels(["one", "two", "three", "four"], signal: nil) {
        try await state.enable($0, throwsOn: "three", failsOn: "one")
    }
    #expect(enabled == ["two"])
    #expect(await state.modelIds == ["one", "two", "three"])
}

@Test func copilotRetryDelayParsesSecondsDatesAndInvalidValues() {
    #expect(copilotRetryDelayMs(retryAfter: "1.5", retry: 0, now: 0) == 1500)
    #expect(copilotRetryDelayMs(retryAfter: "-5", retry: 0, now: 0) == 0)
    #expect(copilotRetryDelayMs(retryAfter: "1 trailing", retry: 0, now: 0) == 1000)
    #expect(copilotRetryDelayMs(retryAfter: "Thu, 01 Jan 1970 00:00:02 GMT", retry: 0, now: 0) == 2000)
    #expect(copilotRetryDelayMs(retryAfter: "invalid", retry: 0, now: 0) == nil)
    #expect(copilotRetryDelayMs(retryAfter: "Infinity", retry: 0, now: 0) == nil)
}

@Test func copilotRetryPropagatesCancellation() async {
    let signal = CancellationToken()
    signal.cancel()
    await #expect(throws: OAuthError.self) {
        _ = try await copilotRateLimitRetry(signal: signal, maxRetries: 2, maxElapsedMs: 5000,
            request: { _ in Issue.record("Request must not run"); return OAuthNetworkResponse(data: Data(), status: 200) })
    }
}
