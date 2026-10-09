import PiSwiftChord
import Synchronization

/// The queued part of an inbox item. Content stays in the submission record.
public struct DurableQueuedItem: Sendable, Equatable, Codable {
    public var id: SubmissionID
    public var mode: InboxItem.Mode
    public init(id: SubmissionID, mode: InboxItem.Mode) { self.id = id; self.mode = mode }
}

public struct DurableSnapshotRun: Sendable, Equatable, Codable {
    public var inputs: [SubmissionID]
    public init(inputs: [SubmissionID]) { self.inputs = inputs }
}

/// The state at event stream acquisition, or at a queue overflow.
public struct DurableAgentSnapshot: Sendable, Equatable, Codable {
    public var entries: [EntryRecord]
    public var run: DurableSnapshotRun?
    public var generation: LiveGeneration?
    public var tools: [ToolSlot]
    public var compactions: [CompactionStatus]
    public var inbox: [DurableQueuedItem]
    public var agent: AgentState
    public var usage: JSONObject
    public var type: String { "snapshot" }
    public init(entries: [EntryRecord] = [], run: DurableSnapshotRun? = nil, generation: LiveGeneration? = nil,
                tools: [ToolSlot] = [], compactions: [CompactionStatus] = [], inbox: [DurableQueuedItem] = [],
                agent: AgentState = .init(), usage: JSONObject = ["models": [:], "tools": [:]]) {
        self.entries = entries; self.run = run; self.generation = generation; self.tools = tools
        self.compactions = compactions; self.inbox = inbox; self.agent = agent; self.usage = usage
    }
    public init(from decoder: any Decoder) throws {
        let o = try recordObject(decoder)
        entries = try recordRequired(o, "entries"); run = try recordOptional(o, "run")
        generation = try recordOptional(o, "generation"); tools = try recordRequired(o, "tools")
        compactions = try recordRequired(o, "compactions"); inbox = try recordRequired(o, "inbox")
        agent = try recordRequired(o, "agent"); usage = try recordRequired(o, "usage")
    }
    public func encode(to encoder: any Encoder) throws {
        var o: JSONObject = ["type": .string(type)]
        try recordSet(&o, "entries", entries); try recordSetOptional(&o, "run", run)
        try recordSetOptional(&o, "generation", generation); try recordSet(&o, "tools", tools)
        try recordSet(&o, "compactions", compactions); try recordSet(&o, "inbox", inbox)
        try recordSet(&o, "agent", agent); try recordSet(&o, "usage", usage)
        try o.encode(to: encoder)
    }
}

/// One change to the in-flight assistant message. Paths are relative to tool arguments.
public enum DurableMessageChange: Sendable, Equatable, Codable {
    case textStart(contentIndex: Int, block: JSONObject)
    case thinkingStart(contentIndex: Int, block: JSONObject)
    case toolCallStart(contentIndex: Int, block: JSONObject)
    case textDelta(contentIndex: Int, delta: String)
    case thinkingDelta(contentIndex: Int, delta: String)
    case toolCallDelta(contentIndex: Int, path: Delta.Path, delta: String)
    case block(contentIndex: Int, block: JSONObject)
    case message(message: JSONObject)
    public var type: String {
        switch self {
        case .textStart: "text_start"
        case .thinkingStart: "thinking_start"
        case .toolCallStart: "toolcall_start"
        case .textDelta: "text_delta"
        case .thinkingDelta: "thinking_delta"
        case .toolCallDelta: "toolcall_delta"
        case .block: "block"
        case .message: "message"
        }
    }
    public init(from decoder: any Decoder) throws {
        let o = try recordObject(decoder)
        let type: String = try recordRequired(o, "type")
        if type == "message" { self = .message(message: try recordRequired(o, "message")); return }
        let index: Int = try recordRequired(o, "contentIndex")
        switch type {
        case "text_start": self = .textStart(contentIndex: index, block: try recordRequired(o, "block"))
        case "thinking_start": self = .thinkingStart(contentIndex: index, block: try recordRequired(o, "block"))
        case "toolcall_start": self = .toolCallStart(contentIndex: index, block: try recordRequired(o, "block"))
        case "text_delta": self = .textDelta(contentIndex: index, delta: try recordRequired(o, "delta"))
        case "thinking_delta": self = .thinkingDelta(contentIndex: index, delta: try recordRequired(o, "delta"))
        case "toolcall_delta":
            let values: [JSONValue] = try recordRequired(o, "path")
            let path = try values.map { value -> Delta.PathSegment in
                if let key = value.stringValue { return .key(key) }
                if let index = value.intValue { return .index(index) }
                throw SessionError.message("Invalid message change path")
            }
            self = .toolCallDelta(contentIndex: index, path: path, delta: try recordRequired(o, "delta"))
        case "block": self = .block(contentIndex: index, block: try recordRequired(o, "block"))
        default: throw recordUnknown("type", type)
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var o: JSONObject = ["type": .string(type)]
        switch self {
        case let .textStart(i, b), let .thinkingStart(i, b), let .toolCallStart(i, b), let .block(i, b):
            try recordSet(&o, "contentIndex", i); o["block"] = .object(b)
        case let .textDelta(i, d), let .thinkingDelta(i, d):
            try recordSet(&o, "contentIndex", i); o["delta"] = .string(d)
        case let .toolCallDelta(i, p, d):
            try recordSet(&o, "contentIndex", i); o["delta"] = .string(d)
            o["path"] = .array(p.map { switch $0 { case .key(let k): .string(k); case .index(let i): .number(Double(i)) } })
        case .message(let m): o["message"] = .object(m)
        }
        try o.encode(to: encoder)
    }
}

/// Retained output changes: a front trim followed by an append, or a replacement.
public enum DurableToolOutputChange: Sendable, Equatable, Codable {
    case delta(trimStart: Int? = nil, append: String? = nil)
    case set(String)
    public init(from decoder: any Decoder) throws {
        let o = try recordObject(decoder)
        if let text: String = try recordOptional(o, "set") { self = .set(text) }
        else { self = .delta(trimStart: try recordOptional(o, "trimStart"), append: try recordOptional(o, "append")) }
    }
    public func encode(to encoder: any Encoder) throws {
        var o: JSONObject = [:]
        switch self {
        case .set(let text): o["set"] = .string(text)
        case let .delta(trim, append): try recordSetOptional(&o, "trimStart", trim); try recordSetOptional(&o, "append", append)
        }
        try o.encode(to: encoder)
    }
}

/// Experimental events from committed durable records. JSON uses the upstream type names.
public enum DurableAgentEvent: Sendable, Equatable, Codable {
    case snapshot(DurableAgentSnapshot)
    case runStart(inputs: [SubmissionID])
    case runEnd(inputs: [SubmissionID])
    case turnStart
    case turnEnd
    case messageStart(message: JSONObject)
    case messageUpdate(usage: JSONObject, changes: [DurableMessageChange])
    case messageEnd(entry: EntryRecord)
    case toolExecutionStart(toolCallId: String, toolName: String, args: JSONObject)
    case toolExecutionUpdate(toolCallId: String, toolName: String, output: DurableToolOutputChange? = nil,
                             details: JSONValue? = nil, diagnostics: [ToolDiagnostic]? = nil)
    case toolExecutionEnd(toolCallId: String, toolName: String, entry: EntryRecord? = nil)
    case inboxUpdate(items: [DurableQueuedItem])
    case submission(record: SubmissionRecord)
    case autoRetryStart(attempt: Int, at: Int64, errorMessage: String)
    case autoRetryEnd(attempt: Int)
    case deferredPoll(pollAt: Int64)
    case entryAppended(entry: EntryRecord)
    case agentChanged(agent: AgentState)
    case usageChanged(usage: JSONObject)
    case taskFailed(taskId: TaskID, kind: String, message: String)
    case compactionStart(taskId: TaskID, reason: CompactionReason, blocking: Bool)
    case compactionEnd(taskId: TaskID, reason: CompactionReason)
    public var type: String {
        switch self {
        case .snapshot: "snapshot"
        case .runStart: "run_start"
        case .runEnd: "run_end"
        case .turnStart: "turn_start"
        case .turnEnd: "turn_end"
        case .messageStart: "message_start"
        case .messageUpdate: "message_update"
        case .messageEnd: "message_end"
        case .toolExecutionStart: "tool_execution_start"
        case .toolExecutionUpdate: "tool_execution_update"
        case .toolExecutionEnd: "tool_execution_end"
        case .inboxUpdate: "inbox_update"
        case .submission: "submission"
        case .autoRetryStart: "auto_retry_start"
        case .autoRetryEnd: "auto_retry_end"
        case .deferredPoll: "deferred_poll"
        case .entryAppended: "entry_appended"
        case .agentChanged: "agent_changed"
        case .usageChanged: "usage_changed"
        case .taskFailed: "task_failed"
        case .compactionStart: "compaction_start"
        case .compactionEnd: "compaction_end"
        }
    }
    public init(from decoder: any Decoder) throws {
        let o = try recordObject(decoder)
        let type: String = try recordRequired(o, "type")
        switch type {
        case "snapshot": self = .snapshot(try JSONValue.object(o).decode(DurableAgentSnapshot.self))
        case "run_start": self = .runStart(inputs: try recordRequired(o, "inputs"))
        case "run_end": self = .runEnd(inputs: try recordRequired(o, "inputs"))
        case "turn_start": self = .turnStart
        case "turn_end": self = .turnEnd
        case "message_start": self = .messageStart(message: try recordRequired(o, "message"))
        case "message_update": self = .messageUpdate(usage: try recordRequired(o, "usage"), changes: try recordRequired(o, "changes"))
        case "message_end": self = .messageEnd(entry: try recordRequired(o, "entry"))
        case "tool_execution_start": self = .toolExecutionStart(toolCallId: try recordRequired(o, "toolCallId"), toolName: try recordRequired(o, "toolName"), args: try recordRequired(o, "args"))
        case "tool_execution_update":
            self = .toolExecutionUpdate(toolCallId: try recordRequired(o, "toolCallId"), toolName: try recordRequired(o, "toolName"),
                output: try recordOptional(o, "output"), details: o["details"], diagnostics: try recordOptional(o, "diagnostics"))
        case "tool_execution_end": self = .toolExecutionEnd(toolCallId: try recordRequired(o, "toolCallId"), toolName: try recordRequired(o, "toolName"), entry: try recordOptional(o, "entry"))
        case "inbox_update": self = .inboxUpdate(items: try recordRequired(o, "items"))
        case "submission": self = .submission(record: try recordRequired(o, "record"))
        case "auto_retry_start": self = .autoRetryStart(attempt: try recordRequired(o, "attempt"), at: try recordRequired(o, "at"), errorMessage: try recordRequired(o, "errorMessage"))
        case "auto_retry_end": self = .autoRetryEnd(attempt: try recordRequired(o, "attempt"))
        case "deferred_poll": self = .deferredPoll(pollAt: try recordRequired(o, "pollAt"))
        case "entry_appended": self = .entryAppended(entry: try recordRequired(o, "entry"))
        case "agent_changed": self = .agentChanged(agent: try recordRequired(o, "agent"))
        case "usage_changed": self = .usageChanged(usage: try recordRequired(o, "usage"))
        case "task_failed": self = .taskFailed(taskId: try recordRequired(o, "taskId"), kind: try recordRequired(o, "kind"), message: try recordRequired(o, "message"))
        case "compaction_start": self = .compactionStart(taskId: try recordRequired(o, "taskId"), reason: try recordRequired(o, "reason"), blocking: try recordRequired(o, "blocking"))
        case "compaction_end": self = .compactionEnd(taskId: try recordRequired(o, "taskId"), reason: try recordRequired(o, "reason"))
        default: throw recordUnknown("type", type)
        }
    }
    public func encode(to encoder: any Encoder) throws {
        if case .snapshot(let snapshot) = self { try snapshot.encode(to: encoder); return }
        var o: JSONObject = ["type": .string(type)]
        switch self {
        case .snapshot, .turnStart, .turnEnd: break
        case .runStart(let inputs), .runEnd(let inputs): try recordSet(&o, "inputs", inputs)
        case .messageStart(let message): o["message"] = .object(message)
        case let .messageUpdate(usage, changes): o["usage"] = .object(usage); try recordSet(&o, "changes", changes)
        case .messageEnd(let entry), .entryAppended(let entry): try recordSet(&o, "entry", entry)
        case let .toolExecutionStart(id, name, args): o["toolCallId"] = .string(id); o["toolName"] = .string(name); o["args"] = .object(args)
        case let .toolExecutionUpdate(id, name, output, details, diagnostics):
            o["toolCallId"] = .string(id); o["toolName"] = .string(name)
            try recordSetOptional(&o, "output", output); o["details"] = details; try recordSetOptional(&o, "diagnostics", diagnostics)
        case let .toolExecutionEnd(id, name, entry): o["toolCallId"] = .string(id); o["toolName"] = .string(name); try recordSetOptional(&o, "entry", entry)
        case .inboxUpdate(let items): try recordSet(&o, "items", items)
        case .submission(let record): try recordSet(&o, "record", record)
        case let .autoRetryStart(attempt, at, error): try recordSet(&o, "attempt", attempt); try recordSet(&o, "at", at); o["errorMessage"] = .string(error)
        case .autoRetryEnd(let attempt): try recordSet(&o, "attempt", attempt)
        case .deferredPoll(let at): try recordSet(&o, "pollAt", at)
        case .agentChanged(let agent): try recordSet(&o, "agent", agent)
        case .usageChanged(let usage): try recordSet(&o, "usage", usage)
        case let .taskFailed(id, kind, message): try recordSet(&o, "taskId", id); o["kind"] = .string(kind); o["message"] = .string(message)
        case let .compactionStart(id, reason, blocking): try recordSet(&o, "taskId", id); try recordSet(&o, "reason", reason); try recordSet(&o, "blocking", blocking)
        case let .compactionEnd(id, reason): try recordSet(&o, "taskId", id); try recordSet(&o, "reason", reason)
        }
        try o.encode(to: encoder)
    }
}

/// Serial batches with an acquisition snapshot. The snapshot is read separately from start.
public final class DurableAgentEventWatch: Sendable {
    public typealias Listener = @Sendable ([DurableAgentEvent], PiSwiftChord.Context) async throws -> Void
    public let snapshot: DurableAgentSnapshot
    private let watch: CommittedWatch<[DurableAgentEvent]>
    internal init(snapshot: DurableAgentSnapshot, watch: CommittedWatch<[DurableAgentEvent]>) {
        self.snapshot = snapshot; self.watch = watch
    }
    public func start(_ listener: @escaping Listener) throws {
        try watch.start { events, _, context in try await listener(events, context) }
    }
    public func stop() async -> WatchEnd { await watch.stop() }
    public var closed: WatchEnd { get async { await watch.closed } }
    package func waitUntilIdle() async { await watch.waitUntilIdle() }
}

public typealias DurableAgentEventStream = DurableAgentEventWatch
