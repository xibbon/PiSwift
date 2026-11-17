import Foundation

/// Server tools end a reply with `pause_turn` when their loop runs long, and sending the reply
/// back lets the model continue it. Each turn requests at most this many continuations.
let anthropicMaximumContinuations = 8

/// Streams a Messages reply, continuing paused turns so callers receive one complete message.
public func streamAnthropic(
    model: Model,
    context: TranscriptContext,
    options: AnthropicOptions
) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()
    Task {
        var reply: AssistantMessage?
        for continuation in 0...anthropicMaximumContinuations {
            let messages = context.messages + (reply.map { [.assistant($0)] } ?? [])
            let part = streamAnthropicResponse(model: model, context: TranscriptContext(messages: messages),
                options: options, keepsContent: continuation > 0)
            for await event in part {
                if let reply {
                    if let event = event.continuing(reply) { stream.push(event) }
                } else if case .done = event {
                    continue
                } else {
                    stream.push(event)
                }
            }
            let message = await part.result()
            let merged = reply.map { $0.continued(by: message) } ?? message
            guard message.stopReason != .error, message.stopReason != .aborted else { break }
            // A paused part without blocks adds no message to the next request, which would then
            // repeat this one. A cancelled signal makes the next request report the abort.
            guard message.rawStopReason == "pause_turn", continuation < anthropicMaximumContinuations,
                  (message.providerContent?.value as? [Any])?.isEmpty == false else {
                stream.push(.done(reason: merged.stopReason, message: merged))
                break
            }
            reply = merged
        }
        stream.end()
    }
    return stream
}

extension AssistantMessage {
    /// This paused reply followed by its continuation. Token counts are the continuation's, since
    /// its request already holds this reply; the cost covers both requests.
    /// A partial message has no wire blocks of its own, so `isPartial` keeps this reply's blocks
    /// as they are. This avoids a copy of all search results for each stream event.
    func continued(by next: AssistantMessage, isPartial: Bool = false) -> AssistantMessage {
        var merged = next
        merged.content = content + next.content
        if isPartial {
            merged.providerContent = providerContent
        } else {
            let blocks = (providerContent?.value as? [[String: Any]] ?? [])
                + (next.providerContent?.value as? [[String: Any]] ?? [])
            merged.providerContent = blocks.isEmpty ? nil : AnyCodable(blocks)
        }
        merged.timestamp = timestamp
        merged.durationMs = nil
        merged.diagnostics = (diagnostics ?? []) + [AssistantMessageDiagnostic(type: "anthropic_pause_turn",
            details: ["responseId": AnyCodable(responseId ?? "")])] + (next.diagnostics ?? [])
        merged.usage.cost = UsageCost(input: usage.cost.input + next.usage.cost.input,
            output: usage.cost.output + next.usage.cost.output,
            cacheRead: usage.cost.cacheRead + next.usage.cost.cacheRead,
            cacheWrite: usage.cost.cacheWrite + next.usage.cost.cacheWrite,
            total: usage.cost.total + next.usage.cost.total,
            totalFromProvider: next.usage.cost.totalFromProvider)
        return merged
    }
}

extension AssistantMessageEvent {
    /// The continuation's event, indexed and reported as part of the paused reply.
    func continuing(_ reply: AssistantMessage) -> AssistantMessageEvent? {
        let offset = reply.content.count
        switch self {
        case .start, .done:
            return nil
        case .textStart(let index, let partial):
            return .textStart(contentIndex: offset + index, partial: reply.continued(by: partial, isPartial: true))
        case .textDelta(let index, let delta, let partial):
            return .textDelta(contentIndex: offset + index, delta: delta, partial: reply.continued(by: partial, isPartial: true))
        case .textEnd(let index, let content, let partial):
            return .textEnd(contentIndex: offset + index, content: content, partial: reply.continued(by: partial, isPartial: true))
        case .thinkingStart(let index, let partial):
            return .thinkingStart(contentIndex: offset + index, partial: reply.continued(by: partial, isPartial: true))
        case .thinkingDelta(let index, let delta, let partial):
            return .thinkingDelta(contentIndex: offset + index, delta: delta, partial: reply.continued(by: partial, isPartial: true))
        case .thinkingEnd(let index, let content, let partial):
            return .thinkingEnd(contentIndex: offset + index, content: content, partial: reply.continued(by: partial, isPartial: true))
        case .toolCallStart(let index, let partial):
            return .toolCallStart(contentIndex: offset + index, partial: reply.continued(by: partial, isPartial: true))
        case .toolCallDelta(let index, let delta, let partial):
            return .toolCallDelta(contentIndex: offset + index, delta: delta, partial: reply.continued(by: partial, isPartial: true))
        case .toolCallEnd(let index, let toolCall, let partial):
            return .toolCallEnd(contentIndex: offset + index, toolCall: toolCall, partial: reply.continued(by: partial, isPartial: true))
        case .error(let reason, let message):
            return .error(reason: reason, error: reply.continued(by: message))
        }
    }
}
