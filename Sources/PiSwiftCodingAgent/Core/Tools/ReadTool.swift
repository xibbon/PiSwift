import Foundation
import PiSwiftAI
import PiSwiftAgent

enum ReadToolError: LocalizedError, Sendable {
    case operationAborted
    case missingPath
    case fileNotFound(path: String)
    case offsetBeyondEnd(offset: Int, totalLines: Int)

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

public struct ReadToolOptions: Sendable {
    public var autoResizeImages: Bool?
    public var blockImages: Bool?
    public var resizeOptions: ModelImageResizeOptions?
    public var modelProvider: (@Sendable () -> Model?)?

    public init(
        autoResizeImages: Bool? = nil,
        blockImages: Bool? = nil,
        resizeOptions: ModelImageResizeOptions? = nil,
        modelProvider: (@Sendable () -> Model?)? = nil
    ) {
        self.autoResizeImages = autoResizeImages
        self.blockImages = blockImages
        self.resizeOptions = resizeOptions
        self.modelProvider = modelProvider
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

public func createReadTool(cwd: String, options: ReadToolOptions? = nil) -> AgentTool {
    let autoResizeImages = options?.autoResizeImages ?? true
    let blockImages = options?.blockImages ?? false
    var tool = AgentTool(
        label: "read",
        name: "read",
        description: "Read the contents of a file. Supports text files and images (jpg, png, gif, webp).",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "path": ["type": "string", "description": "Path to the file to read (relative or absolute)"],
                "offset": ["type": "number", "description": "Line number to start reading from (1-indexed)"],
                "limit": ["type": "number", "description": "Maximum number of lines to read"],
            ]),
        ]
    ) { _, params, signal, _ in
        if signal?.isCancelled == true {
            throw ReadToolError.operationAborted
        }
        guard let path = params["path"]?.value as? String else {
            throw ReadToolError.missingPath
        }
        let offset = intValue(params["offset"])
        let limit = intValue(params["limit"])

        let absolutePath = resolveReadPath(path, cwd: cwd)

        if !FileManager.default.isReadableFile(atPath: absolutePath) {
            throw ReadToolError.fileNotFound(path: path)
        }

        if let mimeType = detectSupportedImageMimeType(fromFile: absolutePath) {
            if blockImages {
                let warning = "[Image file detected: \(absolutePath)]\nImage reading is disabled. The 'blockImages' setting is enabled."
                return readToolResult(content: [.text(TextContent(text: warning))])
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: absolutePath))
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

            let content: [ContentBlock] = [
                .text(TextContent(text: "Read image file [\(mimeType)]")),
                .image(ImageContent(data: base64, mimeType: mimeType)),
            ]
            return readToolResult(content: content)
        }

        let textContent = try String(contentsOfFile: absolutePath, encoding: .utf8)
        let allLines = textContent.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        let totalLines = allLines.count

        let startLine = max(0, (offset ?? 1) - 1)
        let startLineDisplay = startLine + 1

        if startLine >= totalLines {
            throw ReadToolError.offsetBeyondEnd(offset: offset ?? 0, totalLines: totalLines)
        }

        let selectedContent: String
        let userLimitedLines: Int?
        if let limit {
            let endLine = min(startLine + limit, totalLines)
            selectedContent = allLines[startLine..<endLine].joined(separator: "\n")
            userLimitedLines = endLine - startLine
        } else {
            selectedContent = allLines[startLine...].joined(separator: "\n")
            userLimitedLines = nil
        }

        let truncation = truncateHead(selectedContent)
        var details: AnyCodable? = nil
        var outputText: String

        if truncation.firstLineExceedsLimit {
            let firstLine = allLines[startLine]
            let firstLineSize = formatSize(firstLine.utf8.count)
            outputText = "[Line \(startLineDisplay) is \(firstLineSize), exceeds \(formatSize(DEFAULT_MAX_BYTES)) limit. Use bash: sed -n '\(startLineDisplay)p' \(path) | head -c \(DEFAULT_MAX_BYTES)]"
            details = AnyCodable(["truncation": truncationToAnyCodable(truncation).value])
        } else if truncation.truncated {
            let endLineDisplay = startLineDisplay + truncation.outputLines - 1
            let nextOffset = endLineDisplay + 1
            outputText = truncation.content
            if truncation.truncatedBy == "lines" {
                outputText += "\n\n[Showing lines \(startLineDisplay)-\(endLineDisplay) of \(totalLines). Use offset=\(nextOffset) to continue]"
            } else {
                outputText += "\n\n[Showing lines \(startLineDisplay)-\(endLineDisplay) of \(totalLines) (\(formatSize(DEFAULT_MAX_BYTES)) limit). Use offset=\(nextOffset) to continue]"
            }
            details = AnyCodable(["truncation": truncationToAnyCodable(truncation).value])
        } else if let userLimitedLines, startLine + userLimitedLines < totalLines {
            let remaining = totalLines - (startLine + userLimitedLines)
            let nextOffset = startLine + userLimitedLines + 1
            outputText = truncation.content
            outputText += "\n\n[\(remaining) more lines in file. Use offset=\(nextOffset) to continue]"
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
