import Testing
import PiSwiftChord
@testable import PiSwiftDurable

@Suite struct StructuredToolSchemaTests {
    @Test func integerNumbersDoNotRequireSwiftIntegerRange() {
        #expect(durableStructuredSchemaError(.number(1e20), schema: ["type": "integer"]) == nil)
        #expect(durableStructuredSchemaError(.number(-1e20), schema: ["type": "integer"]) == nil)
        #expect(durableStructuredSchemaError(1.5, schema: ["type": "integer"]) != nil)
        #expect(durableStructuredSchemaError("3", schema: ["type": "integer"]) != nil)
        #expect(durableStructuredSchemaError(1, schema: ["type": "boolean"]) != nil)
        #expect(durableStructuredSchemaError(true, schema: ["type": "number"]) != nil)
    }

    @Test func compositionDoesNotSkipSiblingConstraints() {
        let schemas: [JSONObject] = [
            ["type": "number", "enum": [1], "minimum": 2],
            ["type": "number", "const": 1, "minimum": 2],
            ["anyOf": [["type": "number"]], "minimum": 2],
            ["oneOf": [["type": "number"]], "minimum": 2],
            ["allOf": [["type": "number"]], "minimum": 2],
            ["not": ["const": 1]]
        ]
        for schema in schemas { #expect(durableStructuredSchemaError(1, schema: schema) != nil) }
        #expect(durableStructuredSchemaError(2, schema: ["allOf": [["type": "number"]], "minimum": 2]) == nil)
        #expect(durableStructuredSchemaError(1, schema: ["oneOf": [["type": "number"], ["type": "integer"]]]) != nil)
    }

    @Test func objectsValidateNestedPropertiesAndPatterns() {
        let schema: JSONObject = ["type": "object", "required": ["rows"], "additionalProperties": false,
            "properties": ["rows": ["type": "array", "items": ["type": "object", "required": ["id"],
                "properties": ["id": ["type": "integer"]], "additionalProperties": false]]],
            "patternProperties": ["^x-": ["type": "string"]]]
        #expect(durableStructuredSchemaError(["rows": [["id": 3]], "x-label": "ok"], schema: schema) == nil)
        #expect(durableStructuredSchemaError(["rows": [["id": "3"]]], schema: schema) != nil)
        #expect(durableStructuredSchemaError(["rows": [["id": 3, "extra": 1]]], schema: schema) != nil)
        #expect(durableStructuredSchemaError(["rows": [], "extra": 1], schema: schema) != nil)
        #expect(durableStructuredSchemaError(["rows": [], "x-label": 1], schema: schema) != nil)
        #expect(durableStructuredSchemaError([:], schema: schema) != nil)
        #expect(durableStructuredSchemaError(["a": 1], schema: ["additionalProperties": ["type": "integer"]]) == nil)
        #expect(durableStructuredSchemaError(["a": "1"], schema: ["additionalProperties": ["type": "integer"]]) != nil)
    }

    @Test func arraysValidateTuplesContainsAndUniqueness() {
        let tuple: JSONObject = ["type": "array", "prefixItems": [["type": "string"], ["type": "integer"]], "items": false]
        #expect(durableStructuredSchemaError(["a", 1], schema: tuple) == nil)
        #expect(durableStructuredSchemaError(["a", "1"], schema: tuple) != nil)
        #expect(durableStructuredSchemaError(["a", 1, true], schema: tuple) != nil)
        let oldTuple: JSONObject = ["items": [["type": "string"]], "additionalItems": ["type": "integer"]]
        #expect(durableStructuredSchemaError(["a", 1], schema: oldTuple) == nil)
        #expect(durableStructuredSchemaError(["a", true], schema: oldTuple) != nil)
        let contains: JSONObject = ["contains": ["type": "integer"], "minContains": 1, "maxContains": 1]
        #expect(durableStructuredSchemaError(["a", 1], schema: contains) == nil)
        #expect(durableStructuredSchemaError(["a"], schema: contains) != nil)
        #expect(durableStructuredSchemaError([1, 2], schema: contains) != nil)
        #expect(durableStructuredSchemaError([["a": 1, "b": 2], ["b": 2, "a": 1]], schema: ["uniqueItems": true]) != nil)
    }

    @Test func nullConstantsAndStringScalarsKeepJSONTypes() {
        #expect(durableStructuredSchemaError(.null, schema: ["type": ["null", "integer"]]) == nil)
        #expect(durableStructuredSchemaError(.null, schema: ["type": "integer"]) != nil)
        #expect(durableStructuredSchemaError(.null, schema: ["const": .null]) == nil)
        #expect(durableStructuredSchemaError(true, schema: ["const": 1]) != nil)
        #expect(durableStructuredSchemaError(1, schema: ["enum": [true]]) != nil)
        #expect(durableStructuredSchemaError("e\u{301}", schema: ["minLength": 2]) != nil)
        #expect(durableStructuredSchemaError("😀", schema: ["maxLength": 1]) == nil)
        #expect(durableStructuredSchemaError("abc", schema: ["pattern": "^a"]) == nil)
        #expect(durableStructuredSchemaError("abc", schema: ["pattern": "^z"]) != nil)
    }

    @Test func localReferencesKeepRootAndSiblingConstraints() {
        let schema: JSONObject = ["$defs": ["integer": ["type": "integer"]],
            "type": "object", "properties": ["count": ["$ref": "#/$defs/integer", "minimum": 2]]]
        #expect(durableStructuredSchemaError(["count": 2], schema: schema) == nil)
        #expect(durableStructuredSchemaError(["count": 1], schema: schema) != nil)
        #expect(durableStructuredSchemaError(["count": "2"], schema: schema) != nil)
        let distinct: JSONObject = ["$defs": ["é": ["properties": ["first": [:]]], "e\u{301}": ["properties": ["second": [:]]]],
            "allOf": [["$ref": "#/$defs/é"], ["$ref": "#/$defs/e\u{301}"]], "unevaluatedProperties": false]
        #expect(durableStructuredSchemaError(["first": 1, "second": 2], schema: distinct) == nil)
        #expect(durableStructuredSchemaError(1, schema: ["$ref": "#"]) != nil)
        #expect(durableStructuredSchemaError(1, schema: ["$ref": "#/missing"]) != nil)
        #expect(durableStructuredSchemaError(["next": ["next": [:]]], schema: ["type": "object", "properties": ["next": ["$ref": "#"]]]) == nil)
    }
    @Test func conditionsDependenciesAndUnevaluatedValues() {
        let conditional: JSONObject = ["if": ["properties": ["flag": ["const": true]], "required": ["flag"]],
            "then": ["required": ["count"]], "else": ["properties": ["count": ["maximum": 0]]]]
        #expect(durableStructuredSchemaError(["flag": true], schema: conditional) != nil)
        #expect(durableStructuredSchemaError(["flag": true, "count": 1], schema: conditional) == nil)
        #expect(durableStructuredSchemaError(["flag": false, "count": 1], schema: conditional) != nil)
        #expect(durableStructuredSchemaError(["credit": "x"], schema: ["dependentRequired": ["credit": ["billing"]]]) != nil)
        #expect(durableStructuredSchemaError(["credit": "x"], schema: ["dependentSchemas": ["credit": ["required": ["billing"]]]]) != nil)
        let object: JSONObject = ["allOf": [["properties": ["x": ["type": "number"]]]], "unevaluatedProperties": false]
        #expect(durableStructuredSchemaError(["x": 1], schema: object) == nil)
        #expect(durableStructuredSchemaError(["x": 1, "y": 2], schema: object) != nil)
        let array: JSONObject = ["allOf": [["prefixItems": [["type": "number"]]]], "unevaluatedItems": false]
        #expect(durableStructuredSchemaError([1], schema: array) == nil)
        #expect(durableStructuredSchemaError([1, 2], schema: array) != nil)
    }

    @Test func deepSchemasAndValuesEndWithoutStackFailure() async {
        #expect(durableStructuredSchemaError(1, schema: ["$ref": "#"]) != nil)
        var validSchema: JSONValue = ["type": "integer"]
        for _ in 0..<80 { validSchema = ["allOf": [validSchema]] }
        #expect(durableStructuredSchemaError(1, schema: validSchema.objectValue!) == nil)
        var validValue: JSONValue = [:]
        for _ in 0..<40 { validValue = ["next": validValue] }
        #expect(durableStructuredSchemaError(validValue, schema: ["type": "object", "properties": ["next": ["$ref": "#"]]]) == nil)
        var deepSchema: JSONValue = ["type": "integer"]
        for _ in 0..<300 { deepSchema = ["allOf": [deepSchema]] }
        #expect(durableStructuredSchemaError(1, schema: deepSchema.objectValue!) == nil)
        var value: JSONValue = [:]
        for _ in 0..<300 { value = ["next": value] }
        #expect(durableStructuredSchemaError(value, schema: ["type": "object", "properties": ["next": ["$ref": "#"]]]) == nil)
    }

}
