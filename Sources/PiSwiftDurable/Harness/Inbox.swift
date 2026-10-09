import PiSwiftChord

public struct InboxItem: Sendable, Equatable, Codable {
    public enum Mode: String, Sendable, Codable { case steer, followUp, write }
    public var id: SubmissionID
    public var mode: Mode
    public var content: JSONValue?
    public var entry: EntryDraft?
    public init(id: SubmissionID, mode: Mode, content: JSONValue? = nil, entry: EntryDraft? = nil) {
        self.id = id; self.mode = mode; self.content = content; self.entry = entry
    }
    private enum Keys: String, CodingKey { case id, mode, content, entry }
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
public struct InboxState: Sendable, Equatable, Codable {
    public var items: [InboxItem]
    public init(items: [InboxItem] = []) { self.items = items }
}
public let InboxDoc = try! ConversationDocToken<InboxState>(kind: "pi.inbox", version: 1, fork: .initial,
    initial: { InboxState() }, checkpointWhen: { value, _, _ in value["items"]?.arrayValue?.isEmpty == true })
public struct Boundary: Sendable {
    public let conversationId: ConversationID
    public let inbox: JSONDraft
    public let steeringMode: QueueMode
    public let followUpMode: QueueMode
    public var head: EntryID?
}
public enum BoundaryPoint: String, Sendable { case postTools, final }
public struct BoundaryResult: Sendable {
    public let users: [SubmissionID]
    public let reset: Bool
}
public func prepareBoundary(tx: Transaction, conversationId: ConversationID, modes: Settings) async throws -> Boundary {
    let head = try await tx.latestHeadMarker(conversationId)?.head
    let inbox = try await tx.doc(InboxDoc, conversationId: conversationId)
    return Boundary(conversationId: conversationId, inbox: inbox, steeringMode: modes.steeringMode, followUpMode: modes.followUpMode, head: head)
}
public func isStale(boundary: Boundary, entry: EntryDraft) -> Bool {
    if case .entry(let head) = entry.head, let active = boundary.head { return head < active }
    return false
}
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
public func removeInboxItem(tx: Transaction, conversationId: ConversationID, id: SubmissionID) async throws {
    let inbox = try await tx.doc(InboxDoc, conversationId: conversationId)
    let items = try inbox.child("items")!
    let values = try inbox.snapshot().decode(InboxState.self).items
    if let index = values.firstIndex(where: { $0.id == id }) { try items.splice(index, deleteCount: 1) }
}
public func withdrawQueuedInputs(tx: Transaction, conversationId: ConversationID) async throws {
    let inbox = try await tx.doc(InboxDoc, conversationId: conversationId)
    let items = try inbox.child("items")!
    let values = try inbox.snapshot().decode(InboxState.self).items
    for index in values.indices.reversed() where values[index].mode != .write {
        try tx.settleSubmission(values[index].id, settlement: .unanswered(reason: "aborted"))
        try items.splice(index, deleteCount: 1)
    }
}
