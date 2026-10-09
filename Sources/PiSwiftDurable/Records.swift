import PiSwiftChord

/// Ownership selected when a conversation is created. Stored conversations use a separate owner edge.
public enum ConversationOwnership: Sendable, Equatable, Codable {
    /// Creates a conversation with no task owner.
    case ownerless(extensions: JSONObject = [:])
    /// Uses task ownership or document scope.
    case task(taskId: TaskID, extensions: JSONObject = [:])
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        let tag: String = try recordRequired(object, "kind")
        switch tag {
        case "ownerless": try recordForbid(object, ["taskId"]); self = .ownerless(extensions: recordExtensions(object, excluding: ["kind"]))
        case "task": self = .task(taskId: try recordRequired(object, "taskId"), extensions: recordExtensions(object, excluding: ["kind", "taskId"]))
        default: throw recordUnknown("kind", tag)
        }
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws {
        var object: JSONObject
        switch self {
        case let .ownerless(extensions):
            object = extensions
            object["kind"] = .string("ownerless")
            try recordForbid(object, ["taskId"])
        case let .task(taskId, extensions):
            object = extensions
            object["kind"] = .string("task")
            try recordSet(&object, "taskId", taskId)
        }
        try object.encode(to: encoder)
    }
}

/// History inherited from a parent conversation through one inclusive entry.
public struct ConversationParent: Sendable, Equatable, Codable {
    /// The conversation that owns or is addressed by this value.
    public let conversationId: ConversationID
    /// The inclusive history boundary or scheduled time for this value.
    public let at: EntryID
    /// Unknown JSON members retained by upstream record copies.
    public let extensionFields: JSONObject
    /// Records the parent conversation and inclusive inherited entry boundary.
    public init(conversationId: ConversationID, at: EntryID, extensionFields: JSONObject = [:]) {
        self.conversationId = conversationId
        self.at = at
        self.extensionFields = extensionFields
    }
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        conversationId = try recordRequired(object, "conversationId")
        at = try recordRequired(object, "at")
        extensionFields = recordExtensions(object, excluding: ["conversationId", "at"])
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws {
        var object: JSONObject = extensionFields
        try recordSet(&object, "conversationId", conversationId)
        try recordSet(&object, "at", at)
        try object.encode(to: encoder)
    }
}

/// Task creator edge of a conversation.
public struct ConversationOwner: Sendable, Equatable, Codable {
    /// The conversation that owns or is addressed by this value.
    public let conversationId: ConversationID
    /// The ID of the task bound to this value or invocation.
    public let taskId: TaskID
    /// Unknown JSON members retained by upstream record copies.
    public let extensionFields: JSONObject
    /// Records the conversation and task that created the child conversation.
    public init(conversationId: ConversationID, taskId: TaskID, extensionFields: JSONObject = [:]) {
        self.conversationId = conversationId
        self.taskId = taskId
        self.extensionFields = extensionFields
    }
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        conversationId = try recordRequired(object, "conversationId")
        taskId = try recordRequired(object, "taskId")
        extensionFields = recordExtensions(object, excluding: ["conversationId", "taskId"])
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws {
        var object: JSONObject = extensionFields
        try recordSet(&object, "conversationId", conversationId)
        try recordSet(&object, "taskId", taskId)
        try object.encode(to: encoder)
    }
}

/// Immutable conversation identity, history ancestry, and task ownership.
public struct ConversationRecord: Sendable, Equatable, Codable {
    /// The stable identifier of this record or handle.
    public let id: ConversationID
    /// The parent conversation and inclusive inherited entry boundary.
    public let parent: ConversationParent?
    /// The task that created this conversation, when present.
    public let owner: ConversationOwner?
    /// Unknown JSON members retained by upstream record copies.
    public let extensionFields: JSONObject
    /// Creates the immutable identity, parent edge, and owner edge of a conversation.
    public init(id: ConversationID, parent: ConversationParent? = nil, owner: ConversationOwner? = nil, extensionFields: JSONObject = [:]) {
        self.id = id
        self.parent = parent
        self.owner = owner
        self.extensionFields = extensionFields
    }
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        id = try recordRequired(object, "id")
        parent = try recordOptional(object, "parent")
        owner = try recordOptional(object, "owner")
        extensionFields = recordExtensions(object, excluding: ["id", "parent", "owner"])
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws {
        var object: JSONObject = extensionFields
        try recordSet(&object, "id", id)
        try recordSetOptional(&object, "parent", parent)
        try recordSetOptional(&object, "owner", owner)
        try object.encode(to: encoder)
    }
}

/// Override of one visible entry in model context. Replacement messages stay opaque and lossless.
public enum ContextEdit: Sendable, Equatable, Codable {
    /// Removes the target entry's contribution from model context.
    case omit(target: EntryID, extensions: JSONObject = [:])
    /// Replaces the target entry's model contribution with the supplied messages.
    case replace(target: EntryID, messages: [JSONValue], extensions: JSONObject = [:])
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        let tag: String = try recordRequired(object, "action")
        switch tag {
        case "omit": try recordForbid(object, ["messages"]); self = .omit(target: try recordRequired(object, "target"), extensions: recordExtensions(object, excluding: ["action", "target"]))
        case "replace": self = .replace(target: try recordRequired(object, "target"), messages: try recordRequired(object, "messages"), extensions: recordExtensions(object, excluding: ["action", "target", "messages"]))
        default: throw recordUnknown("action", tag)
        }
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws {
        var object: JSONObject
        switch self {
        case let .omit(target, extensions):
            object = extensions
            object["action"] = .string("omit")
            try recordForbid(object, ["messages"])
            try recordSet(&object, "target", target)
        case let .replace(target, messages, extensions):
            object = extensions
            object["action"] = .string("replace")
            try recordSet(&object, "target", target)
            try recordSet(&object, "messages", messages)
        }
        try object.encode(to: encoder)
    }
}

/// Immutable transcript event. Opaque model messages and application data retain all JSON members.
public struct EntryRecord: Sendable, Equatable, Codable {
    /// The stable identifier of this record or handle.
    public let id: EntryID
    /// The conversation that owns or is addressed by this value.
    public let conversationId: ConversationID
    /// The entry kind used to decode application data or recognize built-in entries.
    public let kind: String
    /// Opaque model messages contributed by this entry.
    public let model: [JSONValue]?
    /// Application data retained with the durable entry.
    public let data: JSONValue?
    /// The entry that defines the active model-context lower bound.
    public let head: EntryID?
    /// Context changes applied to earlier visible entries.
    public let edits: [ContextEdit]?
    /// The task that appended this entry, when present.
    public let byTaskId: TaskID?
    /// Unknown JSON members retained by upstream record copies.
    public let extensionFields: JSONObject
    /// Creates an immutable transcript record with opaque model and application data.
    public init(id: EntryID, conversationId: ConversationID, kind: String, model: [JSONValue]? = nil, data: JSONValue? = nil, head: EntryID? = nil, edits: [ContextEdit]? = nil, byTaskId: TaskID? = nil, extensionFields: JSONObject = [:]) {
        self.id = id
        self.conversationId = conversationId
        self.kind = kind
        self.model = model
        self.data = data
        self.head = head
        self.edits = edits
        self.byTaskId = byTaskId
        self.extensionFields = extensionFields
    }
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        id = try recordRequired(object, "id")
        conversationId = try recordRequired(object, "conversationId")
        kind = try recordRequired(object, "kind")
        model = try recordOptional(object, "model")
        data = try recordOptional(object, "data")
        head = try recordOptional(object, "head")
        edits = try recordOptional(object, "edits")
        byTaskId = try recordOptional(object, "byTaskId")
        extensionFields = recordExtensions(object, excluding: ["id", "conversationId", "kind", "model", "data", "head", "edits", "byTaskId"])
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws {
        var object: JSONObject = extensionFields
        try recordSet(&object, "id", id)
        try recordSet(&object, "conversationId", conversationId)
        try recordSet(&object, "kind", kind)
        try recordSetOptional(&object, "model", model)
        try recordSetOptional(&object, "data", data)
        try recordSetOptional(&object, "head", head)
        try recordSetOptional(&object, "edits", edits)
        try recordSetOptional(&object, "byTaskId", byTaskId)
        try object.encode(to: encoder)
    }
}

/// Entry draft context boundary; self selects the ID that the Session assigns.
public enum EntryDraftHead: Sendable, Equatable, Codable {
    /// Uses the visible state at an inclusive entry boundary.
    case entry(EntryID)
    /// Uses the appended entry itself as the context head.
    case `self`
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        if value == .string("self") { self = .self }
        else { self = .entry(try value.decode(EntryID.self)) }
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .entry(let id): try id.encode(to: encoder)
        case .self: try JSONValue.string("self").encode(to: encoder)
        }
    }
}

/// Entry content before the Session assigns identity and task attribution.
public struct EntryDraft: Sendable, Equatable, Codable {
    /// The stored record or document kind.
    public let kind: String
    /// Opaque model messages to contribute when this entry is appended.
    public let model: [JSONValue]?
    /// Application data retained with the durable entry.
    public let data: JSONValue?
    /// The entry that defines the active model-context lower bound.
    public let head: EntryDraftHead?
    /// Context changes applied to earlier visible entries.
    public let edits: [ContextEdit]?
    /// Unknown JSON members retained by upstream record copies.
    public let extensionFields: JSONObject
    /// Creates a pending transcript entry before the transaction allocates its ID.
    public init(kind: String, model: [JSONValue]? = nil, data: JSONValue? = nil, head: EntryDraftHead? = nil, edits: [ContextEdit]? = nil, extensionFields: JSONObject = [:]) {
        self.kind = kind
        self.model = model
        self.data = data
        self.head = head
        self.edits = edits
        self.extensionFields = extensionFields
    }
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        kind = try recordRequired(object, "kind")
        model = try recordOptional(object, "model")
        data = try recordOptional(object, "data")
        head = try recordOptional(object, "head")
        edits = try recordOptional(object, "edits")
        extensionFields = recordExtensions(object, excluding: ["kind", "model", "data", "head", "edits"])
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws {
        var object: JSONObject = extensionFields
        try recordSet(&object, "kind", kind)
        try recordSetOptional(&object, "model", model)
        try recordSetOptional(&object, "data", data)
        try recordSetOptional(&object, "head", head)
        try recordSetOptional(&object, "edits", edits)
        try object.encode(to: encoder)
    }
}

/// How a waiting task handles the tasks in its wait set.
public enum JoinPolicy: String, Sendable, Equatable, Codable {
    /// Aborts unfinished joined tasks after a dependency fails.
    case failFast
    /// Waits for every joined task, including failed tasks.
    case allSettled
}

/// A conversation owns a top-level task; a task owns a child task in the same conversation.
public enum TaskOwnership: Sendable, Equatable, Codable {
    /// Assigns the task to conversation-owned work.
    case conversation(extensions: JSONObject = [:])
    /// Assigns the task to the supplied parent task.
    case task(taskId: TaskID, extensions: JSONObject = [:])
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        let tag: String = try recordRequired(object, "kind")
        switch tag {
        case "conversation": try recordForbid(object, ["taskId"]); self = .conversation(extensions: recordExtensions(object, excluding: ["kind"]))
        case "task": self = .task(taskId: try recordRequired(object, "taskId"), extensions: recordExtensions(object, excluding: ["kind", "taskId"]))
        default: throw recordUnknown("kind", tag)
        }
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws {
        var object: JSONObject
        switch self {
        case let .conversation(extensions):
            object = extensions
            object["kind"] = .string("conversation")
            try recordForbid(object, ["taskId"])
        case let .task(taskId, extensions):
            object = extensions
            object["kind"] = .string("task")
            try recordSet(&object, "taskId", taskId)
        }
        try object.encode(to: encoder)
    }
}

/// JSON error snapshot stored in place of a runtime error.
public struct TaskOutcomeError: Sendable, Equatable, Codable {
    /// Text that describes the error, diagnostic, or model response.
    public let message: String
    /// Optional JSON data that explains the failure or settlement.
    public let detail: JSONValue?
    /// Unknown JSON members retained by upstream record copies.
    public let extensionFields: JSONObject
    /// Stores a task failure message and optional JSON detail.
    public init(message: String, detail: JSONValue? = nil, extensionFields: JSONObject = [:]) {
        self.message = message
        self.detail = detail
        self.extensionFields = extensionFields
    }
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        message = try recordRequired(object, "message")
        detail = try recordOptional(object, "detail")
        extensionFields = recordExtensions(object, excluding: ["message", "detail"])
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws {
        var object: JSONObject = extensionFields
        try recordSet(&object, "message", message)
        try recordSetOptional(&object, "detail", detail)
        try object.encode(to: encoder)
    }
}

/// Durable task result receipt. Result values remain opaque JSON.
public enum TaskOutcome: Sendable, Equatable, Codable {
    /// Stores the task's successful result.
    case completed(result: JSONValue, extensions: JSONObject = [:])
    /// Stores an application failure and optional result.
    case failed(error: TaskOutcomeError, result: JSONValue? = nil, extensions: JSONObject = [:])
    /// Stores the result of cancellation.
    case aborted(reason: String? = nil, result: JSONValue? = nil, extensions: JSONObject = [:])
    /// Stores the reason a task can no longer execute.
    case orphaned(reason: String, extensions: JSONObject = [:])
    /// Stores an unexpected handler or runtime failure.
    case faulted(error: TaskOutcomeError, extensions: JSONObject = [:])
    /// The stored execution or submission state tag.
    public var status: String {
        switch self {
        case .completed: "completed"
        case .failed: "failed"
        case .aborted: "aborted"
        case .orphaned: "orphaned"
        case .faulted: "faulted"
        }
    }
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        let tag: String = try recordRequired(object, "status")
        switch tag {
        case "completed": try recordForbid(object, ["error", "reason"]); self = .completed(result: try recordRequired(object, "result"), extensions: recordExtensions(object, excluding: ["status", "result"]))
        case "failed": try recordForbid(object, ["reason"]); self = .failed(error: try recordRequired(object, "error"), result: try recordOptional(object, "result"), extensions: recordExtensions(object, excluding: ["status", "error", "result"]))
        case "aborted": try recordForbid(object, ["error"]); self = .aborted(reason: try recordOptional(object, "reason"), result: try recordOptional(object, "result"), extensions: recordExtensions(object, excluding: ["status", "reason", "result"]))
        case "orphaned": try recordForbid(object, ["error", "result"]); self = .orphaned(reason: try recordRequired(object, "reason"), extensions: recordExtensions(object, excluding: ["status", "reason"]))
        case "faulted": try recordForbid(object, ["reason", "result"]); self = .faulted(error: try recordRequired(object, "error"), extensions: recordExtensions(object, excluding: ["status", "error"]))
        default: throw recordUnknown("status", tag)
        }
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws {
        var object: JSONObject
        switch self {
        case let .completed(result, extensions):
            object = extensions
            object["status"] = .string("completed")
            try recordForbid(object, ["error", "reason"])
            try recordSet(&object, "result", result)
        case let .failed(error, result, extensions):
            object = extensions
            object["status"] = .string("failed")
            try recordForbid(object, ["reason"])
            try recordSet(&object, "error", error)
            try recordSetOptional(&object, "result", result)
        case let .aborted(reason, result, extensions):
            object = extensions
            object["status"] = .string("aborted")
            try recordForbid(object, ["error"])
            try recordSetOptional(&object, "reason", reason)
            try recordSetOptional(&object, "result", result)
        case let .orphaned(reason, extensions):
            object = extensions
            object["status"] = .string("orphaned")
            try recordForbid(object, ["error", "result"])
            try recordSet(&object, "reason", reason)
        case let .faulted(error, extensions):
            object = extensions
            object["status"] = .string("faulted")
            try recordForbid(object, ["reason", "result"])
            try recordSet(&object, "error", error)
        }
        try object.encode(to: encoder)
    }
}

/// Complete durable execution state. Completing holds an outcome until ordinary owned work settles.
public enum TaskState: Sendable, Equatable, Codable {
    /// Work is saved and waits for scheduler admission.
    case pending(checkpoint: JSONValue, extensions: JSONObject = [:])
    /// Work is executing with its saved checkpoint.
    case running(checkpoint: JSONValue, extensions: JSONObject = [:])
    /// Work waits for the selected tasks under its join policy.
    case waiting(checkpoint: JSONValue, on: [TaskID], policy: JoinPolicy, extensions: JSONObject = [:])
    /// An outcome is saved while ordinary owned work finishes.
    case completing(outcome: TaskOutcome, extensions: JSONObject = [:])
    /// The task has a final outcome and cannot execute again.
    case terminal(outcome: TaskOutcome, extensions: JSONObject = [:])
    /// The stored execution or submission state tag.
    public var status: String {
        switch self {
        case .pending: "pending"
        case .running: "running"
        case .waiting: "waiting"
        case .completing: "completing"
        case .terminal: "terminal"
        }
    }
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        let tag: String = try recordRequired(object, "status")
        switch tag {
        case "pending": try recordForbid(object, ["on", "outcome", "policy"]); self = .pending(checkpoint: try recordRequired(object, "checkpoint"), extensions: recordExtensions(object, excluding: ["status", "checkpoint"]))
        case "running": try recordForbid(object, ["on", "outcome", "policy"]); self = .running(checkpoint: try recordRequired(object, "checkpoint"), extensions: recordExtensions(object, excluding: ["status", "checkpoint"]))
        case "waiting": try recordForbid(object, ["outcome"]); self = .waiting(checkpoint: try recordRequired(object, "checkpoint"), on: try recordRequired(object, "on"), policy: try recordRequired(object, "policy"), extensions: recordExtensions(object, excluding: ["status", "checkpoint", "on", "policy"]))
        case "completing": try recordForbid(object, ["checkpoint", "on", "policy"]); self = .completing(outcome: try recordRequired(object, "outcome"), extensions: recordExtensions(object, excluding: ["status", "outcome"]))
        case "terminal": try recordForbid(object, ["checkpoint", "on", "policy"]); self = .terminal(outcome: try recordRequired(object, "outcome"), extensions: recordExtensions(object, excluding: ["status", "outcome"]))
        default: throw recordUnknown("status", tag)
        }
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws {
        var object: JSONObject
        switch self {
        case let .pending(checkpoint, extensions):
            object = extensions
            object["status"] = .string("pending")
            try recordForbid(object, ["on", "outcome", "policy"])
            try recordSet(&object, "checkpoint", checkpoint)
        case let .running(checkpoint, extensions):
            object = extensions
            object["status"] = .string("running")
            try recordForbid(object, ["on", "outcome", "policy"])
            try recordSet(&object, "checkpoint", checkpoint)
        case let .waiting(checkpoint, on, policy, extensions):
            object = extensions
            object["status"] = .string("waiting")
            try recordForbid(object, ["outcome"])
            try recordSet(&object, "checkpoint", checkpoint)
            try recordSet(&object, "on", on)
            try recordSet(&object, "policy", policy)
        case let .completing(outcome, extensions):
            object = extensions
            object["status"] = .string("completing")
            try recordForbid(object, ["checkpoint", "on", "policy"])
            try recordSet(&object, "outcome", outcome)
        case let .terminal(outcome, extensions):
            object = extensions
            object["status"] = .string("terminal")
            try recordForbid(object, ["checkpoint", "on", "policy"])
            try recordSet(&object, "outcome", outcome)
        }
        try object.encode(to: encoder)
    }
}

/// Complete replacement task record. Input, checkpoints, results, and memos retain opaque JSON.
public struct TaskRecord: Sendable, Equatable, Codable {
    /// The stable identifier of this record or handle.
    public let id: TaskID
    /// The conversation that owns or is addressed by this value.
    public let conversationId: ConversationID
    /// The stable definition name used to resolve this task.
    public let kind: String
    /// The stored schema or task definition version.
    public let version: Double
    /// The decoded or saved input supplied when the task was created.
    public let input: JSONValue
    /// The current durable task, graph, or conversation state.
    public let state: TaskState
    /// The parent task that owns this task, when present.
    public let owner: TaskID?
    /// Whether this task can outlive ordinary conversation work.
    public let background: Bool
    /// Whether an abort request has been saved for this task.
    public let abortRequested: Bool
    /// The time at which task execution started, in milliseconds.
    public let startedAt: Double?
    /// The time at which task execution ended, in milliseconds.
    public let endedAt: Double?
    /// The durable task memos used to avoid repeated effects.
    public let memos: JSONObject?
    /// Unknown JSON members retained by upstream record copies.
    public let extensionFields: JSONObject
    /// Creates a complete stored task record, including ownership and execution state.
    public init(id: TaskID, conversationId: ConversationID, kind: String, version: Double, input: JSONValue, state: TaskState, owner: TaskID? = nil, background: Bool = false, abortRequested: Bool = false, startedAt: Double? = nil, endedAt: Double? = nil, memos: JSONObject? = nil, extensionFields: JSONObject = [:]) {
        self.id = id
        self.conversationId = conversationId
        self.kind = kind
        self.version = version
        self.input = input
        self.state = state
        self.owner = owner
        self.background = background
        self.abortRequested = abortRequested
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.memos = memos
        self.extensionFields = extensionFields
    }
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        id = try recordRequired(object, "id")
        conversationId = try recordRequired(object, "conversationId")
        kind = try recordRequired(object, "kind")
        version = try recordRequired(object, "version")
        input = try recordRequired(object, "input")
        state = try recordRequired(object, "state")
        owner = try recordOptional(object, "owner")
        background = try recordRequired(object, "background")
        abortRequested = try recordRequired(object, "abortRequested")
        startedAt = try recordOptional(object, "startedAt")
        endedAt = try recordOptional(object, "endedAt")
        memos = try recordOptional(object, "memos")
        if state.status == "completing" || state.status == "terminal" { try recordForbid(object, ["memos"]) }
        extensionFields = recordExtensions(object, excluding: ["id", "conversationId", "kind", "version", "input", "state", "owner", "background", "abortRequested", "startedAt", "endedAt", "memos"])
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws {
        if (state.status == "completing" || state.status == "terminal"), memos != nil {
            throw recordUnknown("task memos", "completing and terminal tasks have no memos")
        }
        var object: JSONObject = extensionFields
        try recordSet(&object, "id", id)
        try recordSet(&object, "conversationId", conversationId)
        try recordSet(&object, "kind", kind)
        try recordSet(&object, "version", version)
        try recordSet(&object, "input", input)
        try recordSet(&object, "state", state)
        try recordSetOptional(&object, "owner", owner)
        try recordSet(&object, "background", background)
        try recordSet(&object, "abortRequested", abortRequested)
        try recordSetOptional(&object, "startedAt", startedAt)
        try recordSetOptional(&object, "endedAt", endedAt)
        try recordSetOptional(&object, "memos", memos)
        try object.encode(to: encoder)
    }
}

/// Lifecycle of admitted user input.
public enum InputSubmissionState: Sendable, Equatable, Codable {
    /// The submission waits in the conversation inbox.
    case queued(extensions: JSONObject = [:])
    /// The input has entered the conversation at its saved entry.
    case placed(entry: EntryID, extensions: JSONObject = [:])
    /// The submission or tool execution has a final result.
    case done(entry: EntryID, answer: EntryID, extensions: JSONObject = [:])
    /// The input ended without an answer and has a saved reason.
    case unanswered(reason: String, entry: EntryID? = nil, detail: JSONValue? = nil, extensions: JSONObject = [:])
    /// The stored execution or submission state tag.
    public var status: String {
        switch self {
        case .queued: "queued"
        case .placed: "placed"
        case .done: "done"
        case .unanswered: "unanswered"
        }
    }
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        let tag: String = try recordRequired(object, "status")
        switch tag {
        case "queued": try recordForbid(object, ["answer", "detail", "entry", "reason"]); self = .queued(extensions: recordExtensions(object, excluding: ["status"]))
        case "placed": try recordForbid(object, ["answer", "detail", "reason"]); self = .placed(entry: try recordRequired(object, "entry"), extensions: recordExtensions(object, excluding: ["status", "entry"]))
        case "done": try recordForbid(object, ["detail", "reason"]); self = .done(entry: try recordRequired(object, "entry"), answer: try recordRequired(object, "answer"), extensions: recordExtensions(object, excluding: ["status", "entry", "answer"]))
        case "unanswered": try recordForbid(object, ["answer"]); self = .unanswered(reason: try recordRequired(object, "reason"), entry: try recordOptional(object, "entry"), detail: try recordOptional(object, "detail"), extensions: recordExtensions(object, excluding: ["status", "reason", "entry", "detail"]))
        default: throw recordUnknown("status", tag)
        }
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws {
        var object: JSONObject
        switch self {
        case let .queued(extensions):
            object = extensions
            object["status"] = .string("queued")
            try recordForbid(object, ["answer", "detail", "entry", "reason"])
        case let .placed(entry, extensions):
            object = extensions
            object["status"] = .string("placed")
            try recordForbid(object, ["answer", "detail", "reason"])
            try recordSet(&object, "entry", entry)
        case let .done(entry, answer, extensions):
            object = extensions
            object["status"] = .string("done")
            try recordForbid(object, ["detail", "reason"])
            try recordSet(&object, "entry", entry)
            try recordSet(&object, "answer", answer)
        case let .unanswered(reason, entry, detail, extensions):
            object = extensions
            object["status"] = .string("unanswered")
            try recordForbid(object, ["answer"])
            try recordSet(&object, "reason", reason)
            try recordSetOptional(&object, "entry", entry)
            try recordSetOptional(&object, "detail", detail)
        }
        try object.encode(to: encoder)
    }
}

/// Lifecycle of a passive entry write.
public enum WriteSubmissionState: Sendable, Equatable, Codable {
    /// The submission waits in the conversation inbox.
    case queued(extensions: JSONObject = [:])
    /// The submission or tool execution has a final result.
    case done(entry: EntryID, extensions: JSONObject = [:])
    /// The input ended without an answer and has a saved reason.
    case unanswered(reason: String, detail: JSONValue? = nil, extensions: JSONObject = [:])
    /// The stored execution or submission state tag.
    public var status: String {
        switch self {
        case .queued: "queued"
        case .done: "done"
        case .unanswered: "unanswered"
        }
    }
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        try recordForbid(object, ["answer"])
        let tag: String = try recordRequired(object, "status")
        switch tag {
        case "queued": try recordForbid(object, ["detail", "entry", "reason"]); self = .queued(extensions: recordExtensions(object, excluding: ["status"]))
        case "done": try recordForbid(object, ["detail", "reason"]); self = .done(entry: try recordRequired(object, "entry"), extensions: recordExtensions(object, excluding: ["status", "entry"]))
        case "unanswered": try recordForbid(object, ["entry"]); self = .unanswered(reason: try recordRequired(object, "reason"), detail: try recordOptional(object, "detail"), extensions: recordExtensions(object, excluding: ["status", "reason", "detail"]))
        default: throw recordUnknown("status", tag)
        }
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws {
        var object: JSONObject
        switch self {
        case let .queued(extensions):
            object = extensions
            object["status"] = .string("queued")
            try recordForbid(object, ["detail", "entry", "reason"])
        case let .done(entry, extensions):
            object = extensions
            object["status"] = .string("done")
            try recordForbid(object, ["detail", "reason"])
            try recordSet(&object, "entry", entry)
        case let .unanswered(reason, detail, extensions):
            object = extensions
            object["status"] = .string("unanswered")
            try recordForbid(object, ["entry"])
            try recordSet(&object, "reason", reason)
            try recordSetOptional(&object, "detail", detail)
        }
        try recordForbid(object, ["answer"])
        try object.encode(to: encoder)
    }
}

/// Durable lifecycle of admitted input or a passive write. JSON uses flat type and status fields.
public enum SubmissionRecord: Sendable, Equatable, Codable {
    /// Stores user content and its admission policy.
    case input(id: SubmissionID, conversationId: ConversationID, requestId: String? = nil, state: InputSubmissionState)
    /// Stores an entry write request.
    case write(id: SubmissionID, conversationId: ConversationID, requestId: String? = nil, state: WriteSubmissionState)
    /// The stable identifier of this record or handle.
    public var id: SubmissionID {
        switch self { case .input(let id, _, _, _), .write(let id, _, _, _): id }
    }
    /// The conversation that owns or is addressed by this value.
    public var conversationId: ConversationID {
        switch self { case .input(_, let id, _, _), .write(_, let id, _, _): id }
    }
    /// An optional conversation-scoped key that makes request admission idempotent.
    public var requestId: String? {
        switch self { case .input(_, _, let value, _), .write(_, _, let value, _): value }
    }
    /// The stored input or write submission tag.
    public var type: String {
        switch self { case .input: "input"; case .write: "write" }
    }
    /// The stored execution or submission state tag.
    public var status: String {
        switch self { case .input(_, _, _, let state): state.status; case .write(_, _, _, let state): state.status }
    }
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        var object = try recordObject(decoder)
        let type: String = try recordRequired(object, "type")
        let id: SubmissionID = try recordRequired(object, "id")
        let conversationId: ConversationID = try recordRequired(object, "conversationId")
        let requestId: String? = try recordOptional(object, "requestId")
        for key in ["type", "id", "conversationId", "requestId"] { object[key] = nil }
        switch type {
        case "input": self = .input(id: id, conversationId: conversationId, requestId: requestId, state: try JSONValue.object(object).decode())
        case "write": self = .write(id: id, conversationId: conversationId, requestId: requestId, state: try JSONValue.object(object).decode())
        default: throw recordUnknown("submission type", type)
        }
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws {
        var object: JSONObject
        switch self {
        case .input(_, _, _, let state): object = try JSONValue(encoding: state).decode()
        case .write(_, _, _, let state): object = try JSONValue(encoding: state).decode()
        }
        object["type"] = .string(type)
        try recordSet(&object, "id", id)
        try recordSet(&object, "conversationId", conversationId)
        try recordSetOptional(&object, "requestId", requestId)
        try object.encode(to: encoder)
    }
}

/// Terminal status staged for an existing submission.
public enum SubmissionSettlement: Sendable, Equatable, Codable {
    /// The submission or tool execution has a final result.
    case done(answer: EntryID, extensions: JSONObject = [:])
    /// The input ended without an answer and has a saved reason.
    case unanswered(reason: String, detail: JSONValue? = nil, extensions: JSONObject = [:])
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        let tag: String = try recordRequired(object, "status")
        switch tag {
        case "done": try recordForbid(object, ["detail", "reason"]); self = .done(answer: try recordRequired(object, "answer"), extensions: recordExtensions(object, excluding: ["status", "answer"]))
        case "unanswered": try recordForbid(object, ["answer"]); self = .unanswered(reason: try recordRequired(object, "reason"), detail: try recordOptional(object, "detail"), extensions: recordExtensions(object, excluding: ["status", "reason", "detail"]))
        default: throw recordUnknown("status", tag)
        }
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws {
        var object: JSONObject
        switch self {
        case let .done(answer, extensions):
            object = extensions
            object["status"] = .string("done")
            try recordForbid(object, ["detail", "reason"])
            try recordSet(&object, "answer", answer)
        case let .unanswered(reason, detail, extensions):
            object = extensions
            object["status"] = .string("unanswered")
            try recordForbid(object, ["answer"])
            try recordSet(&object, "reason", reason)
            try recordSetOptional(&object, "detail", detail)
        }
        try object.encode(to: encoder)
    }
}
