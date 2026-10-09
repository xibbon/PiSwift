import CryptoKit
import Darwin
import Foundation
import PiSwiftCodingAgent
import Synchronization

/// An error when no session is available, or when its lock cannot be acquired.
public enum SessionLocationError: Error, Sendable, LocalizedError {
    case noSession(cwd: String)
    case alreadyOpen(directory: String, cause: POSIXError)

    public var errorDescription: String? {
        switch self {
        case .noSession(let cwd): "No durable session exists for \(cwd)"
        case .alreadyOpen(let directory, _): "Session is already open in another process: \(directory)"
        }
    }
}

/// A session directory and its kernel lock. The last reference releases the lock.
/// Swift uses `session.lock` and `flock`, with a two-second retry limit.
/// Upstream uses proper-lockfile, stale detection after ten seconds, and twelve retries.
/// The kernel releases this lock when the process dies. No stale check is needed.
public final class SessionLocation: Sendable {
    public let id: String
    public let directory: String
    public let database: String
    public let cwd: String
    public let created: Bool
    private let descriptor: Mutex<Int32?>

    fileprivate init(directory: String, cwd: String, created: Bool, descriptor: Int32) {
        self.id = URL(fileURLWithPath: directory).lastPathComponent
        self.directory = directory
        self.database = URL(fileURLWithPath: directory).appendingPathComponent("session.sqlite").path
        self.cwd = cwd
        self.created = created
        self.descriptor = Mutex(descriptor)
    }

    /// Releases the lock and closes its file. Repeated calls have no effect.
    public func release() {
        descriptor.withLock { fd in
            guard let openDescriptor = fd else { return }
            fd = nil
            _ = flock(openDescriptor, LOCK_UN)
            _ = close(openDescriptor)
        }
    }

    deinit { release() }

    // Inspect the flag while the descriptor is protected from release.
    internal var lockHasCloseOnExec: Bool {
        descriptor.withLock { fd in
            guard let fd else { return false }
            let flags = fcntl(fd, F_GETFD)
            return flags >= 0 && flags & FD_CLOEXEC != 0
        }
    }
}

/// Selects a new session, or the newest session for the real working directory.
/// `agentDirectory` permits an isolated root. By default, it uses `getAgentDir()`.
/// Swift sessions use `durable-sessions-swift` and are separate from TypeScript sessions.
public func selectSession(
    _ cwdInput: String,
    continueSession: Bool,
    agentDirectory: String? = nil
) async throws -> SessionLocation {
    // Normalize dot components before realpath, as upstream's resolve() does.
    let absolute = cwdInput.hasPrefix("/") ? cwdInput : FileManager.default.currentDirectoryPath + "/" + cwdInput
    let input = URL(fileURLWithPath: absolute).standardized.path
    guard let resolved = realpath(input, nil) else { throw sessionPOSIXError() }
    let cwd = String(cString: resolved)
    free(resolved)
    let hash = SHA256.hash(data: Data(cwd.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    let root = URL(fileURLWithPath: agentDirectory ?? getAgentDir())
        .appendingPathComponent("experimental/durable-sessions-swift")
        .appendingPathComponent(hash)
    let manager = FileManager.default
    try manager.createDirectory(at: root, withIntermediateDirectories: true)

    let directory: URL
    if continueSession {
        let entries = try manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        let candidates = try entries.filter { entry in
            guard sessionDirectoryNameMatches(entry.lastPathComponent) else { return false }
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        guard let newest = candidates.max(by: { $0.lastPathComponent < $1.lastPathComponent }) else {
            throw SessionLocationError.noSession(cwd: cwd)
        }
        directory = root.appendingPathComponent(newest.lastPathComponent)
    } else {
        let milliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
        let id = String(format: "%013lld", milliseconds) + "-" + UUID().uuidString.lowercased()
        directory = root.appendingPathComponent(id)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    let lockPath = directory.appendingPathComponent("session.lock").path
    let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard fd >= 0 else {
        throw SessionLocationError.alreadyOpen(directory: directory.path, cause: sessionPOSIXError())
    }
    var transferred = false
    defer { if !transferred { _ = close(fd) } }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while true {
        try Task.checkCancellation()
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            let location = SessionLocation(directory: directory.path, cwd: cwd, created: !continueSession, descriptor: fd)
            transferred = true
            return location
        }
        let cause = sessionPOSIXError()
        guard (cause.code == .EWOULDBLOCK || cause.code == .EINTR), clock.now < deadline else {
            throw SessionLocationError.alreadyOpen(directory: directory.path, cause: cause)
        }
        try await clock.sleep(until: min(clock.now.advanced(by: .milliseconds(100)), deadline))
    }
}

private func sessionPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

// This is the upstream ASCII pattern: ^\d{13}-[0-9a-f-]{36}$.
private func sessionDirectoryNameMatches(_ name: String) -> Bool {
    let bytes = Array(name.utf8)
    return bytes.count == 50 && bytes[13] == 45
        && bytes.prefix(13).allSatisfy { (48...57).contains($0) }
        && bytes.suffix(36).allSatisfy { (48...57).contains($0) || (97...102).contains($0) || $0 == 45 }
}
