import PiSwiftAI
import PiSwiftAgent

/// A provider report that reasoning was withheld from a request.
public struct ThinkingDropNotice: Sendable {
    public let provider: String
    public let kind: String
    public let count: Int
    public let reasons: [String]
    public let transformations: [[String: AnyCodable]]

    public var text: String {
        let noun: String
        switch kind {
        case "openai_input_transformations": noun = count == 1 ? "reasoning item" : "reasoning items"
        default: noun = count == 1 ? "thinking block" : "thinking blocks"
        }
        let suffix = reasons.isEmpty ? "" : ": " + reasons.joined(separator: ", ")
        return "\(provider) dropped \(count) \(noun)\(suffix) (details in session)"
    }
}

/// The first diagnostic in a response with withheld reasoning, in source order.
public func reasoningDropNotice(in message: AssistantMessage) -> ThinkingDropNotice? {
    for diagnostic in message.diagnostics ?? [] {
        let provider: String
        let droppedType: String
        switch diagnostic.type {
        case "anthropic_input_transformations":
            provider = "Anthropic"; droppedType = "thinking_dropped"
        case "openai_input_transformations":
            provider = "OpenAI"; droppedType = "reasoning"
        default: continue
        }
        guard let raw = diagnostic.details["transformations"]?.value as? [Any] else { continue }
        let transformations = raw.compactMap { $0 as? [String: Any] }
            .filter { $0["type"] as? String == droppedType }
            .map { $0.mapValues { AnyCodable($0) } }
        guard !transformations.isEmpty else { continue }
        var reasons: [String] = []
        for transformation in transformations {
            if let reason = transformation["reason"]?.value as? String, !reasons.contains(reason) {
                reasons.append(reason)
            }
        }
        return ThinkingDropNotice(provider: provider, kind: diagnostic.type,
                                  count: transformations.count, reasons: reasons,
                                  transformations: transformations)
    }
    return nil
}

/// Compatibility API. Use `reasoningDropNotice(in:)` for both providers.
public func thinkingDropTransformations(in message: AssistantMessage) -> [[String: AnyCodable]] {
    reasoningDropNotice(in: message)?.transformations ?? []
}

/// Suppress a cumulative notice when the latest earlier assistant reported the same kind and count.
public func newThinkingDropNotice(current: AssistantMessage, previous: AssistantMessage?) -> ThinkingDropNotice? {
    guard let notice = reasoningDropNotice(in: current) else { return nil }
    if let previousNotice = previous.flatMap(reasoningDropNotice(in:)),
       previousNotice.kind == notice.kind, previousNotice.count >= notice.count { return nil }
    return notice
}

extension SessionManager {
    /// The current message is already persisted when the Swift UI receives `message_end`.
    public func newThinkingDropNotice(for current: AssistantMessage) -> ThinkingDropNotice? {
        var assistants = getBranch().reversed().compactMap { entry -> AssistantMessage? in
            guard case .message(let messageEntry) = entry,
                  case .assistant(let assistant) = messageEntry.message else { return nil }
            return assistant
        }
        if let latest = assistants.first, latest.timestamp == current.timestamp,
           latest.model == current.model, latest.diagnostics == current.diagnostics {
            assistants.removeFirst()
        }
        return PiSwiftCodingAgent.newThinkingDropNotice(current: current, previous: assistants.first)
    }
}
