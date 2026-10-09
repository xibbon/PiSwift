import PiSwiftChord

public enum SchedulingState: String, Sendable { case paused, running, closing }
public enum TaskBlockedReason: String, Sendable { case missingTask = "missing_task", taskTooOld = "task_too_old", migrationFailed = "migration_failed" }
public enum TaskInspectionState: Sendable {
    case running, ready(migrates: Bool), waiting(on: [TaskID]), completing
    case blocked(reason: TaskBlockedReason, error: (any Error)? = nil)
}
public struct TaskInspection: Sendable {
    public let record: TaskRecord
    public let state: TaskInspectionState
    public init(record: TaskRecord, state: TaskInspectionState) { self.record = record; self.state = state }
}
public struct HarnessInspection: Sendable {
    public let scheduling: SchedulingState
    public let tasks: [TaskInspection]
    public let submissions: [SubmissionRecord]
    public init(scheduling: SchedulingState, tasks: [TaskInspection], submissions: [SubmissionRecord]) {
        self.scheduling = scheduling; self.tasks = tasks; self.submissions = submissions
    }
}
public struct SettledTask: Sendable, Equatable {
    public let record: TaskRecord
    public let outcome: TaskOutcome
    public init(record: TaskRecord, outcome: TaskOutcome) { self.record = record; self.outcome = outcome }
    internal init(record: TaskRecord) {
        guard case .terminal(let outcome, _) = record.state else { preconditionFailure("A settled task must be terminal") }
        self.record = record; self.outcome = outcome
    }
    public var id: TaskID { record.id }
    public var conversationId: ConversationID { record.conversationId }
    public var state: TaskState { record.state }
}
public enum TaskAbortResult: String, Sendable { case marked, terminal }
public typealias ConversationInit = @Sendable (Transaction, ConversationID) async throws -> Void
public struct ConversationRootOptions: Sendable {
    public var agent: AgentChange?
    public var initialize: ConversationInit?
    public init(agent: AgentChange? = nil, initialize: ConversationInit? = nil) { self.agent = agent; self.initialize = initialize }
}
public struct ConversationCreateOptions: Sendable {
    public var ownership: ConversationOwnership
    public var agent: AgentChange?
    public var initialize: ConversationInit?
    public init(ownership: ConversationOwnership, agent: AgentChange? = nil, initialize: ConversationInit? = nil) {
        self.ownership = ownership; self.agent = agent; self.initialize = initialize
    }
}
public struct EnvTarget: Sendable {
    public let conversationId: ConversationID
    public let cwd: String?
    public let read: HarnessDocumentReader
    public init(conversationId: ConversationID, cwd: String?, read: HarnessDocumentReader) {
        self.conversationId = conversationId; self.cwd = cwd; self.read = read
    }
}
public typealias HarnessEnvFactory = @Sendable (EnvTarget, ChordContext) async throws -> (any ExecutionEnv)?
public struct HarnessOptions: Sendable {
    public let models: any DurableModels
    public let registry: any RegistryReader
    public var settings: HarnessSettingsProvider?
    public var env: HarnessEnvFactory?
    public var clock: any DurableClock
    public var now: (@Sendable () -> Int64)?
    public var conversationCreated: (@Sendable (Transaction, ConversationRecord) async throws -> Void)?
    public var onReport: (@Sendable (any Error) -> Void)?
    public init(models: any DurableModels, registry: any RegistryReader,
                settings: HarnessSettingsProvider? = nil, env: HarnessEnvFactory? = nil,
                clock: any DurableClock = SystemDurableClock(), now: (@Sendable () -> Int64)? = nil,
                conversationCreated: (@Sendable (Transaction, ConversationRecord) async throws -> Void)? = nil,
                onReport: (@Sendable (any Error) -> Void)? = nil) {
        self.models = models; self.registry = registry; self.settings = settings; self.env = env
        self.clock = clock; self.now = now; self.conversationCreated = conversationCreated; self.onReport = onReport
    }
}

/// A replacement that cannot take the current invocation. The old definition continues.
public struct TaskHandoverError: Error, Sendable, CustomStringConvertible {
    public enum Cause: String, Sendable { case missingTask = "missing_task", incompatibleTask = "incompatible_task" }
    public let taskId: TaskID
    public let kind: String
    public let cause: Cause
    public init(taskId: TaskID, kind: String, cause: Cause) { self.taskId = taskId; self.kind = kind; self.cause = cause }
    public var description: String { "Task \(taskId.rawValue) keeps running under its old \(kind) definition" }
}
