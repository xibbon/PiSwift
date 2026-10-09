/// A table read after the first table write in a transaction.
public struct ReadAfterWrite: Error, Sendable, Equatable, CustomStringConvertible {
    /// The transaction method that attempted a prohibited table read.
    public let method: String
    /// Records the transaction method that attempted a table read after a write.
    public init(_ method: String) { self.method = method }
    /// Text that describes this value or error to the caller.
    public var description: String { "Tx.\(method)() cannot read tables after the first table write" }
}

/// Errors from the Session and its transaction. Messages follow the upstream kernel.
public enum SessionError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Session is closed.
    case closed
    /// Session is poisoned by a failed commit after storage admission; reopen it.
    case poisoned
    /// The submission or transaction already has a final state.
    case settled
    /// Session commit callback settled before its pending Tx operations.
    case pendingOperations
    /// Uses the supplied model message or error text.
    case message(String)

    /// Text that describes this value or error to the caller.
    public var description: String {
        switch self {
        case .closed: "Session is closed"
        case .poisoned: "Session is poisoned by a failed commit after storage admission; reopen it"
        case .settled: "Transaction has settled"
        case .pendingOperations: "Session commit callback settled before its pending Tx operations"
        case .message(let message): message
        }
    }
}
