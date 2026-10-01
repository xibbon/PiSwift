import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

private func f2McpConfigDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("f2-mcp-config-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("agent"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("project/.pi"), withIntermediateDirectories: true)
    return root
}

private func f2McpKeys(_ value: OrderedJSON?) -> [String] { value?.objectEntries?.map { $0.0 } ?? [] }

// Port of mcp-extension.test.ts: merges global and trusted project servers and validates entries.
@Test func f2McpConfigMergesInSourceOrderAndReportsErrorsInSourceOrder() throws {
    let root = try f2McpConfigDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let agent = root.appendingPathComponent("agent")
    let project = root.appendingPathComponent("project")
    try #"{"mcpServers":{"shared":{"command":"global-cmd"},"remote":{"url":"https://example.com/mcp","headers":{"Authorization":"Bearer token"}},"off":{"command":"x","enabled":false},"bad":{"args":["no command"]},"legacy":{"type":"sse","url":"https://example.com/sse"},"badUrl":{"url":"example.com/mcp"},"bad name":{"command":"x"}}}"#
        .write(to: agent.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
    try #"{"mcpServers":{"shared":{"command":"project-cmd","exposure":"direct"},"added":{"command":"new-cmd"}}}"#
        .write(to: project.appendingPathComponent(".pi/mcp.json"), atomically: true, encoding: .utf8)
    let trusted = loadMcpConfig(agentDir: agent, cwd: project, projectTrusted: true)
    #expect(trusted.servers.map(\.name) == ["shared", "remote", "off", "added"])
    #expect(trusted.servers.map(\.scope) == [.project, .global, .global, .project])
    #expect(trusted.servers[0].config.command == "project-cmd")
    #expect(trusted.servers[0].config.exposure == .direct)
    #expect(trusted.servers[2].config.enabled == false)
    #expect(trusted.errors.count == 4)
    #expect(trusted.errors[0].hasSuffix("server \"bad\" needs either \"command\" (stdio) or \"url\" (streamable HTTP)"))
    #expect(trusted.errors[1].contains("legacy SSE transport is not supported"))
    #expect(trusted.errors[2].contains("server \"badUrl\": url must be an http or https URL"))
    #expect(trusted.errors[3].contains("invalid server name \"bad name\""))
    let untrusted = loadMcpConfig(agentDir: agent, cwd: project, projectTrusted: false)
    #expect(untrusted.servers.map(\.name) == ["shared", "remote", "off"])
    #expect(untrusted.servers[0].config.command == "global-cmd")
    #expect(mcpServerListReport(trusted).map(\.name) == trusted.servers.map(\.name))
}

// Port of mcp-extension.test.ts: exposure validation and autoEnableCodemode project precedence.
@Test func f2McpConfigExposureValidationKeepsSourceOrder() throws {
    let root = try f2McpConfigDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let agent = root.appendingPathComponent("agent")
    let project = root.appendingPathComponent("project")
    try #"{"autoEnableCodemode":false,"mcpServers":{"later":{"command":"x","exposure":"deferred"},"scripts":{"command":"x","exposure":"codemode-deferred"},"off":{"command":"x","exposure":"hidden"},"wrong":{"command":"x","exposure":"model-only"}}}"#
        .write(to: agent.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
    let path = project.appendingPathComponent(".pi/mcp.json")
    try #"{"autoEnableCodemode":"yes","mcpServers":{}}"#.write(to: path, atomically: true, encoding: .utf8)
    let trusted = loadMcpConfig(agentDir: agent, cwd: project, projectTrusted: true)
    #expect(trusted.servers.map(\.name) == ["later", "scripts", "off"])
    #expect(trusted.servers.map { $0.config.exposure } == [.deferred, .codemodeDeferred, .hidden])
    #expect(trusted.autoEnableCodemode == false)
    #expect(trusted.errors.count == 2)
    #expect(trusted.errors[0].contains("server \"wrong\": exposure must be one of"))
    #expect(trusted.errors[1].contains("autoEnableCodemode must be a boolean"))
    try #"{"autoEnableCodemode":true}"#.write(to: path, atomically: true, encoding: .utf8)
    #expect(loadMcpConfig(agentDir: agent, cwd: project, projectTrusted: true).autoEnableCodemode == true)
}

// Upstream config.ts editMcpServers preserves object order and the indentation string.
@Test(arguments: ["\t", " \t", "    ", "            "])
func f2McpConfigEditsKeepAllKeyOrderAndIndentCharacters(_ indent: String) throws {
    let root = try f2McpConfigDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("agent/mcp.json")
    let source = """
    {
    \(indent)"other": {"z": [1, {"last": "https://example.com/a/b", "first": true}], "a": null},
    \(indent)"mcpServers": {
    \(indent)\(indent)"zeta": {"url": "https://z.example/mcp", "toolExposure": {"read*": "deferred", "*file": "hidden"}, "custom": {"z": 1, "a": 2}},
    \(indent)\(indent)"alpha": {"url": "https://a.example/mcp", "enabled": false, "exposure": "direct"}
    \(indent)},
    \(indent)"after": []
    }
    """
    try source.write(to: path, atomically: true, encoding: .utf8)
    try updateMcpServerConfig(path: path, name: "zeta", patch: .init(enabled: false, exposure: .deferred))
    var text = try String(contentsOf: path, encoding: .utf8)
    var json = try OrderedJSON.parse(text)
    #expect(f2McpKeys(json) == ["other", "mcpServers", "after"])
    #expect(f2McpKeys(json["other"]) == ["z", "a"])
    #expect(f2McpKeys(json["mcpServers"]) == ["zeta", "alpha"])
    #expect(f2McpKeys(json["mcpServers"]?["zeta"]) == ["url", "toolExposure", "custom", "enabled", "exposure"])
    #expect(f2McpKeys(json["mcpServers"]?["zeta"]?["toolExposure"]) == ["read*", "*file"])
    #expect(f2McpKeys(json["mcpServers"]?["zeta"]?["custom"]) == ["z", "a"])
    #expect(text.contains("\n\(String(indent.prefix(10)))\"other\": {\n"))
    #expect(text.contains("https://example.com/a/b"))
    #expect(!text.contains("\\/"))
    #expect(text.hasSuffix("\n"))
    try updateMcpServerConfig(path: path, name: "alpha", patch: .init(enabled: true, exposure: .codemode))
    #expect(try addMcpServerConfig(path: path, name: "zeta", config: .init(url: "https://new.example/mcp")))
    #expect(!(try addMcpServerConfig(path: path, name: "new", config: .init(command: "server", args: ["--flag"])) ))
    text = try String(contentsOf: path, encoding: .utf8)
    json = try OrderedJSON.parse(text)
    #expect(f2McpKeys(json["mcpServers"]) == ["zeta", "alpha", "new"])
    #expect(f2McpKeys(json["mcpServers"]?["alpha"]) == ["url"])
    #expect(f2McpKeys(json["mcpServers"]?["new"]) == ["command", "args"])
    #expect(json["other"]?.serialized() == (try OrderedJSON.parse(source))["other"]?.serialized())
    #expect(try removeMcpServerConfig(path: path, name: "alpha"))
    #expect(!(try removeMcpServerConfig(path: path, name: "absent")))
    let final = try OrderedJSON.parse(String(contentsOf: path, encoding: .utf8))
    #expect(f2McpKeys(final["mcpServers"]) == ["zeta", "new"])
}

// Port of mcp-command.test.ts add/remove cases, with exact JSON text checks.
@Test func f2McpConfigCreatesWithUpstreamJSONTextAndDoesNotRewriteOnMissingRemove() throws {
    let root = try f2McpConfigDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("new/mcp.json")
    #expect(!(try removeMcpServerConfig(path: path, name: "docs")))
    #expect(!(try addMcpServerConfig(path: path, name: "docs", config: .init(url: "https://example.com/mcp"))))
    let expected = """
    {
      "mcpServers": {
        "docs": {
          "url": "https://example.com/mcp"
        }
      }
    }

    """
    #expect(try String(contentsOf: path, encoding: .utf8) == expected)
    #expect(!(try removeMcpServerConfig(path: path, name: "absent")))
    #expect(try String(contentsOf: path, encoding: .utf8) == expected)
    #expect(try removeMcpServerConfig(path: path, name: "docs"))
    #expect(try String(contentsOf: path, encoding: .utf8) == "{\n  \"mcpServers\": {}\n}\n")
}

// Port of mcp-command.test.ts JSON list report, in upstream construction order.
@Test(.timeLimit(.minutes(1))) func f2McpReportsKeepServerToolAndFieldOrder() async throws {
    let root = try f2McpConfigDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let entries = ["zeta", "alpha"].map { McpServerEntry(name: $0, config: .init(url: "https://example.com/mcp", enabled: false), source: "fixture", scope: .global) }
    var report = await inspectMcpServers(LoadedMcpConfig(servers: entries), cwd: root,
        credentials: McpOAuthCredentialStore(agentDir: root), note: "untrusted", createTransport: { _, _, _ in
            Issue.record("Disabled servers must not connect")
            throw McpRuntimeError.invalidConfig("unexpected connection")
        })
    #expect(report.servers.map(\.name) == ["zeta", "alpha"])
    report.servers[0].tools = ["z_tool", "a_tool"]
    report.servers[0].toolExposure = ["a_tool": .hidden, "z_tool": .direct]
    report.servers[0].resources = 1
    report.servers[0].resourceTemplates = 0
    report.servers[0].error = "failure"
    let text = String(decoding: try report.jsonData(), as: UTF8.self)
    let json = try OrderedJSON.parse(text)
    #expect(f2McpKeys(json) == ["servers", "errors", "note"])
    guard case .array(let servers) = json["servers"] else { Issue.record("Report must contain servers"); return }
    #expect(servers.compactMap { $0["name"]?.stringValue } == ["zeta", "alpha"])
    #expect(f2McpKeys(servers[0]) == ["name", "scope", "source", "enabled", "exposure", "transport", "state", "tools", "toolExposure", "resources", "resourceTemplates", "error"])
    #expect(f2McpKeys(servers[0]["toolExposure"]) == ["z_tool", "a_tool"])
    #expect(text.hasPrefix("{\n  \"servers\": [\n    {\n      \"name\": \"zeta\","))
    #expect(text.contains("\"transport\": \"https://example.com/mcp\""))
    #expect(!text.hasSuffix("\n"))
}

@Test func f2McpConfigDuplicateKeysKeepLastValueAndFirstPosition() throws {
    let root = try f2McpConfigDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let agent = root.appendingPathComponent("agent")
    let path = agent.appendingPathComponent("mcp.json")
    try #"{"mcpServers":{"zeta":{"url":"https://old.example/mcp"},"alpha":{"command":"x"},"zeta":{"url":"https://new.example/mcp"}}}"#
        .write(to: path, atomically: true, encoding: .utf8)
    let loaded = loadMcpConfig(agentDir: agent, cwd: root, projectTrusted: false)
    #expect(loaded.errors.isEmpty)
    #expect(loaded.servers.map(\.name) == ["zeta", "alpha"])
    #expect(loaded.servers[0].config.url == "https://new.example/mcp")
    try updateMcpServerConfig(path: path, name: "zeta", patch: .init(enabled: false))
    let json = try OrderedJSON.parse(String(contentsOf: path, encoding: .utf8))
    #expect(f2McpKeys(json["mcpServers"]) == ["zeta", "alpha"])
}

// JavaScript object enumeration treats canonical array-index keys separately from other keys.
@Test func f2McpConfigUsesJavaScriptIndexKeyAndNumberRules() throws {
    let root = try f2McpConfigDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let agent = root.appendingPathComponent("agent")
    let path = agent.appendingPathComponent("mcp.json")
    try #"{"other":[-0,1.0,1e-6,1e-7,1e20,1e21,9007199254740993],"mcpServers":{"10":{"command":"x"},"2":{"command":"x"},"zeta":{"command":"x"},"01":{"command":"x"},"4294967295":{"command":"x"}}}"#
        .write(to: path, atomically: true, encoding: .utf8)
    let loaded = loadMcpConfig(agentDir: agent, cwd: root, projectTrusted: false)
    #expect(loaded.servers.map(\.name) == ["2", "10", "zeta", "01", "4294967295"])
    try updateMcpServerConfig(path: path, name: "zeta", patch: .init(enabled: false))
    let output = try OrderedJSON.parse(String(contentsOf: path, encoding: .utf8))
    #expect(f2McpKeys(output["mcpServers"]) == ["2", "10", "zeta", "01", "4294967295"])
    #expect(output["other"]?.serialized() == "[0,1,0.000001,1e-7,100000000000000000000,1e+21,9007199254740992]")
}
