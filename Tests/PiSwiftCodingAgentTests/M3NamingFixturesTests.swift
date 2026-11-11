import Foundation
import Testing
import PiSwiftMCP
import PiSwiftCodingAgent

private struct M3NamingFixture: Decodable {
    struct Case: Decodable {
        let id: String
        let server: String
        let tool: String
        let taken: Bool
        let name: String
        let namespace: String
    }
    let tag: String
    let commit: String
    let cases: [Case]
}

@Test func m3NamingMatchesTaggedUpstream() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let path = root.appendingPathComponent("Scripts/mcp-fixtures/naming-v1.5.2.json")
    let fixture = try JSONDecoder().decode(M3NamingFixture.self, from: Data(contentsOf: path))
    #expect(fixture.tag == "v1.5.2")
    #expect(fixture.commit.count == 40)
    #expect(fixture.cases.count >= 40)
    for row in fixture.cases {
        let shared = PiSwiftMCP.createMcpToolName(server: row.server, tool: row.tool, isTaken: { _ in row.taken })
        let forwarded = PiSwiftCodingAgent.createMcpToolName(server: row.server, tool: row.tool, isTaken: { _ in row.taken })
        #expect(shared == row.name, "Shared naming: \(row.id)")
        #expect(forwarded == row.name, "Forwarded naming: \(row.id)")
        #expect(PiSwiftMCP.mcpNamespace(row.server) == row.namespace, "Shared namespace: \(row.id)")
        #expect(PiSwiftCodingAgent.mcpNamespace(row.server) == row.namespace, "Forwarded namespace: \(row.id)")
    }
}
