import Foundation
import Testing
import PiSwiftAI
import PiSwiftCodingAgent

@Test func cm1CodemodeConstraintCommentsMatchUpstream() {
    let schema: [String: Any] = ["type": "object", "properties": [
        "timeoutMs": ["type": "integer", "minimum": 0, "maximum": 30_000, "default": 0,
                      "description": "Wait in milliseconds."],
        "id": ["type": "string", "pattern": "^[a-z]+$", "maxLength": 8],
        "tags": ["type": "array", "items": ["type": "string"], "maxItems": 5,
                 "uniqueItems": true, "deprecated": true],
        "name": ["type": "string"]
    ], "required": ["id"]]
    #expect(schemaToType(AnyCodable(schema)) == """
    {
      // @maxLength 8 @pattern ^[a-z]+$
      id: string;
      name?: string;
      // @maxItems 5 @uniqueItems @deprecated
      tags?: Array<string>;
      // Wait in milliseconds.
      // @integer @minimum 0 @maximum 30000 @default 0
      timeoutMs?: number;
    }
    """)
}

@Test func cm1CodemodeNullableConstraintsMatchUpstream() {
    let optional: [String: Any] = ["type": "object", "properties": ["limit": [
        "anyOf": [["type": "integer", "minimum": 1, "maximum": 100], ["type": "null"]],
        "default": NSNull(), "title": "Limit"
    ]]]
    #expect(schemaToType(AnyCodable(optional)) == "{\n  // @integer @minimum 1 @maximum 100\n  limit?: number | null;\n}")
    let combined: [String: Any] = ["type": "object", "properties": ["n": [
        "anyOf": [["type": "integer", "minimum": 10, "maximum": 50, "format": "int32"], ["type": "null"]],
        "minimum": 0, "maximum": 20, "format": "port"
    ]]]
    #expect(schemaToType(AnyCodable(combined)) == "{\n  // @integer @minimum 10 @maximum 20 @format port @format int32\n  n?: number | null;\n}")
}

@Test func cm1CodemodeDraft04ExclusiveBoundsMatchUpstream() {
    let schema: [String: Any] = ["type": "object", "properties": [
        "n": ["type": "integer", "minimum": 0, "exclusiveMinimum": true,
              "maximum": 10, "exclusiveMaximum": false],
        "m": ["anyOf": [["type": "number", "maximum": 5, "exclusiveMaximum": true], ["type": "null"]],
              "maximum": 8]
    ]]
    #expect(schemaToType(AnyCodable(schema)) == """
    {
      // @maximum 8 @exclusiveMaximum 5
      m?: number | null;
      // @integer @exclusiveMinimum 0 @maximum 10
      n?: number;
    }
    """)
}

@Test func cm1CodemodeLongTagsAndLineTerminatorsMatchUpstream() {
    let long: [String: Any] = ["type": "object", "properties": [
        "config": ["type": "object", "default": ["text": String(repeating: "x", count: 100)]]
    ]]
    #expect(schemaToType(AnyCodable(long)) == "{ config?: { [key: string]: unknown; }; }")
    let separators: [String: Any] = ["type": "object", "properties": [
        "sep": ["type": "string", "pattern": "^[\r\n\u{2028}\u{2029}]$", "default": "\u{2028}",
                "description": "a\u{2028}b"]
    ]]
    #expect(schemaToType(AnyCodable(separators)) == """
    {
      // a
      // b
      // @pattern ^[\\u000d\\u000a\\u2028\\u2029]$ @default "\\u2028"
      sep?: string;
    }
    """)
}

@Test func cm1CodemodeConstraintBudgetRetryMatchesUpstream() {
    let schema = AnyCodable(["type": "object", "properties": ["n": ["type": "integer", "minimum": 1]]] as [String: Any])
    #expect(schemaToType(schema) == "{\n  // @integer @minimum 1\n  n?: number;\n}")
    #expect(schemaToType(schema, maxChars: 20) == "{ n?: number; }")
    #expect(schemaToType(schema, maxChars: 10) == "unknown")
}

@Test func cm1CodemodeConstraintOrderAndBranchAnnotations() {
    let ordered: [String: Any] = ["type": "object", "properties": ["n": [
        "type": ["integer", "null"], "minimum": 1, "exclusiveMinimum": 2, "maximum": 9,
        "exclusiveMaximum": 8, "multipleOf": 2, "minLength": 3, "maxLength": 7, "pattern": "p",
        "format": "f", "minItems": 1, "maxItems": 4, "uniqueItems": true, "default": false, "deprecated": true
    ]]]
    #expect(schemaToType(AnyCodable(ordered)) == "{\n  // @integer @minimum 1 @exclusiveMinimum 2 @maximum 9 @exclusiveMaximum 8 @multipleOf 2 @minLength 3 @maxLength 7 @pattern p @format f @minItems 1 @maxItems 4 @uniqueItems @default false @deprecated\n  n?: number | null;\n}")
    let branch: [String: Any] = ["type": "object", "properties": ["n": [
        "oneOf": [["type": "integer", "multipleOf": 3, "format": "f", "default": 99, "deprecated": true],
                  ["type": "null"]],
        "multipleOf": 2, "format": "f", "default": 0
    ]]]
    #expect(schemaToType(AnyCodable(branch)) == "{\n  // @integer @multipleOf 2 @multipleOf 3 @format f @default 0\n  n?: number | null;\n}")
}

@Test func cm1CodemodeTagLimitCountsUTF16BeforeEscaping() {
    let accepted = String(repeating: "🙂", count: 35)
    let omitted = String(repeating: "🙂", count: 36)
    let escaped = String(repeating: "\u{2028}", count: 69)
    let schema: [String: Any] = ["type": "object", "properties": [
        "a": ["type": "string", "pattern": accepted],
        "b": ["type": "string", "pattern": omitted],
        "c": ["type": "string", "default": escaped,
              "description": "one\rtwo\nthree\u{2028}four\u{2029}five"]
    ]]
    #expect(schemaToType(AnyCodable(schema)) == """
    {
      // @pattern \(accepted)
      a?: string;
      b?: string;
      // one
      // two
      // three
      // four
      // five
      // @default "\(String(repeating: "\\u2028", count: 69))"
      c?: string;
    }
    """)
}

@Test func cm1CodemodeConstraintTagsKeepDistinctUTF16Strings() {
    let composed = "\u{00E9}"
    let decomposed = "e\u{0301}"
    let schema: [String: Any] = ["type": "object", "properties": ["n": [
        "oneOf": [["type": "string", "format": decomposed, "pattern": decomposed], ["type": "null"]],
        "format": composed, "pattern": composed
    ]]]
    let expected = "{\n  // @pattern \(composed) @pattern \(decomposed) @format \(composed) @format \(decomposed)\n  n?: string | null;\n}"
    #expect(Array(schemaToType(AnyCodable(schema)).utf16) == Array(expected.utf16))
}

@Test func cm1CodemodeBudgetRetryUsesFreshReferenceContext() {
    let names = (0..<32).map { String(format: "p%02d", $0) }
    let properties = Dictionary(uniqueKeysWithValues: names.map { ($0, ["$ref": "#/$defs/Entry"]) })
    let schema: [String: Any] = ["type": "object", "properties": properties, "$defs": [
        "Entry": ["type": "object", "properties": ["n": ["type": "integer", "minimum": 1]]]
    ]]
    let expected = "{ " + names.map { "\($0)?: { n?: number; };" }.joined(separator: " ") + " }"
    #expect(schemaToType(AnyCodable(schema), maxChars: expected.utf16.count) == expected)
}

@Test func cm1CodemodeMCPOutputUsesPlainTypesAndKeepsCompatibilityHelper() {
    let schema: [String: Any] = ["type": "object", "properties": [
        "content": ["type": "array", "items": ["type": "object"]],
        "isError": ["type": "boolean"], "_meta": ["type": "object"]
    ], "required": ["content"]]
    #expect(renderToolSignature(.init(name: "plain", inputSchema: AnyCodable(["type": "object", "properties": [:]] as [String: Any]),
                                     outputSchema: AnyCodable(schema))) ==
            "plain(args: { [key: string]: unknown; }): Promise<{ _meta?: { [key: string]: unknown; }; content: Array<{ [key: string]: unknown; }>; isError?: boolean; }>;")
    #expect(mcpStructuredContentSchema(AnyCodable(schema)) == AnyCodable(true))
    var structured = schema
    var properties = structured["properties"] as! [String: Any]
    properties["structuredContent"] = ["type": "string"]
    structured["properties"] = properties
    #expect(mcpStructuredContentSchema(AnyCodable(structured)) == AnyCodable(["type": "string"]))
    #expect(mcpStructuredContentSchema(AnyCodable(["type": "string"])) == nil)
}

@Test(arguments: [
    (1e20, "100000000000000000000"),
    (1e21, "1e+21"),
    (1e-6, "0.000001"),
    (1e-7, "1e-7"),
    (-0.0, "0"),
])
func cm1CodemodeNumberTagsUseJavaScriptFormatting(value: Double, expected: String) {
    let schema: [String: Any] = ["type": "object", "properties": ["n": [
        "type": "number", "minimum": value, "multipleOf": value, "default": value
    ]]]
    #expect(schemaToType(AnyCodable(schema)) == "{\n  // @minimum \(expected) @multipleOf \(expected) @default \(expected)\n  n?: number;\n}")
}

@Test func cm1CodemodeNestedDefaultsUseJavaScriptNumberFormatting() {
    let values: [Double] = [1e20, 1e21, 1e-6, 1e-7, -0.0]
    let schema: [String: Any] = ["type": "object", "properties": ["config": [
        "type": "object", "default": ["values": values, "a": -0.0]
    ]]]
    #expect(schemaToType(AnyCodable(schema)) == "{\n  // @default {\"a\":0,\"values\":[100000000000000000000,1e+21,0.000001,1e-7,0]}\n  config?: { [key: string]: unknown; };\n}")
}

@Test func cm1CodemodeNumericConstraintsUseJavaScriptDoubleEquality() {
    let schema: [String: Any] = ["type": "object", "properties": ["n": [
        "anyOf": [["type": "number", "multipleOf": Int64(9_007_199_254_740_993)], ["type": "null"]],
        "multipleOf": Int64(9_007_199_254_740_992)
    ]]]
    #expect(schemaToType(AnyCodable(schema)) == "{\n  // @multipleOf 9007199254740992\n  n?: number | null;\n}")
}
