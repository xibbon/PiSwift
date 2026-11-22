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

// retry.test.ts: "matches Node socket error codes: %s"
@Test(arguments: ["read ECONNRESET", "connect ETIMEDOUT 140.82.113.3:443", "write EPIPE",
                  "connect ECONNREFUSED 127.0.0.1:443", "ECONNABORTED", "Connection reset by peer"])
func matchesNodeSocketErrorCodes(_ text: String) {
    #expect(isRetryableAssistantError(retryTestMessage(text)))
}

// retry.test.ts: "does not match socket error codes inside longer identifiers: %s"
@Test(arguments: ["Invalid value EXECONNRESET", "Unknown field ETIMEDOUTX", "Invalid key ERR_EPIPE_ID"])
func doesNotMatchSocketCodesInsideLongerIdentifiers(_ text: String) {
    #expect(!isRetryableAssistantError(retryTestMessage(text)))
}

// retry.test.ts: "matches gateway wording for a closed connection"
@Test func matchesGatewayWordingForClosedConnection() {
    #expect(isRetryableAssistantError(retryTestMessage(#"{"type":"error","error":{"type":"api_error","message":"Connection closed."}}"#)))
}

// retry.test.ts: "matches the Codex websocket connection lifetime limit: %s"
@Test(arguments: ["Codex error: Responses websocket connection limit reached (60 minutes). Create a new websocket connection to continue.",
                  "Codex error: websocket_connection_limit_reached"])
func matchesCodexWebsocketConnectionLifetimeLimit(_ text: String) {
    #expect(isRetryableAssistantError(retryTestMessage(text)))
}

// retry.test.ts: "does not match a generic connection limit"
@Test func doesNotMatchGenericConnectionLimit() {
    #expect(!isRetryableAssistantError(retryTestMessage("connection limit reached")))
}

@Test(arguments: [POSIXErrorCode.ECONNRESET, .ECONNABORTED, .ECONNREFUSED, .ETIMEDOUT, .EPIPE, .ENOTCONN])
func structuredSocketCodesMatchTransportErrors(_ code: POSIXErrorCode) {
    #expect(isRetryableTransportError(POSIXError(code)))
    #expect(retryAwareErrorDescription(POSIXError(code)).hasPrefix("Network error: "))
}

@Test(arguments: [URLError.timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet])
func structuredURLErrorCodesMatchTransportErrors(_ code: URLError.Code) {
    #expect(isRetryableTransportError(URLError(code)))
    #expect(retryAwareErrorDescription(URLError(code)).hasPrefix("Network error: "))
}

private struct SocketTextError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

@Test func boundedSocketTextAlsoMatchesThrownTransportErrors() {
    #expect(isRetryableTransportError(SocketTextError(text: "read ECONNRESET")))
    #expect(!isRetryableTransportError(SocketTextError(text: "Invalid value EXECONNRESET")))
    #expect(isRetryableTransportError(SocketTextError(text: "Connection closed.")))
    #expect(isRetryableTransportError(SocketTextError(text: "websocket_connection_limit_reached")))
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
