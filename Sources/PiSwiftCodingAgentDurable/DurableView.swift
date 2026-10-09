import PiSwiftChord
import PiSwiftDurable
import Synchronization

/// A model that the user can select.
public struct ModelSummary: Sendable, Equatable, Codable {
    public let provider: String
    public let modelId: String
    public let name: String
    public let contextWindow: Int

    public init(provider: String, modelId: String, name: String, contextWindow: Int) {
        self.provider = provider
        self.modelId = modelId
        self.name = name
        self.contextWindow = contextWindow
    }
}

/// A message for the user.
public struct Notice: Sendable, Equatable, Codable {
    public enum Level: String, Sendable, Codable {
        case info
        case warning
        case error
    }

    public let id: Int
    public let level: Level
    public let message: String

    public init(id: Int, level: Level, message: String) {
        self.id = id
        self.level = level
        self.message = message
    }
}

/// A conversation that the user can select.
public struct ConversationSummary: Sendable, Equatable, Codable {
    public let id: ConversationID
    public let label: String
    /// The first user message, or the task for a child conversation.
    public let title: String?

    public init(id: ConversationID, label: String, title: String? = nil) {
        self.id = id
        self.label = label
        self.title = title
    }
}

/// The session location shown in the view.
public struct DurableSessionView: Sendable, Equatable, Codable {
    public let id: String
    public let directory: String
    public let cwd: String

    public init(id: String, directory: String, cwd: String) {
        self.id = id
        self.directory = directory
        self.cwd = cwd
    }
}

/// The values shown by a durable session interface.
public struct DurableView: Sendable, Equatable, Codable {
    public let session: DurableSessionView
    public let conversation: ConversationView
    public let conversations: [ConversationSummary]
    public let models: [ModelSummary]
    public let notices: [Notice]
    /// The live task graph, when the task panel is open.
    public let tasks: TaskGraph?

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
    func current() -> DurableView
    func subscribe(_ listener: @escaping @Sendable () -> Void) -> DurableViewSubscription
}

/// Selects what to do with input when the conversation is busy.
public enum SubmitWhenBusy: String, Sendable, Codable {
    case steer
    case followUp
}

/// Commands that a durable session interface can send.
/// Implementations report command failures through view notices.
public protocol DurableController: Sendable {
    func submit(_ text: String, whenBusy: SubmitWhenBusy) async
    func compact(instructions: String?) async
    func abort() async
    func cycleThinking() async
    func setModel(_ model: ModelRef) async
    func toggleTasks() async
    func switchConversation(_ id: ConversationID) async
}

/// Options used to open a durable session.
public struct OpenDurableOptions: Sendable, Equatable, Codable {
    public let cwd: String?
    public let continueSession: Bool

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
