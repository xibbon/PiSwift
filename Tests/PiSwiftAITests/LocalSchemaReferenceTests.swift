import Foundation
import Testing
@testable import PiSwiftAI

private func recursiveNodeSchema() -> [String: Any] {
    [
        "$ref": "#/$defs/Node",
        "$defs": [
            "Node": [
                "type": "object",
                "properties": [
                    "name": ["type": "string"],
                    "children": ["type": "array", "items": ["$ref": "#/$defs/Node"]]
                ],
                "required": ["name"],
                "additionalProperties": false
            ]
        ]
    ]
}

@Test func localSchemaReferencesValidateRecursiveChildren() {
    let valid: [String: Any] = ["name": "root", "children": [["name": "child", "children": [["name": "leaf"]]]]]
    let invalid: [String: Any] = ["name": "root", "children": [["name": "child", "children": [["name": "leaf", "typo": true]]]]]
    #expect(JSONSchemaValidator.shared.validate(valid, against: recursiveNodeSchema(), coerceTypes: false).isValid)
    let result = JSONSchemaValidator.shared.validate(invalid, against: recursiveNodeSchema(), coerceTypes: false)
    #expect(!result.isValid)
    #expect(result.errors.first?.path == "children[0].children[0].typo")
    #expect(result.errors.first?.message == "additional property not allowed")
}

@Test func localSchemaReferencesKeepRootAcrossCombinatorsAndMaps() {
    let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": ["anyOf": [["$ref": "#/$defs/Count"], ["type": "null"]]],
        "$defs": ["Count": ["type": "integer", "minimum": 2]]
    ]
    #expect(JSONSchemaValidator.shared.validate(["a": 3, "b": NSNull()] as [String: Any], against: schema, coerceTypes: false).isValid)
    #expect(!JSONSchemaValidator.shared.validate(["a": 1], against: schema, coerceTypes: false).isValid)
    let result = JSONSchemaValidator.shared.validate(["a": "3"], against: schema)
    #expect(result.isValid)
    #expect((result.coercedValue as? [String: Any])?["a"] as? Int == 3)
}

@Test func localSchemaReferencesDecodeJSONPointerEscapes() {
    let schema: [String: Any] = [
        "$ref": "#/$defs/item~1name~0value",
        "$defs": ["item/name~value": ["type": "string", "minLength": 2]]
    ]
    #expect(JSONSchemaValidator.shared.validate("ok", against: schema, coerceTypes: false).isValid)
    #expect(!JSONSchemaValidator.shared.validate("x", against: schema, coerceTypes: false).isValid)
}

@Test(arguments: ["#/$defs/missing", "https://example.com/schema", "#/$defs/invalid~2escape"])
func localSchemaReferencesRejectUnresolvedReferences(reference: String) {
    let result = JSONSchemaValidator.shared.validate("value", against: ["$ref": reference])
    #expect(!result.isValid)
    #expect(result.errors.first?.message == "unresolved local schema reference")
}

@Test func localSchemaReferencesRejectCyclesWithoutValueProgress() {
    let schema: [String: Any] = ["$ref": "#/$defs/A", "$defs": ["A": ["$ref": "#/$defs/B"], "B": ["$ref": "#/$defs/A"]]]
    let result = JSONSchemaValidator.shared.validate("value", against: schema)
    #expect(!result.isValid)
    #expect(result.errors.first?.message == "cyclic schema reference without value progress")
}

@Test func localSchemaReferencesRejectSelfCycles() {
    let schema: [String: Any] = ["$ref": "#/$defs/A", "$defs": ["A": ["$ref": "#/$defs/A"]]]
    let result = JSONSchemaValidator.shared.validate("value", against: schema)
    #expect(!result.isValid)
    #expect(result.errors.first?.message == "cyclic schema reference without value progress")
}

@Test func localSchemaReferencesAllowCompletedTargetsInSiblingBranches() {
    let schema: [String: Any] = [
        "$ref": "#/$defs/Text",
        "allOf": [["$ref": "#/$defs/Text"], ["$ref": "#/$defs/Text"]],
        "$defs": ["Text": ["type": "string"]]
    ]
    #expect(JSONSchemaValidator.shared.validate("ok", against: schema, coerceTypes: false).isValid)
    #expect(!JSONSchemaValidator.shared.validate(2, against: schema, coerceTypes: false).isValid)
    let result = JSONSchemaValidator.shared.validate(2, against: schema)
    #expect(result.isValid)
    #expect(result.coercedValue as? String == "2")
}

@Test func localSchemaReferencesApplySiblingAssertions() {
    let schema: [String: Any] = ["$ref": "#/$defs/Text", "maxLength": 3, "$defs": ["Text": ["type": "string", "minLength": 2]]]
    #expect(JSONSchemaValidator.shared.validate("ok", against: schema, coerceTypes: false).isValid)
    #expect(!JSONSchemaValidator.shared.validate("long", against: schema, coerceTypes: false).isValid)
}

@Test func localSchemaReferencesApplyObjectSiblingsWithoutType() {
    let schema: [String: Any] = [
        "$ref": "#/$defs/Object",
        "required": ["count"],
        "properties": ["count": ["type": "integer", "minimum": 2]],
        "additionalProperties": false,
        "$defs": ["Object": ["type": "object"]]
    ]
    #expect(JSONSchemaValidator.shared.validate(["count": 2], against: schema, coerceTypes: false).isValid)
    #expect(!JSONSchemaValidator.shared.validate([:] as [String: Any], against: schema, coerceTypes: false).isValid)
    #expect(!JSONSchemaValidator.shared.validate(["count": 1], against: schema, coerceTypes: false).isValid)
    #expect(!JSONSchemaValidator.shared.validate(["count": 2, "extra": 3], against: schema, coerceTypes: false).isValid)
    let result = JSONSchemaValidator.shared.validate(["count": "2"], against: schema)
    #expect(result.isValid)
    #expect((result.coercedValue as? [String: Any])?["count"] as? Int == 2)
}

@Test func localSchemaReferencesApplyNumericSiblingsWithoutType() {
    let schema: [String: Any] = [
        "$ref": "#/$defs/Number",
        "minimum": 2,
        "maximum": 4,
        "$defs": ["Number": ["type": "number"]]
    ]
    #expect(JSONSchemaValidator.shared.validate(2, against: schema, coerceTypes: false).isValid)
    #expect(JSONSchemaValidator.shared.validate(4, against: schema, coerceTypes: false).isValid)
    #expect(!JSONSchemaValidator.shared.validate(1, against: schema, coerceTypes: false).isValid)
    #expect(!JSONSchemaValidator.shared.validate(5, against: schema, coerceTypes: false).isValid)
    let result = JSONSchemaValidator.shared.validate("3", against: schema)
    #expect(result.isValid)
    #expect(result.coercedValue as? Double == 3)
}

@Test(arguments: [0, 1, 2])
func localSchemaReferencesApplyNumericSiblingsToDecodedNumbers(number: Int) throws {
    let decoded = try #require(JSONSerialization.jsonObject(with: Data("{\"value\":\(number)}".utf8)) as? [String: Any])
    let value = try #require(decoded["value"])
    let schema: [String: Any] = [
        "$ref": "#/$defs/Number",
        "minimum": 0,
        "maximum": 2,
        "$defs": ["Number": ["type": "number"]]
    ]
    let result = JSONSchemaValidator.shared.validate(value, against: schema, coerceTypes: false)
    #expect(result.isValid)
    #expect(result.coercedValue as? Double == Double(number))
    #expect(JSONSchemaValidator.shared.validate(value, against: ["minimum": 0, "maximum": 2], coerceTypes: false).isValid)
    #expect(!JSONSchemaValidator.shared.validate(value, against: ["minimum": number + 1], coerceTypes: false).isValid)
}

@Test(arguments: [false, true])
func localSchemaReferencesRejectDecodedBooleansAsNumbers(boolean: Bool) throws {
    let decoded = try #require(JSONSerialization.jsonObject(with: Data("{\"value\":\(boolean)}".utf8)) as? [String: Any])
    let value = try #require(decoded["value"])
    let schema: [String: Any] = [
        "$ref": "#/$defs/Number",
        "minimum": 0,
        "maximum": 2,
        "$defs": ["Number": ["type": "number"]]
    ]
    #expect(!JSONSchemaValidator.shared.validate(value, against: schema, coerceTypes: false).isValid)
    #expect(JSONSchemaValidator.shared.validate(value, against: ["minimum": 2], coerceTypes: false).isValid)
}

@Test func assertionsWithoutTypeApplyOnlyToMatchingValues() {
    let validator = JSONSchemaValidator.shared
    #expect(!validator.validate("long", against: ["maxLength": 3]).isValid)
    #expect(validator.validate(1234, against: ["maxLength": 3]).isValid)
    #expect(!validator.validate(1, against: ["minimum": 2]).isValid)
    let unchanged = validator.validate("1", against: ["minimum": 2])
    #expect(unchanged.isValid)
    #expect(unchanged.coercedValue as? String == "1")
    #expect(validator.validate(true, against: ["minimum": 2]).isValid)
    #expect(validator.validate("value", against: ["required": ["count"]]).isValid)
    #expect(!validator.validate([1, 2], against: ["maxItems": 1]).isValid)
    #expect(validator.validate("value", against: ["maxItems": 1]).isValid)
}

@Test func toolValidationAppliesReferenceSiblingsToDecodedArguments() throws {
    // These cases also pass through pi-mono's validateToolArguments with TypeBox 1.3.27.
    let schema: [String: Any] = [
        "$ref": "#/$defs/Args",
        "allOf": [["$ref": "#/$defs/Args"]],
        "$defs": [
            "Args": ["type": "object", "required": ["text", "count"], "properties": [
                "text": ["$ref": "#/$defs/Text", "maxLength": 3],
                "count": ["$ref": "#/$defs/Count", "minimum": 0, "maximum": 2]
            ]],
            "Text": ["type": "string"],
            "Count": ["type": "integer"]
        ]
    ]
    let tool = AITool(name: "probe", description: "Check arguments", parameters: schema.mapValues(AnyCodable.init))
    let valid = try JSONDecoder().decode([String: AnyCodable].self, from: Data(#"{"text":"ok","count":0}"#.utf8))
    let result = try validateToolArguments(tool: tool, toolCall: ToolCall(id: "valid", name: tool.name, arguments: valid))
    #expect(result["text"]?.value as? String == "ok")
    #expect(result["count"]?.value as? Int == 0)
    for json in [#"{"text":"long","count":0}"#, #"{"text":"ok","count":3}"#, #"{"text":"ok"}"#] {
        let invalid = try JSONDecoder().decode([String: AnyCodable].self, from: Data(json.utf8))
        #expect(throws: ValidationError.self) {
            try validateToolArguments(tool: tool, toolCall: ToolCall(id: "invalid", name: tool.name, arguments: invalid))
        }
    }
}

@Test func localSchemaReferencesKeepProgressSeparateFromErrorPaths() {
    let schema: [String: Any] = [
        "$ref": "#/$defs/Node",
        "$defs": ["Node": [
            "type": "object",
            "properties": ["root": ["$ref": "#/$defs/Node"]],
            "additionalProperties": false
        ]]
    ]
    let valid: [String: Any] = ["root": ["root": [:]]]
    #expect(JSONSchemaValidator.shared.validate(valid, against: schema, coerceTypes: false).isValid)
    let invalid: [String: Any] = ["root": ["root": ["typo": true]]]
    let result = JSONSchemaValidator.shared.validate(invalid, against: schema, coerceTypes: false)
    #expect(!result.isValid)
    #expect(result.errors.first?.message == "additional property not allowed")
}

@Test func localSchemaReferencesResolveArrayIndexes() {
    // zod-to-json-schema emits references into combinator arrays.
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "filter": ["anyOf": [["type": "string", "minLength": 2], ["type": "integer"]]],
            "again": ["$ref": "#/properties/filter/anyOf/0"],
            "pair": ["type": "array", "prefixItems": [["type": "boolean"]], "items": ["$ref": "#/properties/pair/prefixItems/0"]]
        ]
    ]
    #expect(JSONSchemaValidator.shared.validate(["again": "ok", "pair": [true, false]] as [String: Any],
                                                against: schema, coerceTypes: false).isValid)
    let result = JSONSchemaValidator.shared.validate(["again": "x"], against: schema, coerceTypes: false)
    #expect(!result.isValid)
    #expect(result.errors.first?.path == "again")
}

@Test(arguments: ["#/anyOf/2", "#/anyOf/01", "#/anyOf/-1", "#/anyOf/x"])
func localSchemaReferencesRejectInvalidArrayIndexes(reference: String) {
    let schema: [String: Any] = ["anyOf": [["type": "string"], ["type": "integer"]], "$ref": reference]
    let result = JSONSchemaValidator.shared.validate("value", against: schema)
    #expect(result.errors.first?.message == "unresolved local schema reference")
}

@Test func optionalNullsInsideReferencedObjectsFollowTaggedConversion() throws {
    let options: [String: Any] = ["type": "object", "properties": ["limit": ["type": "integer"]]]
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "opts": ["$ref": "#/$defs/Opts"],
            "maybe": ["anyOf": [["$ref": "#/$defs/Opts"], ["type": "null"]]],
            "list": ["type": "array", "items": ["$ref": "#/$defs/Opts"]]
        ],
        "$defs": ["Opts": options]
    ]
    let tool = AITool(name: "pydantic", description: "Pydantic", parameters: schema.mapValues(AnyCodable.init))
    let arguments: [String: AnyCodable] = [
        "opts": AnyCodable(["limit": NSNull()]),
        "maybe": AnyCodable(["limit": NSNull()]),
        "list": AnyCodable([["limit": NSNull()]])
    ]
    let result = try validateToolArguments(tool: tool, toolCall: ToolCall(id: "call", name: "pydantic", arguments: arguments))
    // v1.5.2 S4: optional-null-under-ref converts null to 0 inside referenced objects.
    #expect(((result["opts"]?.value as? [String: Any])?["limit"] as? Int) == 0)
    #expect(((result["maybe"]?.value as? [String: Any])?["limit"] as? Int) == 0)
    #expect(((result["list"]?.value as? [[String: Any]])?.first?["limit"] as? Int) == 0)
}

@Test func optionalNullsAreKeptForNullableReferenceTargets() throws {
    let schema: [String: Any] = [
        "type": "object",
        "properties": ["opts": ["$ref": "#/$defs/Opts"]],
        "$defs": ["Opts": ["type": "object", "properties": ["limit": ["anyOf": [["$ref": "#/$defs/Count"], ["type": "null"]]]]],
                  "Count": ["type": "integer"]]
    ]
    // v1.5.2 S4: test optional null handling through the tool boundary.
    let tool = AITool(name: "echo", description: "", parameters: schema.mapValues(AnyCodable.init))
    let normalized = try validateToolArguments(tool: tool, toolCall: ToolCall(id: "call", name: "echo",
        arguments: ["opts": AnyCodable(["limit": NSNull()])]))
    #expect((normalized["opts"]?.value as? [String: Any])?["limit"] is NSNull)
}
