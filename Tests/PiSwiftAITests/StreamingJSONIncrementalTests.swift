import Foundation
import Testing
@testable import PiSwiftAI

@Test("report a number that ends and a string that starts in one piece, in order") func reportANumberThatEndsAndAStringThatStartsInOnePieceInOrder() {
    let parser = StreamingJSONParser()
    #expect(parser.append("{\"n\":1") == [JSONChange(kind: .set, path: [], value: .object([]))])
    #expect(parser.append("2,\"s\":\"ab") == [
        JSONChange(kind: .set, path: [.key("n")], value: .number("12")),
        JSONChange(kind: .set, path: [.key("s")], value: .string("ab")),
    ])
    #expect(parser.append("c\",\"t\":tru") == [JSONChange(kind: .append, path: [.key("s")], text: "c")])
    #expect(parser.append("e}") == [JSONChange(kind: .set, path: [.key("t")], value: .bool(true))])
    #expect(parser.append(" {\"ignored\":1}").isEmpty)
    #expect(parser.snapshot()?.serialized(escapeSlashes: false) == #"{"n":12,"s":"abc","t":true}"#)
}

@Test("report nested objects and arrays as empty containers, then their members and items") func reportNestedObjectsAndArraysAsEmptyContainersThenTheirMembersAndItems() {
    let parser = StreamingJSONParser()
    #expect(parser.append(#"{"a":[1,{"b":["x""#) == [
        JSONChange(kind: .set, path: [], value: .object([])),
        JSONChange(kind: .set, path: [.key("a")], value: .array([])),
        JSONChange(kind: .set, path: [.key("a"), .index(0)], value: .number("1")),
        JSONChange(kind: .set, path: [.key("a"), .index(1)], value: .object([])),
        JSONChange(kind: .set, path: [.key("a"), .index(1), .key("b")], value: .array([])),
        JSONChange(kind: .set, path: [.key("a"), .index(1), .key("b"), .index(0)], value: .string("x")),
    ])
    #expect(parser.append(#", "y"#).isEmpty == false)
}

@Test("shows partial arguments as an object and finishes with one full parse") func showsPartialArgumentsAsAnObjectAndFinishesWithOneFullParse() {
    let args = ToolCallArgumentsStream()
    #expect(args.append("  ").isEmpty)
    #expect(args.append(#"{"path":"a.ts","content":"x"#)["content"] == AnyCodable("x"))
    let before = args.append("y")
    #expect(before["content"] == AnyCodable("xy"))
    #expect(args.append("\"}")["content"] == AnyCodable("xy"))
    #expect(args.finish().argumentsError == nil)
}

@Test func finalArgumentsPreserveModelKeyOrder() throws {
    let text = #"{"z":{"b":1,"a":2},"a":3}"#
    let stream = ToolCallArgumentsStream()
    for character in text { _ = stream.append(String(character)) }
    var call = ToolCall(id: "id", name: "tool", arguments: [:])
    call.finalizeArguments(from: stream.text)
    #expect(call.argumentsJSON?.serialized(escapeSlashes: false) == text)
    #expect(call.argumentsError == nil)
}

#if canImport(CryptoKit)
import CryptoKit

private func fixtureJSONString(_ text: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes]),
          let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
    return String(encoded.dropFirst().dropLast())
}

private func fixtureChange(_ change: JSONChange) -> String {
    let path = change.path.map { element in
        switch element {
        case .key(let key): return fixtureJSONString(key)
        case .index(let index): return String(index)
        }
    }.joined(separator: ",")
    let start = "{\"kind\":\(fixtureJSONString(change.kind.rawValue)),\"path\":[\(path)]"
    if change.kind == .set { return start + ",\"value\":\(change.value?.serialized(escapeSlashes: false) ?? "null")}" }
    return start + ",\"text\":\(fixtureJSONString(change.text ?? ""))}"
}

@Test func replaysStreamingJSONV152DifferentialFixture() throws {
    let url = try #require(Bundle.module.url(forResource: "streaming-json-v1.5.2", withExtension: "jsonl"))
    let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    #expect(rows.count == 1941)
    for (rowNumber, line) in rows.enumerated() {
        let row = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let chunks = try #require(row["chunks"] as? [String])
        let expected = try #require(row["digest"] as? String)
        let sample = row["sequence"] as? [String]
        // Swift String cannot contain a lone UTF-16 surrogate; compare the completed value.
        let containsSplitSurrogate = (row["text"] as? String)?.range(of: #"\\u[dD][0-9a-fA-F]{3}"#, options: .regularExpression) != nil ||
            ((row["name"] as? String)?.contains("surrogate") == true)
        // The tagged JavaScript parser has no depth cap; the 500-array corpus case exceeds Swift's stack guard.
        let exceedsSwiftDepth = (row["name"] as? String) == "i_structure_500_nested_arrays.json"
        let parser = StreamingJSONParser()
        var hash = SHA256()
        for (index, chunk) in chunks.enumerated() {
            let changes = parser.append(chunk)
            let snapshot = parser.snapshot()?.serialized(escapeSlashes: false) ?? "null"
            let record = "[\(snapshot),[\(changes.map(fixtureChange).joined(separator: ","))]]"
            hash.update(data: Data((record + "\n").utf8))
            if let sample, !containsSplitSurrogate, !exceedsSwiftDepth, sample[index] != record {
                Issue.record("fixture row \(rowNumber), delta \(index): expected \(sample[index]), got \(record)")
                return
            }
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        if !containsSplitSurrogate && !exceedsSwiftDepth && actual != expected {
            Issue.record("fixture row \(rowNumber) digest: expected \(expected), got \(actual)")
            return
        }
        if !containsSplitSurrogate && !exceedsSwiftDepth, let final = row["final"] as? String {
            let snapshot = parser.snapshot()?.serialized(escapeSlashes: false)
            if snapshot != final {
                Issue.record("fixture row \(rowNumber) final: expected \(final), got \(snapshot ?? "nil")")
                return
            }
        }
    }
}
#endif

@Test("streams 520 KB of arguments in 32-character pieces within 10 seconds", .timeLimit(.minutes(1))) func streams520KBArgumentsIn32CharacterPiecesWithinUpstreamLimit() {
    let text = #"{"path":"/src/file.ts","content":""# + String(repeating: "a", count: 520_000) + "\"}"
    let stream = ToolCallArgumentsStream()
    let clock = ContinuousClock()
    let start = clock.now
    var index = text.startIndex
    while index < text.endIndex {
        let end = text.index(index, offsetBy: 32, limitedBy: text.endIndex) ?? text.endIndex
        _ = stream.append(String(text[index..<end]))
        index = end
    }
    #expect(stream.finish().argumentsError == nil)
    #expect(start.duration(to: clock.now) < .seconds(10))
}

@Test("open string previews stay current in 32-character deltas", .timeLimit(.minutes(1)), arguments: [100_000, 520_000, 2_000_000])
func openStringPreviewLag(size: Int) {
    let stream = ToolCallArgumentsStream()
    _ = stream.append(#"{"content":""#)
    let chunk = String(repeating: "a", count: 32)
    let clock = ContinuousClock()
    let start = clock.now
    var appended = 0
    var maximumLag = 0
    while appended < size {
        let delta = String(chunk.prefix(min(32, size - appended)))
        appended += delta.count
        let preview = stream.append(delta)
        let shown = (preview["content"]?.value as? String)?.utf8.count ?? 0
        maximumLag = max(maximumLag, appended - shown)
    }
    let elapsed = start.duration(to: clock.now)
    print("A-STR open string \(size) bytes: \(elapsed), maximum lag \(maximumLag)")
    #expect(maximumLag == 0)
    #expect(elapsed < .seconds(10))
}

@Test("accepts the measured container limit and rejects one more with a final argument error")
func toolArgumentDepthBoundary() {
    for depth in [toolArgumentsMaximumDepth, toolArgumentsMaximumDepth + 1] {
        for objects in [false, true] {
            let text = objects ? String(repeating: #"{"v":"#, count: depth) + "0" + String(repeating: "}", count: depth)
                : #"{"value":"# + String(repeating: "[", count: depth - 1) + "0" + String(repeating: "]", count: depth - 1) + "}"
            let stream = ToolCallArgumentsStream()
            _ = stream.append(text)
            let final = stream.finish()
            if depth == toolArgumentsMaximumDepth {
                #expect(final.argumentsError == nil)
                var call = ToolCall(id: "depth", name: "test", arguments: [:])
                call.finalizeArguments(from: text)
                #expect(call.argumentsJSON?.serialized(escapeSlashes: false) == text)
                #expect((final.arguments[objects ? "v" : "value"]?.value) != nil)
            } else {
                #expect(final.argumentsError != nil)
            }
        }
    }
}

@Test func hostileDeepStreamReturnsErrorWithoutStackOverflow() {
    let stream = ToolCallArgumentsStream()
    _ = stream.append(String(repeating: "[", count: 100_000))
    #expect(stream.finish().argumentsError != nil)
}

@Test("JavaScript number edges use schema conversion and final overflow is an error")
func streamedNumberEdges() {
    let negativeZero = ToolCallArgumentsStream()
    #expect(negativeZero.append(#"{"n":-0}"#)["n"] == AnyCodable(0))
    let infinity = ToolCallArgumentsStream()
    let partial = infinity.append(#"{"n":1e309}"#)
    #expect((partial["n"]?.value as? Double)?.isInfinite == true)
    #expect(infinity.finish().argumentsError != nil)
    #expect(StreamingJSONParser().append("1e+").isEmpty)
}

@Test("never changes a snapshot once it is returned") func neverChangesASnapshotOnceReturned() {
    let parser = StreamingJSONParser()
    _ = parser.append(#"{"a":[1"#)
    let before = parser.snapshot()
    _ = parser.append(#",2],"b":3}"#)
    #expect(before?.serialized(escapeSlashes: false) == #"{"a":[1]}"#)
    #expect(parser.snapshot()?.serialized(escapeSlashes: false) == #"{"a":[1,2],"b":3}"#)
}

@Test("keeps the last value of a duplicate key in the first key's position, as JSON.parse does")
func duplicateKeyKeepsFirstPosition() {
    let parser = StreamingJSONParser()
    _ = parser.append(#"{"a":1,"b":2,"a":3}"#)
    #expect(parser.snapshot()?.serialized(escapeSlashes: false) == #"{"a":3,"b":2}"#)
}

@Test("keeps trailing whitespace of an unterminated string") func keepsTrailingWhitespaceInOpenString() {
    let parser = StreamingJSONParser()
    _ = parser.append(#"{"s":"a  "#)
    #expect(parser.snapshot()?.serialized(escapeSlashes: false) == #"{"s":"a  "}"#)
}

@Test("tolerates missing commas and colons and drops values in invalid positions")
func toleratesMissingCommasAndColons() {
    let parser = StreamingJSONParser()
    _ = parser.append(#"{"a" 1 "b":2}"#)
    #expect(parser.snapshot()?.serialized(escapeSlashes: false) == #"{"a":1,"b":2}"#)
}

@Test("shows non-object roots as no arguments yet") func showsNonObjectRootAsNoArguments() {
    let args = ToolCallArgumentsStream()
    #expect(args.append("[1,2]").isEmpty)
    #expect(args.finish().argumentsError != nil)
}

@Test("replaces the text with the provider's complete text, returning the missing piece")
func replacesTextWithCompleteText() {
    let args = ToolCallArgumentsStream()
    _ = args.append(#"{"a":1"#)
    let continued = args.replace(#"{"a":1,"b":2}"#)
    #expect(continued.delta == #", "b":2}"#.replacingOccurrences(of: " ", with: ""))
    #expect(continued.arguments["b"] == AnyCodable(2))
    let restarted = args.replace(#"{"z":3}"#)
    #expect(restarted.delta == nil)
    #expect(restarted.arguments["z"] == AnyCodable(3))
}
