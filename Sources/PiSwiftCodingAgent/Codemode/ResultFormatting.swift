import Foundation
import PiSwiftAI
import PiSwiftAgent

public enum CodemodeNestedCallStatus: String, Sendable, Codable {
    case running, ok, error, cancelled
}

public struct CodemodeNestedCall: Sendable, Codable {
    public var id: String
    public var name: String
    public var args: String { didSet { args = Self.preview(args, limit: 200) } }
    public var status: CodemodeNestedCallStatus
    public var durationMs: Double?
    public var error: String? { didSet { error = error.map { Self.preview($0, limit: 500) } } }
    public var cost: Double?

    public init(id: String, name: String, args: String, status: CodemodeNestedCallStatus,
                durationMs: Double? = nil, error: String? = nil, cost: Double? = nil) {
        self.id = id
        self.name = name
        self.args = CodemodeNestedCall.preview(args, limit: 200)
        self.status = status
        self.durationMs = durationMs
        self.error = error.map { CodemodeNestedCall.preview($0, limit: 500) }
        self.cost = cost
    }

    public static func preview(_ value: String, limit: Int) -> String {
        let utf16 = value as NSString
        return utf16.length > limit ? utf16.substring(to: max(0, limit - 3)) + "..." : value
    }
}

public enum CodemodeFailureKind: String, Sendable {
    case script, timeout, aborted, sandbox
}

public struct CodemodeFailure: Sendable {
    public var kind: CodemodeFailureKind
    public var name: String?
    public var message: String
    public var stack: String?

    public init(kind: CodemodeFailureKind, message: String, name: String? = nil, stack: String? = nil) {
        self.kind = kind
        self.name = name
        self.message = message
        self.stack = stack
    }
}

/// Output from a script, before the result layout is applied.
public enum CodemodeOutputItem: Sendable {
    case text(String, console: Bool = false)
    case image(ImageContent)

    /// Create ordinary text output from an existing text content block.
    public static func text(_ value: TextContent) -> Self { .text(value.text, console: false) }
}

public struct CodemodeExecutionResult: Sendable {
    public var output: [CodemodeOutputItem]
    public var returnedValue: AnyCodable?
    public var failure: CodemodeFailure?

    public init(output: [CodemodeOutputItem], returnedValue: AnyCodable? = nil, failure: CodemodeFailure? = nil) {
        self.output = output
        self.returnedValue = returnedValue
        self.failure = failure
    }

    // Existing internal image tests pass ContentBlock collections.
    init<C: Collection>(output: C, returnedValue: AnyCodable? = nil, failure: CodemodeFailure? = nil)
    where C.Element == ContentBlock {
        self.init(output: output.compactMap { block in
            switch block {
            case .text(let value): return .text(value.text, console: false)
            case .image(let value): return .image(value)
            default: return nil
            }
        }, returnedValue: returnedValue, failure: failure)
    }
}

private func failureText(_ failure: CodemodeFailure, calls: [CodemodeNestedCall]) -> String {
    let head: String
    switch failure.kind {
    case .script: head = failure.stack ?? "\(failure.name ?? "Error"): \(failure.message)"
    case .timeout: head = "Script timed out: \(failure.message)"
    case .aborted: head = "Script aborted: \(failure.message)"
    case .sandbox: head = "Script sandbox failed: \(failure.message)"
    }
    let summary = calls.isEmpty ? "No tool calls were made." :
        "Tool calls made before the failure (they are not undone): " +
        calls.map { "\($0.name) (\($0.status.rawValue))" }.joined(separator: ", ")
    return "Script error:\n\(head)\n\n\(summary)"
}

private func valueText(_ value: AnyCodable) -> String {
    if let string = value.value as? String { return string }
    if let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) { return text }
    return String(describing: value.value)
}

private func truncateOutput(_ items: [ContentBlock], maxTokens: Int) -> (items: [ContentBlock], fullOutputPath: String?) {
    let texts = items.compactMap { block -> String? in
        if case .text(let value) = block { return value.text }
        return nil
    }
    let combined = texts.joined(separator: "\n")
    let budget = maxTokens > Int.max / 4 ? Int.max : max(0, maxTokens) * 4
    let length = (combined as NSString).length
    guard !texts.isEmpty, length > budget else { return (items, nil) }
    let headChars = budget / 2
    let tailChars = budget - headChars
    let ns = combined as NSString
    let head = ns.substring(to: headChars)
    let tail = tailChars > 0 ? ns.substring(from: length - tailChars) : ""
    let removed = length - budget
    let lineCount = combined.components(separatedBy: "\n").count
    var text = "Warning: truncated output (original token count: \((length + 3) / 4))\nTotal output lines: \(lineCount)\n\n\(head)…\((removed + 3) / 4) tokens truncated…\(tail)"
    var savedPath: String?
    do {
        let path = try writeOutputFile(prefix: "pi-codemode", extension: ".txt", data: Data(combined.utf8))
        savedPath = path
        text += "\n\n[Full output: \(path) (read with offset/limit)]"
    } catch {
        text += "\n\n[Could not save the full output: \(error.localizedDescription)]"
    }
    let images = items.filter { if case .image = $0 { return true }; return false }
    return ([.text(TextContent(text: text))] + images, savedPath)
}

private let codemodeImageExtensions = [
    "image/png": ".png", "image/jpeg": ".jpg", "image/gif": ".gif", "image/webp": ".webp",
]

enum CodemodeImageError: Error, Sendable, LocalizedError, Equatable {
    case unsupportedMIME(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedMIME(let mime): return "No file extension for image type \(mime)"
        }
    }
}

typealias CodemodeImageWriter = (Data, String) throws -> String

private func saveCodemodeImage(_ data: Data, _ fileExtension: String) throws -> String {
    try writeOutputFile(prefix: "pi-codemode", extension: fileExtension, data: data)
}

private func saveCodemodeImages(_ items: [ContentBlock], writer: CodemodeImageWriter,
                                rejectUnsupportedMIME: Bool) throws -> [ContentBlock] {
    var labels: [String: String] = [:]
    var result: [ContentBlock] = []
    for item in items {
        if case .image(let image) = item {
            let label: String
            if let saved = labels[image.data] {
                label = saved
            } else {
                guard let fileExtension = codemodeImageExtensions[image.mimeType] else {
                    if rejectUnsupportedMIME { throw CodemodeImageError.unsupportedMIME(image.mimeType) }
                    result.append(item)
                    continue
                }
                let bytes = Data(base64Encoded: image.data, options: .ignoreUnknownCharacters) ?? Data()
                let kind = "\(image.mimeType), \(formatSize(bytes.count))"
                do {
                    let path = try writer(bytes, fileExtension)
                    label = "[Image saved to \(path) (\(kind))]"
                } catch {
                    label = "[Image (\(kind)) could not be saved: \(error.localizedDescription)]"
                }
                labels[image.data] = label
            }
            result.append(.text(TextContent(text: label)))
        }
        result.append(item)
    }
    return result
}

/// Join adjacent text items. Each part starts on its own line.
func joinAdjacentCodemodeText(_ items: [ContentBlock]) -> [ContentBlock] {
    var joined: [ContentBlock] = []
    for item in items {
        if case .text(let next) = item, case .text(let last)? = joined.last {
            let separator = last.text.isEmpty || last.text.hasSuffix("\n") ? "" : "\n"
            joined[joined.count - 1] = .text(TextContent(text: last.text + separator + next.text))
        } else {
            joined.append(item)
        }
    }
    return joined
}

private func formatCodemodeOutput(_ output: [CodemodeOutputItem]) -> [ContentBlock] {
    let total = output.filter { if case .text(_, console: false) = $0 { return true }; return false }.count
    var items: [ContentBlock] = []
    var consoleLines: [String] = []
    var index = 0
    for item in output {
        switch item {
        case .image(let image): items.append(.image(image))
        case .text(let text, console: true): consoleLines.append(text)
        case .text(let text, console: false):
            index += 1
            items.append(.text(TextContent(text: total > 1 ? "==> text \(index)/\(total) <==\n\(text)" : text)))
        }
    }
    if !consoleLines.isEmpty {
        items.append(.text(TextContent(text: "<console_output>\n" + consoleLines.joined(separator: "\n") + "\n</console_output>")))
    }
    return items
}

/// Keep the nonthrowing API. Unsupported MIME types retain their original image block without a file label.
public func formatCodemodeResult(_ execution: CodemodeExecutionResult,
                                 calls: [CodemodeNestedCall] = [], wallTimeSeconds: Double,
                                 maxOutputTokens: Int = 10_000, usage: Usage? = nil, outputNote: String? = nil) -> AgentToolResult {
    var result = formatCodemodeResultBody(execution, calls: calls, wallTimeSeconds: wallTimeSeconds,
                                         maxOutputTokens: maxOutputTokens, usage: usage, outputNote: outputNote)
    // This policy preserves unknown types, so MIME validation cannot throw here.
    let output = (try? saveCodemodeImages(Array(result.content.dropFirst()), writer: saveCodemodeImage,
                                         rejectUnsupportedMIME: false)) ?? Array(result.content.dropFirst())
    result.content = Array(result.content.prefix(1)) + joinAdjacentCodemodeText(output)
    return result
}

/// The execution path rejects an unsupported MIME type before the file-write error handler.
func formatCodemodeResultForExecution(_ execution: CodemodeExecutionResult,
                                      calls: [CodemodeNestedCall] = [], wallTimeSeconds: Double,
                                      maxOutputTokens: Int = 10_000, usage: Usage? = nil, outputNote: String? = nil,
                                      imageWriter: CodemodeImageWriter = saveCodemodeImage) throws -> AgentToolResult {
    var result = formatCodemodeResultBody(execution, calls: calls, wallTimeSeconds: wallTimeSeconds,
                                         maxOutputTokens: maxOutputTokens, usage: usage, outputNote: outputNote)
    let output = try saveCodemodeImages(Array(result.content.dropFirst()), writer: imageWriter, rejectUnsupportedMIME: true)
    result.content = Array(result.content.prefix(1)) + joinAdjacentCodemodeText(output)
    return result
}

private func formatCodemodeResultBody(_ execution: CodemodeExecutionResult,
                                      calls: [CodemodeNestedCall], wallTimeSeconds: Double,
                                      maxOutputTokens: Int, usage: Usage?, outputNote: String?) -> AgentToolResult {
    var scriptOutput = execution.output
    if execution.failure == nil, let value = execution.returnedValue {
        scriptOutput.append(.text(valueText(value), console: false))
    }
    var items = formatCodemodeOutput(scriptOutput)
    if let failure = execution.failure {
        items.append(.text(TextContent(text: failureText(failure, calls: calls))))
    }
    if let outputNote { items.append(.text(TextContent(text: outputNote))) }
    let truncated = truncateOutput(joinAdjacentCodemodeText(items), maxTokens: maxOutputTokens)
    let header = "Script \(execution.failure == nil ? "completed" : "failed")\nWall time \(String(format: "%.1f", wallTimeSeconds)) seconds\nOutput:\n"
    var details: [String: Any] = ["calls": calls.map { call -> [String: Any] in
        var row: [String: Any] = ["id": call.id, "name": call.name, "args": call.args, "status": call.status.rawValue]
        if let value = call.durationMs { row["durationMs"] = value }
        if let value = call.error { row["error"] = value }
        if let value = call.cost { row["cost"] = value }
        return row
    }]
    if let path = truncated.fullOutputPath { details["fullOutputPath"] = path }
    return AgentToolResult(content: [.text(TextContent(text: header))] + truncated.items,
                           details: AnyCodable(details), usage: usage, isError: execution.failure == nil ? nil : true)
}
