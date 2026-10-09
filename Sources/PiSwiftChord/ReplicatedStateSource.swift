/// A fixed value and source cursor captured at the attachment boundary.
public struct ReplicatedStateSourceSnapshot<Value: Sendable>: Sendable {
    public let value: Value
    public let cursor: Int

    public init(value: Value, cursor: Int) {
        self.value = value
        self.cursor = cursor
    }
}

/// One authoritative commit. Chord publishes the value and operations without changes.
/// Values must remain immutable after publication, including shared reference data.
public struct ReplicatedStateSourceFrame<Value: Sendable>: Sendable {
    public let cursor: Int
    public let value: Value
    public let ops: [Delta.Op]
    public let context: ChordContext

    public init(cursor: Int, value: Value, ops: [Delta.Op], context: ChordContext) {
        self.cursor = cursor
        self.value = value
        self.ops = ops
        self.context = context
    }
}

/// One independent attachment to an authoritative source.
public protocol ReplicatedStateSourceAttachment<Value>: Sendable {
    associatedtype Value: Sendable
    /// Capture this snapshot atomically with registration for subsequent commits.
    var snapshot: ReplicatedStateSourceSnapshot<Value> { get }
    /// Install the sole listener once. Drain buffered commits synchronously in order.
    /// Continue delivery in commit order, including reentrant commits, until disposal.
    /// Do not hold a source lock while the listener runs.
    func activate(_ listener: @escaping @Sendable (ReplicatedStateSourceFrame<Value>) -> Void) throws
    /// Stop delivery and release resources. This method must be idempotent.
    func dispose()
}

/// An authoritative immutable source. Each call creates an independent attachment.
public protocol ReplicatedStateSource<Value>: Sendable {
    associatedtype Value: Sendable
    func attach() throws -> any ReplicatedStateSourceAttachment<Value>
}

/// Metadata for a public value delivery. The sequence is local to the attached state.
public enum ReplicatedStateDelivery: Sendable, Equatable {
    case hydrate(sequence: Int)
    case update(sequence: Int)

    public enum Kind: Sendable, Equatable { case hydrate, update }
    public var kind: Kind {
        switch self {
        case .hydrate: .hydrate
        case .update: .update
        }
    }
    public var sequence: Int {
        switch self {
        case .hydrate(let sequence), .update(let sequence): sequence
        }
    }
}

/// A source cursor outside the JavaScript safe integer range, or a cursor gap.
public enum ReplicatedStateSourceError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidSnapshotCursor(Int)
    case invalidFrameCursor(Int)
    case cursorGap(expected: Int, received: Int)

    public var description: String {
        switch self {
        case .invalidSnapshotCursor:
            "Replicated state source snapshot cursor must be a safe integer"
        case .invalidFrameCursor:
            "Replicated state source frame cursor must be a safe integer"
        case let .cursorGap(expected, received):
            "Replicated state source cursor has a gap: expected \(expected), received \(received)"
        }
    }
}

/// Attach once and activate the source. On setup failure, dispose and rethrow.
/// The default error handler ignores errors. A throwing error handler is also isolated;
/// its error is ignored because Swift has no global error handler for this state.
public func replicatedState<Value: Sendable>(
    _ source: some ReplicatedStateSource<Value>,
    onError: @escaping @Sendable (any Error) throws -> Void = { _ in }
) throws -> AttachedReplicatedState<Value> {
    let attachment = try source.attach()
    do {
        let state = try AttachedReplicatedState(attachment: attachment, onError: onError)
        try state.activate()
        return state
    } catch {
        attachment.dispose()
        throw error
    }
}
