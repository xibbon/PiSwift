import PiSwiftAI
import PiSwiftChord

/// Read-only task services and durable memos supplied to task hooks.
public struct HookApi: Sendable {
    /// The ID of the task bound to this value or invocation.
    public var taskId: TaskID
    /// The conversation that owns or is addressed by this value.
    public var conversationId: ConversationID
    /// The model service used by this harness or task.
    public var models: any DurableModels {
        get { modelsProvider() }
        set { modelsProvider = { newValue } }
    }
    private var modelsProvider: @Sendable () -> any DurableModels
    /// Document snapshot services available to this hook or renderer.
    public var read: HarnessDocumentReader
    /// Reads a saved task memo or installs a candidate when absent.
    public var memo: @Sendable (String, JSONValue?, ChordContext) async throws -> JSONValue?
    private let readEntries: @Sendable (ConversationEntryQuery, Int, Cursor?, ChordContext) async throws -> Page<EntryRecord, Cursor>
    private let readEntry: @Sendable (EntryID, ChordContext) async throws -> EntryRecord?
    /// Binds read services, models, and durable memos to a task invocation.
    public init(taskId: TaskID, conversationId: ConversationID, models: @autoclosure @escaping @Sendable () -> any DurableModels,
                read: HarnessDocumentReader = .init(),
                memo: @escaping @Sendable (String, JSONValue?, ChordContext) async throws -> JSONValue? = { _, _, _ in nil },
                entries: @escaping @Sendable (ConversationEntryQuery, Int, Cursor?, ChordContext) async throws -> Page<EntryRecord, Cursor> = { _, _, _, _ in throw SessionError.message("Hook entry reads unavailable") },
                entry: @escaping @Sendable (EntryID, ChordContext) async throws -> EntryRecord? = { _, _ in throw SessionError.message("Hook entry reads unavailable") }) {
        self.taskId = taskId; self.conversationId = conversationId; self.modelsProvider = models; self.read = read; self.memo = memo
        readEntries = entries; readEntry = entry
    }
    /// Reads a page of raw entries in this task's visible conversation history.
    public func entries(_ query: ConversationEntryQuery = .init(), limit: Int, cursor: Cursor? = nil,
                        context: ChordContext) async throws -> Page<EntryRecord, Cursor> {
        try await readEntries(query, limit, cursor, context)
    }
    /// Reads one raw entry in this task's visible conversation history.
    public func entry(_ id: EntryID, context: ChordContext) async throws -> EntryRecord? {
        try await readEntry(id, context)
    }
    /// Reads one entry only when its kind matches the token.
    public func entry<Data>(_ token: EntryKind<Data>, id: EntryID, context: ChordContext) async throws -> TypedEntry<Data>? {
        guard let record = try await readEntry(id, context), record.kind == token.kind else { return nil }
        return try TypedEntry(record)
    }
}

/// The model messages a before-request hook can replace.
public struct GenerationRequest: Sendable {
    /// The ordered model messages supplied to this operation.
    public var messages: [Message]
    /// Stores the model messages supplied to before-request hooks.
    public init(messages: [Message]) { self.messages = messages }
}
/// The provider's JSON request body after PiSwiftAI has built it.
public struct ProviderRequest: Sendable {
    public var model: Model
    public var payload: JSONValue
    public init(model: Model, payload: JSONValue) { self.model = model; self.payload = payload }
}
/// A replacement body for this provider request.
public struct ProviderRequestReplacement: Sendable {
    public var payload: JSONValue
    public init(payload: JSONValue) { self.payload = payload }
}
/// Additional user content that continues the current generation.
public struct GenerationYield: Sendable {
    /// The user content that continues the current generation.
    public var `continue`: UserContent
    /// Supplies user content to continue the current generation.
    public init(continue input: UserContent) { self.continue = input }
}
/// A child task requested by an afterRun hook.
public struct RunEndTask: Sendable {
    public let task: AnyTaskDefinition
    public let input: JSONValue
    public init<Input, Checkpoint, Result, Hooks>(_ task: TaskDefinition<Input, Checkpoint, Result, Hooks>, input: Input) throws {
        self.task = task.eraseToAnyTaskDefinition()
        self.input = try JSONValue(encoding: input)
    }
}
/// Binds a typed task and input to an afterRun request.
public func runEndTask<Input, Checkpoint, Result, Hooks>(
    _ task: TaskDefinition<Input, Checkpoint, Result, Hooks>, input: Input
) throws -> RunEndTask { try RunEndTask(task, input: input) }
/// Child tasks to start after a run answers.
public struct AfterRunResult: Sendable {
    public var tasks: [RunEndTask]
    public init(tasks: [RunEndTask]) { self.tasks = tasks }
}
/// Callbacks at request, response, yield, and tool completion boundaries.
public struct GenerationHooks: Sendable {
    /// Can replace messages before a model request starts.
    public var beforeRequest: (@Sendable (GenerationRequest, HookApi, ChordContext) async throws -> GenerationRequest?)?
    /// Can replace the provider body for each generated provider request.
    public var beforeProviderRequest: (@Sendable (ProviderRequest, HookApi, ChordContext) async throws -> ProviderRequestReplacement?)?
    /// Runs after a complete assistant response is received.
    public var afterResponse: (@Sendable (AssistantMessage, HookApi, ChordContext) async throws -> Void)?
    /// Can supply additional user content after the assistant yields.
    public var onYield: (@Sendable (AssistantMessage, HookApi, ChordContext) async throws -> GenerationYield?)?
    /// Runs after all tool-result entries are committed.
    public var afterTools: (@Sendable (EntryID, [EntryID], HookApi, ChordContext) async throws -> Void)?
    /// Requests children after an answer and settled inputs.
    public var afterRun: (@Sendable (GenerationRunSummary, HookApi, ChordContext) async throws -> AfterRunResult?)?
    /// Selects optional request, response, yield, and after-tools callbacks.
    public init(
        beforeRequest: (@Sendable (GenerationRequest, HookApi, ChordContext) async throws -> GenerationRequest?)? = nil,
        beforeProviderRequest: (@Sendable (ProviderRequest, HookApi, ChordContext) async throws -> ProviderRequestReplacement?)? = nil,
        afterResponse: (@Sendable (AssistantMessage, HookApi, ChordContext) async throws -> Void)? = nil,
        onYield: (@Sendable (AssistantMessage, HookApi, ChordContext) async throws -> GenerationYield?)? = nil,
        afterTools: (@Sendable (EntryID, [EntryID], HookApi, ChordContext) async throws -> Void)? = nil,
        afterRun: (@Sendable (GenerationRunSummary, HookApi, ChordContext) async throws -> AfterRunResult?)? = nil
    ) {
        self.beforeRequest = beforeRequest; self.beforeProviderRequest = beforeProviderRequest
        self.afterResponse = afterResponse; self.onYield = onYield; self.afterTools = afterTools
        self.afterRun = afterRun
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
    public var beforeTool: (@Sendable (ToolHookCall, HookApi, ChordContext) async throws -> BeforeToolResult?)?
    /// Can replace the result after tool execution.
    public var afterTool: (@Sendable (ToolHookCall, ToolExecutionResult, HookApi, ChordContext) async throws -> ToolExecutionResult?)?
    /// Selects optional callbacks before and after tool execution.
    public init(
        beforeTool: (@Sendable (ToolHookCall, HookApi, ChordContext) async throws -> BeforeToolResult?)? = nil,
        afterTool: (@Sendable (ToolHookCall, ToolExecutionResult, HookApi, ChordContext) async throws -> ToolExecutionResult?)? = nil
    ) { self.beforeTool = beforeTool; self.afterTool = afterTool }

    /// Supports existing hooks that accept the model call type.
    @_disfavoredOverload
    public init(beforeTool: @escaping @Sendable (ToolCall, HookApi, ChordContext) async throws -> BeforeToolResult?,
                afterTool: (@Sendable (ToolCall, ToolExecutionResult, HookApi, ChordContext) async throws -> ToolExecutionResult?)? = nil) {
        self.beforeTool = { call, api, context in try await beforeTool(call.call, api, context) }
        if let afterTool {
            self.afterTool = { call, result, api, context in try await afterTool(call.call, result, api, context) }
        } else { self.afterTool = nil }
    }
    /// Supports existing result hooks that accept the model call type.
    @_disfavoredOverload
    public init(afterTool: @escaping @Sendable (ToolCall, ToolExecutionResult, HookApi, ChordContext) async throws -> ToolExecutionResult?) {
        beforeTool = nil
        self.afterTool = { call, result, api, context in try await afterTool(call.call, result, api, context) }
    }
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
