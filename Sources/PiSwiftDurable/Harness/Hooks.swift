import PiSwiftAI
import PiSwiftChord

/// Read-only task services and durable memos supplied to task hooks.
public struct HookApi: Sendable {
    /// The ID of the task bound to this value or invocation.
    public var taskId: TaskID
    /// The conversation that owns or is addressed by this value.
    public var conversationId: ConversationID
    /// The model service used by this harness or task.
    public var models: any DurableModels
    /// Document snapshot services available to this hook or renderer.
    public var read: HarnessDocumentReader
    /// Reads a saved task memo or installs a candidate when absent.
    public var memo: @Sendable (String, JSONValue?, ChordContext) async throws -> JSONValue?
    /// Binds read services, models, and durable memos to a task invocation.
    public init(taskId: TaskID, conversationId: ConversationID, models: any DurableModels,
                read: HarnessDocumentReader = .init(),
                memo: @escaping @Sendable (String, JSONValue?, ChordContext) async throws -> JSONValue? = { _, _, _ in nil }) {
        self.taskId = taskId; self.conversationId = conversationId; self.models = models; self.read = read; self.memo = memo
    }
}

/// The model messages a before-request hook can replace.
public struct GenerationRequest: Sendable {
    /// The ordered model messages supplied to this operation.
    public var messages: [Message]
    /// Stores the model messages supplied to before-request hooks.
    public init(messages: [Message]) { self.messages = messages }
}
/// Additional user content that continues the current generation.
public struct GenerationYield: Sendable {
    /// The user content that continues the current generation.
    public var `continue`: UserContent
    /// Supplies user content to continue the current generation.
    public init(continue input: UserContent) { self.continue = input }
}
/// Callbacks at request, response, yield, and tool completion boundaries.
public struct GenerationHooks: Sendable {
    /// Can replace messages before a model request starts.
    public var beforeRequest: (@Sendable (GenerationRequest, HookApi, ChordContext) async throws -> GenerationRequest?)?
    /// Runs after a complete assistant response is received.
    public var afterResponse: (@Sendable (AssistantMessage, HookApi, ChordContext) async throws -> Void)?
    /// Can supply additional user content after the assistant yields.
    public var onYield: (@Sendable (AssistantMessage, HookApi, ChordContext) async throws -> GenerationYield?)?
    /// Runs after all tool-result entries are committed.
    public var afterTools: (@Sendable (EntryID, [EntryID], HookApi, ChordContext) async throws -> Void)?
    /// Selects optional request, response, yield, and after-tools callbacks.
    public init(
        beforeRequest: (@Sendable (GenerationRequest, HookApi, ChordContext) async throws -> GenerationRequest?)? = nil,
        afterResponse: (@Sendable (AssistantMessage, HookApi, ChordContext) async throws -> Void)? = nil,
        onYield: (@Sendable (AssistantMessage, HookApi, ChordContext) async throws -> GenerationYield?)? = nil,
        afterTools: (@Sendable (EntryID, [EntryID], HookApi, ChordContext) async throws -> Void)? = nil
    ) {
        self.beforeRequest = beforeRequest; self.afterResponse = afterResponse; self.onYield = onYield; self.afterTools = afterTools
    }
}

/// A tool hook decision that can replace arguments or block execution.
public struct BeforeToolResult: Sendable {
    /// Replacement JSON arguments for the tool call.
    public var arguments: JSONObject?
    /// The reason to reject execution of the tool call.
    public var block: String?
    /// Selects replacement arguments or a reason to block the tool.
    public init(arguments: JSONObject? = nil, block: String? = nil) { self.arguments = arguments; self.block = block }
}
/// Callbacks that can block a tool or replace its arguments and result.
public struct ToolHooks: Sendable {
    /// Can change arguments or block the tool before execution.
    public var beforeTool: (@Sendable (ToolCall, HookApi, ChordContext) async throws -> BeforeToolResult?)?
    /// Can replace the result after tool execution.
    public var afterTool: (@Sendable (ToolCall, ToolExecutionResult, HookApi, ChordContext) async throws -> ToolExecutionResult?)?
    /// Selects optional callbacks before and after tool execution.
    public init(
        beforeTool: (@Sendable (ToolCall, HookApi, ChordContext) async throws -> BeforeToolResult?)? = nil,
        afterTool: (@Sendable (ToolCall, ToolExecutionResult, HookApi, ChordContext) async throws -> ToolExecutionResult?)? = nil
    ) { self.beforeTool = beforeTool; self.afterTool = afterTool }
}
/// The context range and instructions offered to a compaction hook.
public struct CompactionHookInput: Sendable {
    /// The saved cause of cancellation, unanswered input, or compaction.
    public var reason: CompactionReason
    /// Visible entries in conversation order.
    public var entries: [EntryRecord]
    /// The ordered model messages supplied to this operation.
    public var messages: [Message]
    /// The first entry retained after compaction.
    public var firstKept: EntryID
    /// Additional agent or compaction instructions.
    public var instructions: String?
    /// Supplies the context range, trigger, and instructions to a summary hook.
    public init(reason: CompactionReason, entries: [EntryRecord], messages: [Message], firstKept: EntryID, instructions: String? = nil) {
        self.reason = reason; self.entries = entries; self.messages = messages; self.firstKept = firstKept; self.instructions = instructions
    }
}
/// A hook can decline compaction or supply the summary text.
public enum CompactionHookDecision: Sendable {
    /// Does not supply a compaction summary.
    case decline
    /// Uses the hook-supplied summary text.
    case summary(String)
}
/// Callbacks that can provide a summary before the model request.
public struct CompactionHooks: Sendable {
    /// Can supply a compaction summary before the model request.
    public var beforeCompact: (@Sendable (CompactionHookInput, HookApi, ChordContext) async throws -> CompactionHookDecision?)?
    /// Selects an optional callback that can provide a compaction summary.
    public init(beforeCompact: (@Sendable (CompactionHookInput, HookApi, ChordContext) async throws -> CompactionHookDecision?)? = nil) {
        self.beforeCompact = beforeCompact
    }
}

/// User task kinds can store their own Sendable hooks value; the task checks the cast.
public struct HookRegistration: Sendable {
    /// The stable task name that selects these hook handlers.
    public var task: String
    /// The task-specific hook callbacks stored at this JSON boundary.
    public var handlers: any Sendable
    /// Associates typed hook handlers with a stable task name.
    public init<Handlers: Sendable>(task: String, handlers: Handlers) { self.task = task; self.handlers = handlers }
    /// Returns the hook handlers only when they match the requested Swift type.
    public func handlers<Handlers: Sendable>(as type: Handlers.Type) -> Handlers? { handlers as? Handlers }
}
/// Registers callbacks for the selected task kind.
public func hook<Handlers: Sendable>(_ task: String, handlers: Handlers) -> HookRegistration {
    HookRegistration(task: task, handlers: handlers)
}
/// Registers callbacks for the selected task kind.
public func hook(_ handlers: GenerationHooks) -> HookRegistration { hook("pi.generation", handlers: handlers) }
/// Registers callbacks for the selected task kind.
public func hook(_ handlers: ToolHooks) -> HookRegistration { hook("pi.tool", handlers: handlers) }
/// Registers callbacks for the selected task kind.
public func hook(_ handlers: CompactionHooks) -> HookRegistration { hook("pi.compaction", handlers: handlers) }
