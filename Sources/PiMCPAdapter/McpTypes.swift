import Foundation
import PiSwiftAI

// MARK: - Transport

public enum McpTransportType: String, Codable, Sendable {
    case stdio
    case http
}

// MARK: - MCP Tool / Resource Definitions

public struct McpTool: Codable, Sendable {
    public var name: String
    public var title: String?
    public var description: String?
    public var inputSchema: AnyCodable?
    public var outputSchema: AnyCodable?

    public init(
        name: String,
        title: String? = nil,
        description: String? = nil,
        inputSchema: AnyCodable? = nil,
        outputSchema: AnyCodable? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
    }
}

public struct McpResource: Codable, Sendable {
    public var uri: String
    public var name: String
    public var description: String?
    public var mimeType: String?

    public init(uri: String, name: String, description: String? = nil, mimeType: String? = nil) {
        self.uri = uri
        self.name = name
        self.description = description
        self.mimeType = mimeType
    }
}

public struct McpPromptArgument: Codable, Sendable {
    public var name: String
    public var title: String?
    public var description: String?
    public var required: Bool?

    public init(name: String, title: String? = nil, description: String? = nil, required: Bool? = nil) {
        self.name = name
        self.title = title
        self.description = description
        self.required = required
    }
}

public struct McpPrompt: Codable, Sendable {
    public var name: String
    public var title: String?
    public var description: String?
    public var arguments: [McpPromptArgument]?

    public init(name: String, title: String? = nil, description: String? = nil, arguments: [McpPromptArgument]? = nil) {
        self.name = name
        self.title = title
        self.description = description
        self.arguments = arguments
    }
}

public struct McpPromptMessage: Sendable {
    public var role: String
    public var content: [McpContent]

    public init(role: String, content: [McpContent]) {
        self.role = role
        self.content = content
    }
}

public struct McpPromptResult: Sendable {
    public var description: String?
    public var messages: [McpPromptMessage]

    public init(description: String? = nil, messages: [McpPromptMessage]) {
        self.description = description
        self.messages = messages
    }
}

// MARK: - MCP Content Types (tool call responses)

public struct McpContent: Codable, Sendable {
    public var type: String
    public var text: String?
    public var data: String?
    public var mimeType: String?
    public var resource: McpResourceContent?
    public var uri: String?
    public var name: String?

    public init(type: String, text: String? = nil, data: String? = nil, mimeType: String? = nil, resource: McpResourceContent? = nil, uri: String? = nil, name: String? = nil) {
        self.type = type
        self.text = text
        self.data = data
        self.mimeType = mimeType
        self.resource = resource
        self.uri = uri
        self.name = name
    }
}

public struct McpResourceContent: Codable, Sendable {
    public var uri: String
    public var text: String?
    public var blob: String?

    public init(uri: String, text: String? = nil, blob: String? = nil) {
        self.uri = uri
        self.text = text
        self.blob = blob
    }
}

public struct McpToolResult: Sendable {
    public var content: [McpContent]
    public var isError: Bool
    /// Structured MCP result data. The adapter renders this when `content` is
    /// empty, which is permitted by the MCP tools/call result shape.
    public var structuredContent: AnyCodable?
    /// The unmodified JSON-RPC result. This is retained only for proxy-tool
    /// details, where the output guard bounds it before it reaches a session.
    public var rawResult: AnyCodable?

    public init(
        content: [McpContent],
        isError: Bool = false,
        structuredContent: AnyCodable? = nil,
        rawResult: AnyCodable? = nil
    ) {
        self.content = content
        self.isError = isError
        self.structuredContent = structuredContent
        self.rawResult = rawResult
    }
}

// MARK: - Server Configuration

public struct ServerEntry: Codable, Sendable {
    public var command: String?
    public var args: [String]?
    public var socket: String?
    public var env: [String: String]?
    public var cwd: String?
    public var url: String?
    public var headers: [String: String]?
    public var auth: McpAuthMode?
    public var bearerToken: String?
    public var bearerTokenEnv: String?
    public var oauth: OAuthConfiguration?
    public var lifecycle: String?
    public var idleTimeout: Int?
    public var requestTimeoutMs: Int?
    public var exposeResources: Bool?
    public var directTools: DirectToolsConfig?
    public var includeTools: [String]?
    public var excludeTools: [String]?
    public var debug: Bool?
    public var trace: Bool?
    public var disabled: Bool?

    public init(
        command: String? = nil, args: [String]? = nil, socket: String? = nil,
        env: [String: String]? = nil, cwd: String? = nil,
        url: String? = nil, headers: [String: String]? = nil, auth: McpAuthMode? = nil,
        bearerToken: String? = nil, bearerTokenEnv: String? = nil,
        oauth: OAuthConfiguration? = nil, lifecycle: String? = nil, idleTimeout: Int? = nil,
        requestTimeoutMs: Int? = nil, exposeResources: Bool? = nil,
        directTools: DirectToolsConfig? = nil, includeTools: [String]? = nil,
        excludeTools: [String]? = nil, debug: Bool? = nil, trace: Bool? = nil,
        disabled: Bool? = nil
    ) {
        self.command = command; self.args = args; self.socket = socket; self.env = env; self.cwd = cwd
        self.url = url; self.headers = headers; self.auth = auth
        self.bearerToken = bearerToken; self.bearerTokenEnv = bearerTokenEnv
        self.oauth = oauth; self.lifecycle = lifecycle; self.idleTimeout = idleTimeout
        self.requestTimeoutMs = requestTimeoutMs; self.exposeResources = exposeResources
        self.directTools = directTools; self.includeTools = includeTools; self.excludeTools = excludeTools
        self.debug = debug; self.trace = trace; self.disabled = disabled
    }
}

public enum McpAuthMode: Sendable, Equatable, Codable {
    case oauth
    case bearer
    case none

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let enabled = try? container.decode(Bool.self), enabled == false {
            self = .none
            return
        }
        switch try container.decode(String.self) {
        case "oauth": self = .oauth
        case "bearer": self = .bearer
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected oauth, bearer, or false")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .oauth: try container.encode("oauth")
        case .bearer: try container.encode("bearer")
        case .none: try container.encode(false)
        }
    }
}

public struct OAuthConfiguration: Codable, Sendable {
    public var grantType: OAuthGrantType?
    public var clientId: String?
    public var clientSecret: String?
    public var scope: String?
    public var redirectUri: String?
    public var clientName: String?
    public var clientUri: String?

    public init(
        grantType: OAuthGrantType? = nil,
        clientId: String? = nil,
        clientSecret: String? = nil,
        scope: String? = nil,
        redirectUri: String? = nil,
        clientName: String? = nil,
        clientUri: String? = nil
    ) {
        self.grantType = grantType
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.scope = scope
        self.redirectUri = redirectUri
        self.clientName = clientName
        self.clientUri = clientUri
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let enabled = try? value.decode(Bool.self), enabled == false {
            self.init()
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            grantType: try container.decodeIfPresent(OAuthGrantType.self, forKey: .grantType),
            clientId: try container.decodeIfPresent(String.self, forKey: .clientId),
            clientSecret: try container.decodeIfPresent(String.self, forKey: .clientSecret),
            scope: try container.decodeIfPresent(String.self, forKey: .scope),
            redirectUri: try container.decodeIfPresent(String.self, forKey: .redirectUri),
            clientName: try container.decodeIfPresent(String.self, forKey: .clientName),
            clientUri: try container.decodeIfPresent(String.self, forKey: .clientUri)
        )
    }
}

public enum OAuthGrantType: String, Codable, Sendable {
    case authorizationCode = "authorization_code"
    case clientCredentials = "client_credentials"
}

public enum DirectToolsConfig: Codable, Sendable {
    case enabled(Bool)
    case tools([String])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) {
            self = .enabled(b)
        } else if let arr = try? container.decode([String].self) {
            self = .tools(arr)
        } else {
            throw DecodingError.typeMismatch(DirectToolsConfig.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected Bool or [String]"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .enabled(let b): try container.encode(b)
        case .tools(let arr): try container.encode(arr)
        }
    }
}

public struct McpSettings: Codable, Sendable {
    public var toolPrefix: String?
    public var idleTimeout: Int?
    public var directTools: Bool?
    public var requestTimeoutMs: Int?
    public var autoAuth: Bool?
    public var disableProxyTool: Bool?
    public var sampling: Bool?
    public var samplingAutoApprove: Bool?
    public var elicitation: Bool?
    public var outputGuard: OutputGuardConfig?
    public var trace: McpTraceSettings?
    /// Host-defined guidance when an OAuth server needs authorization. The
    /// adapter substitutes `${server}` and never starts a browser flow itself.
    public var authRequiredMessage: String?

    public init(
        toolPrefix: String? = nil,
        idleTimeout: Int? = nil,
        directTools: Bool? = nil,
        requestTimeoutMs: Int? = nil,
        autoAuth: Bool? = nil,
        disableProxyTool: Bool? = nil,
        sampling: Bool? = nil,
        samplingAutoApprove: Bool? = nil,
        elicitation: Bool? = nil,
        outputGuard: OutputGuardConfig? = nil,
        trace: McpTraceSettings? = nil,
        authRequiredMessage: String? = nil
    ) {
        self.toolPrefix = toolPrefix
        self.idleTimeout = idleTimeout
        self.directTools = directTools
        self.requestTimeoutMs = requestTimeoutMs
        self.autoAuth = autoAuth
        self.disableProxyTool = disableProxyTool
        self.sampling = sampling
        self.samplingAutoApprove = samplingAutoApprove
        self.elicitation = elicitation
        self.outputGuard = outputGuard
        self.trace = trace
        self.authRequiredMessage = authRequiredMessage
    }
}

/// The adapter accepts either `true`/`false` or explicit output limits.
/// This matches the programmatic form of pi-mcp-adapter configuration.
public enum OutputGuardConfig: Codable, Sendable {
    case enabled(Bool)
    case limits(OutputGuardLimits)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let enabled = try? container.decode(Bool.self) {
            self = .enabled(enabled)
        } else {
            self = .limits(try container.decode(OutputGuardLimits.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .enabled(let enabled):
            try container.encode(enabled)
        case .limits(let limits):
            try container.encode(limits)
        }
    }
}

public struct OutputGuardLimits: Codable, Sendable {
    public var maxBytes: Int?
    public var maxLines: Int?
    public var detailsMaxBytes: Int?

    public init(maxBytes: Int? = nil, maxLines: Int? = nil, detailsMaxBytes: Int? = nil) {
        self.maxBytes = maxBytes
        self.maxLines = maxLines
        self.detailsMaxBytes = detailsMaxBytes
    }
}

public struct McpConfig: Codable, Sendable {
    public var mcpServers: [String: ServerEntry]
    public var imports: [String]?
    public var settings: McpSettings?

    enum CodingKeys: String, CodingKey {
        case mcpServers
        case imports
        case settings
        // Accept hyphenated alternative
        case mcpServersHyphen = "mcp-servers"
    }

    public init(mcpServers: [String: ServerEntry] = [:], imports: [String]? = nil, settings: McpSettings? = nil) {
        self.mcpServers = mcpServers
        self.imports = imports
        self.settings = settings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let servers = try container.decodeIfPresent([String: ServerEntry].self, forKey: .mcpServers) {
            mcpServers = servers
        } else if let servers = try container.decodeIfPresent([String: ServerEntry].self, forKey: .mcpServersHyphen) {
            mcpServers = servers
        } else {
            mcpServers = [:]
        }
        imports = try container.decodeIfPresent([String].self, forKey: .imports)
        settings = try container.decodeIfPresent(McpSettings.self, forKey: .settings)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mcpServers, forKey: .mcpServers)
        try container.encodeIfPresent(imports, forKey: .imports)
        try container.encodeIfPresent(settings, forKey: .settings)
    }
}

/// Input for an opt-in MCP extension. Configuration is cloned when the
/// extension is created. The adapter never reads project or home config files.
public struct McpAdapterOptions: Sendable {
    public var config: McpConfig
    public var metadataCache: MetadataCache?
    public var metadataStore: any McpMetadataStore
    public var authorizationProvider: (any McpAuthorizationProvider)?
    public var serverRequestHandler: McpServerRequestHandler?
    public var outputStore: any McpOutputStore
    public var traceSink: (any McpTraceSink)?

    public init(
        config: McpConfig,
        metadataCache: MetadataCache? = nil,
        metadataStore: any McpMetadataStore = FileMcpMetadataStore(),
        authorizationProvider: (any McpAuthorizationProvider)? = nil,
        serverRequestHandler: McpServerRequestHandler? = nil,
        outputStore: any McpOutputStore = FileMcpOutputStore(),
        traceSink: (any McpTraceSink)? = nil
    ) {
        self.config = config
        self.metadataCache = metadataCache
        self.metadataStore = metadataStore
        self.authorizationProvider = authorizationProvider
        self.serverRequestHandler = serverRequestHandler
        self.outputStore = outputStore
        self.traceSink = traceSink
    }
}

// MARK: - Tool Metadata

public struct ToolMetadata: Sendable {
    public var name: String
    public var originalName: String
    public var description: String
    public var resourceUri: String?
    public var inputSchema: AnyCodable?

    public init(name: String, originalName: String, description: String, resourceUri: String? = nil, inputSchema: AnyCodable? = nil) {
        self.name = name
        self.originalName = originalName
        self.description = description
        self.resourceUri = resourceUri
        self.inputSchema = inputSchema
    }
}

public struct PromptMetadata: Sendable {
    public var serverName: String
    public var originalName: String
    public var commandName: String
    public var title: String?
    public var description: String
    public var arguments: [McpPromptArgument]

    public init(
        serverName: String,
        originalName: String,
        commandName: String,
        title: String? = nil,
        description: String,
        arguments: [McpPromptArgument] = []
    ) {
        self.serverName = serverName
        self.originalName = originalName
        self.commandName = commandName
        self.title = title
        self.description = description
        self.arguments = arguments
    }
}

// MARK: - Server Provenance

public struct ServerProvenance: Sendable {
    public var source: String
    public var path: String

    public init(source: String, path: String) {
        self.source = source
        self.path = path
    }
}

// MARK: - Name Formatting

public func getServerPrefix(_ serverName: String, mode: String) -> String {
    if mode == "none" { return "" }
    if mode == "short" {
        var short = serverName
            .replacingOccurrences(of: #"-?mcp$"#, with: "", options: [.regularExpression, .caseInsensitive], range: serverName.startIndex..<serverName.endIndex)
            .replacingOccurrences(of: "-", with: "_")
        if short.isEmpty { short = "mcp" }
        return short
    }
    if mode == "mcp" {
        return "mcp__" + serverName.replacingOccurrences(of: "-", with: "_")
    }
    return serverName.replacingOccurrences(of: "-", with: "_")
}

public func formatToolName(_ toolName: String, serverName: String, prefix: String) -> String {
    let p = getServerPrefix(serverName, mode: prefix)
    let normalizedToolName = toolName.replacingOccurrences(of: ".", with: "_")
    return p.isEmpty ? normalizedToolName : "\(p)_\(normalizedToolName)"
}

public func resourceNameToToolName(_ name: String) -> String {
    var sanitized = name
        .replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression)
        .replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        .lowercased()
    if sanitized.isEmpty || sanitized.first?.isNumber == true {
        sanitized = "resource_\(sanitized)"
    }
    return sanitized
}

public func formatPromptCommandName(_ promptName: String, serverName: String, prefix: String) -> String {
    let serverPart = getServerPrefix(serverName, mode: prefix).isEmpty
        ? serverName.replacingOccurrences(of: "-", with: "_")
        : getServerPrefix(serverName, mode: prefix)
    let sanitized = promptName
        .replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "_", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
    let name = sanitized.isEmpty ? "prompt" : (sanitized.first?.isNumber == true ? "_\(sanitized)" : sanitized)
    return "mcp__\(serverPart.isEmpty ? "server" : serverPart)__\(name)"
}

/// Test an original or formatted tool name against the adapter's include and
/// exclude selectors. Exclusions always win.
func isToolAllowed(_ toolName: String, serverName: String, prefix: String, definition: ServerEntry) -> Bool {
    let candidates = Set([
        normalizeToolSelector(toolName),
        normalizeToolSelector(formatToolName(toolName, serverName: serverName, prefix: prefix)),
        normalizeToolSelector(formatToolName(toolName, serverName: serverName, prefix: "server")),
        normalizeToolSelector(formatToolName(toolName, serverName: serverName, prefix: "short")),
        normalizeToolSelector(formatToolName(toolName, serverName: serverName, prefix: "mcp")),
    ])
    if selectorListMatches(definition.excludeTools, candidates: candidates) { return false }
    guard let included = definition.includeTools, !included.isEmpty else { return true }
    return selectorListMatches(included, candidates: candidates)
}

private func normalizeToolSelector(_ value: String) -> String {
    value.replacingOccurrences(of: "-", with: "_")
}

private func selectorListMatches(_ selectors: [String]?, candidates: Set<String>) -> Bool {
    guard let selectors else { return false }
    for selector in selectors {
        let pattern = normalizeToolSelector(selector)
        if !pattern.contains("*") && !pattern.contains("?") {
            if candidates.contains(pattern) { return true }
            continue
        }
        guard let expression = try? NSRegularExpression(pattern: globExpression(pattern)) else { continue }
        if candidates.contains(where: {
            expression.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
        }) {
            return true
        }
    }
    return false
}

private func globExpression(_ pattern: String) -> String {
    let escaped = NSRegularExpression.escapedPattern(for: pattern)
        .replacingOccurrences(of: "\\*", with: ".*")
        .replacingOccurrences(of: "\\?", with: ".")
    return "^\(escaped)$"
}
