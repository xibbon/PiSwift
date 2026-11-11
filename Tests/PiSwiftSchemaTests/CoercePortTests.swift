// Ported from packages/schema/test/coerce.test.ts at pi-mono v1.5.2.
// SchemaValue has value semantics. JavaScript identity, frozen-object and Function
// constructor tests do not apply. Bigint, undefined and cyclic JavaScript object
// graphs have no SchemaValue form. Reference-based recursive schemas are covered.
// Omitted upstream cases: "copies only the changed paths" (reference identity),
// "works on frozen schemas" (JavaScript Object.freeze), "still coerces when the
// Function constructor is unavailable" (JavaScript code generation), "converts
// to a bigint like TypeBox's TryBigInt", "converts to undefined like TypeBox's
// TryUndefined", and "stop at a schema that cycles through shared JS objects
// instead of $ref" (the SchemaValue tree cannot contain an object cycle).
import Foundation
import Testing
@testable import PiSwiftSchema

@Suite struct CoercePortTests {
    private func json(_ text: String) throws -> SchemaValue { try .parse(json: text) }
    private func validator(_ schema: String, _ options: CompileOptions = .init(formats: standardFormats)) throws -> CoercingValidator {
        try compileCoercing(json(schema), options: options)
    }
    private func coerce(_ schema: String, _ input: String) throws -> SchemaValue { try validator(schema).coerce(json(input)) }
    private func value(_ schema: String, _ input: String) throws -> SchemaValue {
        let root = "{\"type\":\"object\",\"properties\":{\"value\":\(schema)},\"required\":[\"value\"]}"
        guard case let .object(object) = try coerce(root, "{\"value\":\(input)}"), let result = object["value"] else {
            throw CoercePortError.invalid
        }
        return result
    }
    private func expectParse(_ validator: CoercingValidator, _ input: String, _ expected: String) throws {
        let result = validator.parse(try json(input))
        guard case let .ok(value) = result else { Issue.record("Expected parse success"); return }
        #expect(value == (try json(expected)))
    }
    private enum CoercePortError: Error { case invalid }

    @Test("adds coerce and parse only with coerce: true")
    func compileOptions() throws {
        let schema = try json(##"{"type":"object","properties":{"n":{"type":"number"}},"required":["n"]}"##)
        let plain: Validator = try compile(schema)
        let coercing: CoercingValidator = try compileCoercing(schema)
        #expect(plain.check(try json(##"{"n":1}"##)))
        #expect(coercing.check(try json(##"{"n":1}"##)))
        try expectParse(coercing, ##"{"n":"1"}"##, ##"{"n":1}"##)
    }

    @Test("never modifies the value")
    func neverModifiesInput() throws {
        let input = try json(##"{"count":"42","tags":"a"}"##)
        let before = input.stringify()
        let v = try validator(##"{"type":"object","properties":{"count":{"type":"number"},"tags":{"type":"array","items":{"type":"string"}}},"required":["count","tags"]}"##)
        #expect(v.coerce(input) == (try json(##"{"count":42,"tags":["a"]}"##)))
        #expect(input.stringify() == before)
    }

    @Test("returns the value itself when nothing changes")
    func unchangedValue() throws {
        let input = try json(##"{"a":{"b":[1,2]},"c":"x"}"##)
        let v = try validator(##"{"type":"object","properties":{"a":{"type":"object","properties":{"b":{"type":"array","items":{"type":"number"}}},"required":["b"]},"c":{"type":"string"}},"required":["a","c"]}"##)
        #expect(v.coerce(input) == input)
    }

    @Test("leaves values it cannot coerce for the check to report")
    func cannotCoerce() throws {
        let v = try validator(##"{"type":"object","properties":{"count":{"type":"number"}},"required":["count"]}"##)
        let input = try json(##"{"count":"many"}"##)
        #expect(v.coerce(input) == input)
        #expect(!v.check(v.coerce(input)))
    }

    @Test("returns the coerced value when it is valid")
    func parseSuccess() throws {
        let v = try validator(##"{"type":"object","properties":{"count":{"type":"number"},"tags":{"type":"array","items":{"type":"string"}}},"required":["count","tags"]}"##)
        try expectParse(v, ##"{"count":"42","tags":"a"}"##, ##"{"count":42,"tags":["a"]}"##)
    }

    @Test("returns the errors of the coerced value when it is invalid")
    func parseFailure() throws {
        let v = try validator(##"{"type":"object","properties":{"count":{"type":"number"},"name":{"type":"string"}},"required":["count","name"]}"##)
        guard case let .failed(errors) = v.parse(try json(##"{"count":"many","name":7}"##)) else {
            Issue.record("Expected parse failure"); return
        }
        #expect(errors == [.init(path: "/count", keyword: "type", message: "expected number, got string")])
    }

    @Test("checks without coercing, with or without the coerce option")
    func validateIsStrict() throws {
        let schema = try json(##"{"type":"object","properties":{"count":{"type":"number"},"tags":{"type":"array","items":{"type":"string"}}},"required":["count","tags"]}"##)
        let plain = try compile(schema)
        let coercing = try compileCoercing(schema)
        let valid = try json(##"{"count":42,"tags":["a"]}"##)
        let loose = try json(##"{"count":"42","tags":"a"}"##)
        for result in [plain.validate(valid), coercing.validate(valid)] {
            guard case let .ok(value) = result else { Issue.record("Expected validation success"); continue }
            #expect(value == valid)
        }
        let expected: [SchemaIssue] = [.init(path: "/count", keyword: "type", message: "expected number, got string"),
                                      .init(path: "/tags", keyword: "type", message: "expected array, got string")]
        for result in [plain.validate(loose), coercing.validate(loose)] {
            guard case let .failed(errors) = result else { Issue.record("Expected validation failure"); continue }
            #expect(errors == expected)
        }
    }

    @Test("drops null in optional non-nullable properties, also nested")
    func optionalNulls() throws {
        let schema = ##"{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"number"},"nullable":{"anyOf":[{"type":"string"},{"type":"null"}]},"metadata":{"type":"object","properties":{"enabled":{"type":"boolean"}}}},"required":["path","metadata"]}"##
        #expect(try coerce(schema, ##"{"path":"file.txt","offset":null,"nullable":null,"metadata":{"enabled":null}}"##) == json(##"{"path":"file.txt","nullable":null,"metadata":{}}"##))
    }

    @Test("keeps a null whose property is a $ref (the reference may allow it)")
    func optionalReferenceNull() throws {
        #expect(try coerce(##"{"type":"object","properties":{"value":{"$ref":"#/$defs/value"}},"$defs":{"value":{"anyOf":[{"type":"number"},{"type":"null"}]}}}"##, ##"{"value":null}"##) == json(##"{"value":null}"##))
    }

    @Test("walks array items")
    func optionalNullInArray() throws {
        #expect(try coerce(##"{"type":"array","items":{"type":"object","properties":{"a":{"type":"string"},"b":{"type":"integer"}},"required":["a"]}}"##, ##"[{"a":"x","b":null}]"##) == json(##"[{"a":"x"}]"##))
    }

    @Test("converts primitives by type")
    func primitiveConversions() throws {
        let cases = [("number", ##""42""##, "42"), ("number", ##""""##, "0"), ("number", ##""true""##, "1"),
                     ("integer", ##""3.5""##, "3"), ("integer", "1.5", "1"), ("boolean", ##""1""##, "true"),
                     ("boolean", ##""FALSE""##, "false"), ("null", ##""null""##, "null"), ("string", "42", ##""42""##)]
        for (type, input, expected) in cases {
            #expect(try value("{\"type\":\"\(type)\"}", input) == json(expected))
        }
    }

    @Test("wraps a single value into an array and converts the items")
    func arrayWrapping() throws {
        #expect(try value(##"{"type":"array","items":{"type":"number"}}"##, ##""1""##) == json("[1]"))
        #expect(try value(##"{"type":"array","items":{"type":"string"}}"##, "null") == json(##"["null"]"##))
    }

    @Test("converts tuple items in place and never wraps for a tuple")
    func tuples() throws {
        let schema = ##"{"type":"array","prefixItems":[{"type":"number"},{"type":"boolean"}],"items":false}"##
        #expect(try value(schema, ##"["1","true"]"##) == json("[1,true]"))
        #expect(try value(schema, ##""1""##) == json(##""1""##))
    }

    @Test("converts const and enum values only when the result is a member")
    func literals() throws {
        for (schema, input, expected) in [(##"{"const":1}"##, ##""1""##, "1"), (##"{"const":1}"##, ##""2""##, ##""2""##),
                                          (##"{"enum":[1,2,"hello"]}"##, ##""2""##, "2"), (##"{"enum":[1,2,"hello"]}"##, ##""world""##, ##""world""##)] {
            #expect(try value(schema, input) == json(expected))
        }
    }

    @Test("keeps a value one union branch accepts, else takes the first branch whose conversion the union accepts")
    func unionOrder() throws {
        let schema = ##"{"anyOf":[{"type":"number"},{"type":"null"}]}"##
        for (input, expected) in [("null", "null"), (##""42""##, "42"), (##""null""##, "null")] {
            #expect(try value(schema, input) == json(expected))
        }
        #expect(try value(##"{"oneOf":[{"type":"boolean"},{"type":"number"}]}"##, ##""1""##) == .bool(true))
    }

    @Test("converts allOf with each member in turn")
    func allOf() throws {
        #expect(try coerce(##"{"allOf":[{"type":"object","properties":{"a":{"type":"number"}},"required":["a"]},{"type":"object","properties":{"b":{"type":"boolean"}},"required":["b"]}]}"##, ##"{"a":"1","b":"true"}"##) == json(##"{"a":1,"b":true}"##))
    }

    @Test("follows $ref")
    func reference() throws {
        #expect(try coerce(##"{"type":"object","properties":{"item":{"$ref":"#/$defs/item"}},"$defs":{"item":{"type":"object","properties":{"id":{"type":"integer"}}}}}"##, ##"{"item":{"id":"7"}}"##) == json(##"{"item":{"id":7}}"##))
    }

    @Test("follows a relative $ref from the root $id on the first call of a schema with $dynamicRef")
    func dynamicReference() throws {
        let schema = ##"{"$id":"https://example.com/root.json","$dynamicAnchor":"node","type":"object","properties":{"count":{"$ref":"defs/n.json"},"children":{"type":"array","items":{"$dynamicRef":"#node"}}}}"##
        let v = try validator(schema, .init(schemas: ["https://example.com/defs/n.json": try json(##"{"type":"integer"}"##)]))
        #expect(v.coerce(try json(##"{"count":"2"}"##)) == (try json(##"{"count":2}"##)))
        for _ in 0..<2 { try expectParse(v, ##"{"count":"2"}"##, ##"{"count":2}"##) }
    }

    @Test("converts patternProperties and additionalProperties")
    func propertyPatterns() throws {
        #expect(try coerce(##"{"type":"object","properties":{"a":{"type":"number"}},"patternProperties":{"^n_":{"type":"number"}},"additionalProperties":{"type":"boolean"}}"##, ##"{"a":"1","n_x":"2","other":"true"}"##) == json(##"{"a":1,"n_x":2,"other":true}"##))
    }

    @Test("coerces like Ajv's coerceTypes")
    func primitivePass() throws {
        let cases = [("number", "true", "1"), ("number", "null", "0"), ("integer", ##""42""##, "42"),
                     ("boolean", ##""true""##, "true"), ("boolean", "0", "false"), ("string", "true", ##""true""##),
                     ("null", ##""""##, "null"), ("null", "0", "null"), ("null", "false", "null")]
        for (type, input, expected) in cases { #expect(try value("{\"type\":\"\(type)\"}", input) == json(expected)) }
    }

    @Test("leaves a value that matches one of a type array's types, else takes the first coercible type")
    func typeArrays() throws {
        #expect(try value(##"{"type":["number","string"]}"##, ##""1""##) == .string("1"))
        #expect(try value(##"{"type":["boolean","number"]}"##, ##""1""##) == .number(1))
        #expect(try value(##"{"type":["integer","null"]}"##, ##""5""##) == .number(5))
    }

    @Test("accepts null for nullable array schemas with items")
    func nullableArray() throws {
        #expect(try value(##"{"type":["array","null"],"items":{"type":"string"}}"##, "null") == .null)
    }

    @Test("coerces nullable unions when the value matches no branch")
    func nullableUnion() throws {
        #expect(try value(##"{"anyOf":[{"type":"number"},{"type":"null"}]}"##, ##""42""##) == .number(42))
        #expect(try value(##"{"oneOf":[{"type":"number"},{"type":"null"}]}"##, "null") == .null)
    }

    @Test("leaves values no rule coerces")
    func noRule() throws {
        let v = try validator(##"{"type":"object","properties":{"value":{"type":"integer"}},"required":["value"]}"##)
        for input in [##""abc""##, ##""4x""##, "{}", ##"["1","2"]"##] {
            #expect(!v.check(v.coerce(try json("{\"value\":\(input)}"))))
        }
    }

    @Test("turns null into 'null' for a required string (pass 3 alone would give '')")
    func requiredNullString() throws { #expect(try value(##"{"type":"string"}"##, "null") == .string("null")) }
    @Test("turns '' into 0 for a number (pass 3 leaves an empty string)")
    func emptyNumber() throws { #expect(try value(##"{"type":"number"}"##, ##""""##) == .number(0)) }
    @Test("turns '1' and '0' into booleans (pass 3 takes only 'true', 'false', 1 and 0)")
    func numericBoolean() throws { #expect(try value(##"{"type":"boolean"}"##, ##""0""##) == .bool(false)) }
    @Test("truncates '42.1' for an integer (pass 3 rejects it)")
    func integerTruncation() throws { #expect(try value(##"{"type":"integer"}"##, ##""42.1""##) == .number(42)) }
    @Test("drops an optional null before converting it (pass 2 alone would give 'null')")
    func dropBeforeConvert() throws {
        #expect(try coerce(##"{"type":"object","properties":{"name":{"type":"string"}}}"##, ##"{"name":null}"##) == json("{}"))
    }

    private var tree: String {
        ##"{"type":"object","properties":{"t":{"$ref":"#/$defs/Tree"}},"$defs":{"Tree":{"anyOf":[{"type":"string"},{"type":"array","items":{"$ref":"#/$defs/Tree"}}]}}}"##
    }
    @Test("convert through a recursive union by its first accepting branch")
    func recursiveUnion() throws {
        let v = try validator(tree)
        for (input, output) in [(##"{"t":["a",["b"]]}"##, ##"{"t":["a",["b"]]}"##),
                                (##"{"t":5}"##, ##"{"t":"5"}"##), (##"{"t":[5]}"##, ##"{"t":["5"]}"##)] {
            try expectParse(v, input, output)
        }
        let jsonSchema = ##"{"type":"object","properties":{"data":{"$ref":"#/$defs/Json"}},"required":["data"],"$defs":{"Json":{"anyOf":[{"type":"string"},{"type":"number"},{"type":"boolean"},{"type":"array","items":{"$ref":"#/$defs/Json"}},{"type":"object","additionalProperties":{"$ref":"#/$defs/Json"}}]}}}"##
        try expectParse(validator(jsonSchema), ##"{"data":{"a":[1,null]}}"##, ##"{"data":{"a":[1,"null"]}}"##)
    }

    @Test("leave a value a recursive schema cannot convert as it is, for the check to report")
    func recursiveFailure() throws {
        let v = try validator(tree)
        guard case .failed = v.parse(try json(##"{"t":{}}"##)) else { Issue.record("Expected parse failure"); return }
        #expect(v.coerce(try json(##"{"t":{"a":1}}"##)) == (try json(##"{"t":{"a":1}}"##)))
    }

    @Test("convert a scalar-or-array schema that refers to itself")
    func recursiveScalarOrArray() throws {
        let schema = ##"{"type":"object","properties":{"value":{"anyOf":[{"type":"number"},{"type":"array","items":{"$ref":"#/properties/value"}}]}},"required":["value"]}"##
        let v = try validator(schema)
        try expectParse(v, ##"{"value":"42"}"##, ##"{"value":42}"##)
        try expectParse(v, ##"{"value":["1",["2"]]}"##, ##"{"value":[1,[2]]}"##)
        guard case .failed = v.parse(try json(##"{"value":{}}"##)) else { Issue.record("Expected parse failure"); return }
    }

    @Test("reset the re-entry state between calls and leave the input unchanged")
    func recursiveStateReset() throws {
        let v = try validator(##"{"anyOf":[{"type":"number"},{"type":"array","items":{"$ref":"#"}}]}"##)
        let input = try json(##"[1,"2",["3"]]"##)
        let before = input.stringify()
        for _ in 0..<20 {
            guard case .failed = v.parse(try json("{}")) else { Issue.record("Expected parse failure"); return }
            try expectParse(v, ##""42""##, "42")
            guard case let .ok(value) = v.parse(input) else { Issue.record("Expected parse success"); return }
            #expect(value == (try json("[1,2,[3]]")))
            #expect(input.stringify() == before)
        }
    }

    @Test("convert and explain a deep value that every branch of a recursive union rejects, in linear time")
    func deepRejectedUnion() throws {
        let schema = ##"{"type":"object","properties":{"s":{"$ref":"#/$defs/S"}},"$defs":{"S":{"anyOf":[{"type":"object","additionalProperties":{"$ref":"#/$defs/S"},"required":["a"]},{"type":"object","additionalProperties":{"$ref":"#/$defs/S"},"required":["b"]}]}}}"##
        var input: SchemaValue = .object(["x": .number(1)])
        for _ in 0..<40 { input = .object(["c": input]) }
        let v = try validator(schema)
        let clock = ContinuousClock()
        let start = clock.now
        guard case let .failed(errors) = v.parse(.object(["s": input])) else { Issue.record("Expected parse failure"); return }
        var expected = (0...40).map { SchemaIssue(path: "/s" + String(repeating: "/c", count: $0) + "/a", keyword: "required", message: "missing") }
        expected.append(.init(path: "/s" + String(repeating: "/c", count: 40) + "/x", keyword: "type", message: "expected object, got integer"))
        #expect(errors == expected)
        #expect(start.duration(to: clock.now) < .seconds(1))
    }

    @Test("convert a TypeBox Cyclic union")
    func typeBoxCyclicUnion() throws {
        // Type.Cyclic emits a $defs entry and a reference to that entry.
        let v = try validator(tree)
        try expectParse(v, ##"{"t":[5]}"##, ##"{"t":["5"]}"##)
        guard case .failed = v.parse(try json(##"{"t":{"a":1}}"##)) else { Issue.record("Expected parse failure"); return }
    }

    @Test("keep a pattern-matched property from additionalProperties in every pass")
    func patternPrecedence() throws {
        let record = try validator(##"{"type":"object","patternProperties":{"^(.*)$":{"type":"number"}},"additionalProperties":{"type":"string"}}"##)
        try expectParse(record, ##"{"n1":"1"}"##, ##"{"n1":1}"##)
        #expect(try coerce(##"{"type":"object","patternProperties":{"^n_":{"type":["integer","null"]}},"additionalProperties":{"type":"string"}}"##, ##"{"n_a":"5","other":7}"##) == json(##"{"n_a":5,"other":"7"}"##))
    }

    @Test("drop optional nulls inside declared, pattern and additional property values alike")
    func nullsInAllPropertyKinds() throws {
        let item = ##"{"type":"object","properties":{"n":{"type":"integer","minimum":1}}}"##
        for schema in ["{\"type\":\"object\",\"properties\":{\"entry\":\(item)},\"required\":[\"entry\"]}",
                       "{\"type\":\"object\",\"additionalProperties\":\(item)}",
                       "{\"type\":\"object\",\"patternProperties\":{\"^entry$\":\(item)},\"additionalProperties\":false}"] {
            let input = try json(##"{"entry":{"n":null}}"##)
            let v = try validator(schema)
            try expectParse(v, input.stringify(), ##"{"entry":{}}"##)
            #expect(input == (try json(##"{"entry":{"n":null}}"##)))
        }
    }

    @Test("keep a null under pattern and additional properties: their keys are not optional properties")
    func keepAdditionalNull() throws {
        try expectParse(validator(##"{"type":"object","additionalProperties":{"type":["integer","null"]}}"##), ##"{"n":null}"##, ##"{"n":null}"##)
    }

    @Test("drop optional nulls in tuple items as in array items")
    func optionalTupleNulls() throws {
        let item = ##"{"type":"object","properties":{"n":{"type":"integer"}}}"##
        for schema in ["{\"type\":\"array\",\"items\":\(item)}", "{\"type\":\"array\",\"prefixItems\":[\(item)],\"items\":false}"] {
            #expect(try coerce(schema, ##"[{"n":null}]"##) == json("[{}]"))
        }
    }

    @Test("coerce tuple items by type in pass 3")
    func typeArrayTuple() throws {
        #expect(try coerce(##"{"type":"array","prefixItems":[{"type":["integer","null"]},{"type":["boolean","null"]}]}"##, ##"["5","true"]"##) == json("[5,true]"))
    }

    @Test("convert the properties a union node declares besides its branches")
    func unionOwnProperties() throws {
        let v = try validator(##"{"type":"object","properties":{"a":{"type":"integer"},"b":{"type":"integer"}},"anyOf":[{"required":["a"]},{"required":["b"]}]}"##)
        try expectParse(v, ##"{"a":"3.5"}"##, ##"{"a":3}"##)
    }

    @Test("check anyOf candidates after the node's own properties convert", arguments: ["anyOf", "oneOf"])
    func unionCandidatesAfterOwnProperties(keyword: String) throws {
        let schema = "{\"type\":\"object\",\"\(keyword)\":[{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"array\",\"items\":{\"type\":\"integer\"}}},\"required\":[\"a\"]},{\"type\":\"object\",\"properties\":{\"b\":{\"type\":\"boolean\"}},\"required\":[\"b\"]}],\"properties\":{\"c\":{\"type\":\"integer\"}},\"required\":[\"c\"]}"
        let input = try json(##"{"a":"3","c":"2"}"##)
        try expectParse(validator(schema), input.stringify(), ##"{"a":[3],"c":2}"##)
        #expect(input == (try json(##"{"a":"3","c":"2"}"##)))
    }

    // The following two cases complete the coercion cases in validator.test.ts.
    @Test("applies a relative root $id once when resolving local references")
    func validatorRelativeRootID() throws {
        let v = try validator(##"{"$id":"schemas/tool.json","type":"object","properties":{"count":{"$ref":"#/$defs/count"}},"required":["count"],"$defs":{"count":{"type":"integer"}}}"##)
        try expectParse(v, ##"{"count":"2"}"##, ##"{"count":2}"##)
    }

    @Test("leave values at their place uncoerced")
    func unresolvedReference() throws {
        let v = try validator(##"{"type":"object","properties":{"t":{"$ref":"#/definitions/Missing"}}}"##, .init(unresolvedRefs: .reject))
        let input = try json(##"{"t":"1"}"##)
        #expect(v.coerce(input) == input)
        guard case let .failed(errors) = v.parse(input) else { Issue.record("Expected parse failure"); return }
        #expect(errors == [.init(path: "/t", keyword: "$ref", message: "unresolved reference #/definitions/Missing")])
    }
}
