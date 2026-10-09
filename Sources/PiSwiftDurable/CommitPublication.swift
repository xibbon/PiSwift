import PiSwiftChord

public struct DocumentCommitChange: Sendable, Equatable {
    public let record: DocumentRecord
    public let conversationId: ConversationID?
    public let version: Int?
    public let value: JSONObject?
    public let ops: [Delta.Op]
    public let source: DocumentCopySource?
    public var type: String { source == nil ? "document" : "document.copy" }
    public init(record: DocumentRecord, conversationId: ConversationID? = nil, version: Int? = nil,
                value: JSONObject? = nil, ops: [Delta.Op] = [], source: DocumentCopySource? = nil) {
        self.record = record; self.conversationId = conversationId; self.version = version
        self.value = value; self.ops = ops; self.source = source
    }
}
public enum CommitChange: Sendable, Equatable {
    case conversation(ConversationRecord)
    case entry(EntryRecord)
    case task(TaskRecord)
    case submission(SubmissionRecord)
    case document(DocumentCommitChange)
}
public struct CommitPublication: Sendable, Equatable {
    public let seq: Seq
    public let changes: [CommitChange]
    public init(seq: Seq, changes: [CommitChange]) { self.seq = seq; self.changes = changes }
}

/// Call cancel to remove the listener. Release of this value does not remove it.
public struct SessionSubscription: Sendable {
    private let remove: @Sendable () -> Void
    internal init(_ remove: @escaping @Sendable () -> Void) { self.remove = remove }
    public func cancel() { remove() }
}
