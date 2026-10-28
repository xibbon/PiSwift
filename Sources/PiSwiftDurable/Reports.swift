/// The task to which a report applies.
public struct ReportTask: Sendable, Equatable, Codable {
    /// The task identifier.
    public let id: TaskID
    /// The registered task name.
    public let kind: String
    /// The task's conversation.
    public let conversationId: ConversationID
    /// Creates a task identity for a report.
    public init(id: TaskID, kind: String, conversationId: ConversationID) {
        self.id = id; self.kind = kind; self.conversationId = conversationId
    }
    internal init(_ record: TaskRecord) {
        self.init(id: record.id, kind: record.kind, conversationId: record.conversationId)
    }
}
/// A host callback, with its HarnessOptions name.
public enum HostCallback: String, Sendable, Codable, CaseIterable {
    case now, settings, registry, env, models, setTimer, onWake
}
/// The cause and source of a report. Reports do not change task or Session state.
public enum ReportInfo: Sendable, Equatable {
    /// The reason a task faulted.
    public enum FaultReason: String, Sendable, Codable { case threw; case restartLimit = "restart_limit" }
    /// The reason a running task keeps its old definition.
    public enum OutdatedReason: String, Sendable, Codable { case missingTask = "missing_task"; case incompatibleTask = "incompatible_task" }
    case sessionFailed
    case taskFaulted(task: ReportTask, extension: String? = nil, reason: FaultReason)
    case taskParked(task: ReportTask, extension: String? = nil)
    case migrationFailed(task: ReportTask, extension: String? = nil)
    case taskError(task: ReportTask, extension: String? = nil)
    case taskOutdated(task: ReportTask, extension: String? = nil, reason: OutdatedReason)
    case extensionError(extension: String? = nil, task: ReportTask? = nil, conversationId: ConversationID? = nil)
    case hostError(callback: HostCallback, task: ReportTask? = nil)
    case listenerError
    /// The upstream report type string.
    public var type: String {
        switch self {
        case .sessionFailed: "session_failed"
        case .taskFaulted: "task_faulted"
        case .taskParked: "task_parked"
        case .migrationFailed: "migration_failed"
        case .taskError: "task_error"
        case .taskOutdated: "task_outdated"
        case .extensionError: "extension_error"
        case .hostError: "host_error"
        case .listenerError: "listener_error"
        }
    }
    /// The task to which this report applies, if known.
    public var task: ReportTask? {
        switch self {
        case let .taskFaulted(task, _, _), let .taskParked(task, _), let .migrationFailed(task, _),
             let .taskError(task, _), let .taskOutdated(task, _, _): task
        case let .extensionError(_, task, _), let .hostError(_, task): task
        case .sessionFailed, .listenerError: nil
        }
    }
    /// The extension whose code caused this report, if known.
    public var `extension`: String? {
        switch self {
        case let .taskFaulted(_, name, _), let .taskParked(_, name), let .migrationFailed(_, name),
             let .taskError(_, name), let .taskOutdated(_, name, _), let .extensionError(name, _, _): name
        case .sessionFailed, .hostError, .listenerError: nil
        }
    }
}
/// The source of a runtime report. Nil means the task's own code.
public enum ReportFrom: Sendable, Equatable {
    case `extension`(String? = nil)
    case host(callback: HostCallback)
    /// The upstream source type string.
    public var type: String { switch self { case .extension: "extension"; case .host: "host" } }
}

/// Encodes the upstream tagged report shape for host views and logs.
extension ReportInfo: Codable {
    private enum Keys: String, CodingKey { case type, task, `extension`, reason, callback, conversationId }
    /// Reads a report with its upstream type and field names.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "session_failed": self = .sessionFailed
        case "task_faulted":
            self = .taskFaulted(task: try c.decode(ReportTask.self, forKey: .task),
                extension: try c.decodeIfPresent(String.self, forKey: .extension),
                reason: try c.decode(FaultReason.self, forKey: .reason))
        case "task_parked":
            self = .taskParked(task: try c.decode(ReportTask.self, forKey: .task),
                extension: try c.decodeIfPresent(String.self, forKey: .extension))
        case "migration_failed":
            self = .migrationFailed(task: try c.decode(ReportTask.self, forKey: .task),
                extension: try c.decodeIfPresent(String.self, forKey: .extension))
        case "task_error":
            self = .taskError(task: try c.decode(ReportTask.self, forKey: .task),
                extension: try c.decodeIfPresent(String.self, forKey: .extension))
        case "task_outdated":
            self = .taskOutdated(task: try c.decode(ReportTask.self, forKey: .task),
                extension: try c.decodeIfPresent(String.self, forKey: .extension),
                reason: try c.decode(OutdatedReason.self, forKey: .reason))
        case "extension_error":
            self = .extensionError(extension: try c.decodeIfPresent(String.self, forKey: .extension),
                task: try c.decodeIfPresent(ReportTask.self, forKey: .task),
                conversationId: try c.decodeIfPresent(ConversationID.self, forKey: .conversationId))
        case "host_error":
            self = .hostError(callback: try c.decode(HostCallback.self, forKey: .callback),
                task: try c.decodeIfPresent(ReportTask.self, forKey: .task))
        case "listener_error": self = .listenerError
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown report type \(type)")
        }
    }
    /// Writes a report with its upstream type and field names.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(task, forKey: .task)
        try c.encodeIfPresent(self.extension, forKey: .extension)
        switch self {
        case .taskFaulted(_, _, let reason): try c.encode(reason, forKey: .reason)
        case .taskOutdated(_, _, let reason): try c.encode(reason, forKey: .reason)
        case .hostError(let callback, _): try c.encode(callback, forKey: .callback)
        case .extensionError(_, _, let conversationId): try c.encodeIfPresent(conversationId, forKey: .conversationId)
        default: break
        }
    }
}
