import Foundation
import Testing
import PiSwiftAI
import PiSwiftCodingAgent

private func c1cAssistant(_ content: [ContentBlock]) -> Message {
    .assistant(AssistantMessage(
        content: content, api: .anthropicMessages, provider: "anthropic", model: "test",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .toolUse, timestamp: 0
    ))
}

// compaction-serialization.test.ts:80
@Test func c1cSerializationOmitsThinking() {
    let message = c1cAssistant([
        .thinking(ThinkingContent(thinking: "private reasoning", thinkingSignature: "sig")),
        .text(TextContent(text: "visible reply")),
        .toolCall(ToolCall(id: "tc1", name: "read", arguments: ["path": AnyCodable("a.ts")]))
    ])
    #expect(serializeConversation([message]) == "[Assistant]: visible reply\n\n[Assistant tool calls]: read(path=\"a.ts\")")
    #expect(serializeConversation([c1cAssistant([.thinking(ThinkingContent(thinking: "private reasoning"))])]) == "")
}

@Test func c1cSerializationUsesJSONValuesAndStoredOrder() throws {
    let source = try OrderedJSON.parse(#"{"text":"a/\"b\n","number":2.5,"flag":true,"object":{"z":null,"a":1},"array":["x",2,false,null,{"b":2,"a":1}],"nil":null}"#)
    let arguments: [String: AnyCodable] = [
        "text": AnyCodable("a/\"b\n"), "number": AnyCodable(2.5), "flag": AnyCodable(true),
        "object": AnyCodable(["z": NSNull(), "a": 1] as [String: Any]),
        "array": AnyCodable(["x", 2, false, NSNull(), ["b": 2, "a": 1]] as [Any]),
        "nil": AnyCodable(NSNull())
    ]
    let message = c1cAssistant([.toolCall(ToolCall(id: "tc1", name: "inspect", arguments: arguments, argumentsJSON: source))])
    // JSON.stringify quotes strings, uses compact JSON, and does not escape slashes.
    let expected = #"[Assistant tool calls]: inspect(text="a/\"b\n", number=2.5, flag=true, object={"z":null,"a":1}, array=["x",2,false,null,{"b":2,"a":1}], nil=null)"#
    #expect(serializeConversation([message]) == expected)
}

@Test func c1cSerializationUsesCurrentValuesAndDictionaryOrderMetadata() throws {
    let source = try OrderedJSON.parse(#"{"z":"old","a":{"second":2,"first":1}}"#)
    let arguments = toolArgumentsWithOrder([
        "a": AnyCodable(["first": 1, "second": 3]), "z": AnyCodable("new")
    ], argumentsJSON: source)
    let message = c1cAssistant([.toolCall(ToolCall(id: "tc1", name: "inspect", arguments: arguments))])
    #expect(serializeConversation([message]) == #"[Assistant tool calls]: inspect(z="new", a={"second":3,"first":1})"#)
}

@Test func c1cSerializationUsesStableOrderWithoutStoredOrder() {
    let message = c1cAssistant([.toolCall(ToolCall(id: "tc1", name: "inspect", arguments: [
        "z": AnyCodable(1), "a": AnyCodable(2), "10": AnyCodable(10), "2": AnyCodable(2)
    ]))])
    #expect(serializeConversation([message]) == "[Assistant tool calls]: inspect(2=2, 10=10, a=2, z=1)")
}

@Test func c1cSerializationUsesJavaScriptNumbersAndIndexKeys() throws {
    let source = try OrderedJSON.parse(#"{"z":{"10":10,"2":2,"a":1},"10":10,"2":2,"01":1,"values":[]}"#)
    let values: [Double] = [-0.0, 1e-7, 1e-6, 1e20, 1e21, .nan, .infinity, -.infinity]
    let arguments: [String: AnyCodable] = [
        "z": AnyCodable(["10": 10, "2": 2, "a": 1]), "10": AnyCodable(10),
        "2": AnyCodable(2), "01": AnyCodable(1), "values": AnyCodable(values)
    ]
    let message = c1cAssistant([.toolCall(ToolCall(id: "tc1", name: "inspect", arguments: arguments, argumentsJSON: source))])
    #expect(serializeConversation([message]) == #"[Assistant tool calls]: inspect(2=2, 10=10, z={"2":2,"10":10,"a":1}, 01=1, values=[0,1e-7,0.000001,100000000000000000000,1e+21,null,null,null])"#)
}

// prompt-templates.test.ts:439
@Test(arguments: ["\"", "'"]) func c1cEmptyPromptArgumentUsesDefaultWithoutShifting(_ quote: String) {
    let template = PromptTemplate(
        name: "review", description: "test", content: "Review $2. Focus: ${1:-correctness}.",
        source: "local", filePath: "/tmp/review.md"
    )
    #expect(expandPromptTemplate("/review \(quote)\(quote) src/index.ts", [template]) == "Review src/index.ts. Focus: correctness.")
    #expect(parseCommandArgs("a \(quote)\(quote) c") == ["a", "", "c"])
    #expect(parseCommandArgs("a \(quote)\(quote)") == ["a", ""])
    #expect(parseCommandArgs("\(quote)\(quote) \(quote) \(quote)") == ["", " "])
}

// prompt-templates.test.ts:456
@Test func c1cPromptArgumentsSplitOnUnquotedNewlines() {
    let input = "label-2\n\nHere is some description #2."
    #expect(parseCommandArgs(input) == ["label-2", "Here", "is", "some", "description", "#2."])
    #expect(parseCommandArgs("a\n\n\tb  c") == ["a", "b", "c"])
    let template = PromptTemplate(
        name: "arg-test", description: "test", content: "- arg1: $1\n- rest: ${@:2}",
        source: "local", filePath: "/tmp/arg-test.md"
    )
    #expect(expandPromptTemplate("/arg-test " + input, [template]) == "- arg1: label-2\n- rest: Here is some description #2.")
}

@Test func c1cPromptArgumentsUseJavaScriptWhitespace() {
    let whitespace = "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D} \u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}"
    for scalar in whitespace.unicodeScalars {
        #expect(parseCommandArgs("a\(scalar)''\(scalar)b") == ["a", "", "b"])
        #expect(parseCommandArgs("'a\(scalar)b'") == ["a\(scalar)b"])
    }
    #expect(parseCommandArgs("a\u{0085}b") == ["a\u{0085}b"])
    #expect(parseCommandArgs("a \u{0301}b") == ["a", "\u{0301}b"])
}
