import PiSwiftChord

/// Whether the harness is paused, running, or closing.
public enum SchedulingState: String, Sendable {
    /// The harness does not schedule new invocations.
    case paused
    /// The harness schedules ready task invocations.
    case running
    /// The harness is cancelling work and releasing its resources.
    case closing
}
/// The definition or migration failure that prevents a task from running.
public enum TaskBlockedReason: String, Sendable {
    /// No installed definition matches the saved task kind.
    case missingTask = "missing_task"
    /// The saved task cannot migrate to the installed definition version.
    case taskTooOld = "task_too_old"
    /// The installed task migration threw an error.
    case migrationFailed = "migration_failed"
}
/// The task definition state selected during harness inspection.
public enum TaskInspectionState: Sendable {
    /// Work is executing with its saved checkpoint.
    case running
    /// The saved task is compatible with its installed definition.
    case ready(migrates: Bool)
    /// Work waits for the selected tasks under its join policy.
    case waiting(on: [TaskID])
    /// An outcome is saved while ordinary owned work finishes.
    case completing
    /// The task cannot run until its definition problem is resolved.
    case blocked(reason: TaskBlockedReason, error: (any Error)? = nil)
}
/// A task record and the reason it is runnable or blocked.
public struct TaskInspection: Sendable {
    /// The durable record from which this typed value is derived.
    public let record: TaskRecord
    /// The runtime or definition state selected for this task record.
    public let state: TaskInspectionState
    /// Pairs a stored task with its definition compatibility state.
    public init(record: TaskRecord, state: TaskInspectionState) { self.record = record; self.state = state }
}
/// The scheduling state, tasks, and submissions currently visible to the host.
public struct HarnessInspection: Sendable {
    /// Whether the harness is paused, running, or closing.
    public let scheduling: SchedulingState
    /// Stored tasks paired with their definition compatibility state.
    public let tasks: [TaskInspection]
    /// The durable submissions visible in this inspection.
    public let submissions: [SubmissionRecord]
    /// Pairs scheduling state with the current task and submission records.
    public init(scheduling: SchedulingState, tasks: [TaskInspection], submissions: [SubmissionRecord]) {
        self.scheduling = scheduling; self.tasks = tasks; self.submissions = submissions
    }
}
/// The final stored task and its terminal outcome.
public struct SettledTask: Sendable, Equatable {
    /// The durable record from which this typed value is derived.
    public let record: TaskRecord
    /// The saved terminal task result.
    public let outcome: TaskOutcome
    /// Pairs a final task record with its terminal outcome.
    public init(record: TaskRecord, outcome: TaskOutcome) { self.record = record; self.outcome = outcome }
    internal init(record: TaskRecord) {
        guard case .terminal(let outcome, _) = record.state else { preconditionFailure("A settled task must be terminal") }
        self.record = record; self.outcome = outcome
    }
    /// The stable identifier of this record or handle.
    public var id: TaskID { record.id }
    /// The conversation that owns or is addressed by this value.
    public var conversationId: ConversationID { record.conversationId }
    /// The current durable task, graph, or conversation state.
    public var state: TaskState { record.state }
}
/// Whether an abort request was marked or the task was already terminal.
public enum TaskAbortResult: String, Sendable {
    /// The abort request was saved for a nonterminal task.
    case marked
    /// The task already had a final outcome.
    case terminal
}
/// A callback that initializes a conversation within its creation transaction.
public typealias ConversationInit = @Sendable (Transaction, ConversationID) async throws -> Void
/// Optional agent changes and initialization for the root conversation.
public struct ConversationRootOptions: Sendable {
    /// Optional changes to apply when the root conversation is created.
    public var agent: AgentChange?
    /// Runs inside the conversation creation transaction.
    public var initialize: ConversationInit?
    /// Selects optional root agent changes and a creation callback.
    public init(agent: AgentChange? = nil, initialize: ConversationInit? = nil) { self.agent = agent; self.initialize = initialize }
}
/// Ownership and optional agent configuration for a new conversation.
public struct ConversationCreateOptions: Sendable {
    /// The owner edge assigned when this record is created.
    public var ownership: ConversationOwnership
    /// Optional changes to the inherited or initial agent configuration.
    public var agent: AgentChange?
    /// Runs inside the conversation creation transaction.
    public var initialize: ConversationInit?
    /// Selects conversation ownership, agent changes, and a creation callback.
    public init(ownership: ConversationOwnership, agent: AgentChange? = nil, initialize: ConversationInit? = nil) {
        self.ownership = ownership; self.agent = agent; self.initialize = initialize
    }
}
/// The conversation, directory, and document reader passed to an environment factory.
public struct EnvTarget: Sendable {
    /// The conversation that owns or is addressed by this value.
    public let conversationId: ConversationID
    /// The working directory used by this conversation or command.
    public let cwd: String?
    /// Document snapshot services available to this hook or renderer.
    public let read: HarnessDocumentReader
    /// Supplies conversation identity, directory, and document reads to an environment factory.
    public init(conversationId: ConversationID, cwd: String?, read: HarnessDocumentReader) {
        self.conversationId = conversationId; self.cwd = cwd; self.read = read
    }
}
/// Creates or selects the execution environment for one conversation.
public typealias HarnessEnvFactory = @Sendable (EnvTarget, ChordContext) async throws -> (any ExecutionEnv)?
/// Host services and live settings required to open a harness.
public struct HarnessOptions: Sendable {
    /// The model service used by this harness or task.
    public let models: any DurableModels
    /// The installed extension and task definitions used by this harness.
    public let registry: any RegistryReader
    /// An optional callback that supplies live host settings.
    public var settings: HarnessSettingsProvider?
    /// The optional execution environment for the conversation.
    public var env: HarnessEnvFactory?
    /// The time source used for task sleeps and retry deadlines.
    public var clock: any DurableClock
    /// An optional callback for the current time in milliseconds.
    public var now: (@Sendable () -> Int64)?
    /// Runs inside the transaction that creates a conversation.
    public var conversationCreated: (@Sendable (Transaction, ConversationRecord) async throws -> Void)?
    /// Receives nonfatal errors from handlers and observers.
    public var onReport: (@Sendable (any Error) -> Void)?
    /// Supplies host model, registry, clock, settings, and environment services.
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
    /// The reason an installed task definition cannot replace a running definition.
    public enum Cause: String, Sendable {
        /// No installed definition matches the saved task kind.
        case missingTask = "missing_task"
        /// The replacement task definition cannot run the current record.
        case incompatibleTask = "incompatible_task"
    }
    /// The ID of the task bound to this value or invocation.
    public let taskId: TaskID
    /// The stored record or document kind.
    public let kind: String
    /// The reason the running task could not adopt its new definition.
    public let cause: Cause
    /// Records the running task whose replacement definition could not take over.
    public init(taskId: TaskID, kind: String, cause: Cause) { self.taskId = taskId; self.kind = kind; self.cause = cause }
    /// Text that describes this value or error to the caller.
    public var description: String { "Task \(taskId.rawValue) keeps running under its old \(kind) definition" }
}
