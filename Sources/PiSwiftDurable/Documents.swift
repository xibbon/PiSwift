import PiSwiftChord

// The source unions require conversation policies and exclude them in the other scopes.
func validateDocumentPolicies(scope: DocumentScope, history: DocumentHistory?, fork: DocumentFork?) throws {
    switch scope {
    case .conversation:
        guard let history, let fork else {
            throw recordUnknown("document policies", "conversation scope requires history and fork")
        }
        guard history != .latest || fork != .asOf else {
            throw recordUnknown("document policies", "latest history does not support asOf forks")
        }
    case .session, .task:
        guard history == nil, fork == nil else {
            throw recordUnknown("document policies", "session and task scopes have no history or fork")
        }
    }
}

/// Document history retention.
public enum DocumentHistory: String, Sendable, Equatable, Codable { case latest, rewindable }
/// Initialization of a conversation document in a history fork.
public enum DocumentFork: String, Sendable, Equatable, Codable { case initial, current, asOf }

/// Exact persisted owner scope of a document.
public enum DocumentScope: Sendable, Equatable, Codable {
    case session(extensions: JSONObject = [:])
    case conversation(conversationId: ConversationID, extensions: JSONObject = [:])
    case task(taskId: TaskID, extensions: JSONObject = [:])
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        let tag: String = try recordRequired(object, "kind")
        switch tag {
        case "session": try recordForbid(object, ["conversationId", "taskId"]); self = .session(extensions: recordExtensions(object, excluding: ["kind"]))
        case "conversation": try recordForbid(object, ["taskId"]); self = .conversation(conversationId: try recordRequired(object, "conversationId"), extensions: recordExtensions(object, excluding: ["kind", "conversationId"]))
        case "task": try recordForbid(object, ["conversationId"]); self = .task(taskId: try recordRequired(object, "taskId"), extensions: recordExtensions(object, excluding: ["kind", "taskId"]))
        default: throw recordUnknown("kind", tag)
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var object: JSONObject
        switch self {
        case let .session(extensions):
            object = extensions
            object["kind"] = .string("session")
            try recordForbid(object, ["conversationId", "taskId"])
        case let .conversation(conversationId, extensions):
            object = extensions
            object["kind"] = .string("conversation")
            try recordForbid(object, ["taskId"])
            try recordSet(&object, "conversationId", conversationId)
        case let .task(taskId, extensions):
            object = extensions
            object["kind"] = .string("task")
            try recordForbid(object, ["conversationId"])
            try recordSet(&object, "taskId", taskId)
        }
        try object.encode(to: encoder)
    }
}

/// Definition semantics. Session and task documents have no history or fork fields.
public enum DocumentSemantics: Sendable, Equatable, Codable {
    case session(extensions: JSONObject = [:])
    case conversation(history: DocumentHistory, fork: DocumentFork, extensions: JSONObject = [:])
    case task(extensions: JSONObject = [:])
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        let tag: String = try recordRequired(object, "scope")
        switch tag {
        case "session": try recordForbid(object, ["fork", "history"]); self = .session(extensions: recordExtensions(object, excluding: ["scope"]))
        case "conversation": self = .conversation(history: try recordRequired(object, "history"), fork: try recordRequired(object, "fork"), extensions: recordExtensions(object, excluding: ["scope", "history", "fork"]))
        case "task": try recordForbid(object, ["fork", "history"]); self = .task(extensions: recordExtensions(object, excluding: ["scope"]))
        default: throw recordUnknown("scope", tag)
        }
        if case .conversation(let history, let fork, _) = self, history == .latest, fork == .asOf {
            throw recordUnknown("document policies", "latest history does not support asOf forks")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        if case .conversation(let history, let fork, _) = self, history == .latest, fork == .asOf {
            throw recordUnknown("document policies", "latest history does not support asOf forks")
        }
        var object: JSONObject
        switch self {
        case let .session(extensions):
            object = extensions
            object["scope"] = .string("session")
            try recordForbid(object, ["fork", "history"])
        case let .conversation(history, fork, extensions):
            object = extensions
            object["scope"] = .string("conversation")
            try recordSet(&object, "history", history)
            try recordSet(&object, "fork", fork)
        case let .task(extensions):
            object = extensions
            object["scope"] = .string("task")
            try recordForbid(object, ["fork", "history"])
        }
        try object.encode(to: encoder)
    }
}

/// Lifecycle of a document incarnation. The content holds its version; a key identifies a family member.
public struct DocumentRecord: Sendable, Equatable, Codable {
    public let id: DocumentID
    public let kind: String
    public let scope: DocumentScope
    public let createdAt: Seq
    public let key: String?
    public let retiredAt: Seq?
    public let history: DocumentHistory?
    public let fork: DocumentFork?
    /// Unknown JSON members retained by upstream record copies.
    public let extensionFields: JSONObject
    /// The JSON boundary checks scope, history, and fork consistency.
    public init(id: DocumentID, kind: String, scope: DocumentScope, createdAt: Seq, key: String? = nil, retiredAt: Seq? = nil, history: DocumentHistory? = nil, fork: DocumentFork? = nil, extensionFields: JSONObject = [:]) {
        self.id = id
        self.kind = kind
        self.scope = scope
        self.createdAt = createdAt
        self.key = key
        self.retiredAt = retiredAt
        self.history = history
        self.fork = fork
        self.extensionFields = extensionFields
    }
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        id = try recordRequired(object, "id")
        kind = try recordRequired(object, "kind")
        scope = try recordRequired(object, "scope")
        createdAt = try recordRequired(object, "createdAt")
        key = try recordOptional(object, "key")
        retiredAt = try recordOptional(object, "retiredAt")
        history = try recordOptional(object, "history")
        fork = try recordOptional(object, "fork")
        try validateDocumentPolicies(scope: scope, history: history, fork: fork)
        extensionFields = recordExtensions(object, excluding: ["id", "kind", "scope", "createdAt", "key", "retiredAt", "history", "fork"])
    }
    public func encode(to encoder: any Encoder) throws {
        try validateDocumentPolicies(scope: scope, history: history, fork: fork)
        var object: JSONObject = extensionFields
        try recordSet(&object, "id", id)
        try recordSet(&object, "kind", kind)
        try recordSet(&object, "scope", scope)
        try recordSet(&object, "createdAt", createdAt)
        try recordSetOptional(&object, "key", key)
        try recordSetOptional(&object, "retiredAt", retiredAt)
        try recordSetOptional(&object, "history", history)
        try recordSetOptional(&object, "fork", fork)
        try object.encode(to: encoder)
    }
}

/// Document fields before storage assigns creation and retirement sequences.
public struct DocumentCreate: Sendable, Equatable, Codable {
    public let id: DocumentID
    public let kind: String
    public let scope: DocumentScope
    public let key: String?
    public let history: DocumentHistory?
    public let fork: DocumentFork?
    /// Unknown JSON members retained by upstream record copies.
    public let extensionFields: JSONObject
    /// The JSON boundary checks scope, history, and fork consistency.
    public init(id: DocumentID, kind: String, scope: DocumentScope, key: String? = nil, history: DocumentHistory? = nil, fork: DocumentFork? = nil, extensionFields: JSONObject = [:]) {
        self.id = id
        self.kind = kind
        self.scope = scope
        self.key = key
        self.history = history
        self.fork = fork
        self.extensionFields = extensionFields
    }
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        id = try recordRequired(object, "id")
        kind = try recordRequired(object, "kind")
        scope = try recordRequired(object, "scope")
        key = try recordOptional(object, "key")
        history = try recordOptional(object, "history")
        fork = try recordOptional(object, "fork")
        try validateDocumentPolicies(scope: scope, history: history, fork: fork)
        extensionFields = recordExtensions(object, excluding: ["id", "kind", "scope", "key", "history", "fork"])
    }
    public func encode(to encoder: any Encoder) throws {
        try validateDocumentPolicies(scope: scope, history: history, fork: fork)
        var object: JSONObject = extensionFields
        try recordSet(&object, "id", id)
        try recordSet(&object, "kind", kind)
        try recordSet(&object, "scope", scope)
        try recordSetOptional(&object, "key", key)
        try recordSetOptional(&object, "history", history)
        try recordSetOptional(&object, "fork", fork)
        try object.encode(to: encoder)
    }
}

/// Complete document checkpoint; creation always supplies a base.
public struct DocumentBaseContent: Sendable, Equatable, Codable {
    public let version: Int
    public let value: JSONObject
    /// Unknown JSON members retained by upstream record copies.
    public let extensionFields: JSONObject
    public init(version: Int, value: JSONObject, extensionFields: JSONObject = [:]) {
        self.version = version
        self.value = value
        self.extensionFields = extensionFields
    }
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        let kind: String = try recordRequired(object, "kind")
        guard kind == "base" else { throw recordUnknown("document content kind", kind) }
        try recordForbid(object, ["ops"])
        version = try recordRequired(object, "version")
        value = try recordRequired(object, "value")
        extensionFields = recordExtensions(object, excluding: ["kind", "version", "value"])
    }
    public func encode(to encoder: any Encoder) throws {
        var object: JSONObject = extensionFields
        object["kind"] = .string("base")
        try recordForbid(object, ["ops"])
        try recordSet(&object, "version", version)
        try recordSet(&object, "value", value)
        try object.encode(to: encoder)
    }
}

/// Document checkpoint or Chord operation batch.
public enum DocumentContent: Sendable, Equatable, Codable {
    case base(version: Int, value: JSONObject, extensions: JSONObject = [:])
    case delta(version: Int, ops: [Delta.Op], extensions: JSONObject = [:])
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        let tag: String = try recordRequired(object, "kind")
        switch tag {
        case "base": try recordForbid(object, ["ops"]); self = .base(version: try recordRequired(object, "version"), value: try recordRequired(object, "value"), extensions: recordExtensions(object, excluding: ["kind", "version", "value"]))
        case "delta": try recordForbid(object, ["value"]); self = .delta(version: try recordRequired(object, "version"), ops: try recordRequired(object, "ops"), extensions: recordExtensions(object, excluding: ["kind", "version", "ops"]))
        default: throw recordUnknown("kind", tag)
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var object: JSONObject
        switch self {
        case let .base(version, value, extensions):
            object = extensions
            object["kind"] = .string("base")
            try recordForbid(object, ["ops"])
            try recordSet(&object, "version", version)
            try recordSet(&object, "value", value)
        case let .delta(version, ops, extensions):
            object = extensions
            object["kind"] = .string("delta")
            try recordForbid(object, ["value"])
            try recordSet(&object, "version", version)
            try recordSet(&object, "ops", ops)
        }
        try object.encode(to: encoder)
    }
}

/// Exact persisted incarnation and point used for a definition-free copy.
public struct DocumentCopySource: Sendable, Equatable, Codable {
    public let id: DocumentID
    public let at: DocumentPoint
    /// Unknown JSON members retained by upstream record copies.
    public let extensionFields: JSONObject
    public init(id: DocumentID, at: DocumentPoint, extensionFields: JSONObject = [:]) {
        self.id = id
        self.at = at
        self.extensionFields = extensionFields
    }
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        id = try recordRequired(object, "id")
        at = try recordRequired(object, "at")
        extensionFields = recordExtensions(object, excluding: ["id", "at"])
    }
    public func encode(to encoder: any Encoder) throws {
        var object: JSONObject = extensionFields
        try recordSet(&object, "id", id)
        try recordSet(&object, "at", at)
        try object.encode(to: encoder)
    }
}

/// Detached materialized document value and its definition version at a selected point.
public struct StoredDocument: Sendable, Equatable, Codable {
    public let record: DocumentRecord
    public let version: Int
    public let value: JSONObject
    public let deltasSinceBase: Int
    /// Unknown JSON members retained by upstream record copies.
    public let extensionFields: JSONObject
    public init(record: DocumentRecord, version: Int, value: JSONObject, deltasSinceBase: Int, extensionFields: JSONObject = [:]) {
        self.record = record
        self.version = version
        self.value = value
        self.deltasSinceBase = deltasSinceBase
        self.extensionFields = extensionFields
    }
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        record = try recordRequired(object, "record")
        version = try recordRequired(object, "version")
        value = try recordRequired(object, "value")
        deltasSinceBase = try recordRequired(object, "deltasSinceBase")
        extensionFields = recordExtensions(object, excluding: ["record", "version", "value", "deltasSinceBase"])
    }
    public func encode(to encoder: any Encoder) throws {
        var object: JSONObject = extensionFields
        try recordSet(&object, "record", record)
        try recordSet(&object, "version", version)
        try recordSet(&object, "value", value)
        try recordSet(&object, "deltasSinceBase", deltasSinceBase)
        try object.encode(to: encoder)
    }
}

/// One mutation in an atomic commit batch. Unknown fields retain upstream JSON copies.
public enum StorageWrite: Sendable, Equatable, Codable {
    case conversation(value: ConversationRecord, extensions: JSONObject = [:])
    case entry(value: EntryRecord, extensions: JSONObject = [:])
    case task(value: TaskRecord, extensions: JSONObject = [:])
    case submission(value: SubmissionRecord, extensions: JSONObject = [:])
    case documentCreate(record: DocumentCreate, content: DocumentBaseContent, extensions: JSONObject = [:])
    case documentCopy(record: DocumentCreate, source: DocumentCopySource, extensions: JSONObject = [:])
    case documentChange(id: DocumentID, content: DocumentContent, extensions: JSONObject = [:])
    case documentRetire(id: DocumentID, extensions: JSONObject = [:])
    public var type: String {
        switch self {
        case .conversation: "conversation"
        case .entry: "entry"
        case .task: "task"
        case .submission: "submission"
        case .documentCreate: "document.create"
        case .documentCopy: "document.copy"
        case .documentChange: "document.change"
        case .documentRetire: "document.retire"
        }
    }
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        let tag: String = try recordRequired(object, "type")
        switch tag {
        case "conversation": try recordForbid(object, ["content", "id", "record", "source"]); self = .conversation(value: try recordRequired(object, "value"), extensions: recordExtensions(object, excluding: ["type", "value"]))
        case "entry": try recordForbid(object, ["content", "id", "record", "source"]); self = .entry(value: try recordRequired(object, "value"), extensions: recordExtensions(object, excluding: ["type", "value"]))
        case "task": try recordForbid(object, ["content", "id", "record", "source"]); self = .task(value: try recordRequired(object, "value"), extensions: recordExtensions(object, excluding: ["type", "value"]))
        case "submission": try recordForbid(object, ["content", "id", "record", "source"]); self = .submission(value: try recordRequired(object, "value"), extensions: recordExtensions(object, excluding: ["type", "value"]))
        case "document.create": try recordForbid(object, ["id", "source", "value"]); self = .documentCreate(record: try recordRequired(object, "record"), content: try recordRequired(object, "content"), extensions: recordExtensions(object, excluding: ["type", "record", "content"]))
        case "document.copy": try recordForbid(object, ["content", "id", "value"]); self = .documentCopy(record: try recordRequired(object, "record"), source: try recordRequired(object, "source"), extensions: recordExtensions(object, excluding: ["type", "record", "source"]))
        case "document.change": try recordForbid(object, ["record", "source", "value"]); self = .documentChange(id: try recordRequired(object, "id"), content: try recordRequired(object, "content"), extensions: recordExtensions(object, excluding: ["type", "id", "content"]))
        case "document.retire": try recordForbid(object, ["content", "record", "source", "value"]); self = .documentRetire(id: try recordRequired(object, "id"), extensions: recordExtensions(object, excluding: ["type", "id"]))
        default: throw recordUnknown("type", tag)
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var object: JSONObject
        switch self {
        case let .conversation(value, extensions):
            object = extensions
            object["type"] = .string("conversation")
            try recordForbid(object, ["content", "id", "record", "source"])
            try recordSet(&object, "value", value)
        case let .entry(value, extensions):
            object = extensions
            object["type"] = .string("entry")
            try recordForbid(object, ["content", "id", "record", "source"])
            try recordSet(&object, "value", value)
        case let .task(value, extensions):
            object = extensions
            object["type"] = .string("task")
            try recordForbid(object, ["content", "id", "record", "source"])
            try recordSet(&object, "value", value)
        case let .submission(value, extensions):
            object = extensions
            object["type"] = .string("submission")
            try recordForbid(object, ["content", "id", "record", "source"])
            try recordSet(&object, "value", value)
        case let .documentCreate(record, content, extensions):
            object = extensions
            object["type"] = .string("document.create")
            try recordForbid(object, ["id", "source", "value"])
            try recordSet(&object, "record", record)
            try recordSet(&object, "content", content)
        case let .documentCopy(record, source, extensions):
            object = extensions
            object["type"] = .string("document.copy")
            try recordForbid(object, ["content", "id", "value"])
            try recordSet(&object, "record", record)
            try recordSet(&object, "source", source)
        case let .documentChange(id, content, extensions):
            object = extensions
            object["type"] = .string("document.change")
            try recordForbid(object, ["record", "source", "value"])
            try recordSet(&object, "id", id)
            try recordSet(&object, "content", content)
        case let .documentRetire(id, extensions):
            object = extensions
            object["type"] = .string("document.retire")
            try recordForbid(object, ["content", "record", "source", "value"])
            try recordSet(&object, "id", id)
        }
        try object.encode(to: encoder)
    }
}
