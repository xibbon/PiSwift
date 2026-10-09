import PiSwiftChord

/// The metadata and JSON operations published for one committed document.
public struct DocumentCommitChange: Sendable, Equatable {
    /// The durable record from which this typed value is derived.
    public let record: DocumentRecord
    /// The owner conversation for a conversation-scoped change, when present.
    public let conversationId: ConversationID?
    /// The committed document schema version, when supplied.
    public let version: Int?
    /// The complete object supplied when a replacement is published.
    public let value: JSONObject?
    /// The JSON operations applied by this commit, when supplied.
    public let ops: [Delta.Op]
    /// The source document and point selected for a fork copy.
    public let source: DocumentCopySource?
    /// The document-change tag; document.copy identifies a change copied from another incarnation.
    public var type: String { source == nil ? "document" : "document.copy" }
    /// Records the committed document metadata and JSON operations.
    public init(record: DocumentRecord, conversationId: ConversationID? = nil, version: Int? = nil,
                value: JSONObject? = nil, ops: [Delta.Op] = [], source: DocumentCopySource? = nil) {
        self.record = record; self.conversationId = conversationId; self.version = version
        self.value = value; self.ops = ops; self.source = source
    }
}
/// One record or document change published after a successful commit.
public enum CommitChange: Sendable, Equatable {
    /// Publishes a new conversation record.
    case conversation(ConversationRecord)
    /// Publishes an appended transcript entry.
    case entry(EntryRecord)
    /// Publishes the new complete task record.
    case task(TaskRecord)
    /// Publishes the new complete submission record.
    case submission(SubmissionRecord)
    /// Publishes document metadata and JSON operations.
    case document(DocumentCommitChange)
}
/// The commit sequence and ordered changes visible to session observers.
public struct CommitPublication: Sendable, Equatable {
    /// The strictly increasing sequence assigned to the commit.
    public let seq: Seq
    /// The ordered changes published by this commit.
    public let changes: [CommitChange]
    /// Pairs a successful commit sequence with its ordered changes.
    public init(seq: Seq, changes: [CommitChange]) { self.seq = seq; self.changes = changes }
}

/// Call cancel to remove the listener. Release of this value does not remove it.
public struct SessionSubscription: Sendable {
    private let remove: @Sendable () -> Void
    internal init(_ remove: @escaping @Sendable () -> Void) { self.remove = remove }
    /// Removes this session listener. Later cancel calls have no effect.
    public func cancel() { remove() }
}
