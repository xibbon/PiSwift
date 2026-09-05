import Foundation
import PiSwiftAI

// MARK: - Extension Formats

/// How the extension was loaded
public enum ExtensionFormat: Sendable {
    case singleFile(url: URL)
    case packageDirectory(url: URL)
    case inline(name: String)
}

/// A named, in-process extension factory. Inline extensions avoid dylib compilation
/// while retaining the same registration surface as file-based extensions.
public struct InlineExtension: Sendable {
    public let name: String
    public let factory: @Sendable (HookAPI) throws -> Void

    public init(name: String, factory: @escaping @Sendable (HookAPI) throws -> Void) {
        self.name = name
        self.factory = factory
    }
}

// MARK: - Extension Errors

/// Error types for extension loading and execution
public enum ExtensionLoadError: Sendable, LocalizedError {
    /// Extension file not found at path
    case fileNotFound(path: String)

    /// Invalid extension format or missing entry point
    case invalidExtension(path: String, reason: String)

    /// Compilation error when loading extension
    case compilationError(path: String, error: String)

    /// Error loading package dependencies
    case packageLoadError(path: String, error: String)

    /// Runtime loading error (dlopen/dlsym)
    case loadError(path: String, error: String)

    /// IO error reading extension
    case ioError(path: String, error: Error)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Extension not found: \(path)"
        case .invalidExtension(let path, let reason):
            return "Invalid extension '\(path)': \(reason)"
        case .compilationError(let path, let error):
            return "Compilation error in '\(path)': \(error)"
        case .packageLoadError(let path, let error):
            return "Package load error in '\(path)': \(error)"
        case .loadError(let path, let error):
            return "Load error in '\(path)': \(error)"
        case .ioError(let path, let error):
            return "IO error loading '\(path)': \(error)"
        }
    }
}

// MARK: - Tool Types

/// Definition of a custom tool that can be registered by extensions
public struct ToolDefinition: Sendable, Decodable {
    /// Tool name (used in LLM tool calls)
    public let name: String
    
    /// Label for display purposes
    public let label: String
    
    /// Description shown to the LLM
    public let description: String
    
    /// Tool parameters schema (JSON Schema-like)
    public let parameters: [String: AnyCodable]?
    
    /// Custom rendering for tool calls
    public let renderCall: (@Sendable ([String: AnyCodable], Theme) -> HookComponent)?

    /// Custom rendering for tool results
    public let renderResult: (@Sendable (HookMessage, HookMessageRenderOptions, Theme) -> HookComponent)?

    public var renderShell: ToolRenderShell
    
    public init(
        name: String,
        label: String,
        description: String,
        parameters: [String: AnyCodable]? = nil,
        renderCall: (@Sendable ([String: AnyCodable], Theme) -> HookComponent)? = nil,
        renderResult: (@Sendable (HookMessage, HookMessageRenderOptions, Theme) -> HookComponent)? = nil,
        renderShell: ToolRenderShell = .default
    ) {
        self.name = name
        self.label = label
        self.description = description
        self.parameters = parameters
        self.renderCall = renderCall
        self.renderResult = renderResult
        self.renderShell = renderShell
    }

    private enum CodingKeys: String, CodingKey {
        case name, label, description, parameters, renderShell
    }

    /// Decode metadata. JSON does not contain render functions.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            label: try container.decode(String.self, forKey: .label),
            description: try container.decode(String.self, forKey: .description),
            parameters: try container.decodeIfPresent([String: AnyCodable].self, forKey: .parameters),
            renderShell: try container.decodeIfPresent(String.self, forKey: .renderShell) == "self" ? .self : .default
        )
    }
}

/// A tool that has been loaded from an extension
public struct LoadedTool: Sendable {
    public let definition: ToolDefinition
    public let execute: @Sendable (String, [String: AnyCodable], CancellationToken?, ToolUpdateCallback?, HookContext) async throws -> ToolResult
    
    public init(
        definition: ToolDefinition,
        execute: @escaping @Sendable (String, [String: AnyCodable], CancellationToken?, ToolUpdateCallback?, HookContext) async throws -> ToolResult
    ) {
        self.definition = definition
        self.execute = execute
    }
}

// MARK: - Extension Result Types

/// Result from loading a single extension
public struct LoadedExtension: Sendable {
    /// Original path provided by user
    public let path: String
    
    /// Resolved absolute path
    public let resolvedPath: String
    
    /// How the extension was loaded
    public let format: ExtensionFormat
    
    /// Event handlers registered by extension
    public let handlers: [String: [HookHandler]]
    
    /// Message renderers registered by extension
    public let messageRenderers: [String: HookMessageRenderer]

    /// Display-only session-entry renderers registered by extension.
    public let entryRenderers: [String: EntryRenderer]
    
    /// Commands registered by extension
    public let commands: [String: RegisteredCommand]
    
    /// Flags registered by extension
    public let flags: [String: HookFlag]
    
    /// Shortcuts registered by extension
    public let shortcuts: [KeyId: HookShortcut]
    
    /// API setter methods (called by runner)
    public let setSendMessageHandler: HookSendMessageSetter
    public let setAppendEntryHandler: HookAppendEntrySetter
    public let setSetSessionNameHandler: @Sendable (@escaping HookSetSessionNameHandler) -> Void
    public let setGetSessionNameHandler: @Sendable (@escaping HookGetSessionNameHandler) -> Void
    public let setGetActiveToolsHandler: HookGetActiveToolsSetter
    public let setGetAllToolsHandler: HookGetAllToolsSetter
    public let setSetActiveToolsHandler: HookSetActiveToolsSetter
    public let setFlagValue: HookSetFlagValue
    
    /// Custom tools registered by extension
    public let tools: [LoadedTool]?
    
    public init(
        path: String,
        resolvedPath: String,
        format: ExtensionFormat,
        handlers: [String: [HookHandler]] = [:],
        messageRenderers: [String: HookMessageRenderer] = [:],
        entryRenderers: [String: EntryRenderer] = [:],
        commands: [String: RegisteredCommand] = [:],
        flags: [String: HookFlag] = [:],
        shortcuts: [KeyId: HookShortcut] = [:],
        setSendMessageHandler: @escaping HookSendMessageSetter,
        setAppendEntryHandler: @escaping HookAppendEntrySetter,
        setSetSessionNameHandler: @escaping @Sendable (@escaping HookSetSessionNameHandler) -> Void,
        setGetSessionNameHandler: @escaping @Sendable (@escaping HookGetSessionNameHandler) -> Void,
        setGetActiveToolsHandler: @escaping HookGetActiveToolsSetter,
        setGetAllToolsHandler: @escaping HookGetAllToolsSetter,
        setSetActiveToolsHandler: @escaping HookSetActiveToolsSetter,
        setFlagValue: @escaping HookSetFlagValue,
        tools: [LoadedTool]? = nil
    ) {
        self.path = path
        self.resolvedPath = resolvedPath
        self.format = format
        self.handlers = handlers
        self.messageRenderers = messageRenderers
        self.entryRenderers = entryRenderers
        self.commands = commands
        self.flags = flags
        self.shortcuts = shortcuts
        self.setSendMessageHandler = setSendMessageHandler
        self.setAppendEntryHandler = setAppendEntryHandler
        self.setSetSessionNameHandler = setSetSessionNameHandler
        self.setGetSessionNameHandler = setGetSessionNameHandler
        self.setGetActiveToolsHandler = setGetActiveToolsHandler
        self.setGetAllToolsHandler = setGetAllToolsHandler
        self.setSetActiveToolsHandler = setSetActiveToolsHandler
        self.setFlagValue = setFlagValue
        self.tools = tools
    }
}

/// Result from loading multiple extensions
public struct LoadExtensionsResult: Sendable {
    /// Successfully loaded hooks (extensions produce LoadedHooks for HookRunner)
    public let hooks: [LoadedHook]

    /// Errors encountered during loading
    public let errors: [ExtensionLoadError]

    public init(hooks: [LoadedHook] = [], errors: [ExtensionLoadError] = []) {
        self.hooks = hooks
        self.errors = errors
    }
}

// MARK: - Tool Callback Types

/// Callback for streaming tool updates
public typealias ToolUpdateCallback = @Sendable (_ update: ToolResult) -> Void

/// Tool result from extension tool execution
public struct ToolResult: Sendable {
    /// Content sent to the LLM
    public let content: [ContentBlock]
    
    /// Additional data for UI/state (not sent to LLM)
    public let details: [String: AnyCodable]?
    
    /// Whether this is an error result
    public let isError: Bool
    
    public init(content: [ContentBlock], details: [String: AnyCodable]? = nil, isError: Bool = false) {
        self.content = content
        self.details = details
        self.isError = isError
    }
}
