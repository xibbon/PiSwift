import Foundation
import Testing
import PiSwiftAI
import PiSwiftCodingAgent

private func v140McpDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-mcp-bom-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func v140WriteBom(_ json: String, to path: URL) throws {
    try ("\u{FEFF}" + json + "\n").write(to: path, atomically: true, encoding: .utf8)
}

// Upstream bdd9f0399, mcp-extension.test.ts:120: read both scopes and edit BOM config.
@Test func v140McpBomLoadsBothScopesAndAddsWithoutChangingOrder() throws {
    let root = try v140McpDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent(".pi")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let globalPath = root.appendingPathComponent("mcp.json")
    let projectPath = project.appendingPathComponent("mcp.json")
    try v140WriteBom(#"{"other":{"keep":true},"mcpServers":{"demo":{"command":"echo","enabled":false},"second":{"command":"second"}}}"#, to: globalPath)
    try v140WriteBom(#"{"mcpServers":{"local":{"command":"local-cmd"}}}"#, to: projectPath)
    let loaded = loadMcpConfig(agentDir: root, cwd: root, projectTrusted: true)
    #expect(loaded.errors.isEmpty)
    #expect(loaded.servers.map(\.name) == ["demo", "second", "local"])
    #expect(loaded.servers.map(\.scope) == [.global, .global, .project])
    #expect(try addMcpServerConfig(path: globalPath, name: "other", config: .init(command: "other-cmd")) == false)
    let saved = try String(contentsOf: globalPath, encoding: .utf8)
    #expect(!saved.hasPrefix("\u{FEFF}"))
    let parsed = try OrderedJSON.parse(saved)
    #expect(parsed.objectEntries?.map(\.0) == ["other", "mcpServers"])
    #expect(parsed["mcpServers"]?.objectEntries?.map(\.0) == ["demo", "second", "other"])
    #expect(parsed["other"]?["keep"]?.serialized() == "true")
    #expect(parsed["mcpServers"]?["demo"]?["enabled"]?.serialized() == "false")
    #expect(parsed["mcpServers"]?["other"]?["command"]?.serialized() == #""other-cmd""#)
}

@Test func v140McpBomUpdateAndRemoveUseTheCommonParser() throws {
    let root = try v140McpDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("mcp.json")
    let json = #"{"mcpServers":{"demo":{"command":"echo","enabled":false},"keep":{"command":"keep"}}}"#
    try v140WriteBom(json, to: path)
    try updateMcpServerConfig(path: path, name: "demo", patch: .init(enabled: true))
    let updated = try String(contentsOf: path, encoding: .utf8)
    #expect(!updated.hasPrefix("\u{FEFF}"))
    #expect(try OrderedJSON.parse(updated)["mcpServers"]?["demo"]?["enabled"]?.serialized() == nil)
    // Put the BOM back to check the remove boundary separately.
    try v140WriteBom(updated, to: path)
    #expect(try removeMcpServerConfig(path: path, name: "demo"))
    let removed = try String(contentsOf: path, encoding: .utf8)
    #expect(!removed.hasPrefix("\u{FEFF}"))
    #expect(try OrderedJSON.parse(removed)["mcpServers"]?.objectEntries?.map(\.0) == ["keep"])
}

@Test func v140McpBomPreservesShapeAndMalformedDiagnostics() throws {
    let root = try v140McpDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("mcp.json")
    for json in ["[]", #"{"mcpServers":[]}"#, #"{"mcpServers":{"demo":}"#] {
        try json.write(to: path, atomically: true, encoding: .utf8)
        let plain = loadMcpConfig(agentDir: root, cwd: root, projectTrusted: false)
        try v140WriteBom(json, to: path)
        let bom = loadMcpConfig(agentDir: root, cwd: root, projectTrusted: false)
        #expect(!plain.errors.isEmpty)
        #expect(bom.errors == plain.errors)
        if json != #"{"mcpServers":{"demo":}"# {
            let expected = "\(path.path): expected an object with an \"mcpServers\" object"
            #expect(bom.errors == [expected])
            do {
                _ = try removeMcpServerConfig(path: path, name: "demo")
                Issue.record("Expected the config shape error")
            } catch {
                #expect(error.localizedDescription == expected)
            }
        }
    }
}

@Test func v140McpBomPreservesDuplicateServerHandling() throws {
    let root = try v140McpDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("mcp.json")
    let json = #"{"mcpServers":{"same":{"command":"first"},"same":{"command":"second"},"bad.name":{"command":"invalid"}}}"#
    try json.write(to: path, atomically: true, encoding: .utf8)
    let plain = loadMcpConfig(agentDir: root, cwd: root, projectTrusted: false)
    try v140WriteBom(json, to: path)
    let bom = loadMcpConfig(agentDir: root, cwd: root, projectTrusted: false)
    #expect(bom.servers.map(\.name) == plain.servers.map(\.name))
    #expect(bom.servers.map(\.config.command) == plain.servers.map(\.config.command))
    #expect(bom.errors == plain.errors)
    #expect(!bom.errors.isEmpty)
}
