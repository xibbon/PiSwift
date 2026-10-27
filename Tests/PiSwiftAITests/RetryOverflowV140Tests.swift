import Foundation
import Testing
@testable import PiSwiftAI

private func v140Failure(_ text: String, provider: String = "test") -> AssistantMessage {
    AssistantMessage(
        content: [], api: .openAIResponses, provider: provider, model: "test",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .error, errorMessage: text
    )
}

@Suite struct RetryOverflowV140Tests {
    // retry.test.ts:82, #10996: node-fetch can omit the reason.
    @Test(arguments: [
        "request to https://oauth2.googleapis.com/token failed, reason:",
        "request to https://oauth2.googleapis.com/token failed, reason: connect ECONNREFUSED 127.0.0.1:9",
    ])
    func nodeFetchRequestFailures(_ text: String) {
        #expect(isRetryableAssistantError(v140Failure(text)))
    }

    // retry.test.ts:90, #10920: gateway response.failed errors.
    @Test(arguments: [
        "unknown: Unable to forward upstream stream",
        "upstream_error: Upstream request failed",
        "upstream_stream_read_error: Upstream response stream was interrupted",
        "Upstream HTTP/2 stream failed",
        "upstream_stream_read_error",
        "stream was interrupted",
        "Upstream HTTP2 stream failed",
        "stream disconnected before completion: stream closed before response.completed",
    ])
    func gatewayAndStreamFailures(_ text: String) {
        #expect(isRetryableAssistantError(v140Failure(text)))
    }

    // retry.test.ts:160, #11057: IDs and byte counts are not HTTP statuses.
    @Test(arguments: [
        #"401 {"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"},"request_id":"req_011CU503xyz"}"#,
        "400 image exceeds 5 MB maximum: 5316784 bytes > 5242880 bytes",
    ])
    func statusDigitsInsideOtherValues(_ text: String) {
        #expect(!isRetryableAssistantError(v140Failure(text)))
    }

    @Test(arguments: ["429", "500", "502", "503", "504", "520", "524"])
    func standaloneStatuses(_ status: String) {
        for text in [status, "HTTP (\(status)): failure", "\(status) status code (no body)"] {
            #expect(isRetryableAssistantError(v140Failure(text)))
        }
        for text in ["idA\(status)", "\(status)xyz", "1\(status)", "\(status)0"] {
            #expect(!isRetryableAssistantError(v140Failure(text)))
        }
    }

    // retry.test.ts:129: the workspace admin must raise this limit.
    @Test func businessWorkspaceLimitIsNotRetryable() {
        let text = #"OpenAI API error (429): {"code":"subscription_sharing_workplace_individual_usage_limit_exceeded","message":"Usage limit reached."}"#
        #expect(!isRetryableAssistantError(v140Failure(text)))
    }

    @Test(arguments: [
        "429 quota exceeded",
        "503 insufficient_quota upstream request failed",
        "stream disconnected before completion: billing limit",
        "upstream_stream_read_error: subscription_sharing_workplace_individual_usage_limit_exceeded",
        "request to https://example.invalid failed, reason: out of budget",
    ])
    func accountLimitsTakePrecedence(_ text: String) {
        #expect(!isRetryableAssistantError(v140Failure(text)))
    }

    @Test(arguments: [
        "subscription_sharing_usage_unavailable: Usage cannot be checked.",
        "subscription_sharing_user_unavailable: User cannot be loaded.",
    ])
    func temporarySubscriptionErrorsRemainRetryable(_ text: String) {
        #expect(isRetryableAssistantError(v140Failure(text)))
        #expect(chatGPTUsageLimitMessage(text) == text)
    }

    // overflow.test.ts:35: request bytes can exceed the limit with zero token usage.
    @Test(arguments: [
        #"github-copilot API error (413): {"message":"failed to parse request","code":""}"#,
        "custom-provider API error (413): Payload Too Large",
        #"413 {"error":{"message":"failed to parse request","code":""}}"#,
        "413",
        "413: Payload Too Large",
    ])
    func providerIndependentRequestSizeOverflow(_ text: String) {
        #expect(isContextOverflow(v140Failure(text), contextWindow: 1_000_000))
        #expect(isContextOverflow(v140Failure(text)))
    }

    // overflow.test.ts:47: only a leading HTTP 413 can match the status pattern.
    @Test(arguments: [
        #"github-copilot API error (400): {"message":"failed to parse request","code":""}"#,
        "custom-provider API error (429): Too many requests",
        #"github-copilot API error (400): {"message":"failed to parse request: invalid value 413"}"#,
        "custom-provider API error (400): upstream mentioned OpenAI API error (413): invalid input",
        "custom-provider API error (4130): invalid input",
        "4130 failed to parse request",
    ])
    func unrelatedErrorsAreNotRequestSizeOverflow(_ text: String) {
        #expect(!isContextOverflow(v140Failure(text)))
    }

    // overflow.test.ts:56: error text applies to failed responses only.
    @Test func requestSizeStatusRequiresFailure() {
        var message = v140Failure(#"OpenAI API error (413): {"message":"failed to parse request"}"#)
        for reason in [StopReason.aborted, .stop, .length, .toolUse] {
            message.stopReason = reason
            #expect(!isContextOverflow(message))
        }
    }

    @Test(arguments: [
        "413: rate limit",
        "custom-provider API error (413): Too many requests",
        "Throttling error: Too many tokens",
        "Service unavailable: Too many tokens",
    ])
    func overflowExclusionsTakePrecedence(_ text: String) {
        #expect(!isContextOverflow(v140Failure(text)))
    }
}
