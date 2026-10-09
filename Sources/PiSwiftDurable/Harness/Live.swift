import PiSwiftChord

public struct LiveRun: Sendable, Equatable, Codable {
    public var taskId: TaskID
    public var inputs: [SubmissionID]
    public init(taskId: TaskID, inputs: [SubmissionID]) { self.taskId = taskId; self.inputs = inputs }
}
public struct LiveRetry: Sendable, Equatable, Codable {
    public var at: Int64
    public var error: String
    public init(at: Int64, error: String) { self.at = at; self.error = error }
}
public struct LiveDeferred: Sendable, Equatable, Codable {
    public var pollAt: Int64
    public init(pollAt: Int64) { self.pollAt = pollAt }
}
public struct LiveGeneration: Sendable, Equatable, Codable {
    public var attempt: Int
    public var message: JSONObject?
    public var retry: LiveRetry?
    public var deferred: LiveDeferred?
    public init(attempt: Int, message: JSONObject? = nil, retry: LiveRetry? = nil, deferred: LiveDeferred? = nil) {
        self.attempt = attempt; self.message = message; self.retry = retry; self.deferred = deferred
    }
}
public struct ToolSlot: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Codable { case pending, running, done }
    public var callId: String
    public var name: String
    public var taskId: TaskID?
    public var status: Status
    public var output: String?
    public var droppedBytes: Int?
    public var droppedLines: Int?
    public var details: JSONValue?
    public var diagnostics: [ToolDiagnostic]?
    public var entry: EntryID?
    public init(callId: String, name: String, taskId: TaskID? = nil, status: Status = .pending, entry: EntryID? = nil) {
        self.callId = callId; self.name = name; self.taskId = taskId; self.status = status; self.entry = entry
    }
}
public struct CompactionStatus: Sendable, Equatable, Codable {
    public var taskId: TaskID
    public var reason: CompactionReason
    public var blocking: Bool
    public var attempt: Int
    public var retry: LiveRetry?
    public init(taskId: TaskID, reason: CompactionReason, blocking: Bool, attempt: Int, retry: LiveRetry? = nil) {
        self.taskId = taskId; self.reason = reason; self.blocking = blocking; self.attempt = attempt; self.retry = retry
    }
}
public struct LiveState: Sendable, Equatable, Codable {
    public var run: LiveRun?
    public var generation: LiveGeneration?
    public var tools: [ToolSlot]?
    public var compactions: [CompactionStatus]?
    public init(run: LiveRun? = nil, generation: LiveGeneration? = nil, tools: [ToolSlot]? = nil, compactions: [CompactionStatus]? = nil) {
        self.run = run; self.generation = generation; self.tools = tools; self.compactions = compactions
    }
}
public let LiveDoc = try! ConversationDocToken<LiveState>(kind: "pi.live", version: 1, fork: .initial,
    initial: { LiveState() }, checkpointWhen: { value, _, _ in
        value["generation"] == nil && !(value["tools"]?.arrayValue ?? []).contains { $0.objectValue?["status"] == .string("running") }
    })

public func endRun(tx: Transaction, live: JSONDraft, taskId: TaskID, settlement: SubmissionSettlement) throws {
    if let run = try live.get("run")?.decode(LiveRun.self), run.taskId == taskId {
        for id in run.inputs { try tx.settleSubmission(id, settlement: settlement) }
        try live.remove("run")
    }
    try live.remove("generation"); try live.remove("tools")
}
public func startRun(tx: Transaction, conversationId: ConversationID, live: JSONDraft, inputs: [SubmissionID]) async throws {
    let id = try await createGeneration(tx: tx, conversationId: conversationId)
    try live.set("run", JSONValue(encoding: LiveRun(taskId: id, inputs: inputs)))
}
public func handOver(live: JSONDraft, from: TaskID, to: TaskID) throws {
    guard let run = try live.child("run"), try run.get("taskId")?.decode(TaskID.self) == from else { return }
    try run.set("taskId", JSONValue(encoding: to))
}
public func toolSlot(live: JSONDraft, taskId: TaskID) throws -> JSONDraft? {
    guard let slots = try live.child("tools") else { return nil }
    for index in 0..<(try slots.count()) {
        if let slot = try slots.child(index), try slot.get("taskId")?.decode(TaskID.self) == taskId { return slot }
    }
    return nil
}
public func clearProgress(slot: JSONDraft) throws {
    for key in ["output", "droppedBytes", "droppedLines", "details", "diagnostics"] { try slot.remove(key) }
}
public func finishSlot(slot: JSONDraft, entry: EntryID?) throws {
    try slot.set("status", .string("done"))
    if let entry { try slot.set("entry", JSONValue(encoding: entry)) }
    try clearProgress(slot: slot)
}
public func addCompactionStatus(live: JSONDraft, status: CompactionStatus) throws {
    if try live.child("compactions") == nil { try live.set("compactions", .array([])) }
    try live.child("compactions")!.append(JSONValue(encoding: status))
}
public func compactionStatus(live: JSONDraft, taskId: TaskID) throws -> JSONDraft? {
    guard let statuses = try live.child("compactions") else { return nil }
    for index in 0..<(try statuses.count()) {
        if let status = try statuses.child(index), try status.get("taskId")?.decode(TaskID.self) == taskId { return status }
    }
    return nil
}
public func removeCompactionStatus(live: JSONDraft, taskId: TaskID) throws {
    guard let statuses = try live.child("compactions") else { return }
    for index in 0..<(try statuses.count()) where try statuses.get(index)?.objectValue?["taskId"]?.decode(TaskID.self) == taskId {
        try statuses.splice(index, deleteCount: 1); break
    }
    if try statuses.count() == 0 { try live.remove("compactions") }
}
internal func settleSchedulerOutcome(tx: Transaction, record: TaskRecord, outcome: TaskOutcome) async throws {
    guard ["pi.generation", "pi.tool", "pi.compaction"].contains(record.kind) else { return }
    let live = try await tx.doc(LiveDoc, conversationId: record.conversationId)
    if record.kind == "pi.tool" { if let slot = try toolSlot(live: live, taskId: record.id) { try finishSlot(slot: slot, entry: nil) }; return }
    if record.kind == "pi.compaction" { try removeCompactionStatus(live: live, taskId: record.id); return }
    guard try live.get("run")?.decode(LiveRun.self).taskId == record.id else { return }
    try await convertPartial(tx: tx, live: live, conversationId: record.conversationId)
    let settlement: SubmissionSettlement
    switch outcome {
    case .faulted(let error, _): settlement = .unanswered(reason: "faulted", detail: .string(error.message))
    case .orphaned(let reason, _): settlement = .unanswered(reason: reason)
    default: return
    }
    try endRun(tx: tx, live: live, taskId: record.id, settlement: settlement)
}
