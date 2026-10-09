/// A table read after the first table write in a transaction.
public struct ReadAfterWrite: Error, Sendable, Equatable, CustomStringConvertible {
    public let method: String
    public init(_ method: String) { self.method = method }
    public var description: String { "Tx.\(method)() cannot read tables after the first table write" }
}

/// Errors from the Session and its transaction. Messages follow the upstream kernel.
public enum SessionError: Error, Sendable, Equatable, CustomStringConvertible {
    case closed
    case poisoned
    case settled
    case pendingOperations
    case message(String)

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
