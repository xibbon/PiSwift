import Foundation
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Port of the input and output image helpers in pi-codex-image-gen
// (`resolveInputImages`, `selectRecentImages`, `readInputImage`,
// `decodeImageData`, and `detectOutputFormat` from `src/image-output.ts`).

let codexMaxEditImages = 5
let codexMaxInputImageBytes = 20 * 1024 * 1024
let codexMaxTotalInputBytes = 50 * 1024 * 1024

enum OutputFormat: String, Sendable, CaseIterable {
    case png, jpeg, webp

    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    var mimeType: String { "image/\(rawValue)" }

    init?(mimeType: String) {
        guard let format = OutputFormat.allCases.first(where: { $0.mimeType == mimeType }) else { return nil }
        self = format
    }
}

private let pngSignature: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]

func hasSignature(_ bytes: Data, of format: OutputFormat) -> Bool {
    switch format {
    case .png:
        return bytes.count >= 8 && Array(bytes.prefix(8)) == pngSignature
    case .jpeg:
        return bytes.count >= 3 && Array(bytes.prefix(3)) == [0xff, 0xd8, 0xff]
    case .webp:
        guard bytes.count >= 12 else { return false }
        let start = bytes.startIndex
        return bytes[start..<start + 4] == Data("RIFF".utf8) && bytes[start + 8..<start + 12] == Data("WEBP".utf8)
    }
}

func formatFromSignature(_ bytes: Data) -> OutputFormat? {
    OutputFormat.allCases.first { hasSignature(bytes, of: $0) }
}

func detectOutputFormat(_ bytes: Data) throws -> OutputFormat {
    guard let format = formatFromSignature(bytes) else {
        throw CodexImageError("Codex returned an unsupported image format. No automatic retry was made.")
    }
    return format
}

/// Strict base64 decoding with a size bound and a file-signature check.
func decodeImageData(_ base64: String, format: OutputFormat? = nil) throws -> Data {
    if base64.utf8.count > codexMaxBase64ImageChars { throw CodexImageError("Codex image exceeded the 32 MiB size limit.") }
    let value = base64.trimmingCharacters(in: .whitespacesAndNewlines)
    let invalid = CodexImageError("Codex returned invalid base64 image data.")
    guard !value.isEmpty, value.utf8.count % 4 == 0, value.unicodeScalars.allSatisfy(isBase64Scalar),
          let bytes = Data(base64Encoded: value), !bytes.isEmpty, bytes.count <= codexMaxImageBytes,
          bytes.base64EncodedString() == value else { throw invalid }
    let valid = format.map { hasSignature(bytes, of: $0) } ?? (formatFromSignature(bytes) != nil)
    guard valid else { throw CodexImageError("Codex returned image data that does not match \(format?.rawValue ?? "a supported format").") }
    return bytes
}

private func isBase64Scalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar {
    case "A"..."Z", "a"..."z", "0"..."9", "+", "/", "=": return true
    default: return false
    }
}

// MARK: - Paths

func resolveUnderCwd(_ cwd: String, _ path: String, home: String = NSHomeDirectory()) -> String {
    if path == "~" { return home }
    if path.hasPrefix("~/") { return URL(fileURLWithPath: home).appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL.path }
    if path.hasPrefix("/") { return path }
    return URL(fileURLWithPath: cwd).appendingPathComponent(path).standardizedFileURL.path
}

// MARK: - Reading references

/// Read a regular file of at most 20 MiB. `O_NONBLOCK` keeps a named pipe
/// from blocking before the regular-file check.
func readInputImage(_ path: String) throws -> Data {
    let fd = open(path, O_RDONLY | O_NONBLOCK)
    guard fd >= 0 else { throw CodexImageError(String(cString: strerror(errno))) }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw CodexImageError(String(cString: strerror(errno))) }
    guard (info.st_mode & S_IFMT) == S_IFREG else { throw CodexImageError("Referenced images must be regular files.") }
    guard Int(info.st_size) <= codexMaxInputImageBytes else { throw CodexImageError("Referenced image exceeds 20 MiB.") }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, min($0.count, codexMaxInputImageBytes + 1 - data.count)) }
        if count < 0 {
            if errno == EINTR { continue }
            throw CodexImageError(String(cString: strerror(errno)))
        }
        if count == 0 { break }
        data.append(buffer, count: count)
        if data.count > codexMaxInputImageBytes { throw CodexImageError("Referenced image exceeds 20 MiB.") }
    }
    return data
}

func mimeFromBytes(_ bytes: Data, path: String) throws -> String {
    guard let format = formatFromSignature(bytes) else {
        throw CodexImageError("Referenced image is unavailable or unsupported: \(path)")
    }
    return format.mimeType
}

// MARK: - Recent conversation images

enum RecentImage: Sendable, Equatable {
    case inline(InputImage)
    case artifact(path: String, mimeType: String)
}

/// One branch item that can hold images, in branch order.
enum ConversationImageSource: Sendable {
    case blocks([ContentBlock])
    case artifact(path: String, mimeType: String)
}

/// The most recent `count` images, returned oldest first.
func selectRecentImages(_ sources: [ConversationImageSource], count: Int) -> [RecentImage] {
    var images: [RecentImage] = []
    for source in sources.reversed() where images.count < count {
        switch source {
        case .artifact(let path, let mimeType):
            images.append(.artifact(path: path, mimeType: mimeType))
        case .blocks(let blocks):
            for block in blocks.reversed() where images.count < count {
                if case .image(let image) = block {
                    images.append(.inline(InputImage(data: image.data, mimeType: image.mimeType)))
                }
            }
        }
    }
    return images.reversed()
}

func conversationBlocks(_ message: AgentMessage) -> [ContentBlock] {
    switch message {
    case .user(let user):
        if case .blocks(let blocks) = user.content { return blocks }
        return []
    case .toolResult(let result):
        return result.content
    case .assistant(let assistant):
        return assistant.content
    default:
        return []
    }
}

/// Resolve the requested reference images. Selectors stay cheap until the
/// caller holds an admission slot; this function loads the bytes.
func resolveInputImages(paths: [String], count: Int?, cwd: String, recent: [RecentImage]) throws -> [InputImage] {
    if !paths.isEmpty && count != nil {
        throw CodexImageError("Provide only one of referencedImagePaths or numLastImagesToInclude.")
    }
    if paths.count > codexMaxEditImages {
        throw CodexImageError("referencedImagePaths accepts at most \(codexMaxEditImages) paths.")
    }
    if !paths.isEmpty {
        var images: [InputImage] = []
        var total = 0
        for path in paths {
            let normalized = path.hasPrefix("@") ? String(path.dropFirst()) : path
            let absolute = resolveUnderCwd(cwd, normalized)
            let bytes: Data
            do {
                bytes = try readInputImage(absolute)
            } catch {
                throw CodexImageError("Unable to read referenced image at \(absolute): \(error.localizedDescription)")
            }
            total += bytes.count
            if total > codexMaxTotalInputBytes { throw CodexImageError("Referenced images exceed 50 MiB in total.") }
            images.append(InputImage(data: bytes.base64EncodedString(), mimeType: try mimeFromBytes(bytes, path: absolute)))
        }
        return images
    }
    guard let count else { return [] }
    guard (1...codexMaxEditImages).contains(count) else {
        throw CodexImageError("numLastImagesToInclude must be between 1 and \(codexMaxEditImages).")
    }
    guard recent.count == count else {
        throw CodexImageError("Requested the last \(count) conversation images, but only \(recent.count) were available.")
    }
    var images: [InputImage] = []
    var total = 0
    for selected in recent {
        let image: InputImage
        switch selected {
        case .inline(let inline): image = inline
        case .artifact(let path, let mimeType):
            image = InputImage(data: try readInputImage(path).base64EncodedString(), mimeType: mimeType)
        }
        if image.data.utf8.count > (codexMaxInputImageBytes + 2) / 3 * 4 { throw CodexImageError("Conversation image exceeds 20 MiB.") }
        guard let format = OutputFormat(mimeType: image.mimeType) else {
            throw CodexImageError("Conversation image has an unsupported format.")
        }
        let bytes = try decodeImageData(image.data, format: format)
        if bytes.count > codexMaxInputImageBytes { throw CodexImageError("Conversation image exceeds 20 MiB.") }
        total += bytes.count
        if total > codexMaxTotalInputBytes { throw CodexImageError("Conversation images exceed 50 MiB in total.") }
        images.append(image)
    }
    return images
}
