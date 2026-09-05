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
    guard case .assistant(let assistant) = message else { return }
    for block in assistant.content {
        if case .toolCall(let toolCall) = block {
            if let path = toolCall.arguments["path"]?.value as? String {
                switch toolCall.name {
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
        }
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
            var thinkingParts: [String] = []
            var toolCalls: [String] = []
            for block in assistant.content {
                switch block {
                case .text(let text):
                    textParts.append(text.text)
                case .thinking(let thinking):
                    thinkingParts.append(thinking.thinking)
                case .toolCall(let call):
                    let args = call.arguments.map { "\($0.key)=\(String(describing: $0.value.value))" }.joined(separator: ", ")
                    toolCalls.append("\(call.name)(\(args))")
                case .image:
                    break
                }
            }
            if !thinkingParts.isEmpty {
                parts.append("[Assistant thinking]: \(thinkingParts.joined(separator: "\n"))")
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

public let SUMMARIZATION_SYSTEM_PROMPT = """
You are a context summarization assistant. Your task is to read a conversation between a user and an AI assistant, then produce a structured summary following the exact format specified.

Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.
"""
