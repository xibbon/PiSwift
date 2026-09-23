import PiSwiftAI
import PiSwiftAgent

/// The full provider diagnostics remain on the assistant message stored in the session.
public struct ThinkingDropNotice: Sendable {
    /// Cumulative number in the current Anthropic response, matching the upstream notice.
    public let count: Int
    /// The transformation records that produced this notice, including paths and reasons.
    public let transformations: [[String: AnyCodable]]
}

public func thinkingDropTransformations(in message: AssistantMessage) -> [[String: AnyCodable]] {
    (message.diagnostics ?? []).filter { $0.type == "anthropic_input_transformations" }.flatMap { diagnostic -> [[String: AnyCodable]] in
        guard let records = diagnostic.details["transformations"]?.value as? [[String: Any]] else { return [] }
        return records.filter { $0["type"] as? String == "thinking_dropped" }.map { record in
            record.mapValues { AnyCodable($0) }
        }
    }
}

/// Suppress cumulative repeats. The UI can call this at message_end, before persistence.
public func newThinkingDropNotice(current: AssistantMessage, previous: AssistantMessage?) -> ThinkingDropNotice? {
    let transformations = thinkingDropTransformations(in: current)
    guard !transformations.isEmpty else { return nil }
    let previousCount = previous.map { thinkingDropTransformations(in: $0).count } ?? 0
    guard transformations.count > previousCount else { return nil }
    return ThinkingDropNotice(count: transformations.count, transformations: transformations)
}

extension SessionManager {
    /// Compare with the last persisted assistant in the current branch.
    public func newThinkingDropNotice(for current: AssistantMessage) -> ThinkingDropNotice? {
        let previous = getBranch().reversed().compactMap { entry -> AssistantMessage? in
            guard case .message(let messageEntry) = entry,
                  case .assistant(let assistant) = messageEntry.message else { return nil }
            return assistant
        }.first
        return PiSwiftCodingAgent.newThinkingDropNotice(current: current, previous: previous)
    }
}
