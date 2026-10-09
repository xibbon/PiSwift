import PiSwiftChord

/// Detached scan values and an optional continuation to the same scan.
public struct Page<Item: Sendable & Equatable & Codable, Continuation: Sendable & Equatable & Codable>: Sendable, Equatable, Codable {
    public var items: [Item]
    public var next: Continuation?
    public init(items: [Item], next: Continuation? = nil) {
        self.items = items
        self.next = next
    }
}

/// Backend-owned JSON state. Callers only pass it back to the same storage scan.
public typealias Cursor = JSONObject

/// ID order. Ascending is oldest first; descending is newest first.
public enum ScanOrder: String, Sendable, Equatable, Codable {
    case ascending, descending
}

public struct ConversationQuery: Sendable, Equatable, Codable {
    public var ownerConversationId: ConversationID?
    public var ownerTaskId: TaskID?
    public var order: ScanOrder?
    public init(ownerConversationId: ConversationID? = nil, ownerTaskId: TaskID? = nil, order: ScanOrder? = nil) {
        self.ownerConversationId = ownerConversationId
        self.ownerTaskId = ownerTaskId
        self.order = order
    }
}

/// Inclusive ID bounds in one conversation's visible ancestry.
public struct EntryQuery: Sendable, Equatable, Codable {
    public var conversationId: ConversationID
    public var minEntryId: EntryID?
    public var maxEntryId: EntryID?
    public var order: ScanOrder?
    public init(conversationId: ConversationID, minEntryId: EntryID? = nil, maxEntryId: EntryID? = nil, order: ScanOrder? = nil) {
        self.conversationId = conversationId
        self.minEntryId = minEntryId
        self.maxEntryId = maxEntryId
        self.order = order
    }
}

public enum TaskStatus: String, Sendable, Equatable, Codable {
    case pending, running, waiting, completing, terminal
}

public struct TaskQuery: Sendable, Equatable, Codable {
    public var conversationId: ConversationID?
    public var kind: String?
    public var status: TaskStatus?
    public var abortRequested: Bool?
    public var background: Bool?
    public var order: ScanOrder?
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

public enum SubmissionStatus: String, Sendable, Equatable, Codable {
    case queued, placed, done, unanswered
}

public struct SubmissionQuery: Sendable, Equatable, Codable {
    public var conversationId: ConversationID?
    public var status: SubmissionStatus?
    public var order: ScanOrder?
    public init(conversationId: ConversationID? = nil, status: SubmissionStatus? = nil, order: ScanOrder? = nil) {
        self.conversationId = conversationId
        self.status = status
        self.order = order
    }
}

/// Current state or one historical commit sequence for membership and content reads.
public enum DocumentPoint: Sendable, Equatable, Codable {
    case current
    case sequence(Seq)
    public init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        if value == .string("current") { self = .current }
        else { self = .sequence(try value.decode(Seq.self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .current: try JSONValue.string("current").encode(to: encoder)
        case .sequence(let seq): try seq.encode(to: encoder)
        }
    }
}

/// Exact singleton or keyed family-member identity. An absent key selects the singleton.
public struct DocumentAddress: Sendable, Equatable, Codable {
    public var kind: String
    public var scope: DocumentScope
    public var key: String?
    public init(kind: String, scope: DocumentScope, key: String? = nil) {
        self.kind = kind
        self.scope = scope
        self.key = key
    }
}

/// Incarnations alive in one exact scope at a selected point.
public struct DocumentQuery: Sendable, Equatable, Codable {
    public var scope: DocumentScope
    public var at: DocumentPoint
    public var kind: String?
    public init(scope: DocumentScope, at: DocumentPoint, kind: String? = nil) {
        self.scope = scope
        self.at = at
        self.kind = kind
    }
}

/// The order and last returned ID of a built-in scan.
public struct ScanStart: Sendable, Equatable {
    public let order: ScanOrder
    public let after: Int64?
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
