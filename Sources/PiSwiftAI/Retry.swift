import Foundation

private let nonRetryableProviderLimitErrorPatterns = [
    // OpenCode Go/free-tier limits returned as 429 JSON error types by OpenCode's
    // Zen API. These are subscription/account limits, not transient throttles.
    "GoUsageLimitError",
    "FreeUsageLimitError",

    // OpenCode Go subscription-limit text asks users to enable available-balance
    // usage after rolling/weekly/monthly limits are reached.
    "Monthly usage limit reached",
    "available balance",

    // Generic quota/budget/billing exhaustion. `insufficient_quota` is OpenAI's
    // quota/billing error code; the other strings cover common gateway wording.
    "insufficient_quota",
    "out of budget",
    "quota exceeded",
    "billing",
]

private let retryableProviderErrorPatterns = [
    // Generic provider load, HTTP status, and server-side transient failures.
    "overloaded",
    "rate.?limit",
    "too many requests",
    "429",
    "500",
    "502",
    "503",
    "504",
    "524",
    "service.?unavailable",
    "server.?error",
    "internal.?error",

    // Wrapper/provider text for transient upstream failures.
    "provider.?returned.?error",

    // Network, proxy, and fetch transport failures.
    "network.?error",
    "connection.?error",
    "connection.?refused",
    "connection.?lost",
    "other side closed",
    "fetch failed",
    "upstream.?connect",
    "reset before headers",
    "socket hang up",
    "socket connection was closed",
    // Foundation can surface POSIX ENOTCONN as "Socket is not connected".
    "socket is not connected",
    "enotconn",
    "timed? out",
    "timeout",
    "terminated",

    // WebSocket transports can report close/error text instead of HTTP/fetch text.
    "websocket.?closed",
    "websocket.?error",

    // Premature stream endings from SDKs and transports.
    "ended without",
    "stream ended before message_stop",
    "http2 request did not get a response",
    "http/2 request did not get a response",

    // Provider-requested retry delay cap failures should flow through the outer
    // retry policy so callers can surface or abort the backoff.
    "retry delay",

    // Explicit retry guidance emitted mid-stream by providers.
    "you can retry your request",
    "try your request again",
    "please retry your request",

    // gRPC-based providers (for example NVIDIA NIM).
    "ResourceExhausted",
]

private let retryableTransportErrorPatterns = [
    "http2 request did not get a response",
    "http/2 request did not get a response",
    "resourceexhausted",
    "network connection was lost",
    "socket connection was closed",
    "socket is not connected",
    "enotconn",
    "connection reset",
    "timed out",
    "temporarily unavailable",
    "you can retry your request",
    "try your request again",
    "please retry your request",
]

private let retryableURLErrorCodes: Set<Int> = [
    URLError.timedOut.rawValue,
    URLError.cannotFindHost.rawValue,
    URLError.cannotConnectToHost.rawValue,
    URLError.networkConnectionLost.rawValue,
    URLError.dnsLookupFailed.rawValue,
    URLError.notConnectedToInternet.rawValue,
]

/// Classifies whether a failed assistant message looks like a transient provider
/// or transport error. Callers remain responsible for context-overflow handling,
/// retry budgets, backoff, and restarting the assistant turn.
public func isRetryableAssistantError(_ message: AssistantMessage) -> Bool {
    guard message.stopReason == .error, let errorMessage = message.errorMessage else {
        return false
    }
    if matchesAnyPattern(errorMessage, patterns: nonRetryableProviderLimitErrorPatterns) {
        return false
    }
    return matchesAnyPattern(errorMessage, patterns: retryableProviderErrorPatterns)
}

/// Classifies transport errors before providers flatten them into assistant-message
/// text. Foundation frequently wraps POSIX socket failures in one or more NSError
/// layers, so inspect the complete underlying-error chain before using text fallback.
func isRetryableTransportError(_ error: Error) -> Bool {
    if hasRetryableTransportCode(error as NSError, depth: 0) {
        return true
    }

    let text = "\(error.localizedDescription) \(String(describing: error))"
    if retryableTransportErrorPatterns.contains(where: {
        text.range(of: $0, options: [.caseInsensitive, .literal]) != nil
    }) {
        return true
    }
    return text.range(of: "http2", options: .caseInsensitive) != nil &&
        text.range(of: "did not get a response", options: .caseInsensitive) != nil
}

/// Keeps structured Foundation retry information available after an Error is
/// flattened into AssistantMessage.errorMessage. The stable prefix is intentional:
/// localized POSIX descriptions alone cannot be classified reliably on mobile.
func retryAwareErrorDescription(_ error: Error) -> String {
    let description = error.localizedDescription
    guard hasRetryableTransportCode(error as NSError, depth: 0) else {
        return description
    }
    return "Network error: \(description)"
}

private func hasRetryableTransportCode(_ error: NSError, depth: Int) -> Bool {
    // Prevent malformed NSError chains from recursing indefinitely.
    guard depth < 8 else { return false }

    if error.domain == NSURLErrorDomain, retryableURLErrorCodes.contains(error.code) {
        return true
    }
    if error.domain == NSPOSIXErrorDomain, error.code == POSIXErrorCode.ENOTCONN.rawValue {
        return true
    }

    if let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? Error {
        return hasRetryableTransportCode(underlyingError as NSError, depth: depth + 1)
    }
    return false
}

private func matchesAnyPattern(_ text: String, patterns: [String]) -> Bool {
    let pattern = patterns.joined(separator: "|")
    return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
}
