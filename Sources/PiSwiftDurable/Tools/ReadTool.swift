import Foundation
import PiSwiftAI
import PiSwiftChord

/// Arguments for the text read tool. Line numbers start at one.
public struct ReadToolInput: Sendable, Codable {
    public var path: String
    public var offset: Double?
    public var limit: Double?
    public init(path: String, offset: Double? = nil, limit: Double? = nil) {
        self.path = path; self.offset = offset; self.limit = limit
    }
}

/// Details from a text read. The truncation object contains counts and limits, without file content.
public struct ReadToolDetails: Sendable, Codable, Equatable {
    public var truncation: JSONValue?
    public init(truncation: JSONValue? = nil) { self.truncation = truncation }
}

/// A read failure that includes text for the caller.
public struct ReadToolError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

/// Creates a tool that reads text with bounded memory and reports continuation in diagnostics.
public func createReadTool() throws -> ToolRegistration {
    try defineTool(name: "read", description: "Read the contents of a text file. Output is truncated to \(defaultMaxLines) lines or \(defaultMaxBytes / 1024)KB (whichever is hit first). Use offset/limit for large files. When you need the full file, continue with offset until complete.", parameters: [
        "type": "object", "properties": .object([
            "path": .object(["type": "string", "description": "Path to the file to read (relative or absolute)"]),
            "offset": .object(["type": "number", "description": "Line number to start reading from (1-indexed)"]),
            "limit": .object(["type": "number", "description": "Maximum number of lines to read"])
        ]), "required": .array(["path"])
    ], args: ReadToolInput.self, execute: executeReadTool)
}

internal func executeReadTool(_ args: ReadToolInput, _ api: ToolExecutionApi,
                              _ context: ChordContext) async throws -> ToolExecutionResult {
    let env = try requireEnv(api)
    let path = try await resolveReadToolPath(env: env, path: args.path, context: context)
    let reader = try await env.openBinaryReader(path, options: nil, context: context).get()
    return try await executeReadReader(reader, args: args, context: context)
}

internal func executeReadReader(_ reader: any BinaryReader, args: ReadToolInput,
                                context: ChordContext) async throws -> ToolExecutionResult {
    do {
        var attempt = 0
        while true {
            let before = try await reader.info(context: context).get()
            let result = try await readText(reader, info: before, args: args, context: context)
            let after = try await reader.info(context: context).get()
            if after.size > before.size || (after.size == before.size && after.mtimeMs == before.mtimeMs) {
                await reader.close(context: context)
                return result
            }
            if attempt == 1 { throw ReadToolError("\(args.path) changed while it was read") }
            attempt += 1
        }
    } catch {
        await reader.close(context: context)
        throw error
    }
}

private func sliceIndex(_ value: Double) -> Double { value.isNaN ? 0 : value.rounded(.towardZero) }
private func safeIndex(_ value: Double) -> Int? {
    value.isFinite && value >= 0 && value <= 9_007_199_254_740_991 && value.rounded(.towardZero) == value ? Int(value) : nil
}
private func jsMax(_ left: Double, _ right: Double) -> Double { left.isNaN || right.isNaN ? .nan : max(left, right) }
private func jsMin(_ left: Double, _ right: Double) -> Double { left.isNaN || right.isNaN ? .nan : min(left, right) }
private func numberText(_ value: Double) -> String {
    if value.isNaN { return "NaN" }
    if value.isInfinite { return value > 0 ? "Infinity" : "-Infinity" }
    return (try? JSONValue.number(value).jsonText()) ?? String(value)
}

private func readHead(_ reader: any BinaryReader, start: Int64, end: Int64, skipBom: Bool,
                      context: ChordContext) async throws -> String {
    var decoder = rangeDecoder()
    var text = ""
    var newlines = 0
    var position = skipBom && start == 0 ? 3 : start
    while position < end {
        let bytes = try await reader.read(offset: position, length: Int(min(64 * 1024, end - position)), context: context).get()
        if bytes.isEmpty { break }
        position += Int64(bytes.count)
        let decoded = decoder.decode(bytes)
        text += decoded
        newlines += decoded.utf8.filter { $0 == 10 }.count
        if newlines >= defaultMaxLines || utf8ByteLength(text) > defaultMaxBytes + 1 { return text }
    }
    return text + decoder.decode()
}

private func readText(_ reader: any BinaryReader, info: FileInfo, args: ReadToolInput,
                      context: ChordContext) async throws -> ToolExecutionResult {
    if let mime = try await detectSupportedImageMimeTypeOf(.init(size: info.size, read: { position, length in
        try await reader.read(offset: position, length: length, context: context).get()
    })) {
        return .init(content: [], isError: true, diagnostics: [
            .init(severity: .error, message: "\(args.path) is an image (\(mime)); reading images is not supported", code: "unsupported_image")
        ])
    }
    let offset = args.offset ?? 0
    let startLine = offset == 0 || offset.isNaN ? 0 : jsMax(0, offset - 1)
    let startDisplay = startLine + 1
    let sliceStart = sliceIndex(startLine)
    let scanStart = safeIndex(sliceStart) ?? 0
    let requestedEnd = args.limit.map { jsMax(Double(scanStart + 1), sliceIndex(startLine + $0)) }
    let scanEnd = requestedEnd.flatMap(safeIndex)
    func scanOf(_ end: Int?) async throws -> LineScan {
        try await reader.scanLines(options: .init(startLine: scanStart, endLine: end), context: context).get()
    }
    var scan = try await scanOf(scanEnd)
    let totalFileLines = scan.newlines + 1
    if startLine >= Double(totalFileLines) {
        throw ReadToolError("Offset \(numberText(offset)) is beyond end of file (\(totalFileLines) lines total)")
    }
    var userLimitedLines: Double?
    var selectedLines = Double(totalFileLines) - sliceStart
    if let limit = args.limit {
        let endLine = jsMin(startLine + limit, Double(totalFileLines))
        userLimitedLines = endLine - startLine
        let relativeEnd = sliceIndex(endLine)
        let sliceEnd = relativeEnd < 0 ? jsMax(Double(totalFileLines) + relativeEnd, 0) : relativeEnd
        selectedLines = jsMax(0, sliceEnd - sliceStart)
        if selectedLines > 0 && relativeEnd < 0 { scan = try await scanOf(safeIndex(sliceEnd)) }
    }
    let empty = selectedLines == 0
    let endsWithNewline = !empty && scan.lastLineStart == scan.end && scan.lastLineStart > scan.start
    let totalLines = empty || scan.selectedBytes == 0 ? 0 : Int(selectedLines) - (endsWithNewline ? 1 : 0)
    let totalBytes = empty ? 0 : Int(scan.selectedBytes)
    let firstBytes = try await reader.read(offset: 0, length: 3, context: context).get()
    let head = empty ? "" : try await readHead(reader, start: scan.start, end: scan.end,
                                             skipBom: startsWithBom(firstBytes), context: context)
    let truncation = truncateHeadOf(head, totals: .init(lines: totalLines, bytes: totalBytes))
    var output = truncation.content
    var diagnostics: [ToolDiagnostic] = []
    var details: JSONValue?
    if truncation.firstLineExceedsLimit {
        let integral = startLine.rounded(.towardZero) == startLine
        let line = integral ? (head.components(separatedBy: "\n").first ?? "") : ""
        let bytes = Array(line.utf8)
        let end = characterEnd(bytes, at: min(defaultMaxBytes, bytes.count))
        output = String(decoding: bytes.prefix(end), as: UTF8.self)
        let size = integral ? Int(scan.firstLineBytes) : 0
        diagnostics.append(.init(severity: .warn, message: "Line \(numberText(startDisplay)) is \(formatSize(size)), exceeds the \(formatSize(defaultMaxBytes)) limit; showing its first \(formatSize(end)). Use bash: sed -n '\(numberText(startDisplay))p' \(args.path) | tail -c +\(end + 1)", code: "truncated"))
        details = truncationDetails(truncation, outputLines: 1, outputBytes: end)
    } else if truncation.truncated {
        let endDisplay = startDisplay + Double(truncation.outputLines) - 1
        let by = truncation.truncatedBy
        let sizeText = by == .lines ? "" : " (\(formatSize(defaultMaxBytes)) limit)"
        diagnostics.append(.init(severity: .info, message: "Showing lines \(numberText(startDisplay))-\(numberText(endDisplay)) of \(totalFileLines)\(sizeText). Use offset=\(numberText(endDisplay + 1)) to continue.", code: "truncated"))
        details = truncationDetails(truncation)
    } else if let userLimitedLines, startLine + userLimitedLines < Double(totalFileLines) {
        let remaining = Double(totalFileLines) - (startLine + userLimitedLines)
        diagnostics.append(.init(severity: .info, message: "\(numberText(remaining)) more lines in file. Use offset=\(numberText(startLine + userLimitedLines + 1)) to continue."))
    }
    return .init(content: output.isEmpty ? [] : [.text(TextContent(text: output))], details: details, diagnostics: diagnostics)
}

private func truncationDetails(_ result: TruncationResult, outputLines: Int? = nil,
                               outputBytes: Int? = nil) -> JSONValue {
    .object(["truncation": .object([
        "truncated": .bool(result.truncated),
        "truncatedBy": result.truncatedBy.map { .string($0.rawValue) } ?? .null,
        "totalLines": .number(Double(result.totalLines)),
        "totalBytes": .number(Double(result.totalBytes)),
        "outputLines": .number(Double(outputLines ?? result.outputLines)),
        "outputBytes": .number(Double(outputBytes ?? result.outputBytes)),
        "lastLinePartial": .bool(result.lastLinePartial),
        "firstLineExceedsLimit": .bool(result.firstLineExceedsLimit),
        "maxLines": .number(Double(result.maxLines)), "maxBytes": .number(Double(result.maxBytes))
    ])])
}
