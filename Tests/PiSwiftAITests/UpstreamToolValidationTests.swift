import Foundation
import Testing
@testable import PiSwiftAI

private func upstreamTool(_ property: [String: Any], required: Bool = true) -> AITool {
    var schema: [String: Any] = ["type": "object", "properties": ["value": property]]
    if required { schema["required"] = ["value"] }
    return AITool(name: "echo", description: "", parameters: schema.mapValues(AnyCodable.init))
}

private func upstreamCall(_ value: Any) -> ToolCall {
    ToolCall(id: "1", name: "echo", arguments: ["value": AnyCodable(value)])
}

@Test("still validates when Function constructor is unavailable")
func upstreamValidationUsesInterpretedCompiler() throws {
    let result = try validateToolArguments(tool: upstreamTool(["type": "number"]), toolCall: upstreamCall("42"))
    #expect(result["value"]?.value as? Int == 42)
}

@Test("coerces serialized plain JSON schemas like TypeBox schemas")
func upstreamValidationCoercionCases() throws {
    let cases: [([String: Any], Any, AnyCodable)] = [
        (["type": "number"], "42", AnyCodable(42)), (["type": "number"], true, AnyCodable(1)),
        (["type": "number"], NSNull(), AnyCodable(0)), (["type": "integer"], "42.1", AnyCodable(42)),
        (["type": "boolean"], "true", AnyCodable(true)), (["type": "boolean"], 0, AnyCodable(false)),
        (["type": "string"], NSNull(), AnyCodable("null")), (["type": "null"], "", AnyCodable(NSNull())),
        (["type": "array", "items": ["type": "number"]], "7", AnyCodable([7]))
    ]
    for (schema, input, expected) in cases {
        let result = try validateToolArguments(tool: upstreamTool(schema), toolCall: upstreamCall(input))
        #expect(result["value"] == expected)
    }
}

@Test("treats null as omission for optional non-nullable properties")
func upstreamOptionalNullOmission() throws {
    let result = try validateToolArguments(tool: upstreamTool(["type": "number"], required: false),
                                           toolCall: upstreamCall(NSNull()))
    #expect(result["value"] == nil)
}

@Test("preserves optional nulls whose referenced schema is nullable")
func upstreamReferencedNullableNull() throws {
    let schema: [String: Any] = ["type": "object", "properties": ["value": ["$ref": "#/$defs/value"]],
        "$defs": ["value": ["anyOf": [["type": "number"], ["type": "null"]]]]]
    let tool = AITool(name: "echo", description: "", parameters: schema.mapValues(AnyCodable.init))
    #expect(try validateToolArguments(tool: tool, toolCall: upstreamCall(NSNull()))["value"]?.value is NSNull)
}

@Test("preserves a value that already matches a nullable union arm")
func upstreamNullableUnionArm() throws {
    #expect(try validateToolArguments(tool: upstreamTool(["anyOf": [["type": "number"], ["type": "null"]]]),
                                      toolCall: upstreamCall(NSNull()))["value"]?.value is NSNull)
}

@Test("preserves a value that already matches a oneOf nullable union arm")
func upstreamNullableOneOfArm() throws {
    #expect(try validateToolArguments(tool: upstreamTool(["oneOf": [["type": "number"], ["type": "null"]]]),
                                      toolCall: upstreamCall(NSNull()))["value"]?.value is NSNull)
}

@Test("still coerces nullable unions when the original value does not match any arm")
func upstreamNullableUnionCoercion() throws {
    #expect(try validateToolArguments(tool: upstreamTool(["anyOf": [["type": "number"], ["type": "null"]]]),
                                      toolCall: upstreamCall("42"))["value"]?.value as? Int == 42)
}

@Test("accepts null for nullable array schemas with items")
func upstreamNullableArray() throws {
    #expect(try validateToolArguments(tool: upstreamTool(["type": ["array", "null"], "items": ["type": "string"]]),
                                      toolCall: upstreamCall(NSNull()))["value"]?.value is NSNull)
}

@Test("rejects invalid coercions for serialized plain JSON schemas")
func upstreamInvalidCoercions() {
    for (schema, value): ([String: Any], Any) in [(["type": "boolean"], "yes"), (["type": "number"], "abc"),
                                                (["type": "null"], "nil"), (["type": "integer"], "4x")] {
        #expect(throws: ValidationError.self) {
            try validateToolArguments(tool: upstreamTool(schema), toolCall: upstreamCall(value))
        }
    }
}

@Test("lists pi-schema's errors, then the arguments it received")
func upstreamCompleteErrorText() {
    do { _ = try validateToolArguments(tool: upstreamTool(["type": "number"]), toolCall: upstreamCall("many")) }
    catch {
        #expect(error.localizedDescription == "Validation failed for tool \"echo\":\n  - value: expected number, got string\n\nReceived arguments:\n{\n  \"value\": \"many\"\n}")
    }
}

@Test("reports a missing required property at the property")
func upstreamMissingProperty() {
    do { _ = try validateToolArguments(tool: upstreamTool(["type": "string"]),
                                       toolCall: ToolCall(id: "1", name: "echo", arguments: [:])) }
    catch { #expect(error.localizedDescription.contains("  - value: missing")) }
}

@Test("returns a copy of the arguments, also when nothing is coerced")
func upstreamUnchangedArguments() throws {
    let call = upstreamCall("x")
    let result = try validateToolArguments(tool: upstreamTool(["type": "string"]), toolCall: call)
    #expect(result == call.arguments)
}

@Test("reports malformed arguments JSON instead of validating empty arguments")
func upstreamMalformedArgumentsError() {
    let call = ToolCall(id: "1", name: "echo", arguments: [:], argumentsError: "Unexpected token")
    do { _ = try validateToolArguments(tool: upstreamTool(["type": "string"], required: false), toolCall: call) }
    catch { #expect(error.localizedDescription == "Invalid arguments for tool \"echo\": Unexpected token") }
}

@Test("accepts the last member of a 10,000-value enum")
func upstreamLargeEnum() throws {
    let members = (0..<10_000).map { "member\($0)" }
    let tool = upstreamTool(["type": "string", "enum": members])
    let result = try validateToolArguments(tool: tool, toolCall: upstreamCall("member9999"))
    #expect(result["value"]?.value as? String == "member9999")
    #expect(throws: ValidationError.self) {
        try validateToolArguments(tool: tool, toolCall: upstreamCall("x"))
    }
}

@Test("schema mutation recompiles the value-keyed Swift cache")
func upstreamSchemaMutationAdaptation() throws {
    var tool = upstreamTool(["type": "number", "minimum": 0])
    #expect(try validateToolArguments(tool: tool, toolCall: upstreamCall("4"))["value"]?.value as? Int == 4)
    tool.parameters["properties"] = AnyCodable(["value": ["type": "number", "minimum": 10] as [String: Any]])
    // Upstream's WeakMap retains the old validator for the same mutated object.
    #expect(throws: ValidationError.self) {
        try validateToolArguments(tool: tool, toolCall: upstreamCall("4"))
    }
}
