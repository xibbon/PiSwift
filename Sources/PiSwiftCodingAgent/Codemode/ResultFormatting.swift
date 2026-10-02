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

public struct CodemodeExecutionResult: Sendable {
    public var output: [ContentBlock]
    public var returnedValue: AnyCodable?
    public var failure: CodemodeFailure?

    public init(output: [ContentBlock], returnedValue: AnyCodable? = nil, failure: CodemodeFailure? = nil) {
        self.output = output
        self.returnedValue = returnedValue
        self.failure = failure
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
    let hex = (0..<8).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("pi-codemode-\(hex).txt").path
    var savedPath: String?
    do {
        try combined.write(toFile: path, atomically: true, encoding: .utf8)
        savedPath = path
        text += "\n\n[Full output: \(path) (read with offset/limit)]"
    } catch {
        text += "\n\n[Could not save the full output: \(error.localizedDescription)]"
    }
    let images = items.filter { if case .image = $0 { return true }; return false }
    return ([.text(TextContent(text: text))] + images, savedPath)
}

public func formatCodemodeResult(_ execution: CodemodeExecutionResult,
                                 calls: [CodemodeNestedCall] = [], wallTimeSeconds: Double,
                                 maxOutputTokens: Int = 10_000, usage: Usage? = nil, outputNote: String? = nil) -> AgentToolResult {
    var items = execution.output
    if let failure = execution.failure {
        items.append(.text(TextContent(text: failureText(failure, calls: calls))))
    } else if let value = execution.returnedValue {
        items.append(.text(TextContent(text: valueText(value))))
    }
    if let outputNote { items.append(.text(TextContent(text: outputNote))) }
    let truncated = truncateOutput(items, maxTokens: maxOutputTokens)
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
