import Foundation

/// A Responses terminal event can arrive before every tool call item is complete.
/// The agent must not execute a partial call.
func unfinishedResponsesToolCallMessage(
    output: AssistantMessage,
    contentIndices: Set<Int>
) -> String? {
    guard output.stopReason == .toolUse else { return nil }
    for index in contentIndices.sorted() where output.content.indices.contains(index) {
        guard case .toolCall(let call) = output.content[index] else { continue }
        return "OpenAI Responses stream completed with an unfinished tool call: \(call.name) (\(call.id))"
    }
    return nil
}
