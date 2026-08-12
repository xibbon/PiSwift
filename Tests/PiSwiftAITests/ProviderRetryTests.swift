import Foundation
import Testing
@testable import PiSwiftAI

private struct RetryTestHTTPClient: ProviderHTTPClient {
    let sendHandler: @Sendable (URLRequest) async throws -> ProviderHTTPResponse

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        try await sendHandler(request)
    }
}

private func providerTestError(
    statusCode: Int,
    headers: [String: String] = [:],
    message: String = "provider failed"
) -> StreamError {
    .providerRequest(statusCode: statusCode, headers: headers, message: message)
}

@Test func abortableSleepReturnsPromptlyWhenCancelled() async {
    let token = CancellationToken()
    let started = Date()
    let task = Task {
        try await abortableSleep(ms: 5_000, signal: token)
    }

    try? await Task.sleep(for: .milliseconds(30))
    token.cancel()

    do {
        try await task.value
        #expect(Bool(false), "Expected cancellation")
    } catch {
        #expect(error.localizedDescription.contains("aborted"))
    }
    #expect(Date().timeIntervalSince(started) < 0.5)
}

@Test func providerRetryDelayHonorsCapAndServerHeaders() throws {
    // The fallback backoff is bounded at 8s by its own formula and is deliberately NOT clamped by
    // `maxRetryDelayMs`, which governs only server-requested delays (upstream provider-retry.ts).
    let fallback = try getRetryDelayMs(
        error: providerTestError(statusCode: 503),
        retryIndex: 8,
        maxRetryDelayMs: 125
    )
    #expect(fallback > 125)
    #expect(fallback >= 6_000 && fallback <= 8_000)

    let validServerDelay = try getRetryDelayMs(
        error: providerTestError(statusCode: 429, headers: ["Retry-After-Ms": "40"]),
        retryIndex: 0,
        maxRetryDelayMs: 100
    )
    #expect(validServerDelay == 40)

    let invalidServerDelay = try getRetryDelayMs(
        error: providerTestError(statusCode: 429, headers: ["retry-after-ms": "NaN"]),
        retryIndex: 0,
        maxRetryDelayMs: 100
    )
    // An unparseable server delay falls back to the exponential backoff, which the cap does not clamp.
    #expect(invalidServerDelay >= 0)
    #expect(invalidServerDelay <= 8_000)

    do {
        _ = try getRetryDelayMs(
            error: providerTestError(
                statusCode: 429,
                headers: ["retry-after-ms": "120000"],
                message: "slow down"
            ),
            retryIndex: 0,
            maxRetryDelayMs: 60_000
        )
        #expect(Bool(false), "Expected an excessive-delay error")
    } catch {
        #expect(error.localizedDescription.contains("120s"))
        #expect(error.localizedDescription.contains("slow down"))
    }
}

@Test func providerRetryDriverRetriesTransientFailureAndStopsAtLimit() async throws {
    let attempts = LockedState(0)
    let value: String = try await retryProviderRequest(
        maxRetries: 2,
        maxRetryDelayMs: 5
    ) {
        let attempt = attempts.withLock { value -> Int in
            value += 1
            return value
        }
        if attempt < 3 {
            throw providerTestError(statusCode: 503, headers: ["retry-after-ms": "1"])
        }
        return "ok"
    }
    #expect(value == "ok")
    #expect(attempts.withLock { $0 } == 3)

    let exhaustedAttempts = LockedState(0)
    do {
        let _: String = try await retryProviderRequest(
            maxRetries: 2,
            maxRetryDelayMs: 5
        ) {
            exhaustedAttempts.withLock { $0 += 1 }
            throw providerTestError(statusCode: 503, headers: ["retry-after-ms": "1"])
        }
        #expect(Bool(false), "Expected retries to be exhausted")
    } catch {
        #expect(exhaustedAttempts.withLock { $0 } == 3)
    }
}

@Test func providerRetryDriverCancellationStopsMidBackoff() async {
    let token = CancellationToken()
    let attempts = LockedState(0)
    let task = Task {
        let _: String = try await retryProviderRequest(
            maxRetries: 4,
            maxRetryDelayMs: 10_000,
            signal: token
        ) {
            attempts.withLock { $0 += 1 }
            throw providerTestError(statusCode: 503, headers: ["retry-after-ms": "5000"])
        }
    }

    try? await Task.sleep(for: .milliseconds(30))
    token.cancel()
    do {
        try await task.value
        #expect(Bool(false), "Expected cancellation")
    } catch {
        #expect(error.localizedDescription.contains("aborted"))
    }
    #expect(attempts.withLock { $0 } == 1)
}

@Test func providerRetryDriverDoesNotRetryAuthenticationFailure() async {
    let attempts = LockedState(0)
    do {
        let _: String = try await retryProviderRequest(maxRetries: 3, maxRetryDelayMs: 1) {
            attempts.withLock { $0 += 1 }
            throw providerTestError(statusCode: 401, message: "invalid api key")
        }
        #expect(Bool(false), "Expected authentication failure")
    } catch {
        #expect(attempts.withLock { $0 } == 1)
    }
}

@Test func retryClassifiesTextualDNSFailures() {
    for message in [
        "getaddrinfo failed for provider.example",
        "connect ENOTFOUND provider.example",
        "lookup failed: EAI_AGAIN",
    ] {
        let error = StreamError.providerRequest(statusCode: nil, headers: nil, message: message)
        #expect(isRetryableTransportError(error))
        let assistant = AssistantMessage(
            content: [],
            api: .openAIResponses,
            provider: "test",
            model: "test",
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
            stopReason: .error,
            errorMessage: message
        )
        #expect(isRetryableAssistantError(assistant))
    }
}

@Test func imageTransportInjectionUsesCustomClientResponse() async {
    let requests = LockedState<[URLRequest]>([])
    let body = Data(#"{"id":"custom-response","choices":[{"message":{"content":"from custom client"}}]}"#.utf8)
    let client = RetryTestHTTPClient { request in
        requests.withLock { $0.append(request) }
        return ProviderHTTPResponse(
            statusCode: 200,
            headers: ["x-custom-client": "yes"],
            body: body
        )
    }
    let responseStatus = LockedState<Int?>(nil)
    let model = getImageModel(provider: .openrouter, modelId: "google/gemini-3-pro-image-preview")
    let result = await generateImages(
        model: model,
        context: ImagesContext(input: [.text(TextContent(text: "draw"))]),
        options: ImagesOptions(
            apiKey: "test-key",
            httpClient: client,
            onResponse: { snapshot in responseStatus.withLock { $0 = snapshot.statusCode } }
        )
    )

    #expect(requests.withLock { $0.count } == 1)
    #expect(requests.withLock { $0.first?.url?.host } == "openrouter.ai")
    #expect(responseStatus.withLock { $0 } == 200)
    #expect(result.responseId == "custom-response")
    #expect(result.output.contains { block in
        if case .text(let text) = block { return text.text == "from custom client" }
        return false
    })
}

@Test func openAICompletionsRetriesInjectedTransportBeforeStreaming() async {
    let attempts = LockedState(0)
    let sse = Data(
        "data: {\"id\":\"chatcmpl-retry\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":\"retry-test\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\n".utf8
    )
    let client = RetryTestHTTPClient { _ in
        let attempt = attempts.withLock { value -> Int in
            value += 1
            return value
        }
        if attempt == 1 {
            return ProviderHTTPResponse(
                statusCode: 503,
                headers: ["retry-after-ms": "1"],
                body: Data("try again".utf8)
            )
        }
        return ProviderHTTPResponse(statusCode: 200, body: sse)
    }
    let model = Model(
        id: "retry-test",
        name: "Retry Test",
        api: .openAICompletions,
        provider: "retry-test",
        baseUrl: "https://retry.example/v1",
        reasoning: false,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 8_192,
        maxTokens: 1_024
    )
    let stream = streamOpenAICompletions(
        model: model,
        context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
        options: OpenAICompletionsOptions(
            apiKey: "test-key",
            httpClient: client,
            maxRetries: 1,
            maxRetryDelayMs: 10
        )
    )
    let result = await stream.result()

    #expect(attempts.withLock { $0 } == 2)
    #expect(result.stopReason == .stop)
    #expect(result.content.contains { block in
        if case .text(let text) = block { return text.text == "ok" }
        return false
    })
}

@Test func googleAdapterRejectsCustomHTTPClient() {
    let client = RetryTestHTTPClient { _ in
        ProviderHTTPResponse(statusCode: 200, body: Data())
    }
    let model = getModel(provider: .google, modelId: "gemini-3.1-pro-preview")
    do {
        _ = try stream(
            model: model,
            context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
            options: StreamOptions(apiKey: "test-key", httpClient: client)
        )
        #expect(Bool(false), "Expected custom-client rejection")
    } catch {
        #expect(error.localizedDescription.contains("Google Generative AI"))
        #expect(error.localizedDescription.contains("custom HTTP client"))
    }
}

@Test func imagesOptionsDefaultHTTPClientRemainsUnset() {
    #expect(ImagesOptions().httpClient == nil)
    #expect(StreamOptions().httpClient == nil)
}
