import PiSwiftAI
import PiSwiftChord

public struct ModelRef: Sendable, Equatable, Codable {
    public var provider: String
    public var modelId: String
    public init(provider: String, modelId: String) { self.provider = provider; self.modelId = modelId }
}

public enum ToolExecutionMode: String, Sendable, Codable { case parallel, sequential }
public enum QueueMode: String, Sendable, Codable { case all; case oneAtATime = "one-at-a-time" }
public enum ToolReplay: String, Sendable, Codable { case safe, unsafe }
public enum CompactionReason: String, Sendable, Codable { case manual, threshold, overflow }

/// Committed document reads with typed token adapters.
public struct HarnessDocumentReader: Sendable {
    internal let typedRead: (@Sendable (DocumentDefinition, DocumentAddress, ChordContext) async throws -> JSONObject?)?
    internal let typedHistoricalRead: (@Sendable (DocumentDefinition, DocumentAddress, EntryID, ChordContext) async throws -> JSONObject?)?
    public var snapshot: @Sendable (String, ConversationID?, ChordContext) async throws -> JSONObject?
    public var snapshotAsOf: @Sendable (String, ConversationID, EntryID, ChordContext) async throws -> JSONObject?
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

public struct PromptInput: Sendable {
    public var conversationId: ConversationID
    public var agent: Agent
    public var env: (any ExecutionEnv)?
    public var shown: [String: String]
    public var read: HarnessDocumentReader
    public init(conversationId: ConversationID, agent: Agent, env: (any ExecutionEnv)? = nil,
                shown: [String: String] = [:], read: HarnessDocumentReader = .init()) {
        self.conversationId = conversationId; self.agent = agent; self.env = env; self.shown = shown; self.read = read
    }
}

public struct PromptSection: Sendable {
    public var key: String
    public var render: @Sendable (PromptInput, ChordContext) async throws -> String?
    public var tag: Bool?
    public init(key: String, tag: Bool? = nil,
                render: @escaping @Sendable (PromptInput, ChordContext) async throws -> String?) {
        self.key = key; self.tag = tag; self.render = render
    }
}

public func section(_ key: String, tag: Bool? = nil,
                    render: @escaping @Sendable (PromptInput, ChordContext) async throws -> String?) -> PromptSection {
    PromptSection(key: key, tag: tag, render: render)
}

public enum Wrap: Sendable {
    case tool(String, @Sendable (ToolRegistration) throws -> ToolRegistration)
    case section(String, @Sendable (PromptSection) throws -> PromptSection)
}
public func wrapTool(_ tool: ToolRegistration, transform: @escaping @Sendable (ToolRegistration) throws -> ToolRegistration) -> Wrap {
    .tool(tool.name, transform)
}
public func wrapSection(_ key: String, transform: @escaping @Sendable (PromptSection) throws -> PromptSection) -> Wrap {
    .section(key, transform)
}

public struct Extension: Sendable {
    public var name: String
    public var tools: [ToolRegistration]
    public var sections: [PromptSection]
    public var hooks: [HookRegistration]
    public var wraps: [Wrap]
    public var tasks: [AnyTaskDefinition]
    public init(name: String, tools: [ToolRegistration] = [], sections: [PromptSection] = [],
                hooks: [HookRegistration] = [], wraps: [Wrap] = [], tasks: [AnyTaskDefinition] = []) {
        self.name = name; self.tools = tools; self.sections = sections; self.hooks = hooks; self.wraps = wraps
        self.tasks = tasks
    }
}
public func defineExtension(_ value: Extension) -> Extension { value }

public struct Agent: Sendable {
    public var model: ModelRef?
    public var thinkingLevel: ModelThinkingLevel
    public var extensions: [Extension]
    public var tools: [ToolRegistration]
    public var sections: [PromptSection]
    public var instructions: String?
    public var cwd: String?
    public init(model: ModelRef? = nil, thinkingLevel: ModelThinkingLevel = .off,
                extensions: [Extension] = [], tools: [ToolRegistration] = [], sections: [PromptSection] = [],
                instructions: String? = nil, cwd: String? = nil) {
        self.model = model; self.thinkingLevel = thinkingLevel; self.extensions = extensions
        self.tools = tools; self.sections = sections; self.instructions = instructions; self.cwd = cwd
    }
}
