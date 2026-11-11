// Re-export everything extensions need.
// Extension authors write `import PiExtensionSDK` and get all the types they're
// likely to touch in one import — events and APIs from PiSwiftCodingAgent, AnyCodable
// + content types from PiSwiftAI, and AgentToolResult / AgentTool plumbing from
// PiSwiftAgent (used by `pi.registerTool(_:)`).
@_exported import PiSwiftAI
@_exported import PiSwiftAgent
@_exported import PiSwiftCodingAgent
@_exported import PiSwiftSchema
import PiSwiftMCP

/// Current MCP helpers, grouped to avoid the names forwarded by PiSwiftCodingAgent.
public enum ExtensionMCP {
    @_alwaysEmitIntoClient
    public static func createMcpToolName(
        server: String, tool: String, isTaken: (String) -> Bool = { _ in false }
    ) -> String {
        PiSwiftMCP.createMcpToolName(server: server, tool: tool, isTaken: isTaken)
    }

    @_alwaysEmitIntoClient
    public static func mcpNamespace(_ server: String) -> String {
        PiSwiftMCP.mcpNamespace(server)
    }

    @_alwaysEmitIntoClient
    public static func normalizeMcpInputSchema(_ schema: [String: Any]) -> [String: Any] {
        PiSwiftMCP.normalizeMcpInputSchema(schema)
    }

    @_alwaysEmitIntoClient
    public static func limitMcpContent(
        _ content: [ContentBlock], saveOutput: PiSwiftMCP.McpOutputSaver? = nil
    ) async -> (content: [ContentBlock], fullOutputPath: String?) {
        await PiSwiftMCP.limitMcpContent(content, saveOutput: saveOutput)
    }
}

/// A string enum tool schema compatible with providers that require `type` and `enum`.
/// This is the Swift equivalent of the extension view's TypeBox `StringEnum` helper.
@_alwaysEmitIntoClient
public func StringEnum(
    _ values: [String], description: String? = nil, defaultValue: String? = nil
) -> [String: AnyCodable] {
    var schema: [String: AnyCodable] = [
        "type": AnyCodable("string"),
        "enum": AnyCodable(values),
    ]
    if let description, !description.isEmpty { schema["description"] = AnyCodable(description) }
    if let defaultValue, !defaultValue.isEmpty { schema["default"] = AnyCodable(defaultValue) }
    return schema
}
