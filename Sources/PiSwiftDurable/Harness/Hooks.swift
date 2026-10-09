import PiSwiftAI
import PiSwiftChord

public struct HookApi: Sendable {
    public var taskId: TaskID
    public var conversationId: ConversationID
    public var models: any DurableModels
    public var read: HarnessDocumentReader
    public var memo: @Sendable (String, JSONValue?, PiSwiftChord.Context) async throws -> JSONValue?
    public init(taskId: TaskID, conversationId: ConversationID, models: any DurableModels,
                read: HarnessDocumentReader = .init(),
                memo: @escaping @Sendable (String, JSONValue?, PiSwiftChord.Context) async throws -> JSONValue? = { _, _, _ in nil }) {
        self.taskId = taskId; self.conversationId = conversationId; self.models = models; self.read = read; self.memo = memo
    }
}

public struct GenerationRequest: Sendable {
    public var messages: [Message]
    public init(messages: [Message]) { self.messages = messages }
}
public struct GenerationYield: Sendable {
    public var `continue`: UserContent
    public init(continue input: UserContent) { self.continue = input }
}
public struct GenerationHooks: Sendable {
    public var beforeRequest: (@Sendable (GenerationRequest, HookApi, PiSwiftChord.Context) async throws -> GenerationRequest?)?
    public var afterResponse: (@Sendable (AssistantMessage, HookApi, PiSwiftChord.Context) async throws -> Void)?
    public var onYield: (@Sendable (AssistantMessage, HookApi, PiSwiftChord.Context) async throws -> GenerationYield?)?
    public var afterTools: (@Sendable (EntryID, [EntryID], HookApi, PiSwiftChord.Context) async throws -> Void)?
    public init(
        beforeRequest: (@Sendable (GenerationRequest, HookApi, PiSwiftChord.Context) async throws -> GenerationRequest?)? = nil,
        afterResponse: (@Sendable (AssistantMessage, HookApi, PiSwiftChord.Context) async throws -> Void)? = nil,
        onYield: (@Sendable (AssistantMessage, HookApi, PiSwiftChord.Context) async throws -> GenerationYield?)? = nil,
        afterTools: (@Sendable (EntryID, [EntryID], HookApi, PiSwiftChord.Context) async throws -> Void)? = nil
    ) {
        self.beforeRequest = beforeRequest; self.afterResponse = afterResponse; self.onYield = onYield; self.afterTools = afterTools
    }
}

public struct BeforeToolResult: Sendable {
    public var arguments: JSONObject?
    public var block: String?
    public init(arguments: JSONObject? = nil, block: String? = nil) { self.arguments = arguments; self.block = block }
}
public struct ToolHooks: Sendable {
    public var beforeTool: (@Sendable (ToolCall, HookApi, PiSwiftChord.Context) async throws -> BeforeToolResult?)?
    public var afterTool: (@Sendable (ToolCall, ToolExecutionResult, HookApi, PiSwiftChord.Context) async throws -> ToolExecutionResult?)?
    public init(
        beforeTool: (@Sendable (ToolCall, HookApi, PiSwiftChord.Context) async throws -> BeforeToolResult?)? = nil,
        afterTool: (@Sendable (ToolCall, ToolExecutionResult, HookApi, PiSwiftChord.Context) async throws -> ToolExecutionResult?)? = nil
    ) { self.beforeTool = beforeTool; self.afterTool = afterTool }
}
public struct CompactionHookInput: Sendable {
    public var reason: CompactionReason
    public var entries: [EntryRecord]
    public var messages: [Message]
    public var firstKept: EntryID
    public var instructions: String?
    public init(reason: CompactionReason, entries: [EntryRecord], messages: [Message], firstKept: EntryID, instructions: String? = nil) {
        self.reason = reason; self.entries = entries; self.messages = messages; self.firstKept = firstKept; self.instructions = instructions
    }
}
public enum CompactionHookDecision: Sendable { case decline, summary(String) }
public struct CompactionHooks: Sendable {
    public var beforeCompact: (@Sendable (CompactionHookInput, HookApi, PiSwiftChord.Context) async throws -> CompactionHookDecision?)?
    public init(beforeCompact: (@Sendable (CompactionHookInput, HookApi, PiSwiftChord.Context) async throws -> CompactionHookDecision?)? = nil) {
        self.beforeCompact = beforeCompact
    }
}

/// User task kinds can store their own Sendable hooks value; the task checks the cast.
public struct HookRegistration: Sendable {
    public var task: String
    public var handlers: any Sendable
    public init<Handlers: Sendable>(task: String, handlers: Handlers) { self.task = task; self.handlers = handlers }
    public func handlers<Handlers: Sendable>(as type: Handlers.Type) -> Handlers? { handlers as? Handlers }
}
public func hook<Handlers: Sendable>(_ task: String, handlers: Handlers) -> HookRegistration {
    HookRegistration(task: task, handlers: handlers)
}
public func hook(_ handlers: GenerationHooks) -> HookRegistration { hook("pi.generation", handlers: handlers) }
public func hook(_ handlers: ToolHooks) -> HookRegistration { hook("pi.tool", handlers: handlers) }
public func hook(_ handlers: CompactionHooks) -> HookRegistration { hook("pi.compaction", handlers: handlers) }
