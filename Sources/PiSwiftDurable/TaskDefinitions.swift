import PiSwiftChord

/// The part of a task definition required to create a durable task.
/// The harness can add phases and execution hooks in a later order.
public struct TaskKind<Input: Codable & Sendable, Checkpoint: Codable & Sendable>: Sendable {
    public let name: String
    public let version: Double
    public let initial: @Sendable (Input) throws -> Checkpoint
    public init(name: String, version: Double, initial: @escaping @Sendable (Input) throws -> Checkpoint) {
        self.name = name
        self.version = version
        self.initial = initial
    }
}

/// Owner and placement selected when a task is created.
public struct TaskOptions: Sendable {
    public let ownership: TaskOwnership
    public let conversationId: ConversationID?
    public let background: Bool
    public init(ownership: TaskOwnership, conversationId: ConversationID? = nil, background: Bool = false) {
        self.ownership = ownership
        self.conversationId = conversationId
        self.background = background
    }
}

/// A submission before the storage assigns an ID.
public enum SubmissionCreate: Sendable {
    case input(conversationId: ConversationID, requestId: String? = nil, state: InputSubmissionState = .queued())
    case write(conversationId: ConversationID, requestId: String? = nil, state: WriteSubmissionState = .queued())
    public var conversationId: ConversationID {
        switch self { case .input(let id, _, _), .write(let id, _, _): id }
    }
    func record(id: SubmissionID) -> SubmissionRecord {
        switch self {
        case .input(let conversationId, let requestId, let state):
            .input(id: id, conversationId: conversationId, requestId: requestId, state: state)
        case .write(let conversationId, let requestId, let state):
            .write(id: id, conversationId: conversationId, requestId: requestId, state: state)
        }
    }
}

/// A typed entry draft. The kind is supplied by its token.
public struct TypedEntryDraft<Data: Codable & Sendable>: Sendable {
    public let model: [JSONValue]?
    public let data: Data?
    public let head: EntryDraftHead?
    public let edits: [ContextEdit]?
    public init(model: [JSONValue]? = nil, data: Data? = nil, head: EntryDraftHead? = nil, edits: [ContextEdit]? = nil) {
        self.model = model
        self.data = data
        self.head = head
        self.edits = edits
    }
}

/// A stored entry with decoded token data.
public struct TypedEntry<Data: Codable & Sendable>: Sendable {
    public let record: EntryRecord
    public let data: Data?
    public var id: EntryID { record.id }
    public var conversationId: ConversationID { record.conversationId }
    public var kind: String { record.kind }
    public var model: [JSONValue]? { record.model }
    public var head: EntryID? { record.head }
    public var edits: [ContextEdit]? { record.edits }
    public var byTaskId: TaskID? { record.byTaskId }
    init(_ record: EntryRecord) throws {
        self.record = record
        self.data = try record.data?.decode(Data.self)
    }
}
