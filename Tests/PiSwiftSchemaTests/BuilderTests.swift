// Ported from packages/schema/test/builders.test.ts, pi-mono v1.5.2.
// Static<T>, compiler type narrowing, and native bigint values have no SchemaValue equivalent.
import Foundation
import Testing
import PiSwiftSchema

@Suite struct BuilderTests {
    private typealias B = SchemaBuilder
    private func json(_ text: String) throws -> SchemaValue { try .parse(json: text) }

    @Test("produce plain JSON Schema")
    func plainJSON() {
        let schema = B.obj([
            .init("path", B.str(["description": .string("File path"), "minLength": .number(1)])),
            .init("offset", B.opt(B.int(["minimum": .number(1)]))),
            .init("mode", B.oneOf([.string("read"), .string("write")])),
        ])
        #expect(schema.stringify() == ##"{"type":"object","properties":{"path":{"type":"string","description":"File path","minLength":1},"offset":{"type":"integer","minimum":1},"mode":{"enum":["read","write"]}},"required":["path","mode"],"additionalProperties":false}"##)
    }

    @Test("produce every leaf")
    func everyLeaf() {
        let leaves = [B.str(), B.num(), B.int(), B.bool(), B.nul(), B.unknown(), B.lit(.number(3)),
                      B.bytes(["maxLength": .number(8)])]
        #expect(SchemaValue.array(leaves).stringify() == ##"[{"type":"string"},{"type":"number"},{"type":"integer"},{"type":"boolean"},{"type":"null"},{},{"const":3},{"type":"bytes","maxLength":8}]"##)
        #expect(B.arr(B.str(), ["maxItems": .number(2)]).stringify() == ##"{"type":"array","items":{"type":"string"},"maxItems":2}"##)
        #expect(B.map(B.num()).stringify() == ##"{"type":"object","additionalProperties":{"type":"number"}}"##)
        #expect(B.tuple([B.str(), B.num()]).stringify() == ##"{"type":"array","prefixItems":[{"type":"string"},{"type":"number"}],"items":false,"minItems":2}"##)
        #expect(B.nullable(B.str()).stringify() == ##"{"anyOf":[{"type":"string"},{"type":"null"}]}"##)
        #expect(B.obj(["a": B.str()], ["open": .bool(true)]).stringify() == ##"{"type":"object","properties":{"a":{"type":"string"}},"required":["a"]}"##)
    }

    @Test("carry the static type of valid values")
    func staticTypeSchemaStructure() throws {
        // Swift has no Static<S>. Check the schema and tuple behavior from this case.
        let message = B.union([
            B.obj(["kind": B.lit(.string("text")), "text": B.str()]),
            B.obj([.init("kind", B.lit(.string("image"))), .init("url", B.str()), .init("alt", B.opt(B.str()))]),
        ])
        let validator = try compile(message)
        #expect(validator.check(try json(##"{"kind":"text","text":"a"}"##)))
        #expect(validator.check(try json(##"{"kind":"image","url":"a"}"##)))
        #expect(!validator.check(try json(##"{"kind":"image","url":"a","alt":1}"##)))
        let pair = try compile(B.tuple([B.str(), B.arr(B.int())]))
        #expect(pair.check(try json(##"["a",[1,2]]"##)))
        #expect(!pair.check(try json(##"["a",[1.5]]"##)))
    }

    @Test("narrow values through a compiled check")
    func compiledPoint() throws {
        let point = B.obj([.init("x", B.num()), .init("y", B.num()), .init("label", B.opt(B.str()))])
        let value = try json(##"{"x":1,"y":2}"##)
        #expect(try compile(point).check(value))
        guard case let .object(object) = value, case let .number(x)? = object["x"],
              case let .number(y)? = object["y"] else { Issue.record("Expected a point"); return }
        #expect(x + y == 3)
    }

    @Test("build a bigint with bounds, typed bigint")
    func bigintKeyword() {
        // A native bigint bound cannot pass through SchemaValue. Preserve the extension keyword.
        #expect(B.nullable(B.bigint()).stringify() == ##"{"anyOf":[{"type":"bigint"},{"type":"null"}]}"##)
    }

    @Test("type a schema as given with unsafe")
    func unsafeSchema() throws {
        let usage = B.unsafe()
        let level = B.unsafe(.object(["type": .string("string"), "enum": .array([.string("low"), .string("high")])]))
        #expect(usage == .object([:]))
        #expect(level.stringify() == ##"{"type":"string","enum":["low","high"]}"##)
        let status = try compile(B.obj(["usage": B.nullable(usage), "level": level]))
        #expect(status.check(try json(##"{"usage":null,"level":"low"}"##)))
        #expect(try compile(usage).check(.string("not usage")))
        #expect(try !compile(level).check(.string("medium")))
    }

    private func tree() -> SchemaValue {
        B.recursive("Tree") { reference in
            B.obj(["name": B.str(), "children": B.arr(reference)])
        }
    }

    @Test("build a recursive schema that checks every level")
    func recursiveTree() throws {
        let schema = tree()
        #expect(schema.stringify() == ##"{"type":"object","properties":{"name":{"type":"string"},"children":{"type":"array","items":{"$ref":"Tree"}}},"required":["name","children"],"additionalProperties":false,"$id":"Tree"}"##)
        let validator = try compile(schema)
        #expect(validator.check(try json(##"{"name":"a","children":[{"name":"b","children":[]}]}"##)))
        let deep = try json(##"{"name":"a","children":[{"name":"b","children":[{"name":1,"children":[]}]}]}"##)
        #expect(validator.errors(deep) == [SchemaIssue(path: "/children/0/children/0/name", keyword: "type", message: "expected string, got integer")])
    }

    @Test("nest recursive schemas with distinct ids inside other schemas")
    func nestedRecursiveSchemas() throws {
        let list = B.recursive("List") { reference in
            B.obj(["value": B.num(), "next": B.nullable(reference)])
        }
        let validator = try compile(B.obj([.init("tree", tree()), .init("list", B.opt(list))]))
        #expect(validator.check(try json(##"{"tree":{"name":"a","children":[{"name":"b","children":[]}]},"list":{"value":1,"next":{"value":2,"next":null}}}"##)))
        #expect(!validator.check(try json(##"{"tree":{"name":"a","children":[{"name":"b","children":[]}]},"list":{"value":1,"next":{"value":"2","next":null}}}"##)))
        #expect(!validator.check(try json(##"{"tree":{"name":"a","children":[{"name":"b","children":[{"name":3}]}]}}"##)))
    }

    @Test("compile into checks with the declared semantics")
    func compiledSemantics() throws {
        let validator = try compile(B.obj([
            .init("name", B.str(["minLength": .number(1)])),
            .init("tags", B.opt(B.arr(B.str(), ["uniqueItems": .bool(true)]))),
        ]))
        #expect(validator.check(try json(##"{"name":"a"}"##)))
        #expect(validator.check(try json(##"{"name":"a","tags":["x","y"]}"##)))
        #expect(validator.errors(try json(##"{"name":"","tags":["x","x"],"other":1}"##)) == [
            SchemaIssue(path: "/name", keyword: "minLength", message: "expected at least 1 characters"),
            SchemaIssue(path: "/tags", keyword: "uniqueItems", message: "expected unique items"),
            SchemaIssue(path: "/other", keyword: "additionalProperties", message: "unknown field"),
        ])
    }

    private enum FixtureError: Error { case invalid(String) }

    private func evaluate(_ value: SchemaValue, selfReference: SchemaValue? = nil) throws -> SchemaValue {
        guard case let .object(call) = value, case let .string(builder)? = call["builder"] else {
            throw FixtureError.invalid("Invalid builder call")
        }
        let options: SchemaObject
        if case let .object(supplied)? = call["options"] { options = supplied } else { options = [:] }
        let argument = call["argument"]
        func item() throws -> SchemaValue {
            guard let argument else { throw FixtureError.invalid("Missing builder argument") }
            return try evaluate(argument, selfReference: selfReference)
        }
        func items() throws -> [SchemaValue] {
            guard case let .array(values)? = argument else { throw FixtureError.invalid("Missing builder array") }
            return try values.map { try evaluate($0, selfReference: selfReference) }
        }
        switch builder {
        case "str": return B.str(options)
        case "num": return B.num(options)
        case "int": return B.int(options)
        case "bigint": return B.bigint(options)
        case "bool": return B.bool(options)
        case "nul": return B.nul(options)
        case "unknown": return B.unknown(options)
        case "bytes": return B.bytes(options)
        case "lit":
            guard let argument else { throw FixtureError.invalid("Missing literal") }
            return B.lit(argument, options)
        case "oneOf":
            guard case let .array(values)? = argument else { throw FixtureError.invalid("Missing enum values") }
            return B.oneOf(values, options)
        case "arr": return try B.arr(item(), options)
        case "map": return try B.map(item(), options)
        case "nullable": return try B.nullable(item(), options)
        case "tuple": return try B.tuple(items(), options)
        case "union": return try B.union(items(), options)
        case "unsafe": return argument.map(B.unsafe) ?? B.unsafe()
        case "self":
            guard let selfReference else { throw FixtureError.invalid("Missing recursive reference") }
            return selfReference
        case "recursive":
            guard case let .object(recursive)? = argument, case let .string(id)? = recursive["id"],
                  let schema = recursive["schema"] else { throw FixtureError.invalid("Invalid recursive call") }
            return try B.recursive(id) { reference in try evaluate(schema, selfReference: reference) }
        case "obj":
            guard case let .array(values)? = argument else { throw FixtureError.invalid("Missing properties") }
            let properties: [B.Property] = try values.map { value in
                guard case let .object(property) = value, case let .string(name)? = property["name"],
                      let schema = property["schema"] else { throw FixtureError.invalid("Invalid property") }
                let result = try evaluate(schema, selfReference: selfReference)
                return property["optional"] == .bool(true) ? .init(name, B.opt(result)) : .init(name, result)
            }
            return B.obj(properties, options)
        default: throw FixtureError.invalid("Unknown builder: \(builder)")
        }
    }

    @Test("builder JSON text matches v1.5.2 fixtures")
    func generatedBuilderCalls() throws {
        let url = (Bundle.module.resourceURL ?? Bundle.module.bundleURL)
            .appendingPathComponent("Fixtures/generated/builders-v1.5.2.jsonl")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count > 80)
        for line in lines.dropFirst() {
            guard case let .object(vector) = try json(String(line)), case let .string(id)? = vector["id"],
                  let call = vector["call"], case let .string(expected)? = vector["expectedJSON"] else {
                throw FixtureError.invalid("Invalid builder fixture")
            }
            #expect(try evaluate(call).stringify() == expected, "Builder call: \(id)")
        }
    }
}
