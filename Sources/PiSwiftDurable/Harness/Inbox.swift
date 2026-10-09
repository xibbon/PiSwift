import PiSwiftChord

/// A queued input or write waiting for a generation boundary.
public struct InboxItem: Sendable, Equatable, Codable {
    /// The queue or execution policy selected for this operation.
    public enum Mode: String, Sendable, Codable {
        /// Admits the input at a steering boundary.
        case steer
        /// Admits the input at a follow-up boundary.
        case followUp
        /// Stores an entry write request.
        case write
    }
    /// The durable submission ID of this queued item.
    public var id: SubmissionID
    /// The steering or follow-up queue selected for this item.
    public var mode: Mode
    /// The queued user content for an input submission.
    public var content: JSONValue?
    /// The queued entry draft for a write submission.
    public var entry: EntryDraft?
    /// Pairs a queued submission with its admission mode and input or entry content.
    public init(id: SubmissionID, mode: Mode, content: JSONValue? = nil, entry: EntryDraft? = nil) {
        self.id = id; self.mode = mode; self.content = content; self.entry = entry
    }
    private enum Keys: String, CodingKey { case id, mode, content, entry }
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(SubmissionID.self, forKey: .id)
        mode = try container.decode(Mode.self, forKey: .mode)
        if mode == .write {
            entry = try container.decode(EntryDraft.self, forKey: .entry); content = nil
        } else {
            content = try container.decode(JSONValue.self, forKey: .content); entry = nil
        }
    }
}
/// The ordered queue stored in the conversation inbox document.
public struct InboxState: Sendable, Equatable, Codable {
    /// The records or queued requests in their stored order.
    public var items: [InboxItem]
    /// Creates an ordered queue of pending submissions.
    public init(items: [InboxItem] = []) { self.items = items }
}
/// The typed token for the built-in inbox conversation document.
public let InboxDoc = try! ConversationDocToken<InboxState>(kind: "pi.inbox", version: 1, fork: .initial,
    initial: { InboxState() }, checkpointWhen: { value, _, _ in value["items"]?.arrayValue?.isEmpty == true })
/// A saved inbox and live-state view used to plan one generation boundary.
public struct Boundary: Sendable {
    /// The conversation that owns or is addressed by this value.
    public let conversationId: ConversationID
    /// The queued conversation submissions.
    public let inbox: JSONDraft
    /// How steering inputs are admitted at the next boundary.
    public let steeringMode: QueueMode
    /// How queued follow-up inputs are admitted at the next boundary.
    public let followUpMode: QueueMode
    /// The entry that defines the active model-context lower bound.
    public var head: EntryID?
}
/// The generation boundary at which queued input can enter the conversation.
public enum BoundaryPoint: String, Sendable {
    /// Applies queued input after tool results are committed.
    case postTools
    /// Applies queued input after the assistant yields its final response.
    case final
}
/// The submissions consumed and control action selected at a generation boundary.
public struct BoundaryResult: Sendable {
    /// The user message entries admitted for this generation.
    public let users: [SubmissionID]
    /// The reset marker that begins the current context.
    public let reset: Bool
}
/// Reads the inbox and active run before any table write at a generation boundary.
public func prepareBoundary(tx: Transaction, conversationId: ConversationID, modes: Settings) async throws -> Boundary {
    let head = try await tx.latestHeadMarker(conversationId)?.head
    let inbox = try await tx.doc(InboxDoc, conversationId: conversationId)
    return Boundary(conversationId: conversationId, inbox: inbox, steeringMode: modes.steeringMode, followUpMode: modes.followUpMode, head: head)
}
internal func isStale(boundary: Boundary, entry: EntryDraft) -> Bool {
    if case .entry(let head) = entry.head, let active = boundary.head { return head < active }
    return false
}
/// Places queued submissions at a generation boundary and returns its control decision.
public func applyBoundary(tx: Transaction, boundary: Boundary, at: BoundaryPoint, now: Int64) async throws -> BoundaryResult {
    var boundary = boundary
    let values = try boundary.inbox.snapshot().decode(InboxState.self).items
    let items = try boundary.inbox.child("items")!
    let reset = values.contains { $0.mode == .write && $0.entry?.head == .self }
    func pick(_ mode: InboxItem.Mode, _ queue: QueueMode) -> [Int] {
        let indexes = values.indices.filter { values[$0].mode == mode }
        return queue == .all ? indexes : Array(indexes.prefix(1))
    }
    let writes = values.indices.filter { values[$0].mode == .write }
    let users = (pick(.steer, boundary.steeringMode) + ((at == .final || reset) ? pick(.followUp, boundary.followUpMode) : [])).sorted()
    for index in writes {
        let item = values[index], draft = item.entry!
        if isStale(boundary: boundary, entry: draft) { try tx.settleSubmission(item.id, settlement: .unanswered(reason: "stale")); continue }
        let entry = try await tx.appendEntry(boundary.conversationId, value: draft)
        if let head = draft.head { switch head { case .self: boundary.head = entry.id; case .entry(let id): boundary.head = id } }
        try tx.placeSubmission(item.id, entry: entry.id)
    }
    var placed: [SubmissionID] = []
    for index in users {
        let item = values[index]
        let message: JSONValue = .object(["role": .string("user"), "content": item.content!, "timestamp": .number(Double(now))])
        let entry = try await tx.appendEntry(boundary.conversationId, value: EntryDraft(kind: userEntry.kind, model: [message]))
        try tx.placeSubmission(item.id, entry: entry.id); placed.append(item.id)
    }
    for index in (writes + users).sorted(by: >) { try items.splice(index, deleteCount: 1) }
    return BoundaryResult(users: placed, reset: reset)
}
internal func removeInboxItem(tx: Transaction, conversationId: ConversationID, id: SubmissionID) async throws {
    let inbox = try await tx.doc(InboxDoc, conversationId: conversationId)
    let items = try inbox.child("items")!
    let values = try inbox.snapshot().decode(InboxState.self).items
    if let index = values.firstIndex(where: { $0.id == id }) { try items.splice(index, deleteCount: 1) }
}
/// Settles and removes queued inputs for the conversation.
public func withdrawQueuedInputs(tx: Transaction, conversationId: ConversationID) async throws {
    let inbox = try await tx.doc(InboxDoc, conversationId: conversationId)
    let items = try inbox.child("items")!
    let values = try inbox.snapshot().decode(InboxState.self).items
    for index in values.indices.reversed() where values[index].mode != .write {
        try tx.settleSubmission(values[index].id, settlement: .unanswered(reason: "aborted"))
        try items.splice(index, deleteCount: 1)
    }
}
