import Foundation
import PiSwiftAI
import PiSwiftAgent
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum ReadToolError: LocalizedError, Sendable {
    case operationAborted
    case missingPath
    case fileNotFound(path: String)
    case offsetBeyondEnd(offset: String, totalLines: Int)

    var errorDescription: String? {
        switch self {
        case .operationAborted:
            return "Operation aborted"
        case .missingPath:
            return "Missing path"
        case let .fileNotFound(path):
            return "File not found: \(path)"
        case let .offsetBeyondEnd(offset, totalLines):
            return "Offset \(offset) is beyond end of file (\(totalLines) lines total)"
        }
    }
}

public struct ReadToolDetails: Sendable {
    public var truncation: TruncationResult?
}

/// File operations for local and remote read tools. The stream is pulled one chunk at a time.
public struct ReadOperations: Sendable {
    public var readFile: @Sendable (String) async throws -> Data
    public var access: @Sendable (String) async throws -> Void
    public var detectImageMimeType: (@Sendable (String) async throws -> String?)?
    public var createReadStream: (@Sendable (String, CancellationToken?) throws -> AsyncThrowingStream<Data, Error>)?

    public init(
        readFile: @escaping @Sendable (String) async throws -> Data,
        access: @escaping @Sendable (String) async throws -> Void,
        detectImageMimeType: (@Sendable (String) async throws -> String?)? = nil,
        createReadStream: (@Sendable (String, CancellationToken?) throws -> AsyncThrowingStream<Data, Error>)? = nil
    ) {
        self.readFile = readFile
        self.access = access
        self.detectImageMimeType = detectImageMimeType
        self.createReadStream = createReadStream
    }
}

actor LocalReadChunks {
    let handle: FileHandle
    var remaining: Int?
    let signal: CancellationToken?

    init(path: String, signal: CancellationToken?) throws {
        handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        self.signal = signal
        var status = stat()
        if fstat(handle.fileDescriptor, &status) == 0,
           status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), status.st_size > 0 {
            remaining = Int(status.st_size)
        }
    }

    deinit { try? handle.close() }

    func next() throws -> Data? {
        if signal?.isCancelled == true || Task.isCancelled {
            try? handle.close()
            throw ReadToolError.operationAborted
        }
        guard remaining != 0 else { try? handle.close(); return nil }
        do {
            guard let data = try handle.read(upToCount: min(64 * 1024, remaining ?? 64 * 1024)), !data.isEmpty else {
                try? handle.close()
                return nil
            }
            if let count = remaining { remaining = count - data.count }
            return data
        } catch {
            try? handle.close()
            throw error
        }
    }
}

private let localReadOperations = ReadOperations(
    readFile: { try Data(contentsOf: URL(fileURLWithPath: $0)) },
    access: { path in
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw ReadToolError.fileNotFound(path: path)
        }
    },
    detectImageMimeType: { path in
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { return nil }
        return detectSupportedImageMimeType(fromFile: path)
    },
    createReadStream: { path, signal in
        let chunks = try LocalReadChunks(path: path, signal: signal)
        return AsyncThrowingStream(unfolding: { try await chunks.next() })
    }
)

private struct SelectedReadLines {
    var totalFileLines: Int
    var truncation: TruncationResult
    var firstLineBytes: Int
}

/// Keep incomplete UTF-8 sequences for the next chunk. Invalid input uses U+FFFD.
private struct ReadUTF8Decoder {
    var pending: [UInt8] = []

    mutating func decode(_ data: Data, final: Bool = false) -> String {
        var bytes = pending
        bytes.append(contentsOf: data)
        pending.removeAll(keepingCapacity: true)
        if !final && !bytes.isEmpty {
            var start = bytes.count - 1
            while start > 0 && bytes[start] & 0xC0 == 0x80 { start -= 1 }
            let first = bytes[start]
            let length = first >= 0xC2 && first <= 0xDF ? 2
                : first >= 0xE0 && first <= 0xEF ? 3
                : first >= 0xF0 && first <= 0xF4 ? 4 : 0
            let count = bytes.count - start
            var valid = length > count
            if valid && count > 1 {
                let second = bytes[start + 1]
                valid = second & 0xC0 == 0x80
                    && !(first == 0xE0 && second < 0xA0)
                    && !(first == 0xED && second >= 0xA0)
                    && !(first == 0xF0 && second < 0x90)
                    && !(first == 0xF4 && second >= 0x90)
            }
            if valid { pending = Array(bytes[start...]); bytes.removeSubrange(start...) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private struct ReadLineSelection {
    let startLine: Int
    let endLine: Int?
    var line = 0
    var storedLines: [String] = []
    var storedBytes = 0
    var pastCaps = false
    var pieces = ""
    var lineBytes = 0
    var selectedLines = 0
    var selectedBytes = 0
    var firstLineBytes = 0
    var lastLineEmpty = true

    var selected: Bool { line >= startLine && (endLine == nil || line < endLine!) }

    mutating func finishLine() {
        if selectedLines == 0 { firstLineBytes = lineBytes }
        if !pastCaps {
            if storedLines.count > DEFAULT_MAX_LINES || storedBytes > DEFAULT_MAX_BYTES { pastCaps = true }
            storedBytes += pieces.utf8.count + (storedLines.isEmpty ? 0 : 1)
            storedLines.append(pieces)
        }
        selectedLines += 1
        lastLineEmpty = lineBytes == 0
        pieces = ""
        lineBytes = 0
    }

    mutating func consume(_ text: String) {
        let segments = text.components(separatedBy: "\n")
        for (index, segment) in segments.enumerated() {
            if selected {
                let count = segment.utf8.count
                selectedBytes += count
                if !pastCaps && lineBytes <= DEFAULT_MAX_BYTES {
                    // At most one byte beyond the cap is needed for truncateHead to reject this line.
                    let available = DEFAULT_MAX_BYTES + 1 - pieces.utf8.count
                    pieces += String(decoding: segment.utf8.prefix(max(0, available)), as: UTF8.self)
                }
                lineBytes += count
            }
            if index + 1 < segments.count {
                if selected {
                    finishLine()
                    if endLine == nil || line + 1 < endLine! { selectedBytes += 1 }
                }
                line += 1
            }
        }
    }

    mutating func result() -> SelectedReadLines {
        if selected { finishLine() }
        var truncation = truncateHead(storedLines.joined(separator: "\n"))
        truncation.totalLines = selectedBytes == 0 ? 0 : selectedLines - (lastLineEmpty ? 1 : 0)
        truncation.totalBytes = selectedBytes
        return SelectedReadLines(totalFileLines: line + 1, truncation: truncation, firstLineBytes: firstLineBytes)
    }
}

private func selectReadLines(
    _ stream: AsyncThrowingStream<Data, Error>, startLine: Int, limit: Int?, signal: CancellationToken?
) async throws -> SelectedReadLines {
    var decoder = ReadUTF8Decoder()
    var selection = ReadLineSelection(startLine: startLine, endLine: limit.map { startLine + $0 })
    for try await chunk in stream {
        if signal?.isCancelled == true || Task.isCancelled { throw ReadToolError.operationAborted }
        selection.consume(decoder.decode(chunk))
    }
    if signal?.isCancelled == true || Task.isCancelled { throw ReadToolError.operationAborted }
    selection.consume(decoder.decode(Data(), final: true))
    return selection.result()
}

public struct ReadToolOptions: Sendable {
    public var autoResizeImages: Bool?
    public var blockImages: Bool?
    public var resizeOptions: ModelImageResizeOptions?
    public var modelProvider: (@Sendable () -> Model?)?
    public var operations: ReadOperations?

    public init(
        autoResizeImages: Bool? = nil,
        blockImages: Bool? = nil,
        resizeOptions: ModelImageResizeOptions? = nil,
        modelProvider: (@Sendable () -> Model?)? = nil,
        operations: ReadOperations? = nil
    ) {
        self.autoResizeImages = autoResizeImages
        self.blockImages = blockImages
        self.resizeOptions = resizeOptions
        self.modelProvider = modelProvider
        self.operations = operations
    }
}

// Upstream v1.0.4 #10251: programmatic callers receive text or the image with its note.
private func readToolResult(content: [ContentBlock], details: AnyCodable? = nil) -> AgentToolResult {
    let text = content.compactMap { block -> String? in
        if case .text(let item) = block { return item.text }
        return nil
    }.first ?? ""
    let image = content.compactMap { block -> ImageContent? in
        if case .image(let item) = block { return item }
        return nil
    }.first
    let output = image.map {
        AnyCodable(["type": "image", "data": $0.data, "mimeType": $0.mimeType, "note": text])
    } ?? AnyCodable(text)
    return AgentToolResult(content: content, details: details, structuredContent: output)
}

private func readNumber(_ number: Double) -> String {
    number == number.rounded(.towardZero) ? String(Int(number)) : String(number)
}

public func createReadTool(cwd: String, options: ReadToolOptions? = nil) -> AgentTool {
    let autoResizeImages = options?.autoResizeImages ?? true
    let blockImages = options?.blockImages ?? false
    let operations = options?.operations ?? localReadOperations
    var tool = AgentTool(
        label: "read",
        name: "read",
        description: "Read the contents of a file. Supports text files and images (jpg, png, gif, webp, bmp). Images are sent as attachments. For text files, output is truncated to \(DEFAULT_MAX_LINES) lines or \(DEFAULT_MAX_BYTES / 1024)KB (whichever is hit first). Use offset/limit for large files. When you need the full file, continue with offset until complete.",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "path": ["type": "string", "description": "Path to the file to read (relative or absolute)"],
                "offset": ["type": "number", "description": "Line number to start reading from (1-indexed)"],
                "limit": ["type": "number", "description": "Maximum number of lines to read"],
            ]),
            "required": AnyCodable(["path"]),
        ]
    ) { _, params, signal, _ in
        if signal?.isCancelled == true {
            throw ReadToolError.operationAborted
        }
        guard let path = params["path"]?.value as? String else {
            throw ReadToolError.missingPath
        }
        let rawOffset = (params["offset"]?.value as? NSNumber)?.doubleValue
        let rawLimit = (params["limit"]?.value as? NSNumber)?.doubleValue
        let offset = intValue(params["offset"])
        let limit = intValue(params["limit"])

        let absolutePath = resolveReadPath(path, cwd: cwd)

        try await operations.access(absolutePath)

        if let mimeType = try await operations.detectImageMimeType?(absolutePath) {
            if blockImages {
                let warning = "[Image file detected: \(absolutePath)]\nImage reading is disabled. The 'blockImages' setting is enabled."
                return readToolResult(content: [.text(TextContent(text: warning))])
            }
            let data = try await operations.readFile(absolutePath)
            let base64 = data.base64EncodedString()

            if autoResizeImages {
                let profile = options?.modelProvider?()?.inputLimits?.images?.resize ?? options?.resizeOptions
                let limits = ImageResizeOptions(modelProfile: profile)
                let resized = resizeImage(ImageContent(data: base64, mimeType: mimeType), options: limits)
                guard imageFitsResizeLimits(resized, options: limits) else {
                    return readToolResult(content: [.text(TextContent(text: "Read image file [\(mimeType)]\n[Image omitted: could not be resized below the inline image size limit.]"))])
                }
                let dimensionNote = formatDimensionNote(resized)
                var textNote = "Read image file [\(resized.mimeType)]"
                if let dimensionNote {
                    textNote += "\n\(dimensionNote)"
                }
                let content: [ContentBlock] = [
                    .text(TextContent(text: textNote)),
                    .image(ImageContent(data: resized.data, mimeType: resized.mimeType)),
                ]
                return readToolResult(content: content)
            }

            // v1.5.2 C-TB: image-process.ts:47-62,72-100 normalizes BMP even when resizing is off.
            var inlineImage = ImageContent(data: base64, mimeType: mimeType)
            var textNote = "Read image file [\(mimeType)]"
            if mimeType == "image/bmp" {
                guard let converted = convertToPng(base64, mimeType) else {
                    return readToolResult(content: [.text(TextContent(text: "Read image file [\(mimeType)]\n[Image omitted: could not be converted to a supported inline image format.]"))])
                }
                inlineImage = converted
                textNote = "Read image file [image/png]\n[Image converted from image/bmp to image/png.]"
            }
            let content: [ContentBlock] = [
                .text(TextContent(text: textNote)),
                .image(inlineImage),
            ]
            return readToolResult(content: content)
        }

        let rawStartLine = max(0, (rawOffset ?? Double(offset ?? 1)) - 1)
        let startLine = Int(rawStartLine)
        let startLineDisplay = readNumber(rawStartLine + 1)
        let streamable = (rawOffset == nil || rawOffset == rawOffset?.rounded(.towardZero))
            && (rawLimit == nil || (rawLimit == rawLimit?.rounded(.towardZero) && rawLimit! >= 0))
        let selection: SelectedReadLines
        if let stream = operations.createReadStream, streamable {
            selection = try await selectReadLines(try stream(absolutePath, signal), startLine: startLine, limit: limit, signal: signal)
        } else {
            let data = try await operations.readFile(absolutePath)
            let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            // JavaScript Array.slice converts each bound to an integer separately.
            let rawStart = max(0, (rawOffset ?? 1) - 1)
            let sliceStart = min(lines.count, max(0, Int(rawStart)))
            let end = rawLimit.map { min(rawStart + $0, Double(lines.count)) } ?? Double(lines.count)
            let sliceEnd = end < 0 ? max(0, lines.count + Int(end)) : min(lines.count, Int(end))
            let selected = sliceEnd > sliceStart ? lines[sliceStart..<sliceEnd].joined(separator: "\n") : ""
            selection = SelectedReadLines(totalFileLines: lines.count, truncation: truncateHead(selected),
                                          firstLineBytes: sliceStart < lines.count ? lines[sliceStart].utf8.count : 0)
        }
        let totalLines = selection.totalFileLines
        if rawStartLine >= Double(totalLines) {
            throw ReadToolError.offsetBeyondEnd(offset: readNumber(rawOffset ?? Double(offset ?? 0)), totalLines: totalLines)
        }
        let userLimitedLines = rawLimit.map { min(rawStartLine + $0, Double(totalLines)) - rawStartLine }
        let truncation = selection.truncation
        var details: AnyCodable? = nil
        var outputText: String

        if truncation.firstLineExceedsLimit {
            let firstLineSize = formatSize(selection.firstLineBytes)
            outputText = "[Line \(startLineDisplay) is \(firstLineSize), exceeds \(formatSize(DEFAULT_MAX_BYTES)) limit. Use bash: sed -n '\(startLineDisplay)p' \(path) | head -c \(DEFAULT_MAX_BYTES)]"
            details = AnyCodable(["truncation": truncationToAnyCodable(truncation).value])
        } else if truncation.truncated {
            let endLineDisplay = rawStartLine + Double(truncation.outputLines)
            let nextOffset = readNumber(endLineDisplay + 1)
            outputText = truncation.content
            if truncation.truncatedBy == "lines" {
                outputText += "\n\n[Showing lines \(startLineDisplay)-\(readNumber(endLineDisplay)) of \(totalLines). Use offset=\(nextOffset) to continue.]"
            } else {
                outputText += "\n\n[Showing lines \(startLineDisplay)-\(readNumber(endLineDisplay)) of \(totalLines) (\(formatSize(DEFAULT_MAX_BYTES)) limit). Use offset=\(nextOffset) to continue.]"
            }
            details = AnyCodable(["truncation": truncationToAnyCodable(truncation).value])
        } else if let userLimitedLines, rawStartLine + userLimitedLines < Double(totalLines) {
            let remaining = readNumber(Double(totalLines) - (rawStartLine + userLimitedLines))
            let nextOffset = readNumber(rawStartLine + userLimitedLines + 1)
            outputText = truncation.content
            outputText += "\n\n[\(remaining) more lines in file. Use offset=\(nextOffset) to continue.]"
        } else {
            outputText = truncation.content
        }

        return readToolResult(content: [.text(TextContent(text: outputText))], details: details)
    }
    tool.executeWithContext = { id, params, signal, onUpdate, context in
        var executionOptions = options ?? ReadToolOptions()
        executionOptions.resizeOptions = context.model?.inputLimits?.images?.resize ?? executionOptions.resizeOptions
        if context.model != nil { executionOptions.modelProvider = nil }
        return try await createReadTool(cwd: resolveToolExecutionCwd(context, fallback: cwd), options: executionOptions).execute(id, params, signal, onUpdate)
    }
    // No property descriptions: the codemode output type stays on one line (#10251).
    tool.outputSchema = ["anyOf": AnyCodable([
        ["type": "string"],
        ["type": "object", "properties": [
            "type": ["type": "string", "const": "image"],
            "data": ["type": "string"],
            "mimeType": ["type": "string"],
            "note": ["type": "string"],
        ], "required": ["type", "data", "mimeType", "note"]],
    ])]
    tool.constrainedSampling = .jsonSchema(strict: .prefer)
    return tool
}
