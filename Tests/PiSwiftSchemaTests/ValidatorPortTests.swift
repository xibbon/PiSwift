// Ported from packages/schema/test/validator.test.ts at pi-mono v1.5.2.
// JavaScript-only values, built-in formats, and coercion are outside this test group.
import Foundation
import Testing
import PiSwiftSchema

@Suite struct ValidatorPortTests {
    private func json(_ text: String) throws -> SchemaValue { try SchemaValue.parse(json: text) }
    private func validator(_ text: String, _ options: CompileOptions = .init()) throws -> Validator {
        try compile(json(text), options: options)
    }
    private func issue(_ path: String, _ keyword: String, _ message: String) -> SchemaIssue {
        SchemaIssue(path: path, keyword: keyword, message: message)
    }
    private var read: String {
        ##"{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer","minimum":1}},"required":["path"],"additionalProperties":false}"##
    }
    private var block: String {
        ##"{"anyOf":[{"type":"object","properties":{"kind":{"const":"text"},"text":{"type":"string"}},"required":["kind","text"],"additionalProperties":false},{"type":"object","properties":{"kind":{"const":"image"},"width":{"type":"integer","minimum":0}},"required":["kind","width"],"additionalProperties":false}]}"##
    }

    @Test("reports a missing field and an unknown field at the field; is empty for a valid value")
    func missingAndUnknownFields() throws {
        let v = try validator(read)
        #expect(v.errors(try json(##"{"offset":0,"extra":true}"##)) == [
            issue("/path", "required", "missing"), issue("/offset", "minimum", "expected >= 1"),
            issue("/extra", "additionalProperties", "unknown field")])
        #expect(v.errors(try json(##"{"path":"a.ts"}"##)).isEmpty)
    }

    @Test("reports the branch a tagged union's tag selects")
    func taggedUnion() throws {
        let v = try validator("{\"type\":\"array\",\"items\":\(block)}")
        #expect(v.errors(try json(##"[{"kind":"text","text":"a"},{"kind":"image","width":-1}]"##)) == [
            issue("/1/width", "minimum", "expected >= 0")])
        #expect(v.errors(try json(##"[{"kind":"video"}]"##)) == [
            issue("/0/kind", "anyOf", ##"expected one of ["text","image"]"##)])
    }

    @Test("escapes ~ and / in paths as JSON Pointer does; follows $ref into the referenced schema")
    func pointersAndReferences() throws {
        #expect(try validator(##"{"type":"object","properties":{"a/b~c":{"type":"string"}}}"##)
            .errors(json(##"{"a/b~c":1}"##)) == [issue("/a~1b~0c", "type", "expected string, got integer")])
        let v = try validator(##"{"$defs":{"point":{"type":"object","properties":{"x":{"type":"number"}},"required":["x"]}},"type":"array","items":{"$ref":"#/$defs/point"}}"##)
        #expect(v.errors(try json(##"[{"x":1},{}]"##)) == [issue("/1/x", "required", "missing")])
    }

    @Test("checks properties named like Object.prototype members as own properties")
    func prototypePropertyNames() throws {
        let v = try validator(##"{"type":"object","properties":{"constructor":{"type":"string"},"toString":{"type":"number"}},"required":["constructor"],"additionalProperties":false}"##)
        #expect(!v.check(try json("{}")))
        #expect(v.check(try json(##"{"constructor":"a"}"##)))
        #expect(!v.check(try json(##"{"constructor":"a","toString":"b"}"##)))
        // does not accept every value for a type named like an Object.prototype member
        #expect(try !validator(##"{"type":"constructor"}"##).check(.number(1)))
    }

    @Test("rejects NaN and Infinity as a number or an integer, with or without bounds, as TypeBox does")
    func nonfiniteNumbers() throws {
        let schemas = [##"{"type":"number"}"##, ##"{"type":"integer"}"##,
            ##"{"type":"number","minimum":0}"##, ##"{"type":["number","string"]}"##,
            ##"{"anyOf":[{"type":"number"},{"type":"null"}]}"##,
            ##"{"type":"object","properties":{"a":{"type":"number"}}}"##]
        for (index, schema) in schemas.enumerated() {
            let v = try validator(schema)
            for n in [Double.nan, .infinity, -.infinity] {
                let value: SchemaValue = index == 5 ? .object(["a": .number(n)]) : .number(n)
                #expect(!v.check(value))
            }
        }
        #expect(try validator(schemas[0]).errors(.number(.nan)) == [issue("", "type", "expected number, got NaN")])
    }

    @Test("checks a detached check function")
    func detachedCheck() throws {
        let check = try validator(read).check
        let values = try [json(##"{"path":"a"}"##), json(##"{"path":1}"##)]
        #expect(values.filter(check) == [values[0]])
    }

    @Test("treats format as an annotation unless formats are given")
    func customFormatOptions() throws {
        let schema = ##"{"type":"string","format":"email"}"##
        #expect(try validator(schema).check(.string("not an email")))
        // The custom format tests the options API. Built-in email rules are in S2.
        let options = CompileOptions(formats: ["email": { $0 == "a@example.com" }])
        let v = try validator(schema, options)
        #expect(!v.check(.string("not an email")))
        #expect(v.check(.string("a@example.com")))
    }

    @Test("resolves $ref to registered documents; throws for a $ref that names nothing")
    func registeredDocuments() throws {
        let point = try json(##"{"type":"object","properties":{"x":{"type":"number"}},"required":["x"]}"##)
        let v = try validator(##"{"$ref":"https://example.com/point.json"}"##,
            .init(schemas: ["https://example.com/point.json": point]))
        #expect(v.check(try json(##"{"x":1}"##)))
        #expect(!v.check(try json("{}")))
        for ref in ["https://example.com/missing.json", "#/$defs/missing"] {
            do {
                _ = try compile(.object(["$ref": .string(ref)]))
                Issue.record("Expected an unresolved reference error")
            } catch { #expect(String(describing: error).contains("Unresolved $ref")) }
        }
    }

    @Test("applies draft 7 semantics: $ref overrides its siblings")
    func draft7References() throws {
        let schema = ##"{"definitions":{"s":{"type":"string"}},"$ref":"#/definitions/s","maxLength":1}"##
        #expect(try validator(schema, .init(draft: .draft7)).check(.string("ab")))
        #expect(try !validator(schema).check(.string("ab")))
    }

    @Test("compiles TypeBox schemas as they are; compiles deep-frozen schemas and never modifies a schema")
    func schemaValuesRemainUnchanged() throws {
        // Type.Object({ name: Type.String(), tags: Type.Array(Type.String()) }) JSON form.
        let v = try validator(##"{"type":"object","properties":{"name":{"type":"string"},"tags":{"type":"array","items":{"type":"string"}}},"required":["name","tags"]}"##)
        #expect(v.check(try json(##"{"name":"a","tags":[]}"##)))
        #expect(v.errors(try json(##"{"name":"a","tags":[1]}"##)) == [issue("/tags/0", "type", "expected string, got integer")])
        let schema = try json(block)
        let before = schema
        let b = try compile(schema)
        #expect(b.check(try json(##"{"kind":"text","text":"x"}"##)))
        #expect(b.errors(try json(##"{"kind":"image","width":-1}"##)).count == 1)
        #expect(schema == before)
    }

    @Test("compiles a recursive schema")
    func recursiveSchema() throws {
        let v = try validator(##"{"type":"object","properties":{"value":{"type":"number"},"children":{"type":"array","items":{"$ref":"#"}}},"required":["value"]}"##)
        #expect(v.check(try json(##"{"value":1,"children":[{"value":2,"children":[{"value":3}]}]}"##)))
        #expect(v.errors(try json(##"{"value":1,"children":[{"value":2,"children":[{}]}]}"##)) == [
            issue("/children/0/children/0/value", "required", "missing")])
    }

    @Test("applies a relative root $id once when resolving local references")
    func relativeRootID() throws {
        let schema = ##"{"$id":"schemas/tool.json","type":"object","properties":{"count":{"$ref":"#/$defs/count"}},"required":["count"],"$defs":{"count":{"type":"integer"}}}"##
        #expect(try validator(schema).check(json(##"{"count":2}"##)))
        let v = try validator(schema, .init(unresolvedRefs: .reject))
        #expect(v.check(try json(##"{"count":2}"##)))
        #expect(v.errors(try json(##"{"count":"a"}"##)) == [issue("/count", "type", "expected integer, got string")])
    }

    @Test("applies a relative root $id once in schemas with unevaluated keywords")
    func relativeIDWithUnevaluatedKeywords() throws {
        let v = try validator(##"{"$id":"schemas/tool.json","type":"object","properties":{"count":{"$ref":"#/$defs/count"}},"$defs":{"count":{"type":"integer"}},"unevaluatedProperties":false}"##, .init(unresolvedRefs: .reject))
        #expect(v.check(try json(##"{"count":2}"##)))
        #expect(v.errors(try json(##"{"count":2,"extra":1}"##)) == [issue("/extra", "unevaluatedProperties", "unknown field")])
        let items = ##"{"$id":"schemas/list.json","type":"array","prefixItems":[{"$ref":"#/$defs/count"}],"$defs":{"count":{"type":"integer"}},"unevaluatedItems":false}"##
        #expect(try validator(items, .init(unresolvedRefs: .reject)).check(json("[2]")))
        #expect(try !validator(items).check(json("[2,3]")))
    }

    @Test("explains errors under nested resources with a relative $id")
    func nestedResources() throws {
        let cloned = ##"{"$id":"https://example.com/root.json","allOf":[{"$ref":"#/$defs/child"}],"$defs":{"child":{"$id":"schemas/tool.json","$ref":"#/$defs/props","unevaluatedProperties":false,"$defs":{"props":{"properties":{"count":{"type":"integer"}}}}}}}"##
        #expect(try validator(cloned).errors(json(##"{"count":2,"extra":1}"##)) == [issue("/extra", "unevaluatedProperties", "unknown field")])
        let branch = ##"{"$id":"https://example.com/root.json","anyOf":[{"$id":"a/b.json","$ref":"#/$defs/n","$defs":{"n":{"type":"integer"}}},{"type":"boolean"}]}"##
        #expect(try validator(branch).errors(json("{}")) == [issue("", "type", "expected integer, got object")])
    }

    @Test("throws for a malformed schema")
    func malformedSchema() throws {
        #expect(throws: SchemaCompileError.self) { try validator(##"{"properties":{"a":1}}"##) }
    }

    @Test("throw when the schema compiles, by default; reject only values at their place with unresolvedRefs: reject; reject a TypeBox Ref without its definition")
    func unresolvedReferences() throws {
        for ref in ["#/definitions/Missing", "https://example.com/schemas/t.json"] {
            let schema: SchemaValue = .object(["type": .string("object"), "properties": .object(["t": .object(["$ref": .string(ref)])])])
            do {
                _ = try compile(schema)
                Issue.record("Expected an unresolved reference error")
            } catch { #expect(String(describing: error).contains("Unresolved $ref \(ref)")) }
            let v = try compile(schema, options: .init(unresolvedRefs: .reject))
            #expect(v.check(try json("{}")))
            #expect(!v.check(try json(##"{"t":1}"##)))
            #expect(v.errors(try json(##"{"t":1}"##)) == [issue("/t", "$ref", "unresolved reference \(ref)")])
        }
        let v = try validator(##"{"type":"object","properties":{"a":{"$ref":"A"}},"required":["a"]}"##, .init(unresolvedRefs: .reject))
        #expect(v.errors(try json(##"{"a":{"x":"1"}}"##)) == [issue("/a", "$ref", "unresolved reference A")])
    }

    @Test("agree with the standalone check as a property, a pattern property and an item")
    func leafChecks() throws {
        let cases: [(String, String)] = [
            (##"{"const":"a"}"##, ##"["a","b",1,null]"##),
            (##"{"const":null}"##, ##"[null,0,false,"null"]"##),
            (##"{"enum":["a",1,null]}"##, ##"["a",1,null,"b",2,true]"##),
            (##"{"type":["string","null"]}"##, ##"["a",null,1,{},[]]"##),
            (##"{"type":["integer","boolean"]}"##, ##"[1,1.5,true,"1"]"##),
            (##"{"type":["number","array"]}"##, ##"[1.5,2,[],{}]"##),
            (##"{"type":["object","bytes"]}"##, ##"[{},[],null]"##),
            (##"{"anyOf":[{"type":"string"},{"type":"null"}]}"##, ##"["a",null,1]"##),
            (##"{"anyOf":[{"type":"integer"},{"type":"string","minLength":2}]}"##, ##"[1,1.5,"ab","a"]"##),
            (##"{"type":"integer","minimum":1,"exclusiveMaximum":5}"##, ##"[1,4,5,0,2.5,"2"]"##),
            (##"{"type":"number","exclusiveMinimum":0,"maximum":1}"##, ##"[0.5,1,0,1.5,"0.5"]"##),
            (##"{"type":"integer","multipleOf":2}"##, "[2,3,2.5]"),
            (##"{"type":"string","minLength":2,"maxLength":3}"##, ##"["ab","abc","a","abcd","😀😀",12]"##),
            (##"{"type":"string","pattern":"^a+$"}"##, ##"["aa","ab",1]"##),
            (##"{"minimum":1}"##, ##"[1,0,"x",null]"##)]
        for (schema, inputs) in cases {
            let alone = try validator(schema)
            let closed = try validator("{\"type\":\"object\",\"properties\":{\"p\":\(schema)},\"additionalProperties\":false}")
            let open = try validator("{\"type\":\"object\",\"properties\":{\"p\":\(schema)},\"required\":[\"q\"]}")
            let pattern = try validator("{\"type\":\"object\",\"patternProperties\":{\"^p$\":\(schema)}}")
            let items = try validator("{\"type\":\"array\",\"items\":\(schema)}")
            guard case .array(let values) = try json(inputs) else { return }
            for value in values {
                let expected = alone.check(value)
                #expect(closed.check(.object(["p": value])) == expected)
                #expect(open.check(.object(["p": value, "q": .number(1)])) == expected)
                #expect(pattern.check(.object(["p": value])) == expected)
                #expect(items.check(.array([value])) == expected)
            }
        }
    }

    @Test("find properties in any order")
    func propertyOrder() throws {
        let v = try validator(##"{"type":"object","properties":{"a":{"const":1},"b":{"type":"string"},"c":{"type":"integer","minimum":0}},"required":["a","c"],"additionalProperties":false}"##)
        for input in [##"{"a":1,"b":"x","c":0}"##, ##"{"c":0,"b":"x","a":1}"##, ##"{"b":"x","c":0,"a":1}"##] {
            #expect(v.check(try json(input)))
        }
        for input in [##"{"a":1,"c":0,"a2":1}"##, ##"{"c":-1,"a":1}"##, ##"{"c":0,"b":1,"a":1}"##, ##"{"c":0,"b":"x"}"##] {
            #expect(!v.check(try json(input)))
        }
    }

    @Test("count an unpaired high surrogate as one code point and a pair as one: valid pair cases")
    func unicodePairs() throws {
        #expect(try validator(##"{"type":"string","maxLength":1}"##).check(.string("😀")))
        #expect(try !validator(##"{"type":"string","minLength":2}"##).check(.string("😀")))
    }

    @Test("list at most 20 enum values; accept a 10,000-value enum")
    func largeEnums() throws {
        let values = (0..<5000).map { SchemaValue.string("v\($0)") }
        let schema: SchemaValue = .object(["type": .string("object"), "properties": .object([
            "e": .object(["type": .string("string"), "enum": .array(values)])])])
        let v = try compile(schema)
        #expect(v.check(.object(["e": .string("v4999")])))
        let prefix = (0..<20).map { "\"v\($0)\"" }.joined(separator: ",")
        #expect(v.errors(.object(["e": .string("v5000")])) == [issue("/e", "enum", "expected one of [\(prefix), ... and 4980 more]")])
        #expect(try validator(##"{"enum":["a","b"]}"##).errors(.string("c")) == [issue("", "enum", ##"expected one of ["a","b"]"##)])
        let big: SchemaValue = .object(["enum": .array((0..<10000).map { .string("member\($0)") })])
        #expect(try compile(big).check(.string("member9999")))
    }

    @Test("describe contains bounds in words")
    func containsMessages() throws {
        let cases: [(String, String)] = [
            (##"{"type":"array","contains":{"type":"number"}}"##, "expected at least 1 matching item"),
            (##"{"type":"array","contains":{"type":"number"},"minContains":2}"##, "expected at least 2 matching items"),
            (##"{"type":"array","contains":{"type":"string"},"maxContains":0,"minContains":0}"##, "expected at most 0 matching items"),
            (##"{"type":"array","contains":{"type":"number"},"minContains":1,"maxContains":3}"##, "expected between 1 and 3 matching items")]
        for (schema, expected) in cases {
            #expect(try validator(schema).errors(.array([.string("a")])).first?.message == expected)
        }
    }

    @Test("blame a oneOf failure on the branch that declares most of the object's properties")
    func recursiveUnionErrors() throws {
        let schema = ##"{"type":"object","properties":{"where":{"$ref":"#/$defs/F"}},"$defs":{"F":{"oneOf":[{"type":"object","properties":{"field":{"type":"string"},"eq":{"type":"string"}},"required":["field","eq"],"additionalProperties":false},{"type":"object","properties":{"and":{"type":"array","items":{"$ref":"#/$defs/F"}}},"required":["and"],"additionalProperties":false}]}}}"##
        let v = try validator(schema)
        #expect(v.errors(try json(##"{"where":{"and":[{"field":"a","eq":1,"x":2}]}}"##)) == [
            issue("/where/and/0/eq", "type", "expected string, got integer"),
            issue("/where/and/0/x", "additionalProperties", "unknown field")])
    }

    @Test("explain one object reached through the same reference at two paths at each path")
    func referencePaths() throws {
        let v = try validator(##"{"type":"object","properties":{"a":{"$ref":"#/$defs/P"},"b":{"$ref":"#/$defs/P"}},"$defs":{"P":{"type":"object","properties":{"n":{"type":"integer"}}}}}"##)
        let shared: SchemaValue = .object(["n": .string("x")])
        #expect(v.errors(.object(["a": shared, "b": shared])) == [
            issue("/a/n", "type", "expected integer, got string"), issue("/b/n", "type", "expected integer, got string")])
    }

    @Test("recursive union explanation at depth 18 completes in less than one second")
    func recursiveUnionTiming() throws {
        // Each failed branch reaches the same child through the same reference.
        let v = try validator(##"{"$defs":{"N":{"anyOf":[{"type":"object","properties":{"a":{"const":1},"child":{"$ref":"#/$defs/N"}},"required":["child","a"]},{"type":"object","properties":{"b":{"const":2},"child":{"$ref":"#/$defs/N"}},"required":["child","b"]}]}},"$ref":"#/$defs/N"}"##)
        var value: SchemaValue = .object([:])
        for _ in 0..<18 { value = .object(["a": .number(0), "b": .number(0), "child": value]) }
        let clock = ContinuousClock()
        let start = clock.now
        let errors = v.errors(value)
        let elapsed = start.duration(to: clock.now)
        #expect(!errors.isEmpty)
        #expect(elapsed < .seconds(1))
    }

    @Test("compile error at explain time returns the schema fallback")
    func explainCompileErrorFallback() throws {
        let v = try validator(##"{"type":"string","minLength":2,"if":42}"##)
        #expect(!v.check(.string("x")))
        #expect(v.errors(.string("x")) == [issue("", "schema", "invalid")])
    }
    @Test("validate returns the original value or the ordered issues")
    func validateResults() throws {
        let v = try validator(read)
        let valid = try json(##"{"path":"a.ts"}"##)
        switch v.validate(valid) {
        case .ok(let value): #expect(value == valid)
        case .failed: Issue.record("Expected the original valid value")
        }
        let invalid = try json(##"{"offset":0,"extra":true}"##)
        switch v.validate(invalid) {
        case .ok: Issue.record("Expected ordered issues")
        case .failed(let issues):
            #expect(issues == [issue("/path", "required", "missing"),
                issue("/offset", "minimum", "expected >= 1"),
                issue("/extra", "additionalProperties", "unknown field")])
        }
    }

}
