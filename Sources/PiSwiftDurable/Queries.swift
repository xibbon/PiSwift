import PiSwiftChord

/// Detached scan values and an optional continuation to the same scan.
public struct Page<Item: Sendable & Equatable & Codable, Continuation: Sendable & Equatable & Codable>: Sendable, Equatable, Codable {
    /// The records or queued requests in their stored order.
    public var items: [Item]
    /// The cursor that continues the scan, or nil when the page is final.
    public var next: Continuation?
    /// Pairs page items with an optional continuation cursor.
    public init(items: [Item], next: Continuation? = nil) {
        self.items = items
        self.next = next
    }
}

/// Backend-owned JSON state. Callers only pass it back to the same storage scan.
public typealias Cursor = JSONObject

/// ID order. Ascending is oldest first; descending is newest first.
public enum ScanOrder: String, Sendable, Equatable, Codable {
    /// Returns records in increasing ID order.
    case ascending
    /// Returns records in decreasing ID order.
    case descending
}

/// Filters and order for a page of conversation records.
public struct ConversationQuery: Sendable, Equatable, Codable {
    /// Filters records by the owner conversation ID.
    public var ownerConversationId: ConversationID?
    /// Filters records by the owner task ID.
    public var ownerTaskId: TaskID?
    /// The requested record-ID order of the scan.
    public var order: ScanOrder?
    /// Selects owner filters and optional conversation scan order.
    public init(ownerConversationId: ConversationID? = nil, ownerTaskId: TaskID? = nil, order: ScanOrder? = nil) {
        self.ownerConversationId = ownerConversationId
        self.ownerTaskId = ownerTaskId
        self.order = order
    }
}

/// Inclusive ID bounds in one conversation's visible ancestry.
public struct EntryQuery: Sendable, Equatable, Codable {
    /// The conversation that owns or is addressed by this value.
    public var conversationId: ConversationID
    /// The inclusive lower entry bound for the scan.
    public var minEntryId: EntryID?
    /// The inclusive upper entry bound for the scan.
    public var maxEntryId: EntryID?
    /// The requested record-ID order of the scan.
    public var order: ScanOrder?
    /// Selects a conversation, inclusive entry bounds, and optional scan order.
    public init(conversationId: ConversationID, minEntryId: EntryID? = nil, maxEntryId: EntryID? = nil, order: ScanOrder? = nil) {
        self.conversationId = conversationId
        self.minEntryId = minEntryId
        self.maxEntryId = maxEntryId
        self.order = order
    }
}

/// A stored task status used by scan filters.
public enum TaskStatus: String, Sendable, Equatable, Codable {
    /// Work is saved and waits for scheduler admission.
    case pending
    /// Work is executing with its saved checkpoint.
    case running
    /// Work waits for the selected tasks under its join policy.
    case waiting
    /// An outcome is saved while ordinary owned work finishes.
    case completing
    /// The task has a final outcome and cannot execute again.
    case terminal
}

/// Filters and order for a page of task records.
public struct TaskQuery: Sendable, Equatable, Codable {
    /// The conversation that owns or is addressed by this value.
    public var conversationId: ConversationID?
    /// The stored record or document kind.
    public var kind: String?
    /// The stored execution or submission state tag.
    public var status: TaskStatus?
    /// Whether an abort request has been saved for this task.
    public var abortRequested: Bool?
    /// Whether this task can outlive ordinary conversation work.
    public var background: Bool?
    /// The requested record-ID order of the scan.
    public var order: ScanOrder?
    /// Selects task filters and optional scan order.
    public init(conversationId: ConversationID? = nil, kind: String? = nil, status: TaskStatus? = nil,
                abortRequested: Bool? = nil, background: Bool? = nil, order: ScanOrder? = nil) {
        self.conversationId = conversationId
        self.kind = kind
        self.status = status
        self.abortRequested = abortRequested
        self.background = background
        self.order = order
    }
}

/// A stored submission status used by scan filters.
public enum SubmissionStatus: String, Sendable, Equatable, Codable {
    /// The input waits in the conversation inbox.
    case queued
    /// The input has entered the conversation and waits for an answer.
    case placed
    /// The input has a final answer or the write has entered the conversation.
    case done
    /// The input ended without an answer and has a saved reason.
    case unanswered
}

/// Filters and order for a page of durable submissions.
public struct SubmissionQuery: Sendable, Equatable, Codable {
    /// The conversation that owns or is addressed by this value.
    public var conversationId: ConversationID?
    /// The stored execution or submission state tag.
    public var status: SubmissionStatus?
    /// The requested record-ID order of the scan.
    public var order: ScanOrder?
    /// Selects submission filters and optional scan order.
    public init(conversationId: ConversationID? = nil, status: SubmissionStatus? = nil, order: ScanOrder? = nil) {
        self.conversationId = conversationId
        self.status = status
        self.order = order
    }
}

/// Current state or one historical commit sequence for membership and content reads.
public enum DocumentPoint: Sendable, Equatable, Codable {
    /// Reads the latest committed document state.
    case current
    /// Reads document state at the inclusive commit sequence.
    case sequence(Seq)
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        if value == .string("current") { self = .current }
        else { self = .sequence(try value.decode(Seq.self)) }
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .current: try JSONValue.string("current").encode(to: encoder)
        case .sequence(let seq): try seq.encode(to: encoder)
        }
    }
}

/// Exact singleton or keyed family-member identity. An absent key selects the singleton.
public struct DocumentAddress: Sendable, Equatable, Codable {
    /// The stored record or document kind.
    public var kind: String
    /// The session, conversation, or task addressed by this document.
    public var scope: DocumentScope
    /// The document family key or named prompt section key.
    public var key: String?
    /// Identifies a document kind and scope, with an optional family key.
    public init(kind: String, scope: DocumentScope, key: String? = nil) {
        self.kind = kind
        self.scope = scope
        self.key = key
    }
}

/// Incarnations alive in one exact scope at a selected point.
public struct DocumentQuery: Sendable, Equatable, Codable {
    /// The session, conversation, or task addressed by this document.
    public var scope: DocumentScope
    /// The inclusive history boundary or scheduled time for this value.
    public var at: DocumentPoint
    /// The stored record or document kind.
    public var kind: String?
    /// Selects document scope, history point, and optional kind filter.
    public init(scope: DocumentScope, at: DocumentPoint, kind: String? = nil) {
        self.scope = scope
        self.at = at
        self.kind = kind
    }
}

/// The order and last returned ID of a built-in scan.
public struct ScanStart: Sendable, Equatable {
    /// The requested record-ID order of the scan.
    public let order: ScanOrder
    /// The continuation point after which a watch supplies changes.
    public let after: Int64?
    /// Records the cursor order and exclusive continuation ID.
    public init(order: ScanOrder, after: Int64?) { self.order = order; self.after = after }
}

/// Continues in cursor order. A legacy cursor without order uses the default.
/// Cursor positions accept all JavaScript safe integers, including zero and negative values.
public func scanStart(requested: ScanOrder?, cursor: Cursor?, fallback: ScanOrder) throws -> ScanStart {
    guard let cursor else { return ScanStart(order: requested ?? fallback, after: nil) }
    guard let value = cursor["after"]?.numberValue, value.isFinite,
          let after = Int64(exactly: value), after >= -Seq.maximumRawValue, after <= Seq.maximumRawValue else {
        throw DurableStorageError.invalidCursor
    }
    let order: ScanOrder
    if let stored = cursor["order"] {
        guard let text = stored.stringValue, let parsed = ScanOrder(rawValue: text) else {
            throw DurableStorageError.invalidCursor
        }
        order = parsed
    } else { order = fallback }
    if let requested, requested != order {
        throw DurableStorageError.cursorOrderMismatch(stored: order, requested: requested)
    }
    return ScanStart(order: order, after: after)
}

/// Makes the continuation after the last returned record ID.
public func nextCursor<Kind: DurableIDKind>(_ id: DurableID<Kind>, order: ScanOrder) -> Cursor {
    ["after": .number(Double(id.rawValue)), "order": .string(order.rawValue)]
}
