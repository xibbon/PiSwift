import Foundation
import Testing
import PiMCPAdapter
import PiSwiftMCP

@Suite("M3 namespace compatibility")
struct M3NamespaceCompatibilityTests {
    @Test("MCP prefixes retain the prior UTF-8 bytes for all server inputs")
    func namespaceCompatibilityTable() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Scripts/mcp-fixtures/naming-v1.5.2.json")
        let fixture = try JSONDecoder().decode(
            NamingFixture.self,
            from: Data(contentsOf: fixtureURL)
        )
        #expect(fixture.cases.count == 63)

        // Keep each fixture row, including repeated server names.
        let rows = fixture.cases + Self.adapterServers.map {
            NamingRow(id: "adapter:\($0)", server: $0)
        }
        for row in rows {
            let prior = "mcp__" + row.server.replacingOccurrences(of: "-", with: "_")
            let adapter = getServerPrefix(row.server, mode: "mcp")
            let shared = PiSwiftMCP.mcpNamespace(row.server)
            let context = "Row \(row.id), server \(String(reflecting: row.server))"

            // String equality can hide differences in Unicode encoding.
            #expect(
                Array(adapter.utf8) == Array(prior.utf8),
                "\(context): adapter \(String(reflecting: adapter)) differs from prior \(String(reflecting: prior))"
            )
            #expect(
                Array(adapter.utf8) == Array(shared.utf8),
                "\(context): adapter \(String(reflecting: adapter)) differs from shared \(String(reflecting: shared))"
            )
        }
    }

    // Server names from the existing adapter tests, including configuration keys.
    private static let adapterServers = [
        "xcodebuild", "my-server", "my-mcp", "MCP", "tools-mcp", "anything",
        "demo-mcp", "mcp", "my-cool-server", "demo", "other", "test", "s1",
        "full", "remote", "srv", "lazy", "disabled", "tools-only", "prompt-failure",
    ]
}

private struct NamingFixture: Decodable {
    let cases: [NamingRow]
}

private struct NamingRow: Decodable {
    let id: String
    let server: String
}
