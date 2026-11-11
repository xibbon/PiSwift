import Foundation
import Testing
import PiSwiftAI
import PiSwiftCodingAgent

private struct C12Fixture: Decodable {
    let tag: String
    let declarations: [C12FixtureRow]
}

private struct C12FixtureRow: Decodable {
    let name: String
    let schema: AnyCodable
    let type: String
    let signature: String
    let sample: String
    let declaration: String
}

// v1.5.2 C-CM: values come from the tagged declarations.ts, through generate-cm-fixtures.mjs.
@Test func c12TaggedDeclarationDifferentialFixtures() throws {
    let url = try #require(Bundle.module.url(forResource: "codemode-cm-v152", withExtension: "json", subdirectory: "fixtures"))
    let fixture = try JSONDecoder().decode(C12Fixture.self, from: Data(contentsOf: url))
    #expect(fixture.tag == "v1.5.2")
    #expect(fixture.declarations.count >= 120)
    for row in fixture.declarations {
        let tool = CodemodeDeclaration(name: row.name, description: "Tool \(row.name)",
                                       inputSchema: row.schema, outputSchema: AnyCodable(["type": "string"]))
        #expect(schemaToType(row.schema) == row.type, "Type: \(row.name)")
        #expect(renderToolSignature(tool) == row.signature, "Signature: \(row.name)")
        #expect(renderToolSample(tool) == row.sample, "Sample: \(row.name)")
        #expect(renderDeclarations(tools: [tool]) == row.declaration, "Declaration: \(row.name)")
    }
}
