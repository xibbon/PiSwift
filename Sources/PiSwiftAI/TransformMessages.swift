import Foundation

public func transformMessages(
    _ messages: [Message],
    model: Model,
    normalizeToolCallId: (@Sendable (_ id: String, _ model: Model, _ source: AssistantMessage) -> String)? = nil
) -> [Message] {
    var toolCallIdMap: [String: String] = [:]

    let transformed = messages.map { msg -> Message in
        switch msg {
        case .user:
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
                    // Redacted thinking must be dropped on cross-model replay for safety
                    if thinking.redacted == true && !isSameModel {
                        return nil
                    }
                    let trimmed = thinking.thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                    if isSameModel {
                        // Preserve empty thinking blocks to maintain reasoning structure
                        // continuity during same-model replay.
                        return .thinking(thinking)
                    }
                    if trimmed.isEmpty {
                        return nil
                    }
                    return .text(TextContent(text: thinking.thinking))
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

    func insertSyntheticToolResults() {
        guard !pendingToolCalls.isEmpty else { return }
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
        pendingToolCalls = []
        existingToolResultIds = Set<String>()
    }

    for msg in transformed {
        switch msg {
        case .assistant(let assistant):
            if !pendingToolCalls.isEmpty {
                insertSyntheticToolResults()
            }

            if assistant.stopReason == .error || assistant.stopReason == .aborted {
                continue
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

    return result
}
