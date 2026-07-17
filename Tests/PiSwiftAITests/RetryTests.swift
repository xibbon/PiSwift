import Foundation
import Testing
@testable import PiSwiftAI

private func retryTestMessage(
    _ errorMessage: String?,
    stopReason: StopReason = .error
) -> AssistantMessage {
    AssistantMessage(
        content: [],
        api: .openAIResponses,
        provider: KnownProvider.openai.rawValue,
        model: "test-model",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: stopReason,
        errorMessage: errorMessage
    )
}

@Test func retryableAssistantErrorMatchesUpstreamProviderAndTransportFailures() {
    let messages = [
        "overloaded_error",
        "524 status code (no body)",
        "The socket connection was closed unexpectedly.",
        "The operation couldn’t be completed. Socket is not connected",
        "NSPOSIXErrorDomain Code=57 (ENOTCONN)",
        "Anthropic stream ended before message_stop",
        "ResourceExhausted: Worker local total request limit reached",
        "The system encountered an unexpected error. Try your request again.",
    ]

    for errorMessage in messages {
        #expect(isRetryableAssistantError(retryTestMessage(errorMessage)))
    }
}

@Test func retryableAssistantErrorKeepsProviderLimitsNonRetryable() {
    let messages = [
        "429 quota exceeded",
        "429 insufficient_quota",
        "GoUsageLimitError: Monthly usage limit reached",
        "FreeUsageLimitError: enable available balance",
        "Account is out of budget",
        "Billing limit reached",
    ]

    for errorMessage in messages {
        #expect(!isRetryableAssistantError(retryTestMessage(errorMessage)))
    }
}

@Test func retryableAssistantErrorRequiresFailedAssistantMessage() {
    #expect(!isRetryableAssistantError(retryTestMessage(nil)))
    #expect(!isRetryableAssistantError(retryTestMessage("rate limit", stopReason: .stop)))
}

@Test func retryableTransportErrorRecognizesDirectAndUnderlyingENOTCONN() {
    let notConnected = NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(POSIXErrorCode.ENOTCONN.rawValue)
    )
    let wrapper = NSError(
        domain: "PiSwiftAITests.Wrapper",
        code: 1,
        userInfo: [NSUnderlyingErrorKey: notConnected]
    )

    #expect(isRetryableTransportError(notConnected))
    #expect(isRetryableTransportError(wrapper))

    let flattenedDescription = retryAwareErrorDescription(wrapper)
    #expect(flattenedDescription.hasPrefix("Network error: "))
    #expect(isRetryableAssistantError(retryTestMessage(flattenedDescription)))
}

@Test func retryableTransportErrorRecognizesURLErrorCodesAndTextFallback() {
    let connectionLost = NSError(
        domain: NSURLErrorDomain,
        code: URLError.networkConnectionLost.rawValue
    )
    let socketText = NSError(
        domain: "PiSwiftAITests.TextOnly",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Socket is not connected"]
    )
    let permissionDenied = NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(POSIXErrorCode.EACCES.rawValue)
    )

    #expect(isRetryableTransportError(connectionLost))
    #expect(isRetryableTransportError(socketText))
    #expect(!isRetryableTransportError(permissionDenied))
}
