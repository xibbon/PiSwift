import Foundation
import PiSwiftAI

// MARK: - MCP Content → Pi ContentBlock

public func transformMcpContent(_ content: [McpContent]) -> [ContentBlock] {
    content.map { c in
        switch c.type {
        case "text":
            return .text(TextContent(text: c.text ?? ""))

        case "image":
            return .image(ImageContent(data: c.data ?? "", mimeType: c.mimeType ?? "image/png"))

        case "resource":
            let uri = c.resource?.uri ?? c.uri ?? ""
            let resourceText = c.resource?.text ?? c.resource?.blob ?? ""
            return .text(TextContent(text: "[Resource: \(uri)]\n\(resourceText)"))

        case "resource_link":
            let name = c.name ?? ""
            let uri = c.uri ?? ""
            return .text(TextContent(text: "[Resource Link: \(name)]\nURI: \(uri)"))

        case "audio":
            return .text(TextContent(text: "[Audio content: \(c.mimeType ?? "audio/*")]"))

        default:
            // Unknown type: serialize to JSON
            if let data = try? JSONEncoder().encode(c),
               let json = String(data: data, encoding: .utf8) {
                return .text(TextContent(text: json))
            }
            return .text(TextContent(text: "(unknown MCP content type: \(c.type))"))
        }
    }
}

/// Convert an MCP tool result to model content. MCP permits successful calls
/// to return only `structuredContent`; retain that information instead of
/// presenting an empty result to the model.
public func resolveMcpResultContent(_ result: McpToolResult) -> [ContentBlock] {
    let blocks = toLlmContent(result)
    guard blocks.isEmpty, let structuredContent = result.structuredContent else {
        return blocks
    }
    if let data = try? JSONSerialization.data(withJSONObject: structuredContent.value, options: [.prettyPrinted]),
       let text = String(data: data, encoding: .utf8) {
        return [.text(TextContent(text: text))]
    }
    return [.text(TextContent(text: String(describing: structuredContent.value)))]
}

/// Convert MCP result blocks to the text and image content accepted by LLM APIs.
public func toLlmContent(_ result: McpToolResult) -> [ContentBlock] {
    var blocks: [ContentBlock] = result.content.map { content in
        switch content.type {
        case "text":
            return .text(TextContent(text: content.text ?? ""))
        case "image":
            return .image(ImageContent(data: content.data ?? "", mimeType: content.mimeType ?? ""))
        case "audio":
            return .text(TextContent(text: "[audio \(content.mimeType ?? "unknown type") omitted]"))
        case "resource_link":
            return .text(TextContent(text: "\(content.name ?? ""): \(content.uri ?? "")"))
        case "resource":
            guard let resource = content.resource else {
                return .text(TextContent(text: "[unsupported MCP content resource]"))
            }
            if let text = resource.text { return .text(TextContent(text: text)) }
            if let mimeType = resource.mimeType, mimeType.hasPrefix("image/"), let data = resource.blob {
                return .image(ImageContent(data: data, mimeType: mimeType))
            }
            return .text(TextContent(text: "[binary resource \(resource.uri) (\(resource.mimeType ?? "unknown type")) omitted]"))
        default:
            return .text(TextContent(text: "[unsupported MCP content \(content.type)]"))
        }
    }
    if blocks.isEmpty, let structuredContent = result.structuredContent {
        if let data = try? JSONSerialization.data(withJSONObject: structuredContent.value, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            blocks.append(.text(TextContent(text: text)))
        }
    }
    return blocks
}
