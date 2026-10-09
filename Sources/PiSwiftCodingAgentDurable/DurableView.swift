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

    /// Creates a notice with its display category.
    public init(id: Int, level: Level, message: String) {
        self.id = id
        self.level = level
        self.message = message
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

    /// Creates a view snapshot for a session interface.
    public init(session: DurableSessionView, conversation: ConversationView,
                conversations: [ConversationSummary], models: [ModelSummary],
                notices: [Notice] = [], tasks: TaskGraph? = nil) {
        self.session = session
        self.conversation = conversation
        self.conversations = conversations
        self.models = models
        self.notices = notices
        self.tasks = tasks
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
    /// Close removes listeners. A callback that has started can finish after cancellation.
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
    /// Selects the next thinking level supported by the current model.
    func cycleThinking() async
    /// Selects a model and clamps the current thinking level to its supported levels.
    func setModel(_ model: ModelRef) async
    /// Shows or hides the live task graph.
    func toggleTasks() async
    /// Shows another conversation. Later commands apply to that conversation.
    func switchConversation(_ id: ConversationID) async
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

/// Returns an empty state if the agent document is absent or cannot be decoded.
public func agentOf(_ view: ConversationView) -> PiSwiftDurable.AgentState {
    guard let document = view.docs["pi.agent"],
          let state = try? JSONValue.object(document).decode(PiSwiftDurable.AgentState.self) else {
        return PiSwiftDurable.AgentState()
    }
    return state
}
