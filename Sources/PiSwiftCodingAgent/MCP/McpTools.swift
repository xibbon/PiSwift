import Foundation
import PiSwiftAI
import PiSwiftAgent
import PiSwiftMCP

@available(*, deprecated, renamed: "PiSwiftMCP.MCP_OUTPUT_MAX_BYTES")
public let MCP_OUTPUT_MAX_BYTES = PiSwiftMCP.MCP_OUTPUT_MAX_BYTES

public func mcpToolExposure(_ exposure: McpExposure) -> ToolExposure {
    exposure == .codemode ? .deferred : ToolExposure(rawValue: exposure.rawValue) ?? .hidden
}

@available(*, deprecated, renamed: "PiSwiftMCP.createMcpToolName")
public func createMcpToolName(server: String, tool: String, isTaken: (String) -> Bool = { _ in false }) -> String {
    PiSwiftMCP.createMcpToolName(server: server, tool: tool, isTaken: isTaken)
}

@available(*, deprecated, renamed: "PiSwiftMCP.normalizeMcpInputSchema")
public func normalizeMcpInputSchema(_ schema: [String: Any]) -> [String: Any] {
    PiSwiftMCP.normalizeMcpInputSchema(schema)
}

public struct McpToolDetails: Sendable {
    public var server: String
    public var tool: String
    public var fullOutputPath: String?

    public init(server: String, tool: String, fullOutputPath: String? = nil) {
        self.server = server; self.tool = tool; self.fullOutputPath = fullOutputPath
    }

    public var value: AnyCodable {
        var fields: [String: Any] = ["server": server, "tool": tool]
        if let fullOutputPath { fields["fullOutputPath"] = fullOutputPath }
        return AnyCodable(fields)
    }
}

@available(*, deprecated, renamed: "PiSwiftMCP.McpOutputSaver")
public typealias McpOutputSaver = PiSwiftMCP.McpOutputSaver

public func saveMcpOutput(_ data: Data, extension fileExtension: String) async throws -> URL {
    let path = try writeOutputFile(prefix: "pi-mcp", extension: fileExtension, data: data)
    return URL(fileURLWithPath: path)
}

@available(*, deprecated, renamed: "PiSwiftMCP.limitMcpContent")
public func limitMcpContent(_ content: [ContentBlock], saveOutput: @escaping McpOutputSaver = saveMcpOutput) async -> (content: [ContentBlock], fullOutputPath: String?) {
    await PiSwiftMCP.limitMcpContent(content, saveOutput: saveOutput)
}

private let mcpSchemaDataKeywords: Set<String> = ["const", "enum", "default", "examples"]
private let mcpSchemaMapKeywords: Set<String> = ["properties", "patternProperties", "dependentSchemas", "dependencies", "$defs", "definitions"]

private func relocateMcpSchema(_ schema: Any, pointer: String) -> Any {
    if let values = schema as? [Any] { return values.map { relocateMcpSchema($0, pointer: pointer) } }
    guard let fields = schema as? [String: Any] else { return schema }
    return fields.reduce(into: [String: Any]()) { relocated, field in
        let (key, value) = field
        if key == "$ref", let reference = value as? String,
           reference == "#" || reference.hasPrefix("#/") {
            relocated[key] = pointer + reference.dropFirst()
        } else if mcpSchemaDataKeywords.contains(key) {
            relocated[key] = value
        } else if mcpSchemaMapKeywords.contains(key), let schemas = value as? [String: Any] {
            relocated[key] = schemas.mapValues { relocateMcpSchema($0, pointer: pointer) }
        } else {
            relocated[key] = relocateMcpSchema(value, pointer: pointer)
        }
    }
}

public func mcpResultSchema(_ structuredSchema: AnyCodable?) -> [String: AnyCodable] {
    let block: [String: Any] = [
        "type": "object",
        "properties": [
            "type": ["enum": ["text", "image", "audio", "resource_link", "resource"]],
            "text": ["type": "string"], "data": ["type": "string"], "mimeType": ["type": "string"],
        ],
        "required": ["type"], "additionalProperties": true,
    ]
    let properties: [String: Any] = [
        "content": ["type": "array", "items": block],
        "structuredContent": structuredSchema.map {
            relocateMcpSchema($0.value, pointer: "#/properties/structuredContent")
        } ?? [String: Any](),
        "isError": ["type": "boolean"],
    ]
    return ["type": AnyCodable("object"), "properties": AnyCodable(properties),
            "required": AnyCodable(["content"]), "additionalProperties": AnyCodable(true)]
}

private func mcpExtension(_ uri: String) -> String {
    let path = URL(string: uri)?.path ?? uri
    let ext = URL(fileURLWithPath: path).pathExtension
    let asciiAlphanumeric = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    return ext.isEmpty || ext.count > 8 || ext.unicodeScalars.contains(where: { !asciiAlphanumeric.contains($0) })
        ? ".bin" : ".\(ext)"
}

private func mcpTextMime(_ value: String?) -> Bool {
    guard let value else { return false }
    let mime = value.split(separator: ";", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
    return mime.hasPrefix("text/") || mime == "application/json" || mime.hasSuffix("+json") || mime.hasSuffix("+xml")
}

public func mcpModelContent(server: String, blocks: [McpContent], readableResources: Bool = false,
                            saveOutput: McpOutputSaver = saveMcpOutput) async -> [ContentBlock] {
    var converted: [ContentBlock] = []
    for block in blocks {
        if block.type == "resource_link" {
            let details = [block.mimeType, block.size.map(formatSize)].compactMap { $0 }
            let detail = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
            let description = block.description.map { ": \($0)" } ?? ""
            let read = readableResources ? ". Read it with \(READ_MCP_RESOURCE_TOOL) (server \"\(server)\")" : ""
            converted.append(.text(TextContent(text: "[Resource \(block.uri ?? "") \"\(block.title ?? block.name ?? "")\"\(detail)\(description)\(read)]")))
        } else if block.type == "resource", let resource = block.resource, let blob = resource.blob,
                  !(resource.mimeType?.hasPrefix("image/") ?? false), let data = Data(base64Encoded: blob) {
            if mcpTextMime(resource.mimeType) {
                converted.append(.text(TextContent(text: String(decoding: data, as: UTF8.self))))
            } else {
                let kind = "\(resource.mimeType ?? "unknown type"), \(formatSize(data.count))"
                let message: String
                do {
                    let url = try await saveOutput(data, mcpExtension(resource.uri))
                    message = "[Binary resource \(resource.uri) (\(kind)) saved to \(url.path)]"
                } catch {
                    message = "[Binary resource \(resource.uri) (\(kind)) could not be saved: \(error.localizedDescription)]"
                }
                converted.append(.text(TextContent(text: message)))
            }
        } else {
            converted += toLlmContent(McpToolResult(content: [block]))
        }
    }
    return converted
}

public func convertMcpResult(server: String, tool: String, result: McpToolResult,
                             readableResources: Bool = false, saveOutput: @escaping PiSwiftMCP.McpOutputSaver = saveMcpOutput) async -> AgentToolResult {
    var converted = result.content.isEmpty ? toLlmContent(result) : await mcpModelContent(server: server, blocks: result.content,
                                                                                           readableResources: readableResources, saveOutput: saveOutput)
    if result.isError && !converted.contains(where: { if case .text(let text) = $0 { return !text.text.isEmpty }; return false }) {
        converted.append(.text(TextContent(text: "MCP tool \(server)/\(tool) returned an error")))
    }
    let limited = await limitMcpContent(converted, saveOutput: saveOutput)
    var scriptResult: [String: Any] = result.rawResult?.value as? [String: Any] ?? ["content": result.content.compactMap { value -> Any? in
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }]
    scriptResult.removeValue(forKey: "_meta")
    if let structuredContent = result.structuredContent { scriptResult["structuredContent"] = structuredContent.value }
    if result.isError { scriptResult["isError"] = true }
    return AgentToolResult(content: limited.content,
        details: McpToolDetails(server: server, tool: tool, fullOutputPath: limited.fullOutputPath).value,
        structuredContent: AnyCodable(scriptResult), isError: result.isError ? true : nil)
}

public func createMcpToolDefinition(server: String, tool: McpTool, name: String, exposure: McpExposure,
                                    namespace: ToolNamespace, timeoutMs: Int,
                                    getClient: @escaping @Sendable () async throws -> McpServerConnection,
                                    readableResources: @escaping @Sendable () async -> Bool = { false }) -> CustomTool {
    let title = tool.title ?? tool.annotations?.title
    let label = "\(server)/\(tool.name)"
    let parameters = PiSwiftMCP.normalizeMcpInputSchema(tool.inputSchema?.value as? [String: Any] ?? [:])
    let hints = tool.annotations
    let annotations: ToolAnnotations? = hints.flatMap { value in
        guard value.readOnlyHint != nil || value.destructiveHint != nil ||
                value.idempotentHint != nil || value.openWorldHint != nil else { return nil }
        return ToolAnnotations(readOnlyHint: value.readOnlyHint, destructiveHint: value.destructiveHint,
            idempotentHint: value.idempotentHint, openWorldHint: value.openWorldHint)
    }
    return CustomTool(name: name, label: label,
        description: tool.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? tool.description! : (title ?? "MCP tool \(tool.name) from server \(server)"),
        parameters: parameters.mapValues(AnyCodable.init),
        execute: { _, params, onUpdate, _, signal in
            let client = try await getClient()
            let result = try await client.callTool(name: tool.name, arguments: params, signal: signal,
                                                   timeoutMs: timeoutMs, onProgress: { progress in
                let total = progress.total.map { "/\($0)" } ?? ""
                let message = progress.message ?? "Progress \(progress.progress)\(total)"
                onUpdate?(AgentToolResult(content: [.text(TextContent(text: message))],
                    details: McpToolDetails(server: server, tool: tool.name).value))
            })
            return await convertMcpResult(server: server, tool: tool.name, result: result,
                                          readableResources: await readableResources())
        },
        outputSchema: mcpResultSchema(tool.outputSchema), exposure: mcpToolExposure(exposure), namespace: namespace,
        annotations: annotations, defaultActive: exposure == .direct)
}
