import PiSwiftAI
import PiSwiftChord

let summarizationSystemPrompt = """
You are a context summarization assistant. Your task is to read a conversation between a user and an AI assistant, then produce a structured summary following the exact format specified.

Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.
"""

private let summarizationPrompt = """
The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work. If the conversation starts with an earlier summary, preserve its information and fold the newer messages into it.

Use this EXACT format:

## Goal
[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]

## Constraints & Preferences
- [Any constraints, preferences, or requirements mentioned by user]
- [Or "(none)" if none were mentioned]

## Progress
### Done
- [x] [Completed tasks/changes]

### In Progress
- [ ] [Current work]

### Blocked
- [Issues preventing progress, if any]

## Key Decisions
- **[Decision]**: [Brief rationale]

## Next Steps
1. [Ordered list of what should happen next]

## Critical Context
- [Any data, examples, or references needed to continue]
- [Or "(none)" if not applicable]

Keep each section concise. Preserve exact file paths, function names, and error messages.
"""

func summaryPrompt(messages: [Message], instructions: String?) -> String {
    let focus = instructions.map { "\n\nAdditional focus: \($0)" } ?? ""
    return "<conversation>\n\(serializeConversation(messages))\n</conversation>\n\n\(summarizationPrompt)\(focus)"
}

/// Read the transcript as text. Do not include system messages.
public func serializeConversation(_ messages: [Message]) -> String {
    var parts: [String] = []
    for message in messages {
        switch message {
        case .user(let user):
            let text: String
            switch user.content {
            case .text(let value): text = value
            case .blocks(let blocks): text = compactionContentText(blocks)
            }
            if !text.isEmpty { parts.append("[User]: \(text)") }
        case .assistant(let assistant):
            let thinking = assistant.content.compactMap { block -> String? in
                if case .thinking(let value) = block { return value.thinking }; return nil
            }
            let text = assistant.content.compactMap { block -> String? in
                if case .text(let value) = block { return value.text }; return nil
            }
            let calls = assistant.content.compactMap { block -> String? in
                guard case .toolCall(let call) = block else { return nil }
                let source = toolArgumentsToOrderedJSON(call.arguments, argumentsJSON: call.argumentsJSON)
                let pairs = compactionJSONValue(source).objectValue ?? JSONObject()
                let arguments = pairs.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                return "\(call.name)(\(arguments))"
            }
            if !thinking.isEmpty { parts.append("[Assistant thinking]: \(thinking.joined(separator: "\n"))") }
            if !text.isEmpty { parts.append("[Assistant]: \(text.joined(separator: "\n"))") }
            if !calls.isEmpty { parts.append("[Assistant tool calls]: \(calls.joined(separator: "; "))") }
        case .toolResult(let result):
            let text = compactionContentText(result.content)
            if !text.isEmpty { parts.append("[Tool result]: \(compactionTruncate(text, maxChars: 2000))") }
        case .system: break
        }
    }
    return parts.joined(separator: "\n\n")
}

private func compactionJSONValue(_ value: OrderedJSON) -> JSONValue {
    switch value {
    case .null: return .null
    case .bool(let value): return .bool(value)
    case .string(let value): return .string(value)
    case .number(let text):
        guard let number = Double(text), number.isFinite else { return .null }
        return .number(number)
    case .array(let values): return .array(values.map(compactionJSONValue))
    case .object(let pairs): return .object(JSONObject(pairs.map { ($0.0, compactionJSONValue($0.1)) }))
    }
}

private func compactionContentText(_ blocks: [ContentBlock]) -> String {
    blocks.compactMap { block -> String? in
        if case .text(let value) = block { return value.text }; return nil
    }.joined(separator: "\n")
}

private func compactionTruncate(_ text: String, maxChars: Int) -> String {
    let count = text.utf16.count
    guard count > maxChars else { return text }
    return "\(String(decoding: text.utf16.prefix(maxChars), as: UTF16.self))\n\n[... \(count - maxChars) more characters truncated]"
}

func compactionSummaryText(_ message: AssistantMessage) -> String? {
    guard message.stopReason == .stop, !message.content.contains(where: {
        if case .toolCall = $0 { return true }; return false
    }) else { return nil }
    let text = compactionContentText(message.content)
    // Match JavaScript String.trim(), including the byte order mark.
    let whitespace: Set<UInt32> = [0x9, 0xA, 0xB, 0xC, 0xD, 0x20, 0xA0, 0x1680,
        0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
        0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF]
    let scalars = text.unicodeScalars.drop(while: { whitespace.contains($0.value) })
        .reversed().drop(while: { whitespace.contains($0.value) }).reversed()
    let trimmed = String(String.UnicodeScalarView(scalars))
    return trimmed.isEmpty ? nil : trimmed
}

func compactionSummaryFailure(_ message: AssistantMessage) -> String {
    if message.stopReason == .error || message.stopReason == .aborted {
        return "Summarization failed: \(message.errorMessage ?? message.stopReason.rawValue)"
    }
    if message.stopReason == .length { return "Summarization hit the token limit; the summary is incomplete" }
    if message.content.contains(where: { if case .toolCall = $0 { return true }; return false }) {
        return "Summarization attempted to call a tool"
    }
    return "Summarization produced no text"
}
