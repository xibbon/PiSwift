import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private func partialEvent(_ value: JSONValue, message: AssistantMessage) throws -> AssistantMessageEvent {
    let index = try #require(value["contentIndex"]?.intValue)
    let delta = value["delta"]?.stringValue ?? ""
    switch value["type"]?.stringValue {
    case "text_delta": return .textDelta(contentIndex: index, delta: delta, partial: message)
    case "thinking_delta": return .thinkingDelta(contentIndex: index, delta: delta, partial: message)
    case "toolcall_start": return .toolCallStart(contentIndex: index, partial: message)
    case "toolcall_delta": return .toolCallDelta(contentIndex: index, delta: delta, partial: message)
    case "text_end": return .textEnd(contentIndex: index, content: value["content"]?.stringValue ?? "", partial: message)
    case "thinking_end": return .thinkingEnd(contentIndex: index, content: value["content"]?.stringValue ?? "", partial: message)
    case "toolcall_end":
        let call = ToolCall(id: "fixture", name: "fixture", arguments: [:])
        return .toolCallEnd(contentIndex: index, toolCall: call, partial: message)
    default: throw DurableJSONBridgeError.invalidMessage(index: index)
    }
}

private func emptyPartial() -> AssistantMessage {
    AssistantMessage(content: [.text(TextContent(text: ""))], api: .openAICompletions,
                     provider: "test", model: "test",
                     usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                     stopReason: .pending, timestamp: 0)
}

@Suite struct HarnessPartialChangesTests {
    @Test(.timeLimit(.minutes(1))) func fiftySeededUpstreamSequencesReplayEveryCommit() async throws {
        let url = try #require(Bundle.module.url(forResource: "partial-changes-v152", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONValue(jsonText: String(contentsOf: url, encoding: .utf8))
        #expect(fixture["tag"] == "v1.5.2")
        let sequences = try #require(fixture["sequences"]?.arrayValue)
        #expect(sequences.count == 50)
        for sequence in sequences {
            let tracker = try Delta.track(#require(sequence["initial"]))
            let changes = PartialChanges()
            for (stepIndex, step) in try #require(sequence["steps"]?.arrayValue).enumerated() {
                if let event = step["event"] {
                    await changes.observe(try partialEvent(event, message: emptyPartial()))
                } else if step["reset"]?.boolValue == true {
                    let change = tracker.beginChange()
                    try change.state.set("generation", ["attempt": 1])
                    try tracker.adopt(change.prepare())
                } else {
                    let message = try #require(step["message"])
                    let taken = await changes.take(message)
                    let change = tracker.beginChange()
                    let generation = try #require(try change.state.child("generation"))
                    try await changes.commit(generation, message: taken.message, taken: taken.commit)
                    if step["fail"]?.boolValue == true {
                        change.abort()
                        await changes.restore(taken.commit)
                    } else {
                        let prepared = try change.prepare()
                        let expected = try #require(step["ops"]?.arrayValue).map { try Delta.Op(json: $0) }
                        try #require(prepared.ops == expected, "Seed \(sequence["seed"]!) step \(stepIndex)")
                        try #require(prepared.value == step["value"], "Seed \(sequence["seed"]!) step \(stepIndex)")
                        #expect(try Delta.applyImmutable(prepared.base, prepared.ops) == prepared.value)
                        try tracker.adopt(prepared)
                    }
                }
            }
        }
    }

    // v1.5.2 harness-partial-changes.test.ts:107. Swift splits at scalar boundaries.
    @Test(.timeLimit(.minutes(1))) func toolArgumentsAtEveryPieceSizeAndCommitRhythm() async throws {
        let arguments: JSONValue = [
            "path": "src/a.ts", "n": 1234, "ok": true,
            "content": "line \"one\"\n\tline \\ two é 😀\n",
            "edits": [["oldText": "a", "newText": "b\nc"], ["oldText": "", "newText": .string(String(repeating: "x", count: 50))]],
            "nested": ["deep": ["list": [1, [2, "three"], ["four": .null]]]]
        ]
        let scalars = Array(try arguments.jsonText().unicodeScalars)
        for size in [1, 2, 3, 5, 7, 16] {
            for every in [1, 3, 10] {
                let changes = PartialChanges()
                let parser = ToolCallArgumentsStream()
                let tracker = try Delta.track(["attempt": 1])
                var message = emptyPartial()
                var call = ToolCall(id: "c1", name: "write", arguments: [:])
                message.content.append(.toolCall(call))
                await changes.observe(.toolCallStart(contentIndex: 1, partial: message))
                for (pieceIndex, start) in stride(from: 0, to: scalars.count, by: size).enumerated() {
                    let piece = String(String.UnicodeScalarView(scalars[start..<min(start + size, scalars.count)]))
                    call.arguments = parser.append(piece)
                    message.content[1] = .toolCall(call)
                    await changes.observe(.toolCallDelta(contentIndex: 1, delta: piece, partial: message))
                    if (pieceIndex + 1) % every == 0 || start + size >= scalars.count {
                        let taken = try #require(try await changes.takeLatest())
                        let change = tracker.beginChange()
                        try await changes.commit(change.state, message: taken.message, taken: taken.commit)
                        try tracker.adopt(change.prepare())
                    }
                }
                #expect(tracker.value["message"]?["content"]?[1]?["arguments"] == arguments,
                        "size \(size), every \(every)")
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func latestPartialAndChangesAreTakenTogether() async throws {
        let changes = PartialChanges()
        var message = emptyPartial()
        message.content = [.text(TextContent(text: "first"))]
        await changes.observe(.textDelta(contentIndex: 0, delta: "first", partial: message))
        message.content = [.text(TextContent(text: "first😀"))]
        await changes.observe(.textDelta(contentIndex: 0, delta: "😀", partial: message))
        let taken = try #require(try await changes.takeLatest())
        #expect(taken.message["content"]?[0]?["text"] == "first😀")
        let tracker = try Delta.track(["message": ["content": [["type": "text", "text": ""]]]])
        let change = tracker.beginChange()
        try await changes.commit(change.state, message: taken.message, taken: taken.commit)
        let prepared = try change.prepare()
        #expect(prepared.ops.contains(.append(["message", "content", 0, "text"], "first😀")))
        #expect(try await changes.takeLatest() == nil)
    }

    @Test func appendPlansUseUTF16LengthsAndArrayFallback() throws {
        let tracker = try Delta.track(["text": "😀", "array": ["😀"], "kept": 1])
        let change = tracker.beginChange()
        let root = try change.state
        try assignJSON(target: root, key: "text", value: "😀e\u{301}", plan: .append("e\u{301}"))
        try assignJSON(target: root, key: "kept", value: 2, plan: .keep)
        let array = try #require(try root.child("array"))
        try assignJSON(target: array, key: "0", value: "😀x", plan: .append("x"))
        #expect(try array.get(0) == "😀x")
        try assignJSON(target: array, key: "0", value: "replacement", plan: .append("x"))
        let prepared = try change.prepare()
        #expect(prepared.value == ["text": "😀e\u{301}", "array": ["replacement"], "kept": 1])
        #expect(prepared.ops.contains(.append(["text"], "e\u{301}")))
    }

    @Test(.timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["PISWIFT_STREAM_BENCHMARK"] == "1"))
    func oneMegabyteStreamBenchmark() async throws {
        let changes = PartialChanges()
        var partial = emptyPartial()
        let tracker = try Delta.track(["attempt": 1])
        var text = ""
        let token = "abcd"
        let clock = ContinuousClock()
        let start = clock.now
        var operationCount = 0
        var appendCount = 0
        var observeFirstHalf = Duration.zero
        var observeSecondHalf = Duration.zero
        // 4-byte provider tokens; one write per 1,024 tokens (4 KiB).
        for index in 0..<262_144 {
            text += token
            partial.content = [.text(TextContent(text: text))]
            let observeStart = clock.now
            await changes.observe(.textDelta(contentIndex: 0, delta: token, partial: partial))
            let observation = observeStart.duration(to: clock.now)
            if index < 131_072 { observeFirstHalf += observation }
            else { observeSecondHalf += observation }
            if (index + 1) % 1_024 != 0 { continue }
            let taken = try #require(try await changes.takeLatest())
            let change = tracker.beginChange()
            try await changes.commit(change.state, message: taken.message, taken: taken.commit)
            let prepared = try change.prepare()
            operationCount += prepared.ops.count
            appendCount += prepared.ops.filter { if case .append = $0 { true } else { false } }.count
            try tracker.adopt(prepared)
        }
        let elapsed = start.duration(to: clock.now)
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        #expect(text.utf8.count == 1_048_576)
        #expect(tracker.value["message"]?["content"]?[0]?["text"] == .string(text))
        #expect(operationCount == 256)
        #expect(appendCount == 255)
        print("STREAM_BENCHMARK bytes=1048576 tokenBytes=4 tokens=262144 commits=256 observeFirstHalf=\(observeFirstHalf) observeSecondHalf=\(observeSecondHalf) operations=\(operationCount) appends=\(appendCount) elapsed=\(elapsed) peakRSS=\(usage.ru_maxrss)")
    }
}
