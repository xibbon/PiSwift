import Foundation
import PiSwiftAI

public enum FileProcessorError: LocalizedError, Sendable {
    case fileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        }
    }
}

public struct FileProcessingResult: Sendable {
    public var textContent: String
    public var imageAttachments: [ImageContent]

    public init(textContent: String, imageAttachments: [ImageContent]) {
        self.textContent = textContent
        self.imageAttachments = imageAttachments
    }
}

public struct ProcessFileOptions: Sendable {
    public var autoResizeImages: Bool?
    public var blockImages: Bool?
    public var resizeOptions: ModelImageResizeOptions?

    public init(autoResizeImages: Bool? = nil, blockImages: Bool? = nil, resizeOptions: ModelImageResizeOptions? = nil) {
        self.autoResizeImages = autoResizeImages
        self.blockImages = blockImages
        self.resizeOptions = resizeOptions
    }
}

public func processFileArguments(_ fileArgs: [String], options: ProcessFileOptions? = nil) throws -> FileProcessingResult {
    let autoResizeImages = options?.autoResizeImages ?? true
    let blockImages = options?.blockImages ?? false
    var textContent = ""
    var imageAttachments: [ImageContent] = []

    for fileArg in fileArgs {
        let resolvedPath = resolveReadPath(fileArg, cwd: FileManager.default.currentDirectoryPath)
        let absolutePath = URL(fileURLWithPath: resolvedPath).standardizedFileURL.path

        guard FileManager.default.fileExists(atPath: absolutePath) else {
            throw FileProcessorError.fileNotFound(absolutePath)
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: absolutePath)
        if let size = attrs[.size] as? Int, size == 0 {
            continue
        }

        if let mimeType = detectSupportedImageMimeType(fromFile: absolutePath) {
            if blockImages {
                if let data = "[blockImages] Skipping image file: \(absolutePath)\n".data(using: .utf8) {
                    FileHandle.standardError.write(data)
                }
                continue
            }
            let rawImageData = try Data(contentsOf: URL(fileURLWithPath: absolutePath))
            let data = applyExifOrientation(rawImageData)
            let base64 = data.base64EncodedString()

            let attachment: ImageContent
            var dimensionNote: String? = nil

            if autoResizeImages {
                let limits = ImageResizeOptions(modelProfile: options?.resizeOptions)
                let resized = resizeImage(ImageContent(data: base64, mimeType: mimeType), options: limits)
                guard imageFitsResizeLimits(resized, options: limits) else {
                    textContent += "<file name=\"\(absolutePath)\">[Image omitted: could not be resized below the inline image size limit.]</file>\n"
                    continue
                }
                dimensionNote = formatDimensionNote(resized)
                attachment = ImageContent(data: resized.data, mimeType: resized.mimeType)
            } else {
                attachment = ImageContent(data: base64, mimeType: mimeType)
            }

            imageAttachments.append(attachment)
            if let dimensionNote {
                textContent += "<file name=\"\(absolutePath)\">\(dimensionNote)</file>\n"
            } else {
                textContent += "<file name=\"\(absolutePath)\"></file>\n"
            }
        } else {
            let content = try String(contentsOfFile: absolutePath, encoding: .utf8)
            textContent += "<file name=\"\(absolutePath)\">\n\(content)\n</file>\n"
        }
    }

    return FileProcessingResult(textContent: textContent, imageAttachments: imageAttachments)
}
