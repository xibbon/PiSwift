import Foundation
import PiSwiftAI
import PiSwiftAgent
import PiSwiftMCP

public let LIST_MCP_RESOURCES_TOOL = "list_mcp_resources"
public let LIST_MCP_RESOURCE_TEMPLATES_TOOL = "list_mcp_resource_templates"

/// MCP App resources require a host that renders their UI.
public func isMcpAppResource(uri: String, mimeType: String?) -> Bool {
    if uri.hasPrefix("ui://") { return true }
    guard let mimeType else { return false }
    return mimeType.range(of: #";\s*profile\s*=\s*"?mcp-app"?"#, options: .regularExpression.union(.caseInsensitive)) != nil
}

public enum McpResourceToolError: Error, LocalizedError, Sendable {
    case invalidArgument(String)
    case noResources(server: String, available: [String])

    public var errorDescription: String? {
        switch self {
        case .invalidArgument(let message): message
        case .noResources(let name, let available):
            "MCP server \"\(name)\" has no resources" +
                (available.isEmpty ? "" : ". Servers with resources: \(available.joined(separator: ", "))")
        }
    }
}

private func resourceStringArgument(_ params: [String: AnyCodable], _ key: String) throws -> String? {
    guard let value = params[key], !(value.value is NSNull) else { return nil }
    guard let string = value.value as? String else { throw McpResourceToolError.invalidArgument("\(key) must be a string") }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func resourceObject<T: Encodable>(_ value: T, server: String) -> [String: Any] {
    guard let data = try? JSONEncoder().encode(value),
          var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return ["server": server]
    }
    object.removeValue(forKey: "_meta")
    object.removeValue(forKey: "icons")
    object["server"] = server
    return object
}

private func resourceSchema(_ fields: [String: Any], required: [String]) -> [String: AnyCodable] {
    ["type": AnyCodable("object"), "properties": AnyCodable(fields), "required": AnyCodable(required)]
}

private let resourceListParameters: [String: AnyCodable] = [
    "type": AnyCodable("object"),
    "properties": AnyCodable([
        "server": ["type": "string", "description": "MCP server name. Omit to list every server with resources."],
        "cursor": ["type": "string", "description": "Opaque cursor from a previous call with the same server; omit for the first page."]
    ]),
    "additionalProperties": AnyCodable(false)
]

private let resourceReadParameters: [String: AnyCodable] = [
    "type": AnyCodable("object"),
    "properties": AnyCodable([
        "server": ["type": "string", "description": "MCP server name exactly as configured. Must match the 'server' field returned by list_mcp_resources."],
        "uri": ["type": "string", "description": "Resource URI to read. Must be one of the URIs returned by list_mcp_resources."]
    ]),
    "required": AnyCodable(["server", "uri"]),
    "additionalProperties": AnyCodable(false)
]

private var resourceErrorsSchema: [String: Any] { [
    "type": "array", "description": "Servers that could not be listed",
    "items": ["type": "object", "properties": ["server": ["type": "string"], "error": ["type": "string"]],
              "required": ["server", "error"]]
] }

private let resourcesOutputSchema = resourceSchema([
    "server": ["type": "string"],
    "resources": ["type": "array", "items": ["type": "object", "properties": [
        "server": ["type": "string"], "uri": ["type": "string"], "name": ["type": "string"],
        "title": ["type": "string"], "description": ["type": "string"], "mimeType": ["type": "string"],
        "size": ["type": "number"]], "required": ["server", "uri", "name"]]],
    "nextCursor": ["type": "string"], "errors": resourceErrorsSchema
], required: ["resources"])

private let templatesOutputSchema = resourceSchema([
    "server": ["type": "string"],
    "resourceTemplates": ["type": "array", "items": ["type": "object", "properties": [
        "server": ["type": "string"], "uriTemplate": ["type": "string", "description": "RFC 6570 URI template"],
        "name": ["type": "string"], "title": ["type": "string"],
        "description": ["type": "string"], "mimeType": ["type": "string"]],
        "required": ["server", "uriTemplate", "name"]]],
    "nextCursor": ["type": "string"], "errors": resourceErrorsSchema
], required: ["resourceTemplates"])

private let readOutputSchema = resourceSchema([
    "server": ["type": "string"], "uri": ["type": "string"],
    "contents": ["type": "array", "items": ["anyOf": [
        ["type": "object", "properties": ["uri": ["type": "string"], "mimeType": ["type": "string"],
                                           "text": ["type": "string"]], "required": ["uri", "text"]],
        ["type": "object", "properties": ["uri": ["type": "string"], "mimeType": ["type": "string"],
                                           "blob": ["type": "string", "description": "base64"]], "required": ["uri", "blob"]]
    ]]]
], required: ["server", "uri", "contents"])

private func resourceJsonResult(tool: String, server: String?, payload: [String: Any]) async -> AgentToolResult {
    let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .fragmentsAllowed])) ?? Data("{}".utf8)
    let text = String(decoding: data, as: UTF8.self)
    let limited = await limitMcpContent([.text(TextContent(text: text))])
    return AgentToolResult(content: limited.content,
        details: McpToolDetails(server: server ?? "", tool: tool, fullOutputPath: limited.fullOutputPath).value,
        structuredContent: AnyCodable(payload))
}

private func findResourceServer(_ name: String, in servers: [McpServerConnection]) throws -> McpServerConnection {
    if let server = servers.first(where: { $0.entry.name == name }) { return server }
    throw McpResourceToolError.noResources(server: name, available: servers.map { $0.entry.name })
}

private func listResourcePayload<T: Encodable & Sendable>(
    params: [String: AnyCodable], key: String, servers: [McpServerConnection],
    page: @escaping @Sendable (McpServerConnection, String?) async throws -> ([T], String?),
    all: @escaping @Sendable (McpServerConnection) async throws -> [T],
    visible: @escaping @Sendable (T) -> Bool
) async throws -> [String: Any] {
    let serverName = try resourceStringArgument(params, "server")
    let cursor = try resourceStringArgument(params, "cursor")
    if let serverName {
        let server = try findResourceServer(serverName, in: servers)
        let (items, nextCursor) = try await page(server, cursor)
        var payload: [String: Any] = ["server": serverName, key: items.filter(visible).map { resourceObject($0, server: serverName) }]
        if let nextCursor { payload["nextCursor"] = nextCursor }
        return payload
    }
    if cursor != nil { throw McpResourceToolError.invalidArgument("cursor can only be used when a server is specified") }
    let sorted = servers.sorted { $0.entry.name < $1.entry.name }
    var items: [[String: Any]] = []
    var errors: [[String: String]] = []
    await withTaskGroup(of: (Int, Result<[T], any Error>).self) { group in
        for (index, server) in sorted.enumerated() {
            group.addTask {
                do { return (index, .success(try await all(server))) }
                catch { return (index, .failure(error)) }
            }
        }
        var results: [Int: Result<[T], any Error>] = [:]
        for await (index, result) in group { results[index] = result }
        for (index, server) in sorted.enumerated() {
            switch results[index] {
            case .success(let listed): items += listed.filter(visible).map { resourceObject($0, server: server.entry.name) }
            case .failure(let error): errors.append(["server": server.entry.name, "error": error.localizedDescription])
            case nil: break
            }
        }
    }
    var payload: [String: Any] = [key: items]
    if !errors.isEmpty { payload["errors"] = errors }
    return payload
}

/// Resource tools use the current connected server set at call time.
public func createMcpResourceToolDefinitions(
    exposure: McpExposure,
    servers: @escaping @Sendable () async -> [McpServerConnection]
) -> [CustomTool] {
    let readOnly = ToolAnnotations(readOnlyHint: true)
    let listResources = CustomTool(name: LIST_MCP_RESOURCES_TOOL, label: LIST_MCP_RESOURCES_TOOL,
        description: "Lists resources provided by MCP servers. Resources allow servers to share data that provides context to language models, such as files, database schemas, or application-specific information. Prefer resources over web search when possible.",
        parameters: resourceListParameters,
        execute: { _, params, _, _, _ in
            let current = await servers()
            let payload = try await listResourcePayload(params: params, key: "resources", servers: current,
                page: { server, cursor in let value = try await server.resourcesPage(cursor: cursor); return (value.resources, value.nextCursor) },
                all: { try await $0.allResources() },
                visible: { !isMcpAppResource(uri: $0.uri, mimeType: $0.mimeType) })
            return await resourceJsonResult(tool: LIST_MCP_RESOURCES_TOOL,
                server: try resourceStringArgument(params, "server"), payload: payload)
        }, outputSchema: resourcesOutputSchema, exposure: mcpToolExposure(exposure), annotations: readOnly,
        defaultActive: exposure == .direct)

    let listTemplates = CustomTool(name: LIST_MCP_RESOURCE_TEMPLATES_TOOL, label: LIST_MCP_RESOURCE_TEMPLATES_TOOL,
        description: "Lists resource templates provided by MCP servers. Parameterized resource templates allow servers to share data that takes parameters and provides context to language models, such as files, database schemas, or application-specific information. Prefer resource templates over web search when possible.",
        parameters: resourceListParameters,
        execute: { _, params, _, _, _ in
            let current = await servers()
            let payload = try await listResourcePayload(params: params, key: "resourceTemplates", servers: current,
                page: { server, cursor in let value = try await server.resourceTemplatesPage(cursor: cursor); return (value.resourceTemplates, value.nextCursor) },
                all: { try await $0.allResourceTemplates() },
                visible: { !isMcpAppResource(uri: $0.uriTemplate, mimeType: $0.mimeType) })
            return await resourceJsonResult(tool: LIST_MCP_RESOURCE_TEMPLATES_TOOL,
                server: try resourceStringArgument(params, "server"), payload: payload)
        }, outputSchema: templatesOutputSchema, exposure: mcpToolExposure(exposure), annotations: readOnly,
        defaultActive: exposure == .direct)

    let readResource = CustomTool(name: READ_MCP_RESOURCE_TOOL, label: READ_MCP_RESOURCE_TOOL,
        description: "Read a specific resource from an MCP server given the server name and resource URI.",
        parameters: resourceReadParameters,
        execute: { _, params, _, _, signal in
            guard let serverName = try resourceStringArgument(params, "server") else {
                throw McpResourceToolError.invalidArgument("server must be provided")
            }
            guard let uri = try resourceStringArgument(params, "uri") else {
                throw McpResourceToolError.invalidArgument("uri must be provided")
            }
            let server = try findResourceServer(serverName, in: await servers())
            let contents = try await server.readResource(uri, signal: signal)
            var blocks: [McpContent] = []
            for item in contents {
                if contents.count > 1 { blocks.append(McpContent(type: "text", text: "\(item.uri):")) }
                blocks.append(McpContent(type: "resource", resource: item))
            }
            let converted = await mcpModelContent(server: serverName, blocks: blocks)
            let limited = await limitMcpContent(converted.isEmpty ? [.text(TextContent(text: "Resource \(uri) is empty."))] : converted)
            var values: [[String: Any]] = []
            for item in contents {
                var object = resourceObject(item, server: serverName)
                object.removeValue(forKey: "server")
                values.append(object)
            }
            return AgentToolResult(content: limited.content,
                details: McpToolDetails(server: serverName, tool: READ_MCP_RESOURCE_TOOL,
                                        fullOutputPath: limited.fullOutputPath).value,
                structuredContent: AnyCodable(["server": serverName, "uri": uri, "contents": values] as [String: Any]))
        }, outputSchema: readOutputSchema, exposure: mcpToolExposure(exposure), annotations: readOnly,
        defaultActive: exposure == .direct)
    return [listResources, listTemplates, readResource]
}
