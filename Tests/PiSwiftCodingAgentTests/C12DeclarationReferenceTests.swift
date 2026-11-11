import Foundation
import Testing
import PiSwiftAI
import PiSwiftCodingAgent

@Test("resolves local references with escaped segments") func c12ResolveSchemaRefMatchesUpstream() {
    let item = AnyCodable(["type": "string"])
    let root = AnyCodable(["$defs": [
        "item": ["type": "string"],
        "a/b": ["type": "string"],
        "c~d": ["type": "string"],
        "e f": ["type": "string"]
    ]])

    #expect(resolveSchemaRef("#", root: root) == root)
    #expect(resolveSchemaRef("#/$defs/item", root: root) == item)
    #expect(resolveSchemaRef("#/$defs/a~1b", root: root) == item)
    #expect(resolveSchemaRef("#/$defs/c~0d", root: root) == item)
    #expect(resolveSchemaRef("#/$defs/e%20f", root: root) == item)
}

@Test("returns undefined for remote, missing, and malformed references") func c12ResolveSchemaRefRejectsInvalidReferences() {
    let root = AnyCodable(["$defs": ["item": ["type": "string"]]])

    #expect(resolveSchemaRef("other.json#/$defs/item", root: root) == nil)
    #expect(resolveSchemaRef("#/$defs/missing", root: root) == nil)
    #expect(resolveSchemaRef("#/$defs/%E0%A4%A", root: root) == nil)
    #expect(resolveSchemaRef("#/$defs/%ZZ", root: root) == nil)
    #expect(resolveSchemaRef("#/$defs/item", root: AnyCodable(["$defs": ["item": 1]])) == nil)
    #expect(resolveSchemaRef("#", root: AnyCodable(true)) == AnyCodable(true))
    #expect(resolveSchemaRef("#", root: AnyCodable(false)) == AnyCodable(false))
    #expect(resolveSchemaRef("#", root: AnyCodable("string")) == nil)
}

@Test func c12SchemaToTypeUsesExportedReferenceRules() {
    let root: [String: Any] = [
        "type": "object",
        "properties": [
            "escaped": ["$ref": "#/$defs/a~1b"],
            "encoded": ["$ref": "#/$defs/e%20f"],
            "malformed": ["$ref": "#/$defs/%E0%A4%A"]
        ],
        "$defs": [
            "a/b": ["type": "string"],
            "e f": ["type": "number"]
        ]
    ]
    #expect(schemaToType(AnyCodable(root)) == "{ encoded?: number; escaped?: string; malformed?: unknown; }")
}

@Test func c12SchemaToTypeBoundsHostileNestingAndOutput() {
    var nested: Any = ["type": "string"]
    for _ in 0..<80 { nested = ["type": "array", "items": nested] }
    #expect(schemaToType(AnyCodable(nested)) == "unknown")

    let oversized = AnyCodable(["const": String(repeating: "x", count: 1_000_001)])
    #expect(schemaToType(oversized) == "unknown")

    let tagged = AnyCodable(["type": "object", "properties": ["n": ["type": "integer", "minimum": 1]]])
    #expect(schemaToType(tagged) == "{\n  // @integer @minimum 1\n  n?: number;\n}")
}
