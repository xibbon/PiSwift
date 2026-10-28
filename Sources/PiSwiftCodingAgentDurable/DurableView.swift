import PiSwiftChord
import PiSwiftDurable
import Synchronization

/// A model that the user can select.
public struct ModelSummary: Sendable, Equatable, Codable {
    /// The provider ID used for model selection.
    public let provider: String
    /// The model ID within the provider.
    public let modelId: String
    /// The model name for display.
    public let name: String
    /// The maximum context size in tokens.
    public let contextWindow: Int

    /// Creates a model choice for the view.
    public init(provider: String, modelId: String, name: String, contextWindow: Int) {
        self.provider = provider
        self.modelId = modelId
        self.name = name
        self.contextWindow = contextWindow
    }
}

/// A message for the user.
public struct Notice: Sendable, Equatable, Codable {
    /// The source of a notice. Task reports do not close the Session.
    public enum Category: String, Sendable, Codable {
        case operation
        case report
        case taskParked
        case taskFault
        case extensionError
        case sessionFailed
    }

    /// The notice category for display.
    public enum Level: String, Sendable, Codable {
        /// Information about the session or an operation.
        case info
        /// A condition that can need user action.
        case warning
        /// A failed operation or runtime report.
        case error
    }

    /// The notice ID within this open runtime.
    public let id: Int
    /// The notice category.
    public let level: Level
    /// The text for display to the user.
    public let message: String
    /// The source of this notice.
    public let category: Category
    /// The task that produced the report, when known.
    public let taskId: TaskID?
    /// The saved kind of that task, when known.
    public let taskKind: String?

    /// The complete typed report, including its reason and host callback.
    public let reportInfo: ReportInfo?

    /// The core report type, when the callback supplied typed data.
    public let reportType: String?
    /// The extension whose code produced the report.
    public let extensionName: String?
    /// The conversation that produced the report.
    public let conversationId: ConversationID?

    /// The report text with a distinct name for each condition.
    public var displayMessage: String {
        let label: String
        switch category {
        case .operation: return message
        case .report: label = "Runtime report"
        case .taskParked: label = "Task parked"
        case .taskFault: label = "Task fault"
        case .extensionError: label = "Extension error"
        case .sessionFailed: label = "Session failed"
        }
        return "\(label): \(message)"
    }

    /// Creates a notice with its display category.
    public init(id: Int, level: Level, message: String, category: Category = .operation,
                taskId: TaskID? = nil, taskKind: String? = nil,
                reportType: String? = nil, extensionName: String? = nil,
                conversationId: ConversationID? = nil, reportInfo: ReportInfo? = nil) {
        self.id = id
        self.level = level
        self.message = message
        self.category = category
        self.taskId = taskId
        self.taskKind = taskKind
        self.reportInfo = reportInfo
        self.reportType = reportType
        self.extensionName = extensionName
        self.conversationId = conversationId
    }

    private enum CodingKeys: String, CodingKey { case id, level, message, category, taskId, taskKind, reportType, extensionName, conversationId, reportInfo }

    /// Reads notices saved before task report categories were added.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        level = try values.decode(Level.self, forKey: .level)
        message = try values.decode(String.self, forKey: .message)
        category = try values.decodeIfPresent(Category.self, forKey: .category) ?? .operation
        taskId = try values.decodeIfPresent(TaskID.self, forKey: .taskId)
        taskKind = try values.decodeIfPresent(String.self, forKey: .taskKind)
        reportInfo = try values.decodeIfPresent(ReportInfo.self, forKey: .reportInfo)
        reportType = try values.decodeIfPresent(String.self, forKey: .reportType)
        extensionName = try values.decodeIfPresent(String.self, forKey: .extensionName)
        conversationId = try values.decodeIfPresent(ConversationID.self, forKey: .conversationId)
    }
}

/// A conversation that the user can select.
public struct ConversationSummary: Sendable, Equatable, Codable {
    /// The conversation ID used for selection.
    public let id: ConversationID
    /// The display label, such as main or subagent.
    public let label: String
    /// The first user message, or the task for a child conversation.
    public let title: String?

    /// Creates a conversation choice with an optional title.
    public init(id: ConversationID, label: String, title: String? = nil) {
        self.id = id
        self.label = label
        self.title = title
    }
}

/// The session location shown in the view.
public struct DurableSessionView: Sendable, Equatable, Codable {
    /// The session directory name.
    public let id: String
    /// The absolute path of the session directory.
    public let directory: String
    /// The resolved working directory for the session.
    public let cwd: String

    /// Creates the session location for display.
    public init(id: String, directory: String, cwd: String) {
        self.id = id
        self.directory = directory
        self.cwd = cwd
    }
}

/// The final session state for display. Nil means that the session is open.
public enum DurableSessionTerminal: Sendable, Equatable, Codable {
    /// The session closed without a storage failure.
    case closed
    /// The session failed. The message describes the first cause.
    case failed(message: String)
}

/// The work state of the shown conversation and its owned tasks.
/// Read blockedTasks as well: other work can progress while one task is parked.
public enum DurableActivity: String, Sendable, Equatable, Codable {
    case idle
    case progressing
    case sleeping
    case parked
    case blocked
}

/// A task that needs a definition change or an explicit user action.
public struct DurableBlockedTask: Sendable, Equatable, Codable {
    public let id: TaskID
    public let kind: String
    public let reason: TaskBlockedReason
    /// The number of consecutive cutoffs without durable progress.
    public let restarts: Double
    /// The exact parking report, or nil for other blocked reasons.
    public let report: String?

    public init(id: TaskID, kind: String, reason: TaskBlockedReason,
                restarts: Double = 0, report: String? = nil) {
        self.id = id; self.kind = kind; self.reason = reason
        self.restarts = restarts; self.report = report
    }

    private enum CodingKeys: String, CodingKey { case id, kind, reason, restarts, report }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(TaskID.self, forKey: .id)
        kind = try values.decode(String.self, forKey: .kind)
        let raw = try values.decode(String.self, forKey: .reason)
        guard let reason = TaskBlockedReason(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .reason, in: values, debugDescription: "Unknown blocked reason: \(raw)")
        }
        self.reason = reason
        restarts = try values.decodeIfPresent(Double.self, forKey: .restarts) ?? 0
        report = try values.decodeIfPresent(String.self, forKey: .report)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(kind, forKey: .kind)
        try values.encode(reason.rawValue, forKey: .reason)
        try values.encode(restarts, forKey: .restarts)
        try values.encodeIfPresent(report, forKey: .report)
    }
}

/// A durable wait, including a generation backoff or deferred poll.
public struct DurableSleepingTask: Sendable, Equatable, Codable {
    public let id: TaskID
    public let kind: String
    public let phase: String
    /// The Harness clock deadline, in milliseconds since the epoch.
    public let until: Double

    public init(id: TaskID, kind: String, phase: String, until: Double) {
        self.id = id; self.kind = kind; self.phase = phase; self.until = until
    }
}

/// The values shown by a durable session interface.
public struct DurableView: Sendable, Equatable, Codable {
    /// The session location.
    public let session: DurableSessionView
    /// The transcript and built-in documents of the shown conversation.
    public let conversation: ConversationView
    /// The conversations available for selection.
    public let conversations: [ConversationSummary]
    /// The model choices recorded when the runtime opened.
    public let models: [ModelSummary]
    /// The notices produced by this open runtime.
    public let notices: [Notice]
    /// The live task graph, when the task panel is open.
    public let tasks: TaskGraph?
    /// The final session state, when the session has ended.
    public let terminal: DurableSessionTerminal?
    /// Blocked work in the shown conversation and its owned tasks, even with the panel hidden.
    public let blockedTasks: [DurableBlockedTask]
    /// Durable waits in the shown conversation and its owned tasks, even with the panel hidden.
    public let sleepingTasks: [DurableSleepingTask]
    /// Whether work can progress or waits for time or user action.
    public let activity: DurableActivity
    /// Queued inputs in inbox order. They remain here after a failed run under keep.
    public let queuedInputs: [InboxItem]
    /// Tasks that reached the restart limit and need retry or abort.
    public var parkedTasks: [DurableBlockedTask] { blockedTasks.filter { $0.reason == .restartLimit } }

    /// Creates a view snapshot for a session interface.
    public init(session: DurableSessionView, conversation: ConversationView,
                conversations: [ConversationSummary], models: [ModelSummary],
                notices: [Notice] = [], tasks: TaskGraph? = nil,
                terminal: DurableSessionTerminal? = nil,
                blockedTasks: [DurableBlockedTask] = [], sleepingTasks: [DurableSleepingTask] = [],
                activity: DurableActivity = .idle, queuedInputs: [InboxItem] = []) {
        self.session = session
        self.conversation = conversation
        self.conversations = conversations
        self.models = models
        self.notices = notices
        self.tasks = tasks
        self.terminal = terminal
        self.blockedTasks = blockedTasks
        self.sleepingTasks = sleepingTasks
        self.activity = activity
        self.queuedInputs = queuedInputs
    }

    private enum CodingKeys: String, CodingKey {
        case session, conversation, conversations, models, notices, tasks, terminal
        case blockedTasks, sleepingTasks, activity, queuedInputs
    }

    /// Reads snapshots saved before task wait and queue fields were added.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        session = try values.decode(DurableSessionView.self, forKey: .session)
        conversation = try values.decode(ConversationView.self, forKey: .conversation)
        conversations = try values.decode([ConversationSummary].self, forKey: .conversations)
        models = try values.decode([ModelSummary].self, forKey: .models)
        notices = try values.decode([Notice].self, forKey: .notices)
        tasks = try values.decodeIfPresent(TaskGraph.self, forKey: .tasks)
        terminal = try values.decodeIfPresent(DurableSessionTerminal.self, forKey: .terminal)
        blockedTasks = try values.decodeIfPresent([DurableBlockedTask].self, forKey: .blockedTasks) ?? []
        sleepingTasks = try values.decodeIfPresent([DurableSleepingTask].self, forKey: .sleepingTasks) ?? []
        activity = try values.decodeIfPresent(DurableActivity.self, forKey: .activity) ?? .idle
        queuedInputs = try values.decodeIfPresent([InboxItem].self, forKey: .queuedInputs) ?? []
    }
}

/// Call cancel() to remove the listener. Release does not remove it.
public final class DurableViewSubscription: Sendable {
    private let cancellation: Mutex<(@Sendable () -> Void)?>

    /// Creates a subscription with a cancellation operation.
    public init(_ cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = Mutex(cancellation)
    }

    /// Removes the listener once. Later calls have no effect.
    public func cancel() {
        let remove = cancellation.withLock { value in
            let remove = value
            value = nil
            return remove
        }
        remove?()
    }
}

/// Supplies the current view and reports changes to it.
public protocol DurableViewSource: Sendable {
    /// Returns the latest snapshot. A closed runtime retains its final snapshot.
    func current() -> DurableView
    /// Adds a change listener. Call `cancel()` on the returned subscription to remove it.
    /// The openDurable source groups changes and calls listeners on a private serial queue.
    /// A UI host must transfer UI work to its main actor. Read `current()` for the new view.
    /// Close schedules a final notification and removes listeners.
    /// A callback already selected for delivery can finish after cancellation.
    func subscribe(_ listener: @escaping @Sendable () -> Void) -> DurableViewSubscription
}

/// Selects what to do with input when the conversation is busy.
public enum SubmitWhenBusy: String, Sendable, Codable {
    /// Sends input as steering for the active turn.
    case steer
    /// Queues input for a later turn.
    case followUp
}

/// Commands that a durable session interface can send.
/// Implementations report command failures through view notices.
public protocol DurableController: Sendable {
    /// Submits input when idle, or steers or queues it when busy.
    /// Return means submission has finished. The answer arrives through the view.
    func submit(_ text: String, whenBusy: SubmitWhenBusy) async
    /// Starts manual compaction. Its result arrives as a view notice.
    func compact(instructions: String?) async
    /// Aborts work in the shown conversation, including manual compaction.
    /// This command bypasses the ordered command queue.
    func abort() async
    /// Clears the restart count and resumes a parked task.
    func retryTask(_ id: TaskID) async
    /// Aborts one task. This command bypasses the ordered command queue.
    func abortTask(_ id: TaskID) async
    /// Selects the next thinking level supported by the current model.
    func cycleThinking() async
    /// Selects a model and clamps the current thinking level to its supported levels.
    func setModel(_ model: ModelRef) async
    /// Shows or hides the live task graph.
    func toggleTasks() async
    /// Shows another conversation. Later commands apply to that conversation.
    func switchConversation(_ id: ConversationID) async
}

extension DurableController {
    /// Existing controllers can omit task retry support.
    public func retryTask(_ id: TaskID) async {}
    /// Existing controllers can omit task abort support.
    public func abortTask(_ id: TaskID) async {}
}

/// Options used to open a durable session.
public struct OpenDurableOptions: Sendable, Equatable, Codable {
    /// The working directory. Nil uses the process working directory.
    public let cwd: String?
    /// Opens the newest session for this directory when true. False creates a session.
    public let continueSession: Bool

    /// Creates options for a new or continued session.
    public init(cwd: String? = nil, continueSession: Bool = false) {
        self.cwd = cwd
        self.continueSession = continueSession
    }
}

/// Reads the agent document. An absent document has no overrides.
public func decodeAgentOf(_ view: ConversationView) throws -> PiSwiftDurable.AgentState {
    guard let document = view.docs["pi.agent"] else { return PiSwiftDurable.AgentState() }
    return try JSONValue.object(document).decode(PiSwiftDurable.AgentState.self)
}

/// Reads live tool and compaction state. An absent document has no live work.
/// Invalid data throws so a host can show the decoding error.
public func decodeLiveOf(_ view: ConversationView) throws -> LiveState {
    guard let document = view.docs["pi.live"] else { return LiveState() }
    return try JSONValue.object(document).decode(LiveState.self)
}

/// Returns an empty state if the agent document is absent or cannot be decoded.
/// Use decodeAgentOf to receive a document decoding error.
public func agentOf(_ view: ConversationView) -> PiSwiftDurable.AgentState {
    do { return try decodeAgentOf(view) }
    catch { return PiSwiftDurable.AgentState() }
}
