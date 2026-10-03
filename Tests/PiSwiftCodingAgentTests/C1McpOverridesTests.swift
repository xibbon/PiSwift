import Foundation
import PiSwiftAI
import PiSwiftMCP
import Testing
@testable import PiSwiftCodingAgent

@Suite struct C1McpOverridesTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("c1-overrides-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("agent"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("project/.pi"), withIntermediateDirectories: true)
        return root
    }

    @Test func overridesKeepGlobalFieldsAndValidateTheMergedConfig() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = root.appendingPathComponent("agent"), cwd = root.appendingPathComponent("project")
        let global = agent.appendingPathComponent("mcp.json"), project = cwd.appendingPathComponent(".pi/mcp.json")
        try #"{"mcpServers":{"docs":{"command":"x","env":{"TOKEN":"secret"},"toolExposure":{"z*":"hidden","*":"direct"}},"remote":{"url":"https://example.com/mcp","headers":{"X-Key":"secret"},"auth":{"provider":"fixture"}},"extra":{"command":"x"},"invalid":{"command":"x"}}}"#
            .write(to: global, atomically: true, encoding: .utf8)
        try #"{"mcpServers":{"docs":{"enabled":false,"exposure":"direct"},"remote":{"toolExposure":{"b*":"hidden","a*":"direct"}},"extra":{"env":{}},"missing":{"enabled":false},"invalid":{"enabled":"no"}}}"#
            .write(to: project, atomically: true, encoding: .utf8)
        let loaded = loadMcpConfig(agentDir: agent, cwd: cwd, projectTrusted: true)
        #expect(loaded.projectConfig == project.path)
        let docs = try #require(loaded.servers.first { $0.name == "docs" })
        #expect(docs.scope == .global && docs.source == global.path && docs.override == project.path)
        #expect(docs.config.env == ["TOKEN": "secret"])
        #expect(docs.config.enabled == false && docs.config.exposure == .direct)
        #expect(docs.config.toolExposureOrder == ["z*", "*"])
        let remote = try #require(loaded.servers.first { $0.name == "remote" })
        #expect(remote.config.headers == ["X-Key": "secret"])
        #expect(remote.config.auth?.provider == "fixture")
        #expect(remote.config.toolExposureOrder == ["b*", "a*"])
        #expect(loaded.errors == [
            "\(project.path): server \"extra\": an override can only set enabled, exposure, toolExposure",
            "\(project.path): server \"missing\" needs \"command\" or \"url\", or a global server to override",
            "\(project.path): server \"invalid\": enabled must be a boolean",
        ])
        let untrusted = loadMcpConfig(agentDir: agent, cwd: cwd, projectTrusted: false)
        #expect(untrusted.projectConfig == nil)
        #expect(untrusted.servers.allSatisfy { $0.override == nil })
        let report = McpListReport(servers: mcpServerListReport(loaded), errors: [], failed: false)
        let json = try OrderedJSON.parse(String(decoding: report.jsonData(), as: UTF8.self))
        let first = try #require(json["servers"]?[0])
        #expect(first.objectEntries?.prefix(4).map { $0.0 } == ["name", "scope", "source", "override"])
        #expect(mcpServerListReport(untrusted).allSatisfy { $0.override == nil })
    }

    @Test func overrideUpdatesKeepDefaultsAndFileOrder() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("project/.pi/mcp.json")
        try "{\n\t\"other\": true,\n\t\"mcpServers\": {\n\t\t\"docs\": {\n\t\t\t\"exposure\": \"hidden\",\n\t\t\t\"enabled\": false\n\t\t}\n\t}\n}\n".write(to: path, atomically: true, encoding: .utf8)
        try updateMcpServerConfig(path: path, name: "docs", patch: .init(enabled: true, exposure: .codemode))
        let text = try String(contentsOf: path, encoding: .utf8)
        let parsed = try OrderedJSON.parse(text)
        #expect(parsed.objectEntries?.map { $0.0 } == ["other", "mcpServers"])
        #expect(parsed["mcpServers"]?["docs"]?.objectEntries?.map { $0.0 } == ["exposure", "enabled"])
        #expect(parsed["mcpServers"]?["docs"]?["enabled"]?.serialized() == "true")
        #expect(parsed["mcpServers"]?["docs"]?["exposure"]?.serialized() == #""codemode""#)
        #expect(text.contains("\n\t\t\t\"exposure\""))
        let newPath = root.appendingPathComponent("new/.pi/mcp.json")
        try updateMcpServerConfig(path: newPath, name: "docs", patch: .init(enabled: true), override: true)
        let added = try OrderedJSON.parse(String(contentsOf: newPath, encoding: .utf8))
        #expect(added["mcpServers"]?["docs"]?["enabled"]?.serialized() == "true")
    }

    @Test func cimdValidationMatchesUpstreamAndRejectsIPv6() throws {
        func error(_ oauth: [String: Any]) -> String? {
            validateMcpServerConfig(name: "docs", value: ["url": "https://example.com/mcp", "oauth": oauth])
        }
        #expect(error(["clientRegistration": "dcr", "clientName": "pi"]) == nil)
        #expect(error(["clientRegistration": "cimd"]) == nil)
        #expect(error(["clientRegistration": "cimd", "callbackUrl": "http://localhost:6000/callback"]) == nil)
        #expect(error(["clientRegistration": "other"]) == "server \"docs\": oauth.clientRegistration must be \"dcr\" or \"cimd\"")
        for key in ["clientId", "clientName"] {
            #expect(error(["clientRegistration": "cimd", key: "client"]) == "server \"docs\": oauth.clientRegistration \"cimd\" cannot be combined with oauth.clientId or oauth.clientName")
        }
        for callback in ["http://localhost/other", "http://[::1]/callback"] {
            #expect(error(["clientRegistration": "cimd", "callbackUrl": callback]) == "server \"docs\": oauth.clientRegistration \"cimd\" requires oauth.callbackUrl on localhost or 127.0.0.1 with path /callback")
        }
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("agent/mcp.json")
        _ = try addMcpServerConfig(path: path, name: "docs", config: .init(url: "https://example.com/mcp", oauth: .init(clientRegistration: .cimd)))
        let loaded = loadMcpConfig(agentDir: root.appendingPathComponent("agent"), cwd: root, projectTrusted: false)
        #expect(loaded.servers.first?.config.oauth?.clientRegistration == .cimd)
    }
}
