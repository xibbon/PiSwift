import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable

@Suite("PiSwiftDurableTests.D8ModelOptions")
struct D8ModelOptionsTests {
    @Test func thinkingBudgetsAndWebsocketTimeoutSurviveStoredRequestAndForwarding() throws {
        // v1.5.2 durable/src/harness/types.ts:562-564.
        let input = ConversationStreamOptions(websocketConnectTimeoutMs: 456,
            thinkingBudgets: [.low: 111, .high: 222])
        let saved = try JSONValue(encoding: input)
        let decoded = try saved.decode(ConversationStreamOptions.self)
        #expect(decoded.websocketConnectTimeoutMs == 456)
        #expect(decoded.thinkingBudgets?[.low] == 111)
        let options = try generationStreamOptions(decoded, thinkingLevel: .high,
            signal: CancellationToken(), sessionId: "d8")
        #expect(options.websocketConnectTimeoutMs == 456)
        #expect(options.thinkingBudgets?[.high] == 222)
    }
}
