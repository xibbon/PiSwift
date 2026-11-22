import Foundation
import Testing
import PiSwiftAI
import PiSwiftCodingAgent

private struct CTAToolSchemaFixture: Decodable {
    let tag: String
    let schemas: [String: AnyCodable]
}

// v1.5.2 C-TA, 6536f8012 and 6291b9bcc: compare JSON values from the tagged tool declarations.
@Test func ctaBuiltInToolParametersMatchTaggedSchemas() throws {
    let url = try #require(Bundle.module.url(
        forResource: "builtin-tool-schemas", withExtension: "json", subdirectory: "fixtures"
    ))
    let fixture = try JSONDecoder().decode(CTAToolSchemaFixture.self, from: Data(contentsOf: url))
    #expect(fixture.tag == "v1.6.0")
    let tools = [
        createBashTool(cwd: "/"), createEditTool(cwd: "/"), createFindTool(cwd: "/"),
        createGrepTool(cwd: "/"), createLsTool(cwd: "/"), createReadTool(cwd: "/"),
        createWriteTool(cwd: "/"),
    ]
    #expect(tools.count == fixture.schemas.count)
    for tool in tools {
        let encoded = try JSONEncoder().encode(tool.parameters)
        let schema = try JSONDecoder().decode(AnyCodable.self, from: encoded)
        #expect(schema == fixture.schemas[tool.name], "Parameters: \(tool.name)")
    }
}
