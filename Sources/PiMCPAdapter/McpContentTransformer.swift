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
    let blocks = transformMcpContent(result.content)
    guard blocks.isEmpty, let structuredContent = result.structuredContent else {
        return blocks
    }
    if let data = try? JSONSerialization.data(withJSONObject: structuredContent.value, options: [.prettyPrinted]),
       let text = String(data: data, encoding: .utf8) {
        return [.text(TextContent(text: text))]
    }
    return [.text(TextContent(text: String(describing: structuredContent.value)))]
}
