import Foundation

/// Error images follow all tool results in the same user message on Claude APIs.
struct SplitErrorToolResult: Sendable {
    let content: [ContentBlock]
    let caption: String
    let images: [ImageContent]
}

func splitErrorToolResultImages(_ message: ToolResultMessage) -> SplitErrorToolResult? {
    guard message.isError else { return nil }
    let images = message.content.compactMap { block -> ImageContent? in
        if case .image(let image) = block { return image }
        return nil
    }
    guard !images.isEmpty else { return nil }
    let placeholder = "(image attached after the tool results)"
    var content: [ContentBlock] = []
    var previousWasPlaceholder = false
    for block in message.content {
        if case .image = block {
            if !previousWasPlaceholder { content.append(.text(TextContent(text: placeholder))) }
            previousWasPlaceholder = true
        } else {
            content.append(block)
            if case .text(let text) = block { previousWasPlaceholder = text.text == placeholder }
            else { previousWasPlaceholder = false }
        }
    }
    return SplitErrorToolResult(content: content,
        caption: "Images from the error result of tool call \(message.toolCallId) (\(message.toolName)):", images: images)
}

public func transformMessages(
    _ messages: [Message],
    model: Model,
    normalizeToolCallId: (@Sendable (_ id: String, _ model: Model, _ source: AssistantMessage) -> String)? = nil
) -> [Message] {
    var toolCallIdMap: [String: String] = [:]

    let transformed = messages.map { msg -> Message in
        switch msg {
        case .system, .user:
            return msg
        case .toolResult(var toolResult):
            if let normalized = toolCallIdMap[toolResult.toolCallId], normalized != toolResult.toolCallId {
                toolResult.toolCallId = normalized
                return .toolResult(toolResult)
            }
            return msg
        case .assistant(var assistant):
            let isSameModel = assistant.provider == model.provider && assistant.api == model.api && assistant.model == model.id

            let transformedContent: [ContentBlock] = assistant.content.compactMap { block in
                switch block {
                case .thinking(let thinking):
                    guard isSameModel else { return nil }
                    if thinking.redacted == true || !(thinking.thinkingSignature ?? "").isEmpty {
                        return .thinking(thinking)
                    }
                    guard !trimJavaScriptWhitespace(thinking.thinking).isEmpty else { return nil }
                    return .thinking(thinking)
                case .text(let text):
                    if isSameModel {
                        return .text(text)
                    }
                    return .text(TextContent(text: text.text))
                case .toolCall(var toolCall):
                    if !isSameModel {
                        toolCall.thoughtSignature = nil
                        if let normalizeToolCallId {
                            let normalized = normalizeToolCallId(toolCall.id, model, assistant)
                            if normalized != toolCall.id {
                                toolCallIdMap[toolCall.id] = normalized
                                toolCall.id = normalized
                            }
                        }
                    }
                    return .toolCall(toolCall)
                default:
                    return block
                }
            }

            assistant.content = transformedContent
            return .assistant(assistant)
        }
    }

    var result: [Message] = []
    var pendingToolCalls: [ToolCall] = []
    var existingToolResultIds = Set<String>()
    var heldSystemMessages: [Message] = []

    func insertSyntheticToolResults() {
        guard !pendingToolCalls.isEmpty || !heldSystemMessages.isEmpty else { return }
        for call in pendingToolCalls where !existingToolResultIds.contains(call.id) {
            let synthetic = ToolResultMessage(
                toolCallId: call.id,
                toolName: call.name,
                content: [.text(TextContent(text: "No result provided"))],
                isError: true,
                timestamp: Int64(Date().timeIntervalSince1970 * 1000)
            )
            result.append(.toolResult(synthetic))
        }
        result.append(contentsOf: heldSystemMessages)
        heldSystemMessages = []
        pendingToolCalls = []
        existingToolResultIds = Set<String>()
    }

    for msg in transformed {
        switch msg {
        case .system:
            if pendingToolCalls.isEmpty { result.append(msg) }
            else { heldSystemMessages.append(msg) }
        case .assistant(let assistant):
            if !pendingToolCalls.isEmpty {
                insertSyntheticToolResults()
            }

            switch assistant.stopReason {
            case .pending, .error, .aborted, .deferred:
                continue
            case .stop, .length, .toolUse:
                break
            }

            let toolCalls = assistant.content.compactMap { block -> ToolCall? in
                if case .toolCall(let toolCall) = block {
                    return toolCall
                }
                return nil
            }
            if !toolCalls.isEmpty {
                pendingToolCalls = toolCalls
                existingToolResultIds = Set<String>()
            }
            result.append(msg)

        case .toolResult(let toolResult):
            existingToolResultIds.insert(toolResult.toolCallId)
            result.append(msg)

        case .user:
            if !pendingToolCalls.isEmpty {
                insertSyntheticToolResults()
            }
            result.append(msg)
        }
    }

    // v0.69.0: synthesize trailing tool results when the transcript ends with unresolved
    // assistant tool calls (e.g., direct low-level history replay where the user terminated
    // mid-batch). Providers reject transcripts that end on unresolved tool_use blocks.
    if !pendingToolCalls.isEmpty || !heldSystemMessages.isEmpty {
        insertSyntheticToolResults()
    }

    return result
}
