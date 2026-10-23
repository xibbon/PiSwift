import PiSwiftAI
import PiSwiftChord

/// The active generation task and its admitted input submissions.
public struct LiveRun: Sendable, Equatable, Codable {
    /// The ID of the task bound to this value or invocation.
    public var taskId: TaskID
    /// The input submission IDs admitted to this generation.
    public var inputs: [SubmissionID]
    /// Records the active generation task and its admitted input submissions.
    public init(taskId: TaskID, inputs: [SubmissionID]) { self.taskId = taskId; self.inputs = inputs }
}
/// The scheduled retry time and last request error.
public struct LiveRetry: Sendable, Equatable, Codable {
    /// The inclusive history boundary or scheduled time for this value.
    public var at: Int64
    /// The saved error message or structured task failure.
    public var error: String
    /// Records the next retry time and last request error.
    public init(at: Int64, error: String) { self.at = at; self.error = error }
}
/// The next poll time for a deferred model request.
public struct LiveDeferred: Sendable, Equatable, Codable {
    /// The next deferred request poll time, in milliseconds.
    public var pollAt: Int64
    /// Records the next deferred-request poll time.
    public init(pollAt: Int64) { self.pollAt = pollAt }
}
/// The current attempt, partial response, and pending retry or deferred request.
public struct LiveGeneration: Sendable, Equatable, Codable {
    /// The current request attempt number.
    public var attempt: Int
    /// Text that describes the error, diagnostic, or model response.
    public var message: JSONObject?
    /// The current scheduled request retry, when present.
    public var retry: LiveRetry?
    /// The pending deferred response state, when present.
    public var deferred: LiveDeferred?
    /// Records the current request attempt and optional partial or retry state.
    public init(attempt: Int, message: JSONObject? = nil, retry: LiveRetry? = nil, deferred: LiveDeferred? = nil) {
        self.attempt = attempt; self.message = message; self.retry = retry; self.deferred = deferred
    }
}
/// The execution state and visible progress of one tool call.
public struct ToolSlot: Sendable, Equatable, Codable {
    /// The current execution state of a tool slot.
    public enum Status: String, Sendable, Codable {
        /// The tool call waits for execution.
        case pending
        /// The tool call is executing.
        case running
        /// The tool call has finished.
        case done
    }
    /// The model-supplied identifier of the tool call.
    public var callId: String
    /// The stable name used to resolve this definition in the registry.
    public var name: String
    /// The ID of the task bound to this value or invocation.
    public var taskId: TaskID?
    /// The stored execution or submission state tag.
    public var status: Status
    /// The retained text output visible for this tool call.
    public var output: String?
    /// The number of UTF-8 bytes removed from the full output.
    public var droppedBytes: Int?
    /// The number of lines removed from the full output.
    public var droppedLines: Int?
    /// Application-defined JSON details reported by a tool.
    public var details: JSONValue?
    /// The diagnostics reported by this tool call.
    public var diagnostics: [ToolDiagnostic]?
    /// The entry created or selected by this operation.
    public var entry: EntryID?
    /// Records a tool call and its initial execution status.
    public init(callId: String, name: String, taskId: TaskID? = nil, status: Status = .pending, entry: EntryID? = nil) {
        self.callId = callId; self.name = name; self.taskId = taskId; self.status = status; self.entry = entry
    }
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        callId = try recordRequired(object, "callId"); name = try recordRequired(object, "name")
        taskId = try recordOptional(object, "taskId"); status = try recordRequired(object, "status")
        output = try recordOptional(object, "output"); droppedBytes = try recordOptional(object, "droppedBytes")
        droppedLines = try recordOptional(object, "droppedLines")
        // An explicit null is a reported value. Absence means no details were reported.
        details = object["details"]
        diagnostics = try recordOptional(object, "diagnostics"); entry = try recordOptional(object, "entry")
    }
}
/// The result summary of one nested tool call. The caller document stores the result.
public struct NestedToolSummary: Sendable, Equatable, Codable {
    /// Whether the call failed.
    public var isError: Bool
    /// The execution time of this attempt, in milliseconds.
    public var durationMs: Int?
    /// The usage reported by the tool.
    public var usage: Usage?
    /// Up to 500 UTF-16 units of error text.
    public var error: String?
    /// Creates a summary for a completed nested call.
    public init(isError: Bool, durationMs: Int? = nil, usage: Usage? = nil, error: String? = nil) {
        self.isError = isError; self.durationMs = durationMs; self.usage = usage; self.error = error
    }
    /// Decodes the summary with the durable usage format.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        isError = try recordRequired(object, "isError"); durationMs = try recordOptional(object, "durationMs")
        usage = try object["usage"].map(durableUsage); error = try recordOptional(object, "error")
    }
    /// Encodes the summary with the durable usage format.
    public func encode(to encoder: any Encoder) throws {
        var object: JSONObject = ["isError": .bool(isError)]
        try recordSetOptional(&object, "durationMs", durationMs); try recordSetOptional(&object, "error", error)
        if let usage { object["usage"] = usageValue(usage) }
        try object.encode(to: encoder)
    }
    /// Compares all summary fields, including usage counters and cost.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isError == rhs.isError && lhs.durationMs == rhs.durationMs &&
            lhs.error.map(JSONValue.string) == rhs.error.map(JSONValue.string) &&
            lhs.usage.map(usageValue) == rhs.usage.map(usageValue)
    }
}

/// The visible state of a tool call made by another tool. Use task IDs to find its parent.
public struct NestedToolSlot: Sendable, Equatable, Codable {
    /// The opaque call ID used in tool events.
    public var callId: String
    /// The name of the called tool.
    public var name: String
    /// The call ID of the calling tool.
    public var parentCallId: String
    /// The task of the calling tool.
    public var parentTaskId: TaskID
    /// The task of this nested call.
    public var taskId: TaskID
    /// The arguments of the call, replaced with the final arguments when execution starts.
    public var arguments: JSONObject
    /// The execution state of the call.
    public var status: ToolSlot.Status
    /// The retained output while the call runs.
    public var output: String?
    /// The number of bytes removed from the full output.
    public var droppedBytes: Int?
    /// The number of lines removed from the full output.
    public var droppedLines: Int?
    /// Details reported by the call.
    public var details: JSONValue?
    /// Diagnostics reported by the call.
    public var diagnostics: [ToolDiagnostic]?
    /// A small result summary after the call ends.
    public var summary: NestedToolSummary?
    /// Creates a nested call slot.
    public init(callId: String, name: String, parentCallId: String, parentTaskId: TaskID, taskId: TaskID,
                arguments: JSONObject, status: ToolSlot.Status = .pending, summary: NestedToolSummary? = nil) {
        self.callId = callId; self.name = name; self.parentCallId = parentCallId; self.parentTaskId = parentTaskId
        self.taskId = taskId; self.arguments = arguments; self.status = status; self.summary = summary
    }
    /// Decodes the slot and preserves explicit null details.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        callId = try recordRequired(object, "callId"); name = try recordRequired(object, "name")
        parentCallId = try recordRequired(object, "parentCallId"); parentTaskId = try recordRequired(object, "parentTaskId")
        taskId = try recordRequired(object, "taskId"); arguments = try recordRequired(object, "arguments")
        status = try recordRequired(object, "status"); output = try recordOptional(object, "output")
        droppedBytes = try recordOptional(object, "droppedBytes"); droppedLines = try recordOptional(object, "droppedLines")
        details = object["details"]; diagnostics = try recordOptional(object, "diagnostics")
        summary = try recordOptional(object, "summary")
    }
    internal var progress: ToolSlot {
        var slot = ToolSlot(callId: callId, name: name, taskId: taskId, status: status)
        slot.output = output; slot.droppedBytes = droppedBytes; slot.droppedLines = droppedLines
        slot.details = details; slot.diagnostics = diagnostics
        return slot
    }
}

/// Selects diagnostic errors first, then text output, for a bounded nested summary.
internal func summaryOf(result: NestedToolExecutionResult, output: [ContentBlock]) -> NestedToolSummary {
    let errors = result.diagnostics.filter { $0.severity == .error }.map(\.message)
    let text = errors.isEmpty ? output.compactMap { block -> String? in
        if case .text(let value) = block { return value.text }; return nil
    }.joined(separator: "\n") : errors.joined(separator: "\n")
    let error = result.isError ? String(decoding: text.utf16.prefix(500), as: UTF16.self) : ""
    return .init(isError: result.isError, durationMs: result.durationMs, usage: result.usage, error: error.isEmpty ? nil : error)
}

/// Progress and retry state for one active compaction.
public struct CompactionStatus: Sendable, Equatable, Codable {
    /// The ID of the task bound to this value or invocation.
    public var taskId: TaskID
    /// The saved cause of cancellation, unanswered input, or compaction.
    public var reason: CompactionReason
    /// Whether the generation must wait for this compaction.
    public var blocking: Bool
    /// The current request attempt number.
    public var attempt: Int
    /// The current scheduled request retry, when present.
    public var retry: LiveRetry?
    /// Records an active compaction task, attempt, and optional retry.
    public init(taskId: TaskID, reason: CompactionReason, blocking: Bool, attempt: Int, retry: LiveRetry? = nil) {
        self.taskId = taskId; self.reason = reason; self.blocking = blocking; self.attempt = attempt; self.retry = retry
    }
}
/// The active generation, tools, and compactions of one conversation.
public struct LiveState: Sendable, Equatable, Codable {
    /// The active generation task and the input submissions it admitted.
    public var run: LiveRun?
    /// The current partial model response and retry state.
    public var generation: LiveGeneration?
    /// The tool registrations or live tool slots in this value.
    public var tools: [ToolSlot]?
    /// Nested calls in creation order, with each parent before its children.
    public var nestedTools: [NestedToolSlot]?
    /// The active compaction tasks and their progress.
    public var compactions: [CompactionStatus]?
    /// Creates the visible state of active generation, tools, and compactions.
    public init(run: LiveRun? = nil, generation: LiveGeneration? = nil, tools: [ToolSlot]? = nil, nestedTools: [NestedToolSlot]? = nil, compactions: [CompactionStatus]? = nil) {
        self.run = run; self.generation = generation; self.tools = tools; self.nestedTools = nestedTools; self.compactions = compactions
    }
}
/// The typed token for the built-in live conversation document.
public let LiveDoc = try! ConversationDocToken<LiveState>(kind: "pi.live", version: 1, fork: .initial,
    initial: { LiveState() }, checkpointWhen: { value, _, _ in
        value["generation"] == nil &&
        !(value["tools"]?.arrayValue ?? []).contains { $0.objectValue?["status"] == .string("running") } &&
        !(value["nestedTools"]?.arrayValue ?? []).contains { $0.objectValue?["status"] == .string("running") }
    })

internal func endRun(tx: Transaction, live: JSONDraft, taskId: TaskID, settlement: SubmissionSettlement) throws {
    if let run = try live.get("run")?.decode(LiveRun.self), run.taskId == taskId {
        for id in run.inputs { try tx.settleSubmission(id, settlement: settlement) }
        try live.remove("run")
    }
    try live.remove("generation"); try live.remove("tools"); try live.remove("nestedTools")
}
internal func startRun(tx: Transaction, conversationId: ConversationID, live: JSONDraft, inputs: [SubmissionID]) async throws {
    let id = try await createGeneration(tx: tx, conversationId: conversationId)
    try live.set("run", JSONValue(encoding: LiveRun(taskId: id, inputs: inputs)))
}
internal func handOver(live: JSONDraft, from: TaskID, to: TaskID) throws {
    guard let run = try live.child("run"), try run.get("taskId")?.decode(TaskID.self) == from else { return }
    try run.set("taskId", JSONValue(encoding: to))
}
internal func toolSlot(live: JSONDraft, taskId: TaskID) throws -> JSONDraft? {
    if let slots = try live.child("tools") {
        for index in 0..<(try slots.count()) {
            if let slot = try slots.child(index), try slot.get("taskId")?.decode(TaskID.self) == taskId { return slot }
        }
    }
    guard let nested = try live.child("nestedTools") else { return nil }
    var low = 0; var high = try nested.count() - 1
    while low <= high {
        let middle = low + (high - low) / 2
        guard let slot = try nested.child(middle), let id = try slot.get("taskId")?.decode(TaskID.self) else {
            throw SessionError.message("Nested tool slot has no task ID")
        }
        if id == taskId { return slot }
        if id < taskId { low = middle + 1 } else { high = middle - 1 }
    }
    return nil
}
/// Removes all descendants of a tool task. The slots have parents before children.
internal func removeNestedSlots(live: JSONDraft, taskId: TaskID) throws {
    guard let nested = try live.child("nestedTools") else { return }
    var removed: Set<TaskID> = [taskId]; var indices: [Int] = []
    for index in 0..<(try nested.count()) {
        guard let slot = try nested.child(index), let parent = try slot.get("parentTaskId")?.decode(TaskID.self),
              let id = try slot.get("taskId")?.decode(TaskID.self) else {
            throw SessionError.message("Nested tool slot has no task identity")
        }
        if removed.contains(parent) { removed.insert(id); indices.append(index) }
    }
    for index in indices.reversed() { try nested.splice(index, deleteCount: 1) }
    if try nested.count() == 0 { try live.remove("nestedTools") }
}
internal func clearProgress(slot: JSONDraft) throws {
    for key in ["output", "droppedBytes", "droppedLines", "details", "diagnostics"] { try slot.remove(key) }
}
internal func finishSlot(slot: JSONDraft, entry: EntryID?) throws {
    try slot.set("status", .string("done"))
    if let entry { try slot.set("entry", JSONValue(encoding: entry)) }
    try clearProgress(slot: slot)
}
internal func addCompactionStatus(live: JSONDraft, status: CompactionStatus) throws {
    if try live.child("compactions") == nil { try live.set("compactions", .array([])) }
    try live.child("compactions")!.append(JSONValue(encoding: status))
}
internal func compactionStatus(live: JSONDraft, taskId: TaskID) throws -> JSONDraft? {
    guard let statuses = try live.child("compactions") else { return nil }
    for index in 0..<(try statuses.count()) {
        if let status = try statuses.child(index), try status.get("taskId")?.decode(TaskID.self) == taskId { return status }
    }
    return nil
}
internal func removeCompactionStatus(live: JSONDraft, taskId: TaskID) throws {
    guard let statuses = try live.child("compactions") else { return }
    for index in 0..<(try statuses.count()) where try statuses.get(index)?.objectValue?["taskId"]?.decode(TaskID.self) == taskId {
        try statuses.splice(index, deleteCount: 1); break
    }
    if try statuses.count() == 0 { try live.remove("compactions") }
}
internal func settleSchedulerOutcome(tx: Transaction, record: TaskRecord, outcome: TaskOutcome) async throws {
    guard ["pi.generation", "pi.tool", "pi.compaction"].contains(record.kind) else { return }
    let live = try await tx.doc(LiveDoc, conversationId: record.conversationId)
    if record.kind == "pi.tool" {
        if let slot = try toolSlot(live: live, taskId: record.id) { try finishSlot(slot: slot, entry: nil) }
        try removeNestedSlots(live: live, taskId: record.id); return
    }
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
