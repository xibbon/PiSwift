// Output layout follows packages/durable/src/codemode/output.ts at v1.3.0.
// The adjacent-text join also follows Sources/PiSwiftCodingAgent/Codemode/ResultFormatting.swift.
import Foundation
import PiSwiftAI
import PiSwiftChord

public enum CodemodeOutputFileResult: Sendable, Equatable {
    case path(String)
    case error(String)
}
public struct CodemodeFormattedResult: Sendable {
    public var content: [ContentBlock]
    public var fullOutputPath: String?
    public init(content: [ContentBlock], fullOutputPath: String? = nil) {
        self.content = content; self.fullOutputPath = fullOutputPath
    }
}

/// Joins text in one pass. The last part controls the separator, without reading a growing string.
internal func codemodeJoinText(_ items: [ContentBlock]) -> [ContentBlock] {
    var result: [ContentBlock] = [], parts: [String] = [], last = ""
    func flush() {
        if !parts.isEmpty { result.append(.text(.init(text: parts.joined()))) }
        parts.removeAll(keepingCapacity: true); last = ""
    }
    for item in items {
        guard case .text(let text) = item else { flush(); result.append(item); continue }
        if !last.isEmpty && !last.hasSuffix("\n") { parts.append("\n"); last = "\n" }
        parts.append(text.text)
        if !text.text.isEmpty { last = text.text }
    }
    flush(); return result
}

// JavaScript toFixed rounds the exact binary value. Construct that value from
// its significand and exponent; Foundation's Double formatting can round a
// shortest decimal representation instead (1.15 is one such boundary).
private func codemodeWallSeconds(_ wallMs: Double) -> String {
    let seconds = wallMs / 1000, absolute = abs(seconds)
    if seconds == 0 { return "0.0" }
    if seconds.isNaN { return "NaN" }
    if seconds == .infinity { return "Infinity" }
    if seconds == -.infinity { return "-Infinity" }
    if absolute >= 1e21 { return (try? JSONValue.number(seconds).jsonText()) ?? String(seconds) }
    if absolute < 0.05 { return seconds < 0 ? "-0.0" : "0.0" }
    // In this range, the exponent is -57...17, so each power fits Int64.
    let bits = absolute.bitPattern
    let significand = (bits & ((UInt64(1) << 52) - 1)) | (UInt64(1) << 52)
    let exponent = Int((bits >> 52) & 0x7ff) - 1023 - 52
    var exact = Decimal(Int64(significand))
    if exponent >= 0 { exact *= Decimal(Int64(1) << exponent) }
    else { exact /= Decimal(Int64(1) << (-exponent)) }
    var rounded = Decimal()
    NSDecimalRound(&rounded, &exact, 1, .plain)
    var text = NSDecimalNumber(decimal: rounded).stringValue
    if !text.contains(".") { text += ".0" }
    return (seconds < 0 ? "-" : "") + text
}

/// Formats output within the token and harness limits. File errors become visible output.
public func codemodeFormatResult(_ result: CodemodeResult, generatedImages: Int, wallMs: Double,
    maxOutputTokens: Int, calls: [CodemodeNestedCall],
    limits: OutputLimits = .init(maxBytes: 200_000, maxLines: 5_000, retain: .tail),
    write: @escaping @Sendable (String, Data) async -> CodemodeOutputFileResult
) async -> CodemodeFormattedResult {
    var output = result.output
    if result.ok, let value = result.value {
        output.append(.text(value.stringValue ?? ((try? value.jsonText()) ?? "undefined")))
    }
    let total = output.reduce(0) { sum, item in if case .text(_, console: false) = item { sum + 1 } else { sum } }
    var items: [ContentBlock] = [], console: [String] = [], index = 0
    for item in output {
        switch item {
        case .image(let data, let mimeType): items.append(.image(.init(data: data, mimeType: mimeType)))
        case .text(let text, console: true): console.append(text)
        case .text(let text, console: false):
            index += 1
            items.append(.text(.init(text: total > 1 ? "==> text \(index)/\(total) <==\n\(text)" : text)))
        }
    }
    if !console.isEmpty { items.append(.text(.init(text: "<console_output>\n\(console.joined(separator: "\n"))\n</console_output>"))) }
    if let error = result.error {
        let head: String
        switch error.kind {
        case .script: head = error.stack ?? "\(error.name ?? "Error"): \(error.message)"
        case .timeout: head = "Script timed out: \(error.message)"
        case .aborted: head = "Script aborted: \(error.message)"
        case .sandbox: head = "Script sandbox failed: \(error.message)"
        }
        let summary = calls.isEmpty ? "No tool calls were made." : "Tool calls made before the failure (they are not undone): " + calls.map { "\($0.name) (\($0.status))" }.joined(separator: ", ")
        items.append(.text(.init(text: "Script error:\n\(head)\n\n\(summary)")))
    }
    if generatedImages > 0 && !items.contains(where: { if case .image = $0 { true } else { false } }) {
        items.append(.text(.init(text: "Note: models.generateImages() returned \(generatedImages) image\(generatedImages == 1 ? "" : "s") that the script did not show. Show each image block of result.output with image(block).")))
    }
    items = codemodeJoinText(items)
    let texts = items.compactMap { item -> String? in if case .text(let text) = item { text.text } else { nil } }
    let combined = texts.joined(separator: "\n"), units = Array(combined.utf16)
    let tokens = max(0, maxOutputTokens)
    let budget = min(tokens > Int.max / 4 ? Int.max : tokens * 4, limits.maxBytes / 4)
    let lineBudget = max(0, (limits.maxLines - 100) / 2)
    let lines = combined.components(separatedBy: "\n")
    var fullOutputPath: String?
    if !texts.isEmpty && (units.count > budget || lines.count > 2 * lineBudget) {
        let headCount = budget / 2, tailCount = budget - headCount
        let head = String(decoding: units.prefix(headCount), as: UTF16.self).components(separatedBy: "\n").prefix(lineBudget).joined(separator: "\n")
        let tail = tailCount > 0 ? String(decoding: units.suffix(tailCount), as: UTF16.self).components(separatedBy: "\n").suffix(lineBudget).joined(separator: "\n") : ""
        let removed = max(0, units.count - head.utf16.count - tail.utf16.count)
        var text = "Warning: truncated output (original token count: \((units.count + 3) / 4))\nTotal output lines: \(lines.count)\n\n\(head)…\((removed + 3) / 4) tokens truncated…\(tail)"
        switch await write("output.txt", Data(combined.utf8)) {
        case .path(let path): fullOutputPath = path; text += "\n\n[Full output: \(path) (read with offset/limit)]"
        case .error(let message): text += "\n\n[Could not save the full output: \(message)]"
        }
        items = [.text(.init(text: text))] + items.filter { if case .image = $0 { true } else { false } }
    }
    var labels: [String: String] = [:], saved: [ContentBlock] = []
    let extensions = ["image/png": ".png", "image/jpeg": ".jpg", "image/gif": ".gif", "image/webp": ".webp"]
    for item in items {
        if case .image(let image) = item {
            let label: String
            if let existing = labels[image.data] { label = existing }
            else {
                let bytes = Data(base64Encoded: image.data) ?? Data()
                let kind = "\(image.mimeType), \(bytes.count) bytes"
                switch await write("image-\(labels.count + 1)\(extensions[image.mimeType] ?? ".bin")", bytes) {
                case .path(let path): label = "[Image saved to \(path) (\(kind))]"
                case .error(let error): label = "[Image (\(kind)) could not be saved: \(error)]"
                }
                labels[image.data] = label
            }
            saved.append(.text(.init(text: label)))
        }
        saved.append(item)
    }
    let header = "\(result.ok ? "Script completed" : "Script failed")\nWall time \(codemodeWallSeconds(wallMs)) seconds\nOutput:\n"
    return CodemodeFormattedResult(content: [.text(.init(text: header))] + codemodeJoinText(saved), fullOutputPath: fullOutputPath)
}
