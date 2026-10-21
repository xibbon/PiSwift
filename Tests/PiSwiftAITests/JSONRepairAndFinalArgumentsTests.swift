import Foundation
import Testing
@testable import PiSwiftAI

struct JSONRepairAndFinalArgumentsTests {
    @Test func invalidUnicodeEscapesKeepEveryField() {
        #expect(parseStreamingJSON(#"{"text":"\url{x}"}"#) == ["text": AnyCodable(#"\url{x}"#)])
        #expect(parseStreamingJSON(#"{"path":"a.tex","content":"\usepackage{x}","mode":"w"}"#) == [
            "path": AnyCodable("a.tex"), "content": AnyCodable(#"\usepackage{x}"#), "mode": AnyCodable("w")])
    }

    @Test func validUnicodeAndIncompleteUnicode() {
        #expect(parseStreamingJSON(#"{"text":"caf\u00e9 \url"}"#)["text"] == AnyCodable(#"café \url"#))
        #expect(parseStreamingJSON(#"{"text":"ab\u00"#)["text"] == AnyCodable("ab"))
        #expect(parseStreamingJSON(#"{"z":1,"text":"ab\u00"#)["z"] == AnyCodable(1))
    }

    @Test func fullFinalParseRepairsEscapesAndKeepsOrder() {
        let raw = #"{"z":{"last":1,"first":2},"a":"\url"}"#
        let parsed = parseToolCallArguments(raw)
        #expect(parsed.argumentsError == nil)
        #expect(parsed.arguments["a"] == AnyCodable(#"\url"#))
        var call = ToolCall(id: "id", name: "tool", arguments: [:])
        call.finalizeArguments(from: raw)
        #expect(call.argumentsJSON?.objectEntries?.map(\.0) == ["z", "a"])
        #expect(call.argumentsJSON?["z"]?.objectEntries?.map(\.0) == ["last", "first"])
    }

    @Test(arguments: ["", " \n\t", "\u{FEFF}", nil]) func blankFinalText(_ raw: String?) {
        let result = parseToolCallArguments(raw)
        #expect(result.arguments.isEmpty)
        #expect(result.argumentsError == nil)
    }

    @Test(arguments: [#"{"action":"apply","actions":[{"kind":"seek","time":.5}]}"#,
                      #"{"kind":"seek","clipId":"clip-fl"#, #"{"z":1} trailing"#, #"{"z":1}{"a":2}"#, #"{"z":1,}"#, #"{"z":[1,]}"#])
    func invalidFinalTextHasNoPrefix(_ raw: String) {
        var call = ToolCall(id: "id", name: "tool", arguments: [:])
        call.setArguments(from: #"{"z":1}"#)
        call.finalizeArguments(from: raw)
        #expect(call.arguments.isEmpty)
        #expect(call.argumentsJSON == nil)
        #expect(call.argumentsError == "Invalid JSON.\n\nReceived arguments:\n\(raw)")
    }

    @Test(arguments: ["[1,2]", "null", "true", "42", #""text""#])
    func finalValueMustBeAnObject(_ raw: String) {
        let result = parseToolCallArguments(raw)
        #expect(result.arguments.isEmpty)
        #expect(result.argumentsError == "Tool arguments must be a JSON object\n\nReceived arguments:\n\(raw)")
    }

    @Test func finalWhitespaceUsesJavaScriptTrimRules() {
        #expect(parseToolCallArguments("\u{85}").argumentsError != nil)
        #expect(parseToolCallArguments("\u{FEFF}{\"a\":1}").argumentsError != nil)
        #expect(parseStreamingJSON("\u{FEFF}{\"a\":1}")["a"] == AnyCodable(1))
    }

    @Test func repairOnlyChangesStringContents() {
        let raw = "{\"text\":\"a\nb\tc\u{0}\u{8}\u{c}\r\u{1f}\\q\",\"valid\":\"\\\\url \\\" \\/ \\u0061\"}"
        let parsed = parseToolCallArguments(raw)
        #expect(parsed.argumentsError == nil)
        #expect(parsed.arguments["text"] == AnyCodable("a\nb\tc\u{0}\u{8}\u{c}\r\u{1f}\\q"))
        #expect(parsed.arguments["valid"] == AnyCodable("\\url \" / a"))
        #expect(repairJSON("\\url") == "\\url")
        #expect(repairJSON(#"{"text":"abc\"#) == #"{"text":"abc\\"#)
    }

    @Test func partialSnapshotKeepsEscapesAndOrder() {
        var call = ToolCall(id: "id", name: "tool", arguments: [:])
        call.setArguments(from: #"{"z":"\\usepackage{x}","a":"line\nnext"#)
        #expect(call.arguments["z"] == AnyCodable(#"\usepackage{x}"#))
        #expect(call.arguments["a"] == AnyCodable("line\nnext"))
        #expect(call.argumentsJSON?.objectEntries?.map(\.0) == ["z", "a"])
    }

    // Golden cases from the pinned partial-json 0.1.7 dependency.
    @Test(arguments: [#"{"a":1,"b":-"#, #"{"a":1,"b":1."#, #"{"a":1,"b":1E"#,
                      #"{"a":1,"b":1E+"#, #"{"a":1,"b":truX"#])
    func malformedPartialChildKeepsPriorMembers(_ raw: String) {
        #expect(parseStreamingJSON(raw) == ["a": AnyCodable(1)])
        #expect(parseToolCallArguments(raw).argumentsError != nil)
    }

    @Test func partialDependencyRules() {
        #expect(parseStreamingJSON(#"{"a":1,"b":1e+"#) == ["a": AnyCodable(1), "b": AnyCodable(1)])
        for raw in [#"{"a":1,"b":"text\q"#, #"{"a":1,"b":"text\uZZ"#, #"{"a":1,"b":"text\u12"#] {
            #expect(parseStreamingJSON(raw) == ["a": AnyCodable(1), "b": AnyCodable("text")])
        }
        #expect(parseStreamingJSON(#"{"a":"text   "#)["a"] == AnyCodable("text"))
        #expect(parseStreamingJSON(#"{"a":"x" "b":"y"#) == ["a": AnyCodable("x"), "b": AnyCodable("y")])
        #expect(parseStreamingJSON(#"{"a"="b"#) == ["a": AnyCodable("b")])
        #expect(parseStreamingJSON(#"{"a":[1,-"#)["a"] == AnyCodable([1]))
        #expect(parseStreamingJSON(#"{"a":{"x":1,"y":-"#)["a"] == AnyCodable(["x": 1]))
        #expect(parseStreamingJSON(#"{"a":"\usepackage","b":"open"#).isEmpty)
        #expect((parseStreamingJSON(#"{"a":Na"#)["a"]?.value as? Double)?.isNaN == true)
        #expect((parseStreamingJSON(#"{"a":Inf"#)["a"]?.value as? Double) == .infinity)
        #expect((parseStreamingJSON(#"{"a":-Inf"#)["a"]?.value as? Double) == -.infinity)
    }

    @Test func incrementalUpdatesCannotClearFinalError() {
        var call = ToolCall(id: "id", name: "tool", arguments: [:])
        call.finalizeArguments(from: "{")
        let error = call.argumentsError
        call.setArguments(from: #"{"valid":true}"#)
        #expect(call.argumentsError == error)
        call.finalizeArguments(from: #"{"valid":true}"#)
        #expect(call.argumentsError == nil)
    }

    @Test func sharedCodecsRetainFinalError() throws {
        var call = ToolCall(id: "id", name: "tool", arguments: [:])
        call.finalizeArguments(from: #"{"kind":"cut"#)
        let text = contentBlockToOrderedJSON(.toolCall(call)).serialized()
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        for block in [contentBlockFromJSONObject(object), contentBlockFromJSONObject(object, ordered: try OrderedJSON.parse(text))] {
            guard case .toolCall(let copy) = block else { Issue.record("Missing call"); continue }
            #expect(copy.argumentsError == call.argumentsError)
            #expect(copy.arguments.isEmpty)
            #expect(copy.argumentsJSON == nil)
        }
    }

    @Test func largeSnapshotsStayBounded() {
        let deadline = ContinuousClock.now + .seconds(10)
        for size in [8_000, 32_000, 128_000] {
            for _ in 0..<3 {
                let raw = "{\"z\":1,\"text\":\"" + String(repeating: "a", count: size)
                #expect((parseStreamingJSON(raw)["text"]?.value as? String)?.utf8.count == size)
                #expect(ContinuousClock.now < deadline)
            }
        }
        let manyKeys = "{" + (0..<4000).map { "\"key\($0)\":\($0)" }.joined(separator: ",") + "}"
        #expect(parseStreamingJSON(manyKeys).count == 4000)
        #expect(ContinuousClock.now < deadline)
    }
}
