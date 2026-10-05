import Foundation
import CryptoKit
import PiSwiftAI
import PiSwiftAgent
import PiSwiftMCP

public let MCP_OUTPUT_MAX_BYTES = 20 * 1024

public func mcpToolExposure(_ exposure: McpExposure) -> ToolExposure {
    exposure == .codemode ? .deferred : ToolExposure(rawValue: exposure.rawValue) ?? .hidden
}

/// Names follow upstream's ASCII replacement and eight digit SHA-256 suffix rule.
public func createMcpToolName(server: String, tool: String, isTaken: (String) -> Bool = { _ in false }) -> String {
    let source = "mcp__\(server)__\(tool)"
    // JavaScript's non-Unicode global regex replaces UTF-16 code units. A surrogate
    // pair therefore becomes two underscores, which affects the 64 character cut.
    let name = String(source.utf16.map { unit -> Character in
        if (65...90).contains(unit) || (97...122).contains(unit) || (48...57).contains(unit)
            || unit == 95 {
            return Character(UnicodeScalar(unit)!)
        }
        return "_"
    })
    if name.count <= 64 && !isTaken(name) { return name }
    let digest = SHA256.hash(data: Data("\(server)\u{0}\(tool)".utf8))
    let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    return "\(name.prefix(55))_\(suffix)"
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

public typealias McpOutputSaver = @Sendable (Data, String) async throws -> URL

public func saveMcpOutput(_ data: Data, extension fileExtension: String) async throws -> URL {
    let path = try writeOutputFile(prefix: "pi-mcp", extension: fileExtension, data: data)
    return URL(fileURLWithPath: path)
}

public func limitMcpContent(_ content: [ContentBlock], saveOutput: McpOutputSaver = saveMcpOutput) async -> (content: [ContentBlock], fullOutputPath: String?) {
    let combined = content.compactMap { block -> String? in
        if case .text(let text) = block { return text.text }
        return nil
    }.joined(separator: "\n")
    let cut = truncateMiddle(combined, maxBytes: MCP_OUTPUT_MAX_BYTES)
    guard cut.truncated else { return (content, nil) }
    var path: String?
    let whereText: String
    do {
        let url = try await saveOutput(Data(combined.utf8), ".txt")
        path = url.path
        whereText = "[Full output: \(url.path) (read it with offset/limit)]"
    } catch {
        whereText = "[Could not save the full output: \(error.localizedDescription)]"
    }
    let tokens = (cut.totalBytes + 3) / 4
    let text = "Warning: truncated output (original token count: \(tokens))\nTotal output lines: \(cut.totalLines)\n\n\(cut.content)\n\n\(whereText)"
    return ([.text(TextContent(text: text))] + content.filter { if case .image = $0 { true } else { false } }, path)
}

public func mcpResultSchema(_ structuredSchema: AnyCodable?) -> [String: AnyCodable] {
    var properties: [String: Any] = [
        "content": ["type": "array", "items": ["type": "object"]],
        "isError": ["type": "boolean"], "_meta": ["type": "object"]
    ]
    if let structuredSchema { properties["structuredContent"] = structuredSchema.value }
    return ["type": AnyCodable("object"), "properties": AnyCodable(properties), "required": AnyCodable(["content"])]
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
                             readableResources: Bool = false, saveOutput: McpOutputSaver = saveMcpOutput) async -> AgentToolResult {
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
    var parameters = tool.inputSchema?.value as? [String: Any] ?? [:]
    if parameters["type"] == nil { parameters["type"] = "object" }
    if parameters["properties"] == nil { parameters["properties"] = [String: Any]() }
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
