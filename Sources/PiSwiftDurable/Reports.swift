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
    case now, settings, registry, env, models, setTimer, onWake, telemetry
}
/// The cause and source of a report. Reports do not change task or Session state.
public enum ReportInfo: Sendable, Equatable {
    /// The reason a task faulted.
    public enum FaultReason: String, Sendable, Codable { case threw; case restartLimit = "restart_limit" }
    /// The reason a running task keeps its old definition.
    public enum InterruptedReason: String, Sendable, Codable { case restartLimit = "restart_limit"; case interrupted }
    public enum OutdatedReason: String, Sendable, Codable {
        case missingTask = "missing_task", taskTooOld = "task_too_old", migrationFailed = "migration_failed"
        @available(*, deprecated, message: "Use taskTooOld or migrationFailed according to the definition version")
        case incompatibleTask = "incompatible_task"
    }
    case storageFailed
    case taskInterrupted(task: ReportTask, extension: String? = nil, reason: InterruptedReason, restarts: Double)
    @available(*, deprecated, message: "Use storageFailed")
    case sessionFailed
    case taskFaulted(task: ReportTask, extension: String? = nil, reason: FaultReason)
    @available(*, deprecated, message: "Tasks end at the restart limit; use taskInterrupted or taskFaulted")
    case taskParked(task: ReportTask, extension: String? = nil)
    case migrationFailed(task: ReportTask, extension: String? = nil)
    case taskError(task: ReportTask, extension: String? = nil)
    case taskOutdated(task: ReportTask, extension: String? = nil, reason: OutdatedReason)
    case extensionError(extension: String? = nil, task: ReportTask? = nil, conversationId: ConversationID? = nil)
    case hostError(callback: HostCallback, task: ReportTask? = nil)
    case listenerError
    /// The upstream report type string.
    public var kind: String {
        switch self {
        case .storageFailed: "storage_failed"
        case .taskInterrupted: "task_interrupted"
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
    @available(*, deprecated, renamed: "kind")
    public var type: String { kind }
    /// The task to which this report applies, if known.
    public var task: ReportTask? {
        switch self {
        case let .taskFaulted(task, _, _), let .taskInterrupted(task, _, _, _), let .taskParked(task, _), let .migrationFailed(task, _),
             let .taskError(task, _), let .taskOutdated(task, _, _): task
        case let .extensionError(_, task, _), let .hostError(_, task): task
        case .storageFailed, .sessionFailed, .listenerError: nil
        }
    }
    /// The extension whose code caused this report, if known.
    public var `extension`: String? {
        switch self {
        case let .taskFaulted(_, name, _), let .taskInterrupted(_, name, _, _), let .taskParked(_, name), let .migrationFailed(_, name),
             let .taskError(_, name), let .taskOutdated(_, name, _), let .extensionError(name, _, _): name
        case .storageFailed, .sessionFailed, .hostError, .listenerError: nil
        }
    }
}
/// A single tagged report delivered to the host. `info.kind` selects the fields.
public struct Report: Sendable {
    public let info: ReportInfo
    public let error: any Error
    public init(_ info: ReportInfo, error: any Error) { self.info = info; self.error = error }
    public var kind: String { info.kind }
    public var task: ReportTask? { info.task }
    public var `extension`: String? { info.extension }
    public var callback: HostCallback? {
        if case .hostError(let callback, _) = info { return callback }
        return nil
    }
    public var reason: String? {
        switch info {
        case .taskFaulted(_, _, let reason): return reason.rawValue
        case .taskInterrupted(_, _, let reason, _): return reason.rawValue
        case .taskOutdated(_, _, let reason): return reason.rawValue
        default: return nil
        }
    }
    public var restarts: Double? {
        if case .taskInterrupted(_, _, _, let value) = info { return value }
        return nil
    }
    public var conversationId: ConversationID? {
        if case .extensionError(_, _, let id) = info { return id }
        return nil
    }
}
extension Report: Codable {
    private enum ErrorKey: String, CodingKey { case error }
    public init(from decoder: any Decoder) throws {
        let info = try ReportInfo(from: decoder)
        let text = try decoder.container(keyedBy: ErrorKey.self).decode(String.self, forKey: .error)
        self.init(info, error: SessionError.message(text))
    }
    public func encode(to encoder: any Encoder) throws {
        try info.encode(to: encoder)
        var values = encoder.container(keyedBy: ErrorKey.self)
        try values.encode(String(describing: error), forKey: .error)
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
    private enum Keys: String, CodingKey { case kind, type, task, `extension`, reason, restarts, callback, conversationId }
    /// Reads a report with its upstream type and field names.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? c.decode(String.self, forKey: .type)
        switch kind {
        case "storage_failed": self = .storageFailed
        case "task_interrupted":
            self = .taskInterrupted(task: try c.decode(ReportTask.self, forKey: .task),
                extension: try c.decodeIfPresent(String.self, forKey: .extension),
                reason: try c.decode(InterruptedReason.self, forKey: .reason),
                restarts: try c.decode(Double.self, forKey: .restarts))
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
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown report kind \(kind)")
        }
    }
    /// Writes a report with its upstream type and field names.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(task, forKey: .task)
        try c.encodeIfPresent(self.extension, forKey: .extension)
        switch self {
        case .taskFaulted(_, _, let reason): try c.encode(reason, forKey: .reason)
        case .taskInterrupted(_, _, let reason, let restarts):
            try c.encode(reason, forKey: .reason); try c.encode(restarts, forKey: .restarts)
        case .taskOutdated(_, _, let reason): try c.encode(reason, forKey: .reason)
        case .hostError(let callback, _): try c.encode(callback, forKey: .callback)
        case .extensionError(_, _, let conversationId): try c.encodeIfPresent(conversationId, forKey: .conversationId)
        default: break
        }
    }
}
