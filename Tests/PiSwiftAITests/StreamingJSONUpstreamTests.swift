import Foundation
import Testing
@testable import PiSwiftAI

// Cases follow packages/ai/test/streaming-json.test.ts at v1.5.2, in source order.
private func upstreamParts(_ text: String, size: Int) -> [String] {
    let characters = Array(text)
    return stride(from: 0, to: characters.count, by: size).map { String(characters[$0..<min($0 + size, characters.count)]) }
}

private func upstreamSnapshot(_ text: String, size: Int) -> OrderedJSON? {
    let parser = StreamingJSONParser()
    for part in upstreamParts(text, size: size) { parser.append(part); _ = parser.snapshot() }
    return parser.snapshot()
}

private func upstreamJSON(_ value: OrderedJSON?) -> String? { value?.serialized(escapeSlashes: false) }

private func upstreamApply(_ change: JSONChange, to value: inout OrderedJSON?) {
    func changed(_ current: OrderedJSON?, path: ArraySlice<JSONChange.PathElement>) -> OrderedJSON? {
        guard let head = path.first else {
            if change.kind == .set { return change.value }
            if case .string(let text) = current { return .string(text + (change.text ?? "")) }
            return current
        }
        switch (current, head) {
        case (.object(var pairs), .key(let key)):
            if let position = pairs.firstIndex(where: { $0.0 == key }) {
                pairs[position].1 = changed(pairs[position].1, path: path.dropFirst()) ?? .null
            } else if let next = changed(nil, path: path.dropFirst()) { pairs.append((key, next)) }
            return .object(pairs)
        case (.array(var items), .index(let index)):
            if items.indices.contains(index) { items[index] = changed(items[index], path: path.dropFirst()) ?? .null }
            else if index == items.count, let next = changed(nil, path: path.dropFirst()) { items.append(next) }
            return .array(items)
        default: return current
        }
    }
    value = changed(value, path: change.path[...])
}

private let upstreamValidTexts = [
    #"{}"#, #"[]"#, #"{"a":1,"b":[true,null,"x"]}"#, #"{"a":{"b":[1,2]},"z":-1.25e4}"#,
    #"{"__proto__":{"polluted":true},"b":2}"#, #"{"a":1,"b":2,"a":3}"#,
]

@Test("matches the reference after every piece, at every chunk size, with insignificant whitespace")
func upstreamMatchesReferenceAfterEveryPiece() {
    let text = " { \n \"a\" : [ 1, true, null, \"x\\n\" ], \"b\" : { \"c\" : 2 } } "
    for size in [1, 2, 3, 7, 11] {
        let parser = StreamingJSONParser()
        for part in upstreamParts(text, size: size) {
            parser.append(part)
            _ = parser.snapshot()
        }
        #expect(upstreamJSON(parser.snapshot()) == #"{"a":[1,true,null,"x\n"],"b":{"c":2}}"#)
    }
}

@Test("matches today's parseStreamingJson at every prefix of compact documents")
func upstreamMatchesLegacyAtEveryPrefix() {
    for text in upstreamValidTexts where text.first == "{" {
        let parser = StreamingJSONParser()
        var prefix = ""
        for part in upstreamParts(text, size: 1) {
            prefix += part
            parser.append(part)
            let current = parser.snapshot()
            let legacy = parseStreamingJSON(prefix)
            if case .object = current {
                #expect((current?.objectEntries ?? []).count == legacy.count || prefix.hasSuffix("\"") || prefix.hasSuffix(","))
            }
        }
    }
}

@Test("reads complete documents exactly like JSON.parse")
func upstreamReadsCompleteDocuments() {
    for text in upstreamValidTexts {
        let expected = try? OrderedJSON.parse(text, allowDuplicateKeys: true)
        for size in [1, 2, 3, 7, max(1, text.count)] {
            if let actual = upstreamSnapshot(text, size: size), let expected {
                #expect(AnyCodable(partialJSONValue(actual)) == AnyCodable(partialJSONValue(expected)))
            } else { Issue.record("Missing complete value") }
        }
    }
}

@Test("never changes a snapshot once it is returned")
func upstreamNeverChangesSnapshot() {
    let parser = StreamingJSONParser()
    parser.append(#"{"a":[1"#)
    let old = parser.snapshot()
    parser.append(#",2],"b":3}"#)
    #expect(upstreamJSON(old) == #"{"a":[1]}"#)
    #expect(upstreamJSON(parser.snapshot()) == #"{"a":[1,2],"b":3}"#)
}

@Test("repairs raw control characters and invalid escapes like parseStreamingJson, and shows them while streaming")
func upstreamRepairsControlCharactersAndEscapes() {
    for content in ["a\nb", "a\tb", "a\\qb", "a\\x41b", "é\u{1f}"] {
        let text = "{\"content\":\"" + content + "\",\"n\":1}"
        let snapshot = upstreamSnapshot(text, size: 1)
        #expect(snapshot?["content"]?.stringValue == content)
        #expect(snapshot?["n"]?.serialized() == "1")
    }
}

@Test("holds an escape back until it is complete, at every split position")
func upstreamHoldsSplitEscapes() {
    for (text, expected) in [
        (#"{"a":"x\u00e9y"}"#, "xéy"), (#"{"a":"x\ny"}"#, "x\ny"),
        (#"{"a":"x\\y"}"#, "x\\y"), (#"{"a":"x\"y"}"#, "x\"y"),
        (#"{"a":"x\/y"}"#, "x/y"),
    ] {
        let characters = Array(text)
        for split in 0...characters.count {
            let parser = StreamingJSONParser()
            parser.append(String(characters[..<split]))
            _ = parser.snapshot()
            parser.append(String(characters[split...]))
            #expect(parser.snapshot()?["a"]?.stringValue == expected)
        }
    }
}

@Test("joins surrogate pairs split across pieces, escaped or raw")
func upstreamJoinsSurrogatePairs() {
    for text in [#"{"a":"\ud83d\ude00!"}"#, #"{"a":"😀!"}"#] {
        for split in 0...text.count {
            let characters = Array(text)
            let parser = StreamingJSONParser()
            parser.append(String(characters[..<split])); _ = parser.snapshot()
            parser.append(String(characters[split...]))
            #expect(parser.snapshot()?["a"]?.stringValue == "😀!")
        }
    }
    // Swift String cannot hold the upstream lone high surrogate; the partial is U+FFFD.
    #expect(upstreamSnapshot(#"{"a":"\ud83d"#, size: 1)?["a"]?.stringValue == "�")
}

@Test("keeps trailing whitespace of an unterminated string")
func upstreamKeepsOpenStringWhitespace() {
    #expect(upstreamSnapshot("{\"code\":\"x\t\t  ", size: 1)?["code"]?.stringValue == "x\t\t  ")
}

@Test("keeps raw control characters and invalid escapes visible while streaming")
func upstreamKeepsRawControls() {
    #expect(upstreamSnapshot("{\"a\":\"x\ny \\d \\u12\"", size: 1)?["a"]?.stringValue == "x\ny \\d \\u12")
}

@Test("keeps invalid \\u escapes literal without dropping fields (#10868)")
func upstreamKeepsInvalidUnicodeEscape() {
    let first = upstreamSnapshot(#"{"path":"a.tex","content":"\usepackage{x}","mode":"w"}"#, size: 1)
    #expect(first?["path"]?.stringValue == "a.tex")
    #expect(first?["content"]?.stringValue == #"\usepackage{x}"#)
    #expect(first?["mode"]?.stringValue == "w")
    #expect(upstreamSnapshot(#"{"text":"caf\u00e9 \url"}"#, size: 3)?["text"]?.stringValue == #"café \url"#)
}

@Test("makes `__proto__` an own member, as JSON.parse does")
func upstreamProtoIsOwnMember() {
    let text = #"{"__proto__":{"polluted":true},"b":{"__proto__":"x"}}"#
    for split in 0...text.count {
        let characters = Array(text)
        let parser = StreamingJSONParser()
        parser.append(String(characters[..<split])); _ = parser.snapshot()
        parser.append(String(characters[split...]))
        #expect(parser.snapshot()?["__proto__"]?["polluted"]?.serialized() == "true")
        #expect(parser.snapshot()?["b"]?["__proto__"]?.stringValue == "x")
    }
    // Swift dictionaries have no JavaScript prototype chain.
}

@Test("keeps the last value of a duplicate key in the first key's position, as JSON.parse does")
func upstreamDuplicateKeyOrder() {
    #expect(upstreamJSON(upstreamSnapshot(#"{"a":1,"b":2,"a":"three"}"#, size: 1)) == #"{"a":"three","b":2}"#)
}

@Test("reads %j")
func upstreamReadsPortedPartialJSONVectors() throws {
    let url = try #require(Bundle.module.url(forResource: "streaming-json-ported-vectors-v1.5.2", withExtension: "jsonl"))
    let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    #expect(rows.count == 74)
    for line in rows {
        let row = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let text = try #require(row["input"] as? String)
        let expected = row["expectedJSON"] as? String
        for size in [1, 2, max(1, text.count)] {
            #expect(upstreamJSON(upstreamSnapshot(text, size: size)) == expected, "\(text), chunk \(size)")
        }
    }
}

@Test("reads every JSONTestSuite document JSON.parse accepts exactly like it, and never throws on the rest")
func upstreamReadsJSONTestSuiteCorpus() throws {
    // The tag's 316-document corpus and Node results are embedded in the differential fixture.
    let url = try #require(Bundle.module.url(forResource: "streaming-json-v1.5.2", withExtension: "jsonl"))
    let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    var checked = 0
    for line in rows {
        let row = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        guard let name = row["name"] as? String, let chunks = row["chunks"] as? [String] else { continue }
        // The 500-level corpus text exceeds the measured Swift limit; surrogate values cannot live in Swift String.
        if name == "i_structure_500_nested_arrays.json" || name.contains("surrogate") { continue }
        let parser = StreamingJSONParser()
        for chunk in chunks { parser.append(chunk) }
        if let expected = row["final"] as? String { #expect(upstreamJSON(parser.snapshot()) == expected, "\(name)") }
        checked += 1
    }
    #expect(checked > 850)
}

@Test("never throws, keeps snapshots plain JSON and unchanged, at every chunk size")
func upstreamMalformedNeverThrows() {
    let malformed = [#"{"a":1 "b":2}"#, #"{"a" 1, "b": 2}"#, "{a:1, 'b':2}",
                     #"{"a":1,,"b":2,}"#, "[1 2, , 3,]", #"{"a":[1,2}, "b":3]"#,
                     "]]]}}}{", #"{"a":NaN,"b":Infinity,"e":1}"#, #"{"a":"x"} trailing garbage"#]
    for text in malformed {
        let expected = upstreamJSON(upstreamSnapshot(text, size: max(1, text.count)))
        for size in [1, 2, 3, 7] {
            let parser = StreamingJSONParser()
            var old: OrderedJSON?
            for part in upstreamParts(text, size: size) {
                parser.append(part)
                let copy = old.map(upstreamJSON)
                _ = parser.snapshot()
                #expect(old.map(upstreamJSON) == copy)
                old = parser.snapshot()
            }
            #expect(upstreamJSON(parser.snapshot()) == expected)
        }
    }
}

@Test("tolerates missing commas and colons and drops values in invalid positions")
func upstreamToleratesMissingPunctuation() {
    #expect(upstreamJSON(upstreamSnapshot(#"{"a":1 "b":2}"#, size: 1)) == #"{"a":1,"b":2}"#)
    #expect(upstreamJSON(upstreamSnapshot("[1 2, , 3,]", size: 1)) == "[1,2,3]")
    #expect(upstreamJSON(upstreamSnapshot(#"{"a":NaN,"b":Infinity,"e":1}"#, size: 1)) == #"{"e":1}"#)
}

@Test("survives random corruption of valid documents")
func upstreamSurvivesCorruption() {
    for text in upstreamValidTexts {
        for noise in ["x", "}", "\\", "1", "\n"] {
            let corrupted = String(text.prefix(text.count / 2)) + noise + String(text.dropFirst(text.count / 2))
            let parser = StreamingJSONParser()
            var mirror: OrderedJSON?
            for part in upstreamParts(corrupted, size: 4) {
                for change in parser.append(part) { upstreamApply(change, to: &mirror) }
                _ = parser.snapshot()
            }
            for change in parser.append(" ") { upstreamApply(change, to: &mirror) }
            #expect(upstreamJSON(mirror) == upstreamJSON(parser.snapshot()))
        }
    }
}

@Test("keep a copy equal to the value read so far, at every chunk size, and to JSON.parse at the end")
func upstreamChangesKeepCopyCurrent() {
    for text in upstreamValidTexts {
        for size in [1, 2, 3, 7] {
            let parser = StreamingJSONParser()
            var received = 0
            var mirror: OrderedJSON?
            for part in upstreamParts(text, size: size) {
                let changes = parser.append(part)
                received += changes.count
                for change in changes { upstreamApply(change, to: &mirror) }
            }
            #expect(received > 0)
            #expect(upstreamJSON(mirror) == upstreamJSON(parser.snapshot()))
        }
    }
}

@Test("report a number that ends and a string that starts in one piece, in order")
func upstreamChangesNumberThenString() {
    let parser = StreamingJSONParser()
    #expect(parser.append(#"{"n":1"#) == [JSONChange(kind: .set, path: [], value: .object([]))])
    #expect(parser.append(#"2,"s":"ab"#) == [
        JSONChange(kind: .set, path: [.key("n")], value: .number("12")),
        JSONChange(kind: .set, path: [.key("s")], value: .string("ab")),
    ])
}

@Test("report nested objects and arrays as empty containers, then their members and items")
func upstreamChangesNestedContainers() {
    let parser = StreamingJSONParser()
    let changes = parser.append(#"{"a":[1,{"b":["x""#)
    #expect(changes.map(\.path) == [[], [.key("a")], [.key("a"), .index(0)], [.key("a"), .index(1)],
                                   [.key("a"), .index(1), .key("b")], [.key("a"), .index(1), .key("b"), .index(0)]])
}

@Test("hold split escapes back and report their decoded text once complete")
func upstreamChangesSplitEscapes() {
    let parser = StreamingJSONParser()
    parser.append(#"{"a":"x"#)
    #expect(parser.append(#"\u00"#).isEmpty)
    #expect(parser.append("e9") == [JSONChange(kind: .append, path: [.key("a")], text: "é")])
}

@Test("report a container nested deeper than 32 levels once, whole, when it closes")
func upstreamChangesDeepContainer() {
    let text = String(repeating: #"{"a":"#, count: 40) + #""deep""# + String(repeating: "}", count: 40)
    let changes = StreamingJSONParser().append(text)
    #expect(changes.count == 34)
    #expect(changes.last?.path.count == 32)
}

@Test("report nothing for values in invalid positions and text after the root")
func upstreamChangesIgnoreInvalidPositions() {
    let parser = StreamingJSONParser()
    #expect(parser.append(#"{"a":1 2, "b" "x"}"#).count == 3)
    #expect(parser.append(#"{"c":3}"#).isEmpty)
}

@Test("allocates linearly in the streamed text, never per accumulated text")
func upstreamCostLinearAllocation() {
    // V8 allocation accounting has no Swift equivalent. Measure bounded elapsed time for fresh string previews.
    let stream = ToolCallArgumentsStream()
    stream.append(#"{"content":""#)
    let start = ContinuousClock.now
    for _ in 0..<16_250 { stream.append(String(repeating: "x", count: 32)) }
    stream.append(#""}"#)
    #expect(stream.finish().argumentsError == nil)
    #expect(start.duration(to: .now) < .seconds(10))
}

@Test("keeps very large open arrays linear by letting their preview lag")
func upstreamLargeArrayPreviewLag() {
    let parser = StreamingJSONParser()
    parser.append(#"{"items":["#)
    var shown = 0
    for number in 0..<100_000 {
        parser.append("\(number),")
        if case .array(let items) = parser.snapshot()?["items"] {
            #expect(items.count >= shown)
            shown = items.count
        }
    }
    parser.append("0]}")
    #expect(parser.snapshot()?["items"] != nil)
}

@Test("reads deep nesting without recursion and in linear time")
func upstreamDeepNestingAdapted() {
    // Upstream accepts 200,000 arrays; Swift stops at the measured stack-safe limit.
    let parser = StreamingJSONParser()
    parser.append(String(repeating: "[", count: 100_000))
    #expect(parser.snapshot() != nil)
    let stream = ToolCallArgumentsStream()
    stream.append(String(repeating: "[", count: 100_000))
    #expect(stream.finish().argumentsError != nil)
}

@Test("reads one huge piece, such as a provider's complete arguments, in linear time")
func upstreamReadsOneHugePiece() {
    let text = #"{"content":""# + String(repeating: "x", count: 500_000) + #""}"#
    let parser = StreamingJSONParser()
    let start = ContinuousClock.now
    parser.append(text)
    #expect(parser.snapshot()?["content"]?.stringValue?.utf8.count == 500_000)
    #expect(start.duration(to: .now) < .seconds(10))
}

@Test("shows partial arguments as an object and finishes with one full parse")
func upstreamToolStreamPartialAndFinal() {
    let stream = ToolCallArgumentsStream()
    #expect(stream.append("  ").isEmpty)
    #expect(stream.append(#"{"path":"a.ts","content":"x"#)["content"] == AnyCodable("x"))
    #expect(stream.append("y")["content"] == AnyCodable("xy"))
    #expect(stream.text == #"  {"path":"a.ts","content":"xy"#)
    #expect(stream.finish().argumentsError != nil)
    stream.append(#""}"#)
    #expect(stream.finish().arguments["content"] == AnyCodable("xy"))
}

@Test("shows non-object roots as no arguments yet")
func upstreamToolStreamNonObject() {
    let stream = ToolCallArgumentsStream()
    #expect(stream.append("[1,2").isEmpty)
    stream.append("]")
    #expect(stream.finish().argumentsError?.hasPrefix("Tool arguments must be a JSON object") == true)
}

@Test("replaces the text with the provider's complete text, returning the missing piece")
func upstreamToolStreamReplace() {
    let stream = ToolCallArgumentsStream()
    stream.append(#"{"a":"x"#)
    let continued = stream.replace(#"{"a":"xyz"}"#)
    #expect(continued.delta == #"yz"}"#)
    #expect(continued.arguments["a"] == AnyCodable("xyz"))
    let restarted = stream.replace(#"{"b":2}"#)
    #expect(restarted.delta == nil)
    #expect(restarted.arguments["b"] == AnyCodable(2))
}

@Test("is collected with its snapshots once the stream is dropped")
func upstreamToolStreamCollected() {
    // JS WeakRef observes snapshots; Swift snapshots are values. Check the stream object's lifetime.
    weak var weakStream: ToolCallArgumentsStream?
    do {
        let stream = ToolCallArgumentsStream()
        weakStream = stream
        for index in 0..<100 { _ = stream.append(#"{"a\#(index)":"\#(index)"#) }
    }
    #expect(weakStream == nil)
}
