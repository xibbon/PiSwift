import Testing
import Foundation
import PiSwiftAI
@testable import PiMCPAdapter

@Suite("Tool Name Formatting")
struct ToolNameTests {
    @Test("Server prefix mode")
    func serverPrefix() {
        #expect(formatToolName("list_sims", serverName: "xcodebuild", prefix: "server") == "xcodebuild_list_sims")
        #expect(formatToolName("query", serverName: "my-server", prefix: "server") == "my_server_query")
    }

    @Test("Short prefix mode strips -mcp suffix")
    func shortPrefix() {
        #expect(formatToolName("query", serverName: "my-mcp", prefix: "short") == "my_query")
        #expect(formatToolName("query", serverName: "MCP", prefix: "short") == "mcp_query")
        #expect(formatToolName("query", serverName: "tools-mcp", prefix: "short") == "tools_query")
    }

    @Test("None prefix mode returns raw tool name")
    func nonePrefix() {
        #expect(formatToolName("query", serverName: "anything", prefix: "none") == "query")
    }

    @Test("MCP prefix mode and dotted names")
    func mcpPrefix() {
        #expect(formatToolName("tools.search", serverName: "my-server", prefix: "mcp") == "mcp__my_server_tools_search")
    }

    @Test("prompt commands use a stable namespaced form")
    func formatsPromptCommandName() {
        #expect(formatPromptCommandName("daily brief", serverName: "demo-mcp", prefix: "short") == "mcp__demo__daily_brief")
    }

    @Test("getServerPrefix edge cases")
    func serverPrefixEdgeCases() {
        // Empty after stripping should become "mcp"
        #expect(getServerPrefix("mcp", mode: "short") == "mcp")
        #expect(getServerPrefix("MCP", mode: "short") == "mcp")
        // Hyphens replaced
        #expect(getServerPrefix("my-cool-server", mode: "server") == "my_cool_server")
    }

    @Test("Resource name to tool name")
    func resourceNames() {
        #expect(resourceNameToToolName("My Resource") == "my_resource")
        #expect(resourceNameToToolName("123-data") == "resource_123_data")
    }
}

@Suite("Tool Visibility")
struct ToolVisibilityTests {
    @Test("exclude patterns take precedence over include patterns")
    func excludeWins() {
        let definition = ServerEntry(
            includeTools: ["demo_*"] ,
            excludeTools: ["demo_delete"]
        )
        #expect(isToolAllowed("search", serverName: "demo", prefix: "server", definition: definition))
        #expect(!isToolAllowed("delete", serverName: "demo", prefix: "server", definition: definition))
        #expect(!isToolAllowed("search", serverName: "other", prefix: "server", definition: definition))
    }
}

@Suite("DirectToolsConfig Codable")
struct DirectToolsConfigTests {
    @Test("Decode boolean true")
    func decodeBoolTrue() throws {
        let json = "true".data(using: .utf8)!
        let config = try JSONDecoder().decode(DirectToolsConfig.self, from: json)
        if case .enabled(let v) = config {
            #expect(v == true)
        } else {
            Issue.record("Expected .enabled(true)")
        }
    }

    @Test("Decode boolean false")
    func decodeBoolFalse() throws {
        let json = "false".data(using: .utf8)!
        let config = try JSONDecoder().decode(DirectToolsConfig.self, from: json)
        if case .enabled(let v) = config {
            #expect(v == false)
        } else {
            Issue.record("Expected .enabled(false)")
        }
    }

    @Test("Decode string array")
    func decodeStringArray() throws {
        let json = #"["tool1", "tool2"]"#.data(using: .utf8)!
        let config = try JSONDecoder().decode(DirectToolsConfig.self, from: json)
        if case .tools(let arr) = config {
            #expect(arr == ["tool1", "tool2"])
        } else {
            Issue.record("Expected .tools([...])")
        }
    }

    @Test("Encode round-trip")
    func roundTrip() throws {
        let original = DirectToolsConfig.tools(["a", "b"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DirectToolsConfig.self, from: data)
        if case .tools(let arr) = decoded {
            #expect(arr == ["a", "b"])
        } else {
            Issue.record("Round-trip failed")
        }
    }
}

@Suite("McpConfig Codable")
struct McpConfigTests {
    @Test("Decode with mcpServers")
    func decodeMcpServers() throws {
        let json = """
        {
            "mcpServers": {
                "test": {"command": "echo", "args": ["hello"]}
            },
            "settings": {
                "toolPrefix": "short",
                "authRequiredMessage": "Sign in to ${server}."
            }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(McpConfig.self, from: json)
        #expect(config.mcpServers.count == 1)
        #expect(config.mcpServers["test"]?.command == "echo")
        #expect(config.mcpServers["test"]?.args == ["hello"])
        #expect(config.settings?.toolPrefix == "short")
        #expect(config.settings?.authRequiredMessage == "Sign in to ${server}.")
    }

    @Test("Decode with mcp-servers (hyphenated)")
    func decodeHyphenated() throws {
        let json = """
        {"mcp-servers": {"s1": {"url": "http://localhost:3000"}}}
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(McpConfig.self, from: json)
        #expect(config.mcpServers.count == 1)
        #expect(config.mcpServers["s1"]?.url == "http://localhost:3000")
    }

    @Test("Decode empty config")
    func decodeEmpty() throws {
        let json = "{}".data(using: .utf8)!
        let config = try JSONDecoder().decode(McpConfig.self, from: json)
        #expect(config.mcpServers.isEmpty)
        #expect(config.imports == nil)
        #expect(config.settings == nil)
    }

    @Test("Server entry with all fields")
    func fullServerEntry() throws {
        let json = """
        {
            "mcpServers": {
                "full": {
                    "command": "npx",
                    "args": ["-y", "my-server"],
                    "env": {"KEY": "value"},
                    "cwd": "/tmp",
                    "lifecycle": "keep-alive",
                    "idleTimeout": 5,
                    "exposeResources": true,
                    "directTools": true,
                    "debug": true
                }
            }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(McpConfig.self, from: json)
        let entry = config.mcpServers["full"]!
        #expect(entry.command == "npx")
        #expect(entry.args == ["-y", "my-server"])
        #expect(entry.env == ["KEY": "value"])
        #expect(entry.cwd == "/tmp")
        #expect(entry.lifecycle == "keep-alive")
        #expect(entry.idleTimeout == 5)
        #expect(entry.exposeResources == true)
        #expect(entry.debug == true)
        if case .enabled(true) = entry.directTools {} else {
            Issue.record("Expected .enabled(true)")
        }
    }

    @Test("OAuth false is accepted as explicit disabled OAuth configuration")
    func decodesDisabledOAuth() throws {
        let json = Data(#"{"mcpServers":{"remote":{"url":"https://example.com/mcp","oauth":false}}}"#.utf8)
        let config = try JSONDecoder().decode(McpConfig.self, from: json)
        #expect(config.mcpServers["remote"]?.oauth != nil)
    }
}
