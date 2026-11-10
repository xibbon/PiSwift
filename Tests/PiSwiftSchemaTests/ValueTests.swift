import Foundation
import Testing
@testable import PiSwiftSchema

@Test func structuralEquality() throws {
    let cases: [(String, String, Bool)] = [
        ("1", "1", true), ("\"a\"", "\"b\"", false), ("null", "null", true),
        ("{\"a\":1,\"b\":[1,{\"c\":2}]}", "{\"b\":[1,{\"c\":2}],\"a\":1}", true),
        ("{\"a\":1}", "{\"a\":1,\"b\":2}", false), ("[1,2]", "[2,1]", false),
        ("[1]", "{\"0\":1}", false), ("{}", "[]", false), ("true", "1", false),
        ("\"é\"", "\"e\\u0301\"", false),
    ]
    for (a, b, expected) in cases {
        #expect(schemaEqual(try .parse(json: a), try .parse(json: b)) == expected)
    }
}

@Test func jsonTextAndFoundationNumbers() throws {
    let value = try SchemaValue.parse(json: "{\"b\":1,\"a\":2,\"b\":3}")
    #expect(value.stringify() == "{\"b\":3,\"a\":2}")
    #expect(try SchemaValue.parse(json: "{\"2\":0,\"a\":1,\"1\":2}").stringify() == "{\"1\":2,\"2\":0,\"a\":1}")
    #expect(try SchemaValue.parse(json: Data("[true,false,0,1]".utf8)) == .array([.bool(true), .bool(false), .number(0), .number(1)]))
    #expect(try SchemaValue(jsonObject: NSNumber(value: true)) == .bool(true))
    #expect(try SchemaValue(jsonObject: NSNumber(value: false)) == .bool(false))
    #expect(try SchemaValue(jsonObject: NSNumber(value: 0)) == .number(0))
    #expect(try SchemaValue(jsonObject: NSNumber(value: 1)) == .number(1))
    #expect(throws: (any Error).self) { try SchemaValue(jsonObject: Date()) }
    let url = (Bundle.module.resourceURL ?? Bundle.module.bundleURL).appendingPathComponent("Fixtures/generated/number-text-v1.5.2.json")
    guard case let .array(vectors) = try SchemaValue.parse(json: Data(contentsOf: url)) else { Issue.record("Invalid number fixture"); return }
    for vector in vectors {
        guard case let .object(item) = vector, case let .string(input)? = item["input"],
              case let .string(expected)? = item["expected"] else { Issue.record("Invalid number vector"); continue }
        #expect(try SchemaValue.parse(json: input).stringify() == expected, "Input: \(input)")
    }
    for input in ["", "01", "[1,]", "{\"a\":}", "NaN", "true false"] {
        #expect(throws: (any Error).self) { try SchemaValue.parse(json: input) }
    }
}

@Test func regexEndAnchorRequiresAbsoluteEnd() {
    // Node.js RegExp("a$", "u") rejects each trailing line terminator.
    #expect(schemaRegexMatches("a$", "a"))
    #expect(schemaRegexMatches("a$", "ba"))
    for suffix in ["\n", "\r", "\r\n", "\u{2028}", "\u{2029}"] {
        #expect(!schemaRegexMatches("a$", "a" + suffix))
    }
}

@Test func objectIterationAndTextMatchJavaScript() throws {
    let url = (Bundle.module.resourceURL ?? Bundle.module.bundleURL)
        .appendingPathComponent("Fixtures/generated/object-text-v1.5.2.json")
    guard case let .array(vectors) = try SchemaValue.parse(json: Data(contentsOf: url)) else {
        Issue.record("Invalid object text fixture")
        return
    }
    for vector in vectors {
        guard case let .object(item) = vector,
              case let .string(input)? = item["input"],
              case let .string(expected)? = item["expected"] else {
            Issue.record("Invalid object text vector")
            continue
        }
        let parsed = try SchemaValue.parse(json: input)
        #expect(parsed.stringify() == expected, "Input: \(input)")
        guard case let .object(object) = parsed,
              case let .object(expectedObject) = try SchemaValue.parse(json: expected) else {
            Issue.record("Invalid object text value")
            continue
        }
        #expect(object.keys == expectedObject.keys, "Input: \(input)")
        #expect(Array(object).map { $0.key } == expectedObject.keys, "Input: \(input)")
    }
}
