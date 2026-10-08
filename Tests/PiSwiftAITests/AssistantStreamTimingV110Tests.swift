import Foundation
import Testing
@testable import PiSwiftAI

private func timingMessage(timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000), durationMs: Int? = nil) -> AssistantMessage {
    AssistantMessage(content: [], api: .openAIResponses, provider: "openai", model: "timing",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .stop, timestamp: timestamp, durationMs: durationMs)
}

@Suite(.timeLimit(.minutes(1))) struct AssistantStreamTimingV110Tests {
    @Test func doneTimesDeliveredValueAndFinishesWithoutEnd() async throws {
        let stream = AssistantMessageEventStream()
        let message = timingMessage()
        try await Task.sleep(for: .milliseconds(20))
        stream.push(.done(reason: .stop, message: message))
        var iterator = stream.makeAsyncIterator()
        guard case .done(_, let delivered) = await iterator.next() else {
            Issue.record("Expected done event")
            return
        }
        #expect(try #require(delivered.durationMs) >= 15)
        #expect(await stream.result().durationMs == delivered.durationMs)
        #expect(await iterator.next() == nil)
        #expect(message.durationMs == nil)
    }

    @Test func errorAndEndTimeTheResult() async throws {
        let failed = AssistantMessageEventStream()
        var error = timingMessage()
        error.stopReason = .error
        failed.push(.error(reason: .error, error: error))
        var iterator = failed.makeAsyncIterator()
        guard case .error(_, let delivered) = await iterator.next() else {
            Issue.record("Expected error event")
            return
        }
        #expect(try #require(delivered.durationMs) >= 0)
        #expect(await failed.result().durationMs == delivered.durationMs)
        #expect(await iterator.next() == nil)
        let ended = AssistantMessageEventStream()
        ended.end(timingMessage())
        #expect(try #require(await ended.result().durationMs) >= 0)
        var endedIterator = ended.makeAsyncIterator()
        #expect(await endedIterator.next() == nil)
    }

    @Test func forwardingKeepsInnerDurationAndPreset() async throws {
        let outer = AssistantMessageEventStream()
        try await Task.sleep(for: .milliseconds(20))
        let inner = AssistantMessageEventStream()
        inner.push(.done(reason: .stop, message: timingMessage()))
        let answer = await inner.result()
        outer.push(.done(reason: .stop, message: answer))
        #expect(try #require(answer.durationMs) < 20)
        #expect(await outer.result().durationMs == answer.durationMs)
        let preset = AssistantMessageEventStream()
        preset.push(.done(reason: .stop, message: timingMessage(durationMs: 1234)))
        #expect(await preset.result().durationMs == 1234)
    }

    @Test func oldMessagesStayUntimed() async {
        let stream = AssistantMessageEventStream()
        stream.push(.done(reason: .stop, message: timingMessage(timestamp: Int64(Date().timeIntervalSince1970 * 1000) - 60_000)))
        #expect(await stream.result().durationMs == nil)
    }

    @Test func firstTerminalWinsAndLatePushesAreIgnored() async {
        let stream = AssistantMessageEventStream()
        stream.push(.done(reason: .stop, message: timingMessage(durationMs: 1234)))
        let late = timingMessage()
        stream.push(.start(partial: late))
        stream.push(.error(reason: .error, error: late))
        stream.end(timingMessage(durationMs: 5678))
        #expect(late.durationMs == nil)
        #expect(await stream.result().durationMs == 1234)
        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 1)
    }

    @Test func endResultWinsAndEndNilFinishesIteration() async {
        let stream = AssistantMessageEventStream()
        stream.end(timingMessage(durationMs: 42))
        stream.push(.done(reason: .stop, message: timingMessage(durationMs: 99)))
        #expect(await stream.result().durationMs == 42)
        let empty = AssistantMessageEventStream()
        empty.end()
        var iterator = empty.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test func concurrentTerminalAndEndKeepResultAndDeliveryTogether() async {
        for _ in 0..<100 {
            let stream = AssistantMessageEventStream()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { stream.push(.done(reason: .stop, message: timingMessage(durationMs: 42))) }
                group.addTask { stream.end(timingMessage(durationMs: 99)) }
            }
            let result = await stream.result()
            var delivered: [Int?] = []
            for await event in stream {
                if case .done(_, let message) = event { delivered.append(message.durationMs) }
            }
            if result.durationMs == 42 {
                #expect(delivered == [42])
            } else {
                #expect(result.durationMs == 99)
                #expect(delivered.isEmpty)
            }
        }
    }

    @Test func jsonRoundTripAndDurationIsLastKey() throws {
        let message = timingMessage(durationMs: 1234)
        let json = assistantMessageToJSONObject(message)
        let data = try JSONSerialization.data(withJSONObject: json)
        let restored = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(assistantMessageFromJSONObject(restored).durationMs == 1234)
        let ordered = assistantMessageToOrderedJSON(message)
        #expect(ordered.objectEntries?.last?.0 == "durationMs")
        #expect(assistantMessageFromJSONObject(json).durationMs == 1234)
        let old = assistantMessageToJSONObject(timingMessage())
        #expect(old["durationMs"] == nil)
        #expect(assistantMessageFromJSONObject(old).durationMs == nil)
        #expect(assistantMessageToOrderedJSON(timingMessage())["durationMs"] == nil)
    }

    @Test func jsonNumbersRoundAndNonNumbersAreAbsent() throws {
        for (raw, expected) in [("12.5", 13), ("12.49", 12), ("-1.5", 0), ("1e3", 1000),
                                ("0.5", 1), ("0.49999999999999994", 0), ("1e100", Int.max)] {
            let object = try #require(JSONSerialization.jsonObject(with: Data("{\"durationMs\":\(raw)}".utf8)) as? [String: Any])
            #expect(assistantMessageFromJSONObject(object).durationMs == expected)
        }
        for raw in ["null", "true", "false", "\"12\"", "[]", "{}"] {
            let object = try #require(JSONSerialization.jsonObject(with: Data("{\"durationMs\":\(raw)}".utf8)) as? [String: Any])
            #expect(assistantMessageFromJSONObject(object).durationMs == nil)
        }
    }

}

// A private registration and the internal faux stream keep this case off the global provider registry.
@Suite(.timeLimit(.minutes(1))) struct FauxStreamTimingV110Tests {
    @Test func fauxProviderTimesFreshFactoryAndKeepsPresetDurationV110() async throws {
        let model = Model(id: "duration-v110", name: "Duration", api: .openAICompletions, provider: "faux-duration-v110",
                          baseUrl: "https://example.invalid/v1", reasoning: false, input: [.text],
                          cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                          contextWindow: 8192, maxTokens: 1024)
        let registration = FauxProviderRegistration(api: model.api, provider: model.provider, models: [model],
            sourceId: "duration-v110", minTokenSize: 1, maxTokenSize: 3, tokensPerSecond: nil)
        registration.setResponses([
            .factory { _, _, _, _ in timingMessage() },
            .message(timingMessage(durationMs: 1234))
        ])
        let context = normalizeContext(Context(messages: []))
        let first = fauxStream(model: model, context: context, registration: registration, simpleOptions: nil)
        #expect(try #require(await first.result().durationMs) >= 0)
        let second = fauxStream(model: model, context: context, registration: registration, simpleOptions: SimpleStreamOptions())
        #expect(await second.result().durationMs == 1234)
    }
}
