import Synchronization

/// Prevents saved API values from operating after their tool call ends.
internal final class ToolInvocationLifetime: Sendable {
    private let settled = Mutex(false)
    private let callId: String

    internal init(callId: String) { self.callId = callId }

    internal func check() throws {
        try settled.withLock { value in
            if value { throw TaskDefinitionError("Tool call \(callId) has settled") }
        }
    }

    internal func end() { settled.withLock { $0 = true } }
}
