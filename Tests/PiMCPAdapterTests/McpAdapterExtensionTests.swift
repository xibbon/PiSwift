import Testing
import Foundation
import PiSwiftAI
import PiSwiftCodingAgent
@testable import PiMCPAdapter

@Suite("MCP Adapter Extension")
struct McpAdapterExtensionTests {
    @Test("accepts object and JSON-string proxy arguments")
    func decodesProxyArguments() throws {
        let object = try decodeProxyArguments(AnyCodable([
            "query": "swift",
            "limit": 3,
        ] as [String: Any]))
        #expect(object["query"]?.value as? String == "swift")
        #expect(object["limit"]?.value as? Int == 3)

        let string = try decodeProxyArguments(AnyCodable(#"{"query":"swift","limit":3}"#))
        #expect(string["query"]?.value as? String == "swift")
        #expect(string["limit"]?.value as? Int == 3)

        #expect(throws: McpError.self) {
            _ = try decodeProxyArguments(AnyCodable(["not", "an", "object"]))
        }
    }

    @Test("marks only returned MCP tool failures as agent errors")
    func identifiesMcpToolFailures() {
        #expect(shouldMarkMcpToolResultAsError(AnyCodable(["error": "tool_error"])))
        #expect(shouldMarkMcpToolResultAsError(AnyCodable(["error": "call_failed"])))
        #expect(!shouldMarkMcpToolResultAsError(AnyCodable(["error": "auth_required"])))
        #expect(!shouldMarkMcpToolResultAsError(nil))
    }

    @Test("registers the proxy tool from explicit configuration")
    func registersProxyTool() async {
        let adapter = McpAdapter.makeExtension(McpAdapterOptions(
            config: McpConfig(mcpServers: [:])
        ))
        let result = await createAgentSession(CreateAgentSessionOptions(
            inlineExtensions: [adapter.inlineExtension()]
        ))
        defer { result.session.dispose() }

        #expect(result.session.getAllToolNames().contains("mcp"))
    }

    @Test("omits the proxy tool when direct-only mode is selected")
    func omitsProxyTool() async {
        let adapter = McpAdapter.makeExtension(McpAdapterOptions(
            config: McpConfig(mcpServers: [:], settings: McpSettings(disableProxyTool: true))
        ))
        let result = await createAgentSession(CreateAgentSessionOptions(
            inlineExtensions: [adapter.inlineExtension()]
        ))
        defer { result.session.dispose() }

        #expect(!result.session.getAllToolNames().contains("mcp"))
    }

    @Test("registers configured direct tools from the supplied metadata cache")
    func registersCachedDirectTool() async {
        let server = ServerEntry(command: "unused", directTools: .enabled(true))
        let config = McpConfig(mcpServers: ["demo": server])
        let cache = MetadataCache(servers: [
            "demo": ServerCacheEntry(
                configHash: computeServerHash(server),
                tools: [CachedTool(name: "lookup", description: "Look up an item")],
                resources: [],
                cachedAt: Date().timeIntervalSince1970 * 1000
            ),
        ])
        let adapter = McpAdapter.makeExtension(McpAdapterOptions(
            config: config,
            metadataCache: cache
        ))
        let result = await createAgentSession(CreateAgentSessionOptions(
            inlineExtensions: [adapter.inlineExtension()]
        ))
        defer { result.session.dispose() }

        #expect(result.session.getAllToolNames().contains("demo_lookup"))
    }

    @Test("reports headless status without connecting lazy servers")
    func reportsRuntimeStatus() async throws {
        let lazyServer = ServerEntry(url: "https://example.invalid/mcp")
        let disabledServer = ServerEntry(url: "https://example.invalid/disabled", disabled: true)
        let adapter = McpAdapter.makeExtension(McpAdapterOptions(
            config: McpConfig(mcpServers: [
                "lazy": lazyServer,
                "disabled": disabledServer,
            ]),
            metadataCache: MetadataCache(servers: [
                "lazy": ServerCacheEntry(
                    configHash: computeServerHash(lazyServer),
                    tools: [CachedTool(name: "search")],
                    resources: [],
                    cachedAt: Date().timeIntervalSince1970 * 1000
                ),
            ])
        ))

        try await adapter.runtime.start()
        defer { Task { await adapter.runtime.shutdown() } }
        let status = await adapter.runtime.status()
        #expect(status.connectedCount == 0)
        #expect(status.disabledCount == 1)
        #expect(status.servers.first(where: { $0.name == "lazy" })?.status == .cached)
        #expect(status.servers.first(where: { $0.name == "disabled" })?.status == .disabled)
    }
}
