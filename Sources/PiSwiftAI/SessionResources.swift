import Foundation

public typealias SessionResourceCleanup = @Sendable (String?) throws -> Void

private let sessionResourceCleanups = LockedState<[(UUID, SessionResourceCleanup)]>([])

/// Contains all errors from a session resource cleanup operation.
public struct SessionResourceCleanupError: Error, Sendable {
    public let errors: [any Error]
    public var message: String { "Failed to cleanup session resources" }
}

/// Register a cleanup function. Call the returned function to remove it.
public func registerSessionResourceCleanup(_ cleanup: @escaping SessionResourceCleanup) -> @Sendable () -> Void {
    let id = UUID()
    sessionResourceCleanups.withLock { $0.append((id, cleanup)) }
    return { sessionResourceCleanups.withLock { $0.removeAll { $0.0 == id } } }
}

/// Release resources for one session, or all sessions if no ID is supplied.
public func cleanupSessionResources(_ sessionId: String? = nil) throws {
    let cleanups = sessionResourceCleanups.withLock { $0.map { $0.1 } }
    var errors: [any Error] = []
    for cleanup in cleanups {
        do { try cleanup(sessionId) } catch { errors.append(error) }
    }
    if !errors.isEmpty { throw SessionResourceCleanupError(errors: errors) }
}
