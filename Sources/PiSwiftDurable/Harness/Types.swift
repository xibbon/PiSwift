import PiSwiftAI
import PiSwiftChord

/// The provider and model identifier saved in agent configuration.
public struct ModelRef: Sendable, Equatable, Codable {
    /// The provider identifier used to resolve the model.
    public var provider: String
    /// The model identifier within its provider.
    public var modelId: String
    /// Pairs a provider identifier with its model identifier.
    public init(provider: String, modelId: String) { self.provider = provider; self.modelId = modelId }
}

/// Selects parallel or sequential tool execution.
public enum ToolExecutionMode: String, Sendable, Codable {
    /// Allows tool calls to execute concurrently.
    case parallel
    /// Executes tool calls one at a time.
    case sequential
}
/// Selects all queued inputs or one input at each admission boundary.
public enum QueueMode: String, Sendable, Codable {
    /// Admits all queued inputs at the selected boundary.
    case all
    /// Admits one queued input at each selected boundary.
    case oneAtATime = "one-at-a-time"
}
/// Whether execution can safely repeat after a process restart.
public enum ToolReplay: String, Sendable, Codable {
    /// Execution can repeat after restart without an unsafe duplicate effect.
    case safe
    /// A restart cannot repeat execution safely.
    case unsafe
}
/// The trigger for a manual or automatic context compaction.
public enum CompactionReason: String, Sendable, Codable {
    /// The host explicitly requested this compaction.
    case manual
    /// The automatic context threshold requested this compaction.
    case threshold
    /// The provider rejected the request because its context was too large.
    case overflow
}

/// Committed document reads with typed token adapters.
public struct HarnessDocumentReader: Sendable {
    internal let typedRead: (@Sendable (DocumentDefinition, DocumentAddress, ChordContext) async throws -> JSONObject?)?
    internal let typedHistoricalRead: (@Sendable (DocumentDefinition, DocumentAddress, EntryID, ChordContext) async throws -> JSONObject?)?
    /// Reads a current document object by kind and conversation.
    public var snapshot: @Sendable (String, ConversationID?, ChordContext) async throws -> JSONObject?
    /// Reads a historical conversation document through an entry boundary.
    public var snapshotAsOf: @Sendable (String, ConversationID, EntryID, ChordContext) async throws -> JSONObject?
    /// Stores callbacks for current and historical document object reads.
    public init(
        snapshot: @escaping @Sendable (String, ConversationID?, ChordContext) async throws -> JSONObject? = { _, _, _ in nil },
        snapshotAsOf: @escaping @Sendable (String, ConversationID, EntryID, ChordContext) async throws -> JSONObject? = { _, _, _, _ in nil }
    ) { self.snapshot = snapshot; self.snapshotAsOf = snapshotAsOf; typedRead = nil; typedHistoricalRead = nil }
    internal init(snapshot: @escaping @Sendable (String, ConversationID?, ChordContext) async throws -> JSONObject?,
                  snapshotAsOf: @escaping @Sendable (String, ConversationID, EntryID, ChordContext) async throws -> JSONObject?,
                  typedRead: @escaping @Sendable (DocumentDefinition, DocumentAddress, ChordContext) async throws -> JSONObject?,
                  typedHistoricalRead: @escaping @Sendable (DocumentDefinition, DocumentAddress, EntryID, ChordContext) async throws -> JSONObject?) {
        self.snapshot = snapshot; self.snapshotAsOf = snapshotAsOf; self.typedRead = typedRead; self.typedHistoricalRead = typedHistoricalRead
    }
}

/// The conversation, resolved agent, environment, and read services used to render sections.
public struct PromptInput: Sendable {
    /// The conversation that owns or is addressed by this value.
    public var conversationId: ConversationID
    /// The resolved agent whose sections are being rendered.
    public var agent: Agent
    /// The optional execution environment for the conversation.
    public var env: (any ExecutionEnv)?
    /// The prompt section text already visible to the model.
    public var shown: [String: String]
    /// Document snapshot services available to this hook or renderer.
    public var read: HarnessDocumentReader
    /// Supplies the resolved conversation state and read services to a section renderer.
    public init(conversationId: ConversationID, agent: Agent, env: (any ExecutionEnv)? = nil,
                shown: [String: String] = [:], read: HarnessDocumentReader = .init()) {
        self.conversationId = conversationId; self.agent = agent; self.env = env; self.shown = shown; self.read = read
    }
}

/// A named prompt section with a renderer and optional XML-style tag.
public struct PromptSection: Sendable {
    /// The stable key used to update this prompt section.
    public var key: String
    /// Renders the prompt section text. Nil removes the section.
    public var render: @Sendable (PromptInput, ChordContext) async throws -> String?
    /// Whether to surround rendered text with its section-name tag.
    public var tag: Bool?
    /// Associates a section key and optional tag policy with its renderer.
    public init(key: String, tag: Bool? = nil,
                render: @escaping @Sendable (PromptInput, ChordContext) async throws -> String?) {
        self.key = key; self.tag = tag; self.render = render
    }
}

/// Creates a named prompt section with an asynchronous renderer.
public func section(_ key: String, tag: Bool? = nil,
                    render: @escaping @Sendable (PromptInput, ChordContext) async throws -> String?) -> PromptSection {
    PromptSection(key: key, tag: tag, render: render)
}

/// A transformation of a selected tool or prompt section.
public enum Wrap: Sendable {
    /// Transforms the tool selected by its name.
    case tool(String, @Sendable (ToolRegistration) throws -> ToolRegistration)
    /// Transforms the prompt section selected by its key.
    case section(String, @Sendable (PromptSection) throws -> PromptSection)
}
/// Creates a transformation for the selected tool name.
public func wrapTool(_ tool: ToolRegistration, transform: @escaping @Sendable (ToolRegistration) throws -> ToolRegistration) -> Wrap {
    .tool(tool.name, transform)
}
/// Creates a transformation for the selected prompt section key.
public func wrapSection(_ key: String, transform: @escaping @Sendable (PromptSection) throws -> PromptSection) -> Wrap {
    .section(key, transform)
}

/// A named group of tools, prompt sections, task hooks, wrappers, and task definitions.
public struct Extension: Sendable {
    /// The stable name used to resolve this definition in the registry.
    public var name: String
    /// The tool registrations or live tool slots in this value.
    public var tools: [ToolRegistration]
    /// The ordered prompt sections selected for the agent.
    public var sections: [PromptSection]
    /// Hook callbacks supplied by the selected extensions.
    public var hooks: [HookRegistration]
    /// Transformations applied to selected tools and prompt sections.
    public var wraps: [Wrap]
    /// The task definitions or records included in this value.
    public var tasks: [AnyTaskDefinition]
    /// Groups named tools, sections, hooks, wrappers, and task definitions for registry installation.
    public init(name: String, tools: [ToolRegistration] = [], sections: [PromptSection] = [],
                hooks: [HookRegistration] = [], wraps: [Wrap] = [], tasks: [AnyTaskDefinition] = []) {
        self.name = name; self.tools = tools; self.sections = sections; self.hooks = hooks; self.wraps = wraps
        self.tasks = tasks
    }
}
/// Returns the extension value for use in host registration.
public func defineExtension(_ value: Extension) -> Extension { value }

/// The resolved model, tools, prompt sections, and directory for one conversation.
public struct Agent: Sendable {
    /// The stored provider and model reference or entry model contribution.
    public var model: ModelRef?
    /// The reasoning effort selected for the model.
    public var thinkingLevel: ModelThinkingLevel
    /// The selected extensions or extension-selection change.
    public var extensions: [Extension]
    /// The tool registrations or live tool slots in this value.
    public var tools: [ToolRegistration]
    /// The ordered prompt sections selected for the agent.
    public var sections: [PromptSection]
    /// Additional agent or compaction instructions.
    public var instructions: String?
    /// The working directory used by this conversation or command.
    public var cwd: String?
    /// Creates the resolved model, tools, sections, instructions, and working directory.
    public init(model: ModelRef? = nil, thinkingLevel: ModelThinkingLevel = .off,
                extensions: [Extension] = [], tools: [ToolRegistration] = [], sections: [PromptSection] = [],
                instructions: String? = nil, cwd: String? = nil) {
        self.model = model; self.thinkingLevel = thinkingLevel; self.extensions = extensions
        self.tools = tools; self.sections = sections; self.instructions = instructions; self.cwd = cwd
    }
}
