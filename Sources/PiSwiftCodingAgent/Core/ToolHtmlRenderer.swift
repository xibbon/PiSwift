import PiSwiftAI

/// Render custom tools for HTML export. Return nil to use the template fallback.
/// Implementations must protect any mutable state for concurrent exports.
public protocol ToolHtmlRenderer: Sendable {
    func renderCall(toolCallId: String, name: String, arguments: OrderedJSON) async -> String?
    func renderResult(
        toolCallId: String, name: String, result: [ContentBlock],
        details: AnyCodable?, isError: Bool
    ) async -> (collapsed: String?, expanded: String?)?
}

/// HTML for one tool call. Field names match the export template.
public struct RenderedToolHtml: Sendable, Equatable, Codable {
    public var callHtml: String?
    public var resultHtmlCollapsed: String?
    public var resultHtmlExpanded: String?

    public init(callHtml: String? = nil, resultHtmlCollapsed: String? = nil, resultHtmlExpanded: String? = nil) {
        self.callHtml = callHtml
        self.resultHtmlCollapsed = resultHtmlCollapsed
        self.resultHtmlExpanded = resultHtmlExpanded
    }
}

/// Process all entries in storage order, including entries outside the current branch.
public func preRenderCustomTools(
    entries: [SessionEntry], toolRenderer: any ToolHtmlRenderer
) async throws -> [String: RenderedToolHtml] {
    let templateRenderedTools: Set<String> = ["bash", "read", "write", "edit", "ls"]
    var renderedTools: [String: RenderedToolHtml] = [:]
    for entry in entries {
        guard case .message(let entry) = entry else { continue }
        switch entry.message {
        case .assistant(let message):
            for block in message.content {
                guard case .toolCall(let call) = block, !templateRenderedTools.contains(call.name) else { continue }
                if let html = await toolRenderer.renderCall(
                    toolCallId: call.id, name: call.name,
                    arguments: toolArgumentsToOrderedJSON(call.arguments, argumentsJSON: call.argumentsJSON)
                ), !html.isEmpty {
                    renderedTools[call.id] = RenderedToolHtml(callHtml: html)
                }
            }
        case .toolResult(let message) where !message.toolCallId.isEmpty:
            let existing = renderedTools[message.toolCallId]
            if existing != nil || !templateRenderedTools.contains(message.toolName) {
                if let html = await toolRenderer.renderResult(
                    toolCallId: message.toolCallId, name: message.toolName, result: message.content,
                    details: message.details, isError: message.isError
                ) {
                    renderedTools[message.toolCallId] = RenderedToolHtml(
                        callHtml: existing?.callHtml,
                        resultHtmlCollapsed: html.collapsed, resultHtmlExpanded: html.expanded
                    )
                }
            }
        default: break
        }
    }
    return renderedTools
}
