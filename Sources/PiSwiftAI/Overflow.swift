import Foundation

private let overflowPatterns: [NSRegularExpression] = [
    try! NSRegularExpression(pattern: "prompt is too long", options: [.caseInsensitive]),
    try! NSRegularExpression(pattern: "input is too long for requested model", options: [.caseInsensitive]),
    try! NSRegularExpression(pattern: "exceeds the context window", options: [.caseInsensitive]),
    try! NSRegularExpression(pattern: "input is too long", options: [.caseInsensitive]),
    try! NSRegularExpression(pattern: "input token count.*exceeds the maximum", options: [.caseInsensitive]),
    try! NSRegularExpression(pattern: "maximum prompt length is \\d+", options: [.caseInsensitive]),
    try! NSRegularExpression(pattern: "reduce the length of the messages", options: [.caseInsensitive]),
    try! NSRegularExpression(pattern: "maximum context length is \\d+ tokens", options: [.caseInsensitive]),
    try! NSRegularExpression(pattern: "exceeds the limit of \\d+", options: [.caseInsensitive]),
    try! NSRegularExpression(pattern: "exceeds the available context size", options: [.caseInsensitive]),
    try! NSRegularExpression(pattern: "greater than the context length", options: [.caseInsensitive]),
    try! NSRegularExpression(pattern: "context window exceeds limit", options: [.caseInsensitive]),
    try! NSRegularExpression(pattern: "exceeded model token limit", options: [.caseInsensitive]),
    try! NSRegularExpression(pattern: "context[_ ]length[_ ]exceeded", options: [.caseInsensitive]),
    try! NSRegularExpression(pattern: "too many tokens", options: [.caseInsensitive]),
    try! NSRegularExpression(pattern: "token limit exceeded", options: [.caseInsensitive]),
    try! NSRegularExpression(pattern: "model_context_window_exceeded", options: [.caseInsensitive]),
    try! NSRegularExpression(pattern: "too large for model with \\d+ maximum context length", options: [.caseInsensitive]),
]

public func isContextOverflow(_ message: AssistantMessage, contextWindow: Int? = nil) -> Bool {
    if message.stopReason == .error, let errorMessage = message.errorMessage {
        let range = NSRange(errorMessage.startIndex..., in: errorMessage)
        for pattern in overflowPatterns {
            if pattern.firstMatch(in: errorMessage, options: [], range: range) != nil {
                return true
            }
        }

        if let codeMatch = try? NSRegularExpression(pattern: "^4(00|13)\\s*(status code)?\\s*\\(no body\\)", options: [.caseInsensitive]) {
            if codeMatch.firstMatch(in: errorMessage, options: [], range: range) != nil {
                return true
            }
        }
    }

    if let contextWindow, message.stopReason == .stop {
        let inputTokens = message.usage.input + message.usage.cacheRead
        if inputTokens > contextWindow {
            return true
        }
    }

    return false
}

public func getOverflowPatterns() -> [NSRegularExpression] {
    overflowPatterns
}
