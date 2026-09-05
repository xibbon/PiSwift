import Foundation
import Testing
@testable import PiSwiftAI

private func strictPortSchema() -> [String: AnyCodable] {
    ["type": AnyCodable("object"), "required": AnyCodable(["path", "metadata"]), "properties": AnyCodable([
        "path": ["type": "string"],
        "offset": ["type": "number"],
        "metadata": ["type": "object", "properties": ["enabled": ["type": "boolean"]]],
        "nullable": ["anyOf": [["type": "string"], ["type": "null"]]],
    ] as [String: Any])]
}

@Test func strictSchemaDerivesProviderSchemaWithoutChangingTool() throws {
    let parameters = strictPortSchema()
    let strict = try makeStrictJsonSchema(parameters).mapValues(\.value)
    #expect(parameters["additionalProperties"] == nil)
    #expect(parameters["required"]?.value as? [String] == ["path", "metadata"])
    #expect(strict["additionalProperties"] as? Bool == false)
    #expect(Set(strict["required"] as? [String] ?? []) == Set(["path", "offset", "metadata", "nullable"]))
    let properties = try #require(strict["properties"] as? [String: Any])
    let offset = try #require(properties["offset"] as? [String: Any])
    #expect(offset["anyOf"] as? [[String: String]] == [["type": "number"], ["type": "null"]])
    let metadata = try #require(properties["metadata"] as? [String: Any])
    #expect(metadata["required"] as? [String] == ["enabled"])
    #expect(metadata["additionalProperties"] as? Bool == false)
    let children = try #require(metadata["properties"] as? [String: Any])
    #expect((children["enabled"] as? [String: Any])?["anyOf"] as? [[String: String]] == [["type": "boolean"], ["type": "null"]])
    #expect((properties["nullable"] as? [String: Any])?["anyOf"] as? [[String: String]] == [["type": "string"], ["type": "null"]])
}

@Test func strictSchemaUnsupportedFormsPreferFallbackAndRequireError() throws {
    let cases: [([String: Any], String)] = [
        (["type": "object", "properties": ["metadata": ["type": "object", "additionalProperties": ["type": "string"]]]], "additionalProperties is unsupported"),
        (["allOf": [["type": "object", "properties": ["a": ["type": "string"]]], ["type": "object", "properties": ["b": ["type": "number"]]]]], "allOf schemas are unsupported"),
        (["type": "object", "properties": ["value": ["anyOf": [["type": "object", "properties": ["nested": ["type": "string"]]], ["type": "null"]]]]], "object and array unions are unsupported"),
        (["type": "object", "properties": ["child": ["$ref": "https://example.com/child.json"]], "required": ["child"]], "$ref schemas are unsupported"),
    ]
    for (parameters, expected) in cases {
        let original = parameters.mapValues(AnyCodable.init)
        let preferred = AITool(name: "sample", description: "Sample", parameters: original, constrainedSampling: .jsonSchema(strict: .prefer))
        #expect(try resolveJsonSchemaStrictSampling(tool: preferred, supportsStrictMode: true) == nil)
        #expect(try getJsonSchemaToolParameters(preferred, strict: false) == original)
        do {
            _ = try makeStrictJsonSchema(original)
            Issue.record("Unsupported schema was accepted")
        } catch { #expect(error.localizedDescription.contains(expected)) }
        let required = AITool(name: "sample", description: "Sample", parameters: original, constrainedSampling: .jsonSchema(strict: .require))
        do {
            _ = try resolveJsonSchemaStrictSampling(tool: required, supportsStrictMode: true)
            Issue.record("Required strict schema was accepted")
        } catch { #expect(error.localizedDescription.contains(expected)) }
    }
}

@Test func strictSchemaRecursesThroughArrayItems() throws {
    let schema: [String: Any] = ["type": "object", "required": ["rows"], "properties": ["rows": [
        "type": "array", "items": ["type": "object", "properties": ["label": ["type": "string"]]],
    ]]]
    let strict = try makeStrictJsonSchema(schema.mapValues(AnyCodable.init)).mapValues(\.value)
    let properties = try #require(strict["properties"] as? [String: Any])
    let rows = try #require(properties["rows"] as? [String: Any])
    let items = try #require(rows["items"] as? [String: Any])
    #expect(items["required"] as? [String] == ["label"])
    #expect(items["additionalProperties"] as? Bool == false)
}

@Test func optionalNullsAreOmissionsBeforeValidation() throws {
    let tool = AITool(name: "echo", description: "Echo", parameters: strictPortSchema())
    let arguments: [String: AnyCodable] = ["path": AnyCodable("file.txt"), "offset": AnyCodable(NSNull()),
        "nullable": AnyCodable(NSNull()), "metadata": AnyCodable(["enabled": NSNull()])]
    let result = try validateToolArguments(tool: tool, toolCall: ToolCall(id: "tool-1", name: "echo", arguments: arguments))
    #expect(result["path"]?.value as? String == "file.txt")
    #expect(result["offset"] == nil)
    #expect(result["nullable"]?.value is NSNull)
    #expect((result["metadata"]?.value as? [String: Any])?.isEmpty == true)
    #expect(arguments["offset"]?.value is NSNull)
}

@Test func optionalReferencedNullableNullIsPreserved() throws {
    let schema: [String: Any] = ["type": "object", "properties": ["value": ["$ref": "#/$defs/value"]],
        "$defs": ["value": ["anyOf": [["type": "number"], ["type": "null"]]]]]
    let tool = AITool(name: "echo", description: "Echo", parameters: schema.mapValues(AnyCodable.init))
    let result = try validateToolArguments(tool: tool, toolCall: ToolCall(id: "tool-1", name: "echo", arguments: ["value": AnyCodable(NSNull())]))
    #expect(result["value"]?.value is NSNull)
}

@Test func optionalNullNormalizationHandlesArraysTuplesAndExplicitNulls() throws {
    let optionalObject: [String: Any] = ["type": "object", "properties": ["optional": ["type": "number"], "required": ["type": "string"]], "required": ["required"]]
    let value: [String: Any] = ["optional": NSNull(), "required": NSNull(), "unknown": NSNull()]
    let arraySchemas: [[String: Any]] = [["type": "array", "items": optionalObject], ["type": "array", "items": [optionalObject]]]
    for schema in arraySchemas {
        let normalized = try #require(normalizeOptionalNulls([value], schema: schema) as? [[String: Any]])
        #expect(normalized[0]["optional"] == nil)
        #expect(normalized[0]["required"] is NSNull)
        #expect(normalized[0]["unknown"] is NSNull)
    }
    let nullable: [[String: Any]] = [["type": "null"], ["type": ["string", "null"]], ["const": NSNull()], ["enum": ["x", NSNull()]], ["anyOf": [["type": "string"], ["type": "null"]]], ["$ref": "external"]]
    for property in nullable {
        let schema: [String: Any] = ["type": "object", "properties": ["value": property]]
        #expect((normalizeOptionalNulls(["value": NSNull()], schema: schema) as? [String: Any])?["value"] is NSNull)
    }
}

@Test func optionalNullsRespectUnconstrainedAndConstantSchemas() throws {
    for property: [String: Any] in [[:], ["const": NSNull()], ["enum": ["yes", NSNull()]], ["allOf": [["type": "null"]]]] {
        let schema: [String: Any] = ["type": "object", "properties": ["value": property]]
        let tool = AITool(name: "test", description: "Test", parameters: schema.mapValues(AnyCodable.init))
        let result = try validateToolArguments(tool: tool, toolCall: ToolCall(id: "call", name: "test", arguments: ["value": AnyCodable(NSNull())]))
        #expect(result["value"]?.value is NSNull)
    }
}
