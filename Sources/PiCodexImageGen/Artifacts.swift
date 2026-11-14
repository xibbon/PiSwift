import Foundation
import PiSwiftAI
import PiSwiftCodingAgent
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Port of pi-codex-image-gen `src/artifacts.ts`. Completed originals stay
// until user or OS cleanup; reload, shutdown and branch changes must not
// remove them. Only this call's incomplete reservation is cleaned up.

let artifactEntryType = "codex-image-artifact"
let reservationEntryType = "codex-image-artifact-reservation"
private let maxManifestBytes = 8192
private let artifactMimeTypes = ["image/png", "image/jpeg", "image/webp"]

struct ImageArtifact: Sendable, Equatable {
    var path: String
    var mimeType: String
    var byteCount: Int

    var dictionary: [String: Any] { ["path": path, "mimeType": mimeType, "byteCount": byteCount] }
}

struct ArtifactRecord: Sendable, Equatable {
    var artifact: ImageArtifact
    var toolCallId: String

    var dictionary: [String: Any] { ["artifact": artifact.dictionary, "toolCallId": toolCallId] }
}

struct ArtifactReservationRecord: Sendable, Equatable {
    var path: String
    var mimeType: String
    var toolCallId: String

    var dictionary: [String: Any] { ["path": path, "mimeType": mimeType, "toolCallId": toolCallId] }
}

private func hasControlCharacter(_ value: String) -> Bool {
    value.unicodeScalars.contains { $0.value <= 0x1f || $0.value == 0x7f }
}

/// Validate metadata from a session file. Session files can be edited
/// externally, so never spread their data into tool results.
func artifactRecord(_ value: Any?) -> ArtifactRecord? {
    guard let record = value as? [String: Any], let artifact = record["artifact"] as? [String: Any],
          let path = artifact["path"] as? String, path.utf8.count <= 4096, path.hasPrefix("/"), !hasControlCharacter(path),
          let mimeType = artifact["mimeType"] as? String, artifactMimeTypes.contains(mimeType),
          let byteCount = integer(artifact["byteCount"]), byteCount > 0, byteCount <= codexMaxImageBytes,
          let toolCallId = record["toolCallId"] as? String, toolCallId.utf8.count <= 256 else { return nil }
    return ArtifactRecord(artifact: ImageArtifact(path: path, mimeType: mimeType, byteCount: byteCount), toolCallId: toolCallId)
}

func artifactReservation(_ value: Any?) -> ArtifactReservationRecord? {
    guard let record = value as? [String: Any] else { return nil }
    // Reuse the path/MIME/call-ID validation without accepting a completed image.
    guard let validated = artifactRecord([
        "artifact": ["path": record["path"] as Any, "mimeType": record["mimeType"] as Any, "byteCount": 1],
        "toolCallId": record["toolCallId"] as Any,
    ]) else { return nil }
    return ArtifactReservationRecord(path: validated.artifact.path, mimeType: validated.artifact.mimeType,
                                     toolCallId: validated.toolCallId)
}

func integer(_ value: Any?) -> Int? {
    if value is Bool { return nil }
    if let int = value as? Int { return int }
    if let double = value as? Double, double.rounded() == double, abs(double) < 1e15 { return Int(double) }
    return nil
}

/// Only a published, bounded manifest marks a reservation ready.
func readArtifactManifest(_ reservation: ArtifactReservationRecord) -> ArtifactRecord? {
    let manifestPath = reservation.path + ".json"
    let fd = open(manifestPath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var info = stat()
    var visible = stat()
    guard fstat(fd, &info) == 0, lstat(manifestPath, &visible) == 0,
          (info.st_mode & S_IFMT) == S_IFREG, (visible.st_mode & S_IFMT) == S_IFREG,
          info.st_ino == visible.st_ino, info.st_dev == visible.st_dev, info.st_size <= maxManifestBytes else { return nil }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: maxManifestBytes + 1)
    while data.count <= maxManifestBytes {
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, maxManifestBytes + 1 - data.count) }
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    guard data.count <= maxManifestBytes, let json = try? JSONSerialization.jsonObject(with: data),
          let record = artifactRecord(json) else { return nil }
    // The reservation MIME is requested, while the completed MIME is actual.
    return record.toolCallId == reservation.toolCallId ? record : nil
}

/// Validated artifact records on the branch, newest last, one per path.
func branchArtifacts(_ entries: [SessionEntry]) -> [ArtifactRecord] {
    var order: [String] = []
    var records: [String: ArtifactRecord] = [:]
    for entry in entries {
        guard case .custom(let custom) = entry else { continue }
        let record: ArtifactRecord?
        if custom.customType == reservationEntryType {
            record = artifactReservation(custom.data?.value).flatMap(readArtifactManifest)
        } else if custom.customType == artifactEntryType {
            record = artifactRecord(custom.data?.value)
        } else {
            record = nil
        }
        guard let record else { continue }
        order.removeAll { $0 == record.artifact.path }
        order.append(record.artifact.path)
        records[record.artifact.path] = record
    }
    return order.compactMap { records[$0] }
}

// MARK: - Reservation

/// Private storage reserved before quota is spent.
final class ArtifactReservation: Sendable {
    let path: String
    private let dir: String
    private struct State: Sendable {
        var fd: Int32
        var committed = false
        var outputPath: String
    }
    private let state: LockedState<State>

    private init(path: String, dir: String, fd: Int32) {
        self.path = path
        self.dir = dir
        self.state = LockedState(State(fd: fd, outputPath: path))
    }

    static func reserve(fileExtension: String, root: String = NSTemporaryDirectory()) throws -> ArtifactReservation {
        guard ["png", "jpg", "webp"].contains(fileExtension) else { throw CodexImageError("Unsupported artifact format.") }
        let absoluteRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        guard absoluteRoot.utf8.count <= 4000, !hasControlCharacter(absoluteRoot) else {
            throw CodexImageError("Image artifact storage path is unsupported. No generation request was made.")
        }
        var template = Array(join(absoluteRoot, "pi-codex-image-XXXXXX").utf8CString)
        guard let created = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else {
            throw CodexImageError("Image artifact storage is unavailable. No generation request was made.")
        }
        let dir = String(cString: created)
        let path = join(dir, "original.\(fileExtension)")
        let fd = open(path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            try? FileManager.default.removeItem(atPath: dir)
            throw CodexImageError("Image artifact storage is unavailable. No generation request was made.")
        }
        return ArtifactReservation(path: path, dir: dir, fd: fd)
    }

    func commit(_ bytes: Data, mimeType: String) throws -> ImageArtifact {
        try state.withLock { state in
            guard !state.committed else { throw CodexImageError("Image artifact was already committed.") }
            guard let format = OutputFormat(mimeType: mimeType) else { throw CodexImageError("Unsupported artifact MIME type.") }
            let actualPath = join(dir, "original.\(format.fileExtension)")
            let output: Int32
            if actualPath == path {
                output = state.fd
            } else {
                output = open(actualPath, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
                guard output >= 0 else { throw CodexImageError(posixMessage(actualPath)) }
            }
            state.outputPath = actualPath
            defer { if output != state.fd { close(output) } }
            try writeAll(output, bytes)
            _ = fsync(output)
            var info = stat()
            var visible = stat()
            guard fstat(output, &info) == 0, lstat(actualPath, &visible) == 0, (visible.st_mode & S_IFMT) == S_IFREG,
                  info.st_ino == visible.st_ino, info.st_dev == visible.st_dev, Int(visible.st_size) == bytes.count else {
                throw CodexImageError("Image artifact is no longer available at its reserved path.")
            }
            state.committed = true
            return ImageArtifact(path: actualPath, mimeType: mimeType, byteCount: bytes.count)
        }
    }

    /// Write the recovery manifest next to the reserved path.
    func publish(_ record: ArtifactRecord) throws {
        guard let validated = artifactRecord(record.dictionary) else { throw CodexImageError("Invalid artifact recovery metadata.") }
        let json = try JSONSerialization.data(withJSONObject: validated.dictionary, options: [.sortedKeys])
        guard json.count <= maxManifestBytes else { throw CodexImageError("Artifact recovery metadata exceeds the size limit.") }
        try writeExclusive(json, to: path + ".json")
        let outputPath = state.withLock { $0.outputPath }
        if record.artifact.path != path { try? FileManager.default.removeItem(atPath: path) }
        if outputPath != path && record.artifact.path != outputPath { try? FileManager.default.removeItem(atPath: outputPath) }
        // Retain fallback manifests too, never incomplete originals.
        state.withLock { $0.committed = true }
    }

    func dispose() {
        let (fd, committed) = state.withLock { state -> (Int32, Bool) in
            defer { state.fd = -1 }
            return (state.fd, state.committed)
        }
        if fd >= 0 { close(fd) }
        if !committed { try? FileManager.default.removeItem(atPath: dir) }
    }
}
