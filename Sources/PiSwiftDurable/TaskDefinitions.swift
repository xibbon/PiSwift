import PiSwiftChord

/// The part of a task definition required to create a durable task.
/// The harness can add phases and execution hooks in a later order.
public struct TaskKind<Input: Codable & Sendable, Checkpoint: Codable & Sendable>: Sendable {
    /// The stable name used to resolve this definition in the registry.
    public let name: String
    /// The stored schema or task definition version.
    public let version: Double
    /// Creates the encoded initial checkpoint from task input.
    public let initial: @Sendable (Input) throws -> Checkpoint
    /// Defines the stored task name, version, and initial checkpoint factory.
    public init(name: String, version: Double, initial: @escaping @Sendable (Input) throws -> Checkpoint) {
        self.name = name
        self.version = version
        self.initial = initial
    }
}

/// Owner and placement selected when a task is created.
public struct TaskOptions: Sendable {
    /// The owner edge assigned when this record is created.
    public let ownership: TaskOwnership
    /// The conversation that owns or is addressed by this value.
    public let conversationId: ConversationID?
    /// Whether this task can outlive ordinary conversation work.
    public let background: Bool
    /// Selects task ownership, optional conversation, and background lifetime.
    public init(ownership: TaskOwnership, conversationId: ConversationID? = nil, background: Bool = false) {
        self.ownership = ownership
        self.conversationId = conversationId
        self.background = background
    }
}

/// A submission before the storage assigns an ID.
public enum SubmissionCreate: Sendable {
    /// Stores user content and its admission policy.
    case input(conversationId: ConversationID, requestId: String? = nil, state: InputSubmissionState = .queued())
    /// Stores an entry write request.
    case write(conversationId: ConversationID, requestId: String? = nil, state: WriteSubmissionState = .queued())
    /// The conversation that owns or is addressed by this value.
    public var conversationId: ConversationID {
        switch self { case .input(let id, _, _), .write(let id, _, _): id }
    }
    /// Records this model request for later test inspection.
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
    /// Opaque model messages to contribute when this entry is appended.
    public let model: [JSONValue]?
    /// Application data retained with the durable entry.
    public let data: Data?
    /// The entry that defines the active model-context lower bound.
    public let head: EntryDraftHead?
    /// Context changes applied to earlier visible entries.
    public let edits: [ContextEdit]?
    /// Creates an entry draft with typed application data.
    public init(model: [JSONValue]? = nil, data: Data? = nil, head: EntryDraftHead? = nil, edits: [ContextEdit]? = nil) {
        self.model = model
        self.data = data
        self.head = head
        self.edits = edits
    }
}

/// A stored entry with decoded token data.
public struct TypedEntry<Data: Codable & Sendable>: Sendable {
    /// The durable record from which this typed value is derived.
    public let record: EntryRecord
    /// The decoded application data of the stored entry.
    public let data: Data?
    /// The stable identifier of this record or handle.
    public var id: EntryID { record.id }
    /// The conversation that owns or is addressed by this value.
    public var conversationId: ConversationID { record.conversationId }
    /// The stored record or document kind.
    public var kind: String { record.kind }
    /// The stored provider and model reference or entry model contribution.
    public var model: [JSONValue]? { record.model }
    /// The entry that defines the active model-context lower bound.
    public var head: EntryID? { record.head }
    /// Context changes applied to earlier visible entries.
    public var edits: [ContextEdit]? { record.edits }
    /// Graph nodes indexed by their task IDs.
    public var byTaskId: TaskID? { record.byTaskId }
    init(_ record: EntryRecord) throws {
        self.record = record
        self.data = try record.data?.decode(Data.self)
    }
}
