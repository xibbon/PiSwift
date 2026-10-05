import Testing
import PiSwiftAI

@Suite("v1.0.4 HTTP/2 retry")
struct RetryV104Tests {
    // Upstream retry.test.ts: #10379, Node ERR_HTTP2_STREAM_CANCEL.
    @Test(arguments: [
        "The pending stream has been canceled",
        "The pending stream has been canceled (caused by: socket closed)",
    ])
    func pendingStreamCancellationIsRetryable(_ errorMessage: String) {
        let message = AssistantMessage(
            content: [], api: .openAIResponses, provider: KnownProvider.openai.rawValue,
            model: "test-model",
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
            stopReason: .error, errorMessage: errorMessage
        )
        #expect(isRetryableAssistantError(message))
    }
}
