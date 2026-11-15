import Foundation
import PiSwiftCodingAgent
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Port of `resolveSaveConfig` and `saveImage` in pi-codex-image-gen. Only the
// per-call `save` and `saveDir` parameters are kept. There is no config file
// and no environment override.

enum SaveMode: String, Sendable, CaseIterable {
    case none, project, global, custom
}

let defaultSaveMode = SaveMode.global

struct SaveConfig: Sendable, Equatable {
    var mode: SaveMode
    var outputDir: String?
}

/// Keep `[A-Za-z0-9_-]`, replace other characters with `_`, drop trailing `_`.
func sanitizePathPart(_ value: String, fallback: String) -> String {
    var result = String(String.UnicodeScalarView(value.unicodeScalars.prefix(128).map { scalar -> Unicode.Scalar in
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "_", "-": return scalar
        default: return "_"
        }
    }))
    while result.hasSuffix("_") { result.removeLast() }
    return result.isEmpty ? fallback : result
}

func resolveSaveConfig(save: String?, saveDir: String?, cwd: String, sessionId: String,
                       agentDir: String = getAgentDir()) throws -> SaveConfig {
    let raw = save ?? defaultSaveMode.rawValue
    guard let mode = SaveMode(rawValue: raw) else {
        throw CodexImageError("Invalid save mode: \(raw). Expected one of \(SaveMode.allCases.map(\.rawValue).joined(separator: ", ")).")
    }
    let session = sanitizePathPart(sessionId, fallback: "session")
    switch mode {
    case .none:
        return SaveConfig(mode: mode)
    case .project:
        return SaveConfig(mode: mode, outputDir: join(cwd, CONFIG_DIR_NAME, "generated-images", session))
    case .global:
        return SaveConfig(mode: mode, outputDir: join(agentDir, "generated-images", session))
    case .custom:
        guard let dir = saveDir, !dir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexImageError("save=custom requires saveDir.")
        }
        return SaveConfig(mode: mode, outputDir: join(URL(fileURLWithPath: resolveToCwd(dir, cwd: cwd)).standardizedFileURL.path, session))
    }
}

func join(_ parts: String...) -> String {
    parts.dropFirst().reduce(URL(fileURLWithPath: parts[0])) { $0.appendingPathComponent($1) }.path
}

func imagePath(format: OutputFormat, outputDir: String, imageCallId: String) -> String {
    join(outputDir, "\(sanitizePathPart(imageCallId, fallback: "image_generation")).\(format.fileExtension)")
}

/// Write a new file with mode 0600 in a directory with mode 0700. An existing
/// file is never overwritten.
func saveImage(_ bytes: Data, format: OutputFormat, outputDir: String, imageCallId: String) async throws -> String {
    let path = imagePath(format: format, outputDir: outputDir, imageCallId: imageCallId)
    try await writeNewImage(bytes, path: path, directory: outputDir)
    return path
}

/// Create `directory` with mode 0700, then write a new file with mode 0600.
func writeNewImage(_ bytes: Data, path: String, directory: String) async throws {
    try await FileMutationQueue.shared.withFileLock(path) {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try writeExclusive(bytes, to: path)
    }
}

/// `O_CREAT | O_EXCL | O_NOFOLLOW`, mode 0600, then fsync.
func writeExclusive(_ bytes: Data, to path: String) throws {
    let fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw CodexImageError(posixMessage(path)) }
    defer { close(fd) }
    try writeAll(fd, bytes)
    _ = fsync(fd)
}

func writeAll(_ fd: Int32, _ bytes: Data) throws {
    try bytes.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                throw CodexImageError(String(cString: strerror(errno)))
            }
            offset += written
        }
    }
}

func posixMessage(_ path: String) -> String {
    "\(String(cString: strerror(errno))): \(path)"
}
