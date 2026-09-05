import Foundation
import Testing
@testable import PiSwiftAI

private func messagePortOutput() -> AssistantMessage {
    AssistantMessage(content: [.text(TextContent(text: "partial", textSignature: "text-sig")),
        .thinking(ThinkingContent(thinking: "", thinkingSignature: "opaque", redacted: true)),
        .toolCall(ToolCall(id: "call", name: "read", arguments: ["path": AnyCodable("a")], thoughtSignature: "tool-sig", namespace: "files"))],
        api: .anthropicMessages, provider: "anthropic", model: "model", responseId: "response",
        usage: Usage(input: 1, output: 2, cacheRead: 3, cacheWrite: 4, reasoning: 1, totalTokens: 10),
        stopReason: .error, errorMessage: "exceeded request buffer limit while retrying upstream", timestamp: 123,
        rawStopReason: "provider-reason", diagnostics: [AssistantMessageDiagnostic(type: "example", timestamp: 456,
            details: ["nested": AnyCodable(["values": ["one", "two"]]), "flag": AnyCodable(true)])],
        providerThinkingLevel: "xhigh", endTurn: false)
}

@Test func assistantMessageJSONRoundTripsNewFieldsAndSignatures() throws {
    let source = messagePortOutput()
    let encoded = assistantMessageToJSONObject(source)
    let data = try JSONSerialization.data(withJSONObject: encoded)
    let wire = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let restored = assistantMessageFromJSONObject(wire)
    #expect(restored.providerThinkingLevel == "xhigh")
    #expect(restored.endTurn == false)
    #expect(restored.responseId == "response")
    #expect(restored.rawStopReason == "provider-reason")
    #expect(restored.errorMessage == source.errorMessage)
    #expect(restored.timestamp == 123)
    #expect(restored.usage.reasoning == 1)
    #expect(restored.diagnostics == source.diagnostics)
    #expect(restored.content.count == 3)
    guard case .text(let text) = restored.content[0], case .thinking(let thinking) = restored.content[1], case .toolCall(let tool) = restored.content[2] else {
        Issue.record("Content order changed during JSON round trip"); return
    }
    #expect(text.textSignature == "text-sig")
    #expect(thinking.redacted == true)
    #expect(thinking.thinkingSignature == "opaque")
    #expect(tool.namespace == "files")
    #expect(tool.thoughtSignature == "tool-sig")
    #expect(tool.arguments["path"]?.value as? String == "a")
}

@Test func assistantMessageJSONOmitsAbsentNewFieldsAndPreservesTrue() throws {
    var source = messagePortOutput()
    source.providerThinkingLevel = nil
    source.endTurn = nil
    let json = assistantMessageToJSONObject(source)
    #expect(json["providerThinkingLevel"] == nil)
    #expect(json["endTurn"] == nil)
    let legacy = assistantMessageFromJSONObject(json)
    #expect(legacy.providerThinkingLevel == nil)
    #expect(legacy.endTurn == nil)
    source.endTurn = true
    #expect(assistantMessageFromJSONObject(assistantMessageToJSONObject(source)).endTurn == true)
}

@Test func retryRecognizesUpstreamRequestBufferLimit() {
    var message = messagePortOutput()
    #expect(isRetryableAssistantError(message))
    message.errorMessage = "EXCEEDED REQUEST BUFFER LIMIT WHILE RETRYING UPSTREAM"
    #expect(isRetryableAssistantError(message))
    message.stopReason = .aborted
    #expect(!isRetryableAssistantError(message))
    message.stopReason = .stop
    #expect(!isRetryableAssistantError(message))
}

private actor RetryPortRecord {
    var calls = 0
    var finished: [(Bool, Int, String?)] = []
    func produce() -> AssistantMessage { calls += 1; return messagePortOutput() }
    func finish(_ success: Bool, _ attempt: Int, _ error: String?) { finished.append((success, attempt, error)) }
}

@Test func retrySleepAbortRemovesErrorAndPreservesAssistantData() async throws {
    let signal = CancellationToken()
    let record = RetryPortRecord()
    let result = await retryAssistantCall(produce: { await record.produce() },
        policy: RetryPolicy(enabled: true, maxRetries: 2, baseDelayMs: 60_000), signal: signal,
        callbacks: RetryCallbacks(onRetryScheduled: { _, _, _, _ in signal.cancel() },
            onRetryFinished: { success, attempt, error in await record.finish(success, attempt, error) }))
    #expect(result.stopReason == .aborted)
    #expect(result.errorMessage == nil)
    #expect(assistantMessageToJSONObject(result)["errorMessage"] == nil)
    #expect(result.providerThinkingLevel == "xhigh")
    #expect(result.responseId == "response")
    #expect(result.content.count == 3)
    #expect(await record.calls == 1)
    let finished = await record.finished
    #expect(finished.count == 1)
    #expect(finished.first?.0 == false)
    #expect(finished.first?.1 == 1)
}

@Test func sharedSleepRejectsAlreadyAbortedSignal() async {
    let signal = CancellationToken()
    signal.cancel()
    await #expect(throws: StreamError.self) { try await abortableSleep(ms: 60_000, signal: signal) }
}

@Test func sharedSleepRespondsToCancellationDuringWait() async throws {
    let signal = CancellationToken()
    let sleeper = Task { try await abortableSleep(ms: 60_000, signal: signal) }
    await Task.yield()
    signal.cancel()
    await #expect(throws: StreamError.self) { try await sleeper.value }
}
