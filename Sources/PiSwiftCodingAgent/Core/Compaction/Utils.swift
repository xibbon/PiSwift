import Foundation
import PiSwiftAI
import PiSwiftAgent

public struct FileOperations: Sendable {
    public var read: Set<String>
    public var written: Set<String>
    public var edited: Set<String>

    public init(read: Set<String> = [], written: Set<String> = [], edited: Set<String> = []) {
        self.read = read
        self.written = written
        self.edited = edited
    }
}

public func createFileOps() -> FileOperations {
    FileOperations()
}

public func extractFileOpsFromMessage(_ message: AgentMessage, _ fileOps: inout FileOperations) {
    switch message {
    case .toolResult(let result):
        for call in result.nestedCalls?.calls ?? [] {
            addFileOp(call.name, arguments: call.arguments, to: &fileOps)
        }
    case .assistant(let assistant):
        for block in assistant.content {
            if case .toolCall(let call) = block {
                addFileOp(call.name, arguments: call.arguments, to: &fileOps)
            }
        }
    default:
        break
    }
}

private func addFileOp(_ name: String, arguments: [String: AnyCodable]?, to fileOps: inout FileOperations) {
    guard let path = arguments?["path"]?.value as? String, !path.isEmpty else { return }
    switch name {
    case "read":
        fileOps.read.insert(path)
    case "write":
        fileOps.written.insert(path)
    case "edit":
        fileOps.edited.insert(path)
    default:
        break
    }
}

public func computeFileLists(_ fileOps: FileOperations) -> (readFiles: [String], modifiedFiles: [String]) {
    let modified = Set(fileOps.written).union(fileOps.edited)
    let readOnly = fileOps.read.filter { !modified.contains($0) }.sorted()
    let modifiedFiles = Array(modified).sorted()
    return (readOnly, modifiedFiles)
}

public func formatFileOperations(readFiles: [String], modifiedFiles: [String]) -> String {
    var sections: [String] = []
    if !readFiles.isEmpty {
        sections.append("<read-files>\n\(readFiles.joined(separator: "\n"))\n</read-files>")
    }
    if !modifiedFiles.isEmpty {
        sections.append("<modified-files>\n\(modifiedFiles.joined(separator: "\n"))\n</modified-files>")
    }
    if sections.isEmpty { return "" }
    return "\n\n" + sections.joined(separator: "\n\n")
}

public func serializeConversation(_ messages: [Message]) -> String {
    var parts: [String] = []

    for message in messages {
        switch message {
        case .system:
            continue
        case .user(let user):
            switch user.content {
            case .text(let text):
                if !text.isEmpty { parts.append("[User]: \(text)") }
            case .blocks(let blocks):
                let text = blocks.compactMap { block -> String? in
                    if case .text(let t) = block { return t.text }
                    return nil
                }.joined()
                if !text.isEmpty { parts.append("[User]: \(text)") }
            }
        case .assistant(let assistant):
            var textParts: [String] = []
            var toolCalls: [String] = []
            for block in assistant.content {
                switch block {
                case .text(let text):
                    textParts.append(text.text)
                case .toolCall(let call):
                    let arguments = summaryJSONValue(toolArgumentsToOrderedJSON(call.arguments, argumentsJSON: call.argumentsJSON))
                    let args = (arguments.objectEntries ?? []).map {
                        "\($0.0)=\($0.1.serialized(escapeSlashes: false))"
                    }.joined(separator: ", ")
                    toolCalls.append("\(call.name)(\(args))")
                case .thinking, .image:
                    break
                }
            }
            if !textParts.isEmpty {
                parts.append("[Assistant]: \(textParts.joined(separator: "\n"))")
            }
            if !toolCalls.isEmpty {
                parts.append("[Assistant tool calls]: \(toolCalls.joined(separator: "; "))")
            }
        case .toolResult(let result):
            var text = result.content.compactMap { block -> String? in
                if case .text(let t) = block { return t.text }
                return nil
            }.joined()
            if text.count > 10000 {
                text = String(text.prefix(10000)) + "\n[...truncated]"
            }
            if !text.isEmpty {
                parts.append("[Tool result]: \(text)")
            }
        }
    }

    return parts.joined(separator: "\n\n")
}

private func summaryJSONValue(_ value: OrderedJSON) -> OrderedJSON {
    switch value {
    case .number(let text):
        guard let number = Double(text), number.isFinite else { return .null }
        return .number(summaryJSONNumber(number))
    case .array(let values):
        return .array(values.map(summaryJSONValue))
    case .object(let pairs):
        // Object.entries and JSON.stringify put array-index keys before string keys.
        func arrayIndex(_ key: String) -> UInt32? {
            guard let index = UInt32(key), index < UInt32.max, String(index) == key else { return nil }
            return index
        }
        let indices = pairs.filter { arrayIndex($0.0) != nil }.sorted { arrayIndex($0.0)! < arrayIndex($1.0)! }
        let strings = pairs.filter { arrayIndex($0.0) == nil }
        return .object((indices + strings).map { ($0.0, summaryJSONValue($0.1)) })
    default:
        return value
    }
}

private func summaryJSONNumber(_ value: Double) -> String {
    // Use JavaScript's decimal and exponent thresholds, as in PiSwiftChord.JSONValue.
    if value == 0 { return "0" }
    let sign = value < 0 ? "-" : ""
    let parts = String(abs(value)).lowercased().split(separator: "e")
    let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
    let exponent = parts.count == 2 ? Int(parts[1])! : 0
    var digits = Array(mantissa.joined())
    var n = mantissa[0].count + exponent
    while digits.first == "0" { digits.removeFirst(); n -= 1 }
    while digits.last == "0" { digits.removeLast() }
    let k = digits.count
    let text = String(digits)
    if k <= n && n <= 21 { return sign + text + String(repeating: "0", count: n - k) }
    if 0 < n && n <= 21 {
        return sign + String(digits.prefix(n)) + "." + String(digits.dropFirst(n))
    }
    if -6 < n && n <= 0 { return sign + "0." + String(repeating: "0", count: -n) + text }
    let tail = k > 1 ? "." + String(digits.dropFirst()) : ""
    return sign + String(digits[0]) + tail + "e" + (n - 1 >= 0 ? "+" : "-") + String(abs(n - 1))
}

public let SUMMARIZATION_SYSTEM_PROMPT = """
You are a context summarization assistant. Your task is to read a conversation between a user and an AI assistant, then produce a structured summary following the exact format specified.

Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.
"""
