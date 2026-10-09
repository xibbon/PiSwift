/// A fixed value and source cursor captured at the attachment boundary.
public struct ReplicatedStateSourceSnapshot<Value: Sendable>: Sendable {
    /// The immutable value at this source cursor.
    public let value: Value
    /// The source sequence number captured with this value.
    public let cursor: Int

    /// Creates a source snapshot with its value and cursor.
    public init(value: Value, cursor: Int) {
        self.value = value
        self.cursor = cursor
    }
}

/// One authoritative commit. Chord publishes the value and operations without changes.
/// Values must remain immutable after publication, including shared reference data.
public struct ReplicatedStateSourceFrame<Value: Sendable>: Sendable {
    /// The source sequence number captured with this value.
    public let cursor: Int
    /// The immutable value at this source cursor.
    public let value: Value
    /// The exact ordered operations for this revision.
    public let ops: [Delta.Op]
    /// The context supplied with this source commit.
    public let context: ChordContext

    /// Creates a source frame with its exact committed operations.
    public init(cursor: Int, value: Value, ops: [Delta.Op], context: ChordContext) {
        self.cursor = cursor
        self.value = value
        self.ops = ops
        self.context = context
    }
}

/// One independent attachment to an authoritative source.
public protocol ReplicatedStateSourceAttachment<Value>: Sendable {
    /// The immutable value published by this source or attachment.
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
    /// The immutable value published by this source or attachment.
    associatedtype Value: Sendable
    /// Atomically captures the value and registers a new independent attachment.
    func attach() throws -> any ReplicatedStateSourceAttachment<Value>
}

/// Metadata for a public value delivery. The sequence is local to the attached state.
public enum ReplicatedStateDelivery: Sendable, Equatable {
    /// The initial attached value and local sequence.
    case hydrate(sequence: Int)
    /// A subsequent committed value and local sequence.
    case update(sequence: Int)

    /// The initial hydration or subsequent update delivery kind.
    public enum Kind: Sendable, Equatable {
        /// The initial attached value and local sequence.
        case hydrate
        /// A subsequent committed value and local sequence.
        case update
    }
    /// The kind of this draft or delivery.
    public var kind: Kind {
        switch self {
        /// A failure reported by this operation.
        case .hydrate: .hydrate
        /// A failure reported by this operation.
        case .update: .update
        }
    }
    /// The local sequence number of this delivery.
    public var sequence: Int {
        switch self {
        case .hydrate(let sequence), .update(let sequence): sequence
        }
    }
}

/// A source cursor outside the JavaScript safe integer range, or a cursor gap.
public enum ReplicatedStateSourceError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The snapshot cursor is outside the safe integer range.
    case invalidSnapshotCursor(Int)
    /// The frame cursor is outside the safe integer range.
    case invalidFrameCursor(Int)
    /// A frame did not follow the prior source cursor.
    case cursorGap(expected: Int, received: Int)

    /// The text description of this value or error.
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
