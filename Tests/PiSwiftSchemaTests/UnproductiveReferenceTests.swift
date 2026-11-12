import Testing
@testable import PiSwiftSchema

@Suite("PiSwiftSchemaTests.UnproductiveReference")
struct UnproductiveReferenceTests {
    @Test func directSelfReferenceRejectsBeforeExecution() {
        // v1.5.2 D8: compiler.ts:200 permits this reference, but its check has no value progress.
        #expect(throws: SchemaCompileError.self) {
            try compile(.object(["$ref": .string("#")]))
        }
    }
    @Test func cacheKeepsCanonicallyDistinctReferenceTargets() throws {
        // v1.5.2 D8: schema/src/compiler.ts:95 caches by JavaScript string identity.
        let schema: SchemaValue = .object([
            "$defs": .object(["é": .object(["properties": .object(["first": .object([:])])]),
                              "e\u{301}": .object(["properties": .object(["second": .object([:])])])]),
            "allOf": .array([.object(["$ref": .string("#/$defs/é")]),
                             .object(["$ref": .string("#/$defs/e\u{301}")])]),
            "unevaluatedProperties": .bool(false)
        ])
        #expect(try compile(schema, options: .init(unresolvedRefs: .reject)).check(.object(["first": .number(1), "second": .number(2)])))
    }
}
