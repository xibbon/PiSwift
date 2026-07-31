import Foundation
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

// MARK: - Extension State

final class McpExtensionState: Sendable {
    let manager: McpServerManager
    let lifecycle: McpLifecycleManager
    let toolMetadata: LockedState<[String: [ToolMetadata]]>
    let promptMetadata: LockedState<[String: [PromptMetadata]]>
    let metadataCache: LockedState<MetadataCache>
    let metadataStore: any McpMetadataStore
    let outputStore: any McpOutputStore
    let config: McpConfig
    let failureTracker: LockedState<[String: Date]>
    let prefix: String
    let toolSurfaceChangedHandler: LockedState<(@Sendable () async -> Void)?>

    init(
        manager: McpServerManager,
        lifecycle: McpLifecycleManager,
        config: McpConfig,
        prefix: String,
        metadataCache: MetadataCache?,
        metadataStore: any McpMetadataStore,
        outputStore: any McpOutputStore,
        toolSurfaceChangedHandler: (@Sendable () async -> Void)?
    ) {
        self.manager = manager
        self.lifecycle = lifecycle
        self.toolMetadata = LockedState([:])
        self.promptMetadata = LockedState([:])
        self.metadataCache = LockedState(metadataCache ?? MetadataCache())
        self.metadataStore = metadataStore
        self.outputStore = outputStore
        self.config = config
        self.failureTracker = LockedState([:])
        self.prefix = prefix
        self.toolSurfaceChangedHandler = LockedState(toolSurfaceChangedHandler)
    }
}

// MARK: - Constants

private let failureBackoffSeconds: TimeInterval = 60
private let maxParallelConnections = 10
private let builtinToolNames: Set<String> = ["read", "bash", "edit", "write", "grep", "find", "ls", "mcp", "subagent"]

// MARK: - Direct Tool Spec

struct DirectToolSpec: Sendable {
    var prefixedName: String
    var originalName: String
    var serverName: String
    var description: String
    var inputSchema: AnyCodable?
    var resourceUri: String?
}

// MARK: - Public API

public enum McpAdapter {
    /// Create an opt-in extension for one agent session.
    public static func makeExtension(_ options: McpAdapterOptions) -> McpAdapterExtension {
        McpAdapterExtension(options: options)
    }

    /// Create an inline extension with explicit configuration.
    public static func inlineExtension(
        options: McpAdapterOptions,
        name: String = "mcp-adapter"
    ) -> InlineExtension {
        McpAdapterExtension(options: options).inlineExtension(name: name)
    }
}

/// A programmatic, session-scoped MCP extension. Make one instance for each
/// `CreateAgentSessionOptions` value so its state cannot leak to another agent.
public final class McpAdapterExtension: Sendable {
    private let options: McpAdapterOptions
    public let runtime: McpAdapterRuntime

    public init(options: McpAdapterOptions) {
        self.options = options
        self.runtime = McpAdapterRuntime(options: options)
    }

    /// Add this value to `CreateAgentSessionOptions.inlineExtensions`.
    /// Inline extensions retain registered tools for the lifetime of the session.
    public func inlineExtension(name: String = "mcp-adapter") -> InlineExtension {
        let options = self.options
        let runtime = self.runtime
        return InlineExtension(name: name) { api in
            registerMcpAdapter(api: api, options: options, runtime: runtime)
        }
    }
}

// MARK: - Registration

public func registerMcpAdapter(_ pi: HookAPI, options: McpAdapterOptions) {
    registerMcpAdapter(api: pi, options: options, runtime: McpAdapterRuntime(options: options))
}

private func registerMcpAdapter(
    api pi: HookAPI,
    options: McpAdapterOptions,
    runtime: McpAdapterRuntime
) {

    // Helper: wait for state
    let getState: @Sendable () async -> McpExtensionState? = {
        await runtime.readyState()
    }

    // The configuration is supplied by the host. This avoids ambient config
    // discovery and makes each embedded session deterministic.
    let earlyConfig = options.config
    let earlyCache = options.metadataCache
    let prefix = earlyConfig.settings?.toolPrefix ?? "server"

    // Resolve direct tools from cache
    let directSpecs = resolveDirectTools(config: earlyConfig, cache: earlyCache, prefix: prefix)

    // Register unified mcp proxy tool unless the host chose direct tools only.
    if earlyConfig.settings?.disableProxyTool != true {
        let proxyDescription = buildProxyDescription(config: earlyConfig, cache: earlyCache, directSpecs: directSpecs)
        registerProxyTool(pi, description: proxyDescription, getState: getState)
    }

    // Register direct tools
    for spec in directSpecs {
        registerDirectTool(pi, spec: spec, getState: getState)
    }

    // Commands are available at session creation when the supplied cache has
    // prompt metadata. Live discovery updates the cache for later sessions.
    for metadata in resolveCachedPrompts(config: earlyConfig, cache: earlyCache, prefix: prefix) {
        registerPromptCommand(pi, metadata: metadata, getState: getState)
    }

    // Keep direct tools and prompt commands in sync when a live MCP connection
    // refreshes its metadata. The hook API updates the agent's tool roster after
    // session startup, while the runner reads the current command registrations.
    let registeredDirectToolNames = LockedState(Set(directSpecs.map(\.prefixedName)))
    let registeredPromptNames = LockedState(Set(resolveCachedPrompts(config: earlyConfig, cache: earlyCache, prefix: prefix).map(\.commandName)))
    let syncToolSurface: @Sendable () async -> Void = {
        let cache = await runtime.metadataCache()
        let freshDirectSpecs = resolveDirectTools(config: earlyConfig, cache: cache, prefix: prefix)
        let freshDirectNames = Set(freshDirectSpecs.map(\.prefixedName))
        let removedDirectNames = registeredDirectToolNames.withLock { known -> Set<String> in
            let removed = known.subtracting(freshDirectNames)
            known = freshDirectNames
            return removed
        }
        for name in removedDirectNames {
            _ = pi.unregisterTool(name)
        }
        for spec in freshDirectSpecs {
            registerDirectTool(pi, spec: spec, getState: getState)
        }

        let freshPrompts = resolveCachedPrompts(config: earlyConfig, cache: cache, prefix: prefix)
        let freshPromptNames = Set(freshPrompts.map(\.commandName))
        let removedPromptNames = registeredPromptNames.withLock { known -> Set<String> in
            let removed = known.subtracting(freshPromptNames)
            known = freshPromptNames
            return removed
        }
        for name in removedPromptNames {
            _ = pi.unregisterCommand(name)
        }
        for metadata in freshPrompts {
            registerPromptCommand(pi, metadata: metadata, getState: getState)
        }
    }

    // Headless command surface. Configuration changes remain host-owned, but
    // inspection, reconnect, and injected credential logout work in all hosts.
    pi.registerCommand("mcp", description: "Show or control MCP servers") { args, ctx in
        guard let state = await getState() else {
            await ctx.ui.notify("MCP not initialized", .warning)
            return
        }
        let parts = args.split(whereSeparator: { $0.isWhitespace })
        let command = parts.first.map(String.init) ?? "status"
        let serverName = parts.dropFirst().joined(separator: " ")
        switch command {
        case "", "status":
            await ctx.ui.notify(await buildStatusText(state), .info)
        case "tools":
            await ctx.ui.notify(buildToolsText(state: state, serverName: serverName.isEmpty ? nil : serverName), .info)
        case "prompts":
            await ctx.ui.notify(buildPromptsText(state: state, serverName: serverName.isEmpty ? nil : serverName), .info)
        case "reconnect":
            let names = serverName.isEmpty ? state.config.mcpServers.keys.sorted() : [serverName]
            var results: [String] = []
            for name in names {
                guard state.config.mcpServers[name]?.disabled != true else {
                    results.append("\(name): disabled")
                    continue
                }
                do {
                    let snapshot = try await runtime.reconnect(serverName: name)
                    results.append("\(name): connected (\(snapshot.toolCount) tools)")
                } catch {
                    results.append("\(name): failed (\(error))")
                }
            }
            await ctx.ui.notify(results.isEmpty ? "No MCP servers configured." : results.joined(separator: "\n"), .info)
        case "logout":
            guard !serverName.isEmpty else {
                await ctx.ui.notify("Usage: /mcp logout <server>", .warning)
                return
            }
            do {
                let cleared = try await runtime.logout(serverName: serverName)
                await ctx.ui.notify(
                    cleared ? "Cleared host credentials for \"\(serverName)\"." : "Disconnected \"\(serverName)\". The host did not expose credential removal.",
                    .info
                )
            } catch {
                await ctx.ui.notify("Could not log out \"\(serverName)\": \(error)", .warning)
            }
        default:
            await ctx.ui.notify("Usage: /mcp [status|tools [server]|prompts [server]|reconnect [server]|logout <server>]", .info)
        }
    }

    // MCP tool failures are returned by the protocol rather than thrown. Mark
    // only these two result codes as agent-level errors; configuration and
    // discovery guidance must remain ordinary tool output.
    pi.on("tool_result") { (event: ToolResultEvent, _: HookContext) -> Any? in
        guard shouldMarkMcpToolResultAsError(event.details) else { return nil }
        return ToolResultEventResult(isError: true)
    }

    // session_start: non-blocking init
    pi.on("session_start") { (event: SessionStartEvent, ctx: HookContext) -> Any? in
        Task {
            do {
                await runtime.setToolSurfaceChangedHandler(syncToolSurface)
                try await runtime.start()
                pi.events.emit(mcpStatusEvent, await runtime.status())
            } catch {
                fputs("[mcp] Initialization failed: \(error)\n", stderr)
            }
        }
        return nil
    }

    // session_shutdown: graceful shutdown + cache flush
    pi.on("session_shutdown") { (event: SessionShutdownEvent, ctx: HookContext) -> Any? in
        await runtime.shutdown()
        pi.events.emit(mcpStatusEvent, McpStatusSnapshot(
            servers: [],
            totalTools: 0,
            totalResources: 0,
            connectedCount: 0,
            disabledCount: 0
        ))
        return nil
    }
}

// MARK: - Proxy Tool Registration

private func registerProxyTool(_ pi: HookAPI, description: String, getState: @escaping @Sendable () async -> McpExtensionState?) {
    pi.registerTool(CustomTool(
        name: "mcp",
        label: "MCP",
        description: description,
        parameters: proxyToolParameters()
    ) { _, params, _, _, signal in
        guard let state = await getState() else {
            return AgentToolResult(content: [.text(TextContent(text: "MCP is still initializing."))])
        }
        return try await executeProxyTool(params: params, state: state, signal: signal)
    })
}

// MARK: - Proxy Tool Execution

func executeProxyTool(
    params: [String: AnyCodable],
    state: McpExtensionState,
    signal: CancellationToken? = nil
) async throws -> AgentToolResult {
    try throwIfMcpCancelled(signal)
    let tool = params["tool"]?.value as? String
    let connect = params["connect"]?.value as? String
    let describe = params["describe"]?.value as? String
    let instructions = params["instructions"]?.value as? String
    let search = params["search"]?.value as? String
    let serverFilter = params["server"]?.value as? String

    // Mode resolution: tool > connect > describe > search > server > status
    if let toolName = tool {
        return try await executeToolCall(
            toolName: toolName,
            args: params["args"],
            serverFilter: serverFilter,
            state: state,
            signal: signal
        )
    }

    if let serverName = connect {
        return try await executeConnect(serverName: serverName, state: state)
    }

    if let toolName = describe {
        return executeDescribe(toolName: toolName, serverFilter: serverFilter, state: state)
    }

    if let serverName = instructions {
        return try await executeInstructions(serverName: serverName, state: state)
    }

    if let query = search {
        let useRegex = params["regex"]?.value as? Bool ?? false
        let includeSchemas = params["includeSchemas"]?.value as? Bool ?? true
        return executeSearch(query: query, useRegex: useRegex, includeSchemas: includeSchemas, serverFilter: serverFilter, state: state)
    }

    if let serverName = serverFilter {
        return executeListServer(serverName: serverName, state: state)
    }

    return executeStatus(state: state)
}

// MARK: - Mode Implementations

private func executeToolCall(
    toolName: String,
    args: AnyCodable?,
    serverFilter: String?,
    state: McpExtensionState,
    signal: CancellationToken?
) async throws -> AgentToolResult {
    // Find the tool
    guard let (serverName, metadata) = findToolByName(toolName, serverFilter: serverFilter, state: state) else {
        return AgentToolResult(content: [.text(TextContent(text: "Tool not found: \(toolName). Use mcp({ search: \"...\" }) to find tools."))])
    }

    // Parse arguments
    let arguments: [String: AnyCodable]
    do {
        arguments = try decodeProxyArguments(args)
    } catch {
        return AgentToolResult(content: [.text(TextContent(text: "Invalid args: \(error)"))])
    }

    // Check failure backoff
    let isBackoff = state.failureTracker.withLock { tracker in
        if let failedAt = tracker[serverName] {
            return Date().timeIntervalSince(failedAt) < failureBackoffSeconds
        }
        return false
    }
    if isBackoff {
        return AgentToolResult(content: [.text(TextContent(text: "Server \"\(serverName)\" recently failed. Retry in \(Int(failureBackoffSeconds))s or use mcp({ connect: \"\(serverName)\" }) to reconnect."))])
    }

    // Lazy connect
    let definition = state.config.mcpServers[serverName]
    guard let definition else {
        return AgentToolResult(content: [.text(TextContent(text: "Server \"\(serverName)\" not found in config"))])
    }
    guard definition.disabled != true else {
        return AgentToolResult(content: [.text(TextContent(text: "Server \"\(serverName)\" is disabled."))])
    }

    do {
        try throwIfMcpCancelled(signal)
        await state.manager.incrementInFlight(name: serverName)
        defer { Task { await state.manager.decrementInFlight(name: serverName) } }

        let isConnected = await state.manager.isConnected(name: serverName)
        if !isConnected {
            try throwIfMcpCancelled(signal)
            _ = try await state.manager.connect(name: serverName, definition: definition)
            if definition.lifecycle == "lazy-keep-alive" {
                await state.lifecycle.markKeepAlive(name: serverName, definition: definition)
            }
            // Update metadata
            if let conn = await state.manager.getConnection(name: serverName) {
                updateToolMetadata(state: state, serverName: serverName, connection: conn, definition: definition)
            }
        }

        await state.manager.touch(name: serverName)

        // Handle resource tools
        if let resourceUri = metadata.resourceUri {
            let contents = try await state.manager.withSessionRecovery(name: serverName) { client in
                try await client.readResource(uri: resourceUri, signal: signal)
            }
            let mcpContent = contents.map { c -> McpContent in
                McpContent(type: "resource", resource: c, uri: c.uri)
            }
            let guarded = await guardMcpOutput(
                transformMcpContent(mcpContent),
                serverName: serverName,
                settings: state.config.settings,
                outputStore: state.outputStore
            )
            return AgentToolResult(content: guarded.content, details: guarded.detailsValue)
        }

        // Call tool
        let result = try await state.manager.withSessionRecovery(name: serverName) { client in
            try await client.callTool(name: metadata.originalName, arguments: arguments, signal: signal)
        }
        let guarded = await guardMcpOutput(
            result.isError ? transformMcpContent(result.content) : resolveMcpResultContent(result),
            serverName: serverName,
            settings: state.config.settings,
            outputStore: state.outputStore,
            rawMcpResult: result.rawResult
        )

        if result.isError {
            return AgentToolResult(
                content: guarded.content,
                details: mcpErrorDetails(guarded.detailsValue, code: "tool_error")
            )
        }

        // Clear failure tracker on success
        state.failureTracker.withLock { $0.removeValue(forKey: serverName) }

        return AgentToolResult(content: guarded.content, details: guarded.detailsValue)

    } catch is CancellationError {
        throw CancellationError()
    } catch {
        state.failureTracker.withLock { $0[serverName] = Date() }
        return AgentToolResult(
            content: [.text(TextContent(text: "Error calling \(toolName): \(mcpFailureMessage(error, serverName: serverName, definition: definition, settings: state.config.settings))"))],
            details: mcpErrorDetails(nil, code: "call_failed")
        )
    }
}

private func executeConnect(serverName: String, state: McpExtensionState) async throws -> AgentToolResult {
    guard let definition = state.config.mcpServers[serverName] else {
        let available = state.config.mcpServers.keys.sorted().joined(separator: ", ")
        return AgentToolResult(content: [.text(TextContent(text: "Server \"\(serverName)\" not found. Available: \(available)"))])
    }
    guard definition.disabled != true else {
        return AgentToolResult(content: [.text(TextContent(text: "Server \"\(serverName)\" is disabled."))])
    }

    do {
        let conn = try await state.manager.connect(name: serverName, definition: definition)
        if definition.lifecycle == "lazy-keep-alive" {
            await state.lifecycle.markKeepAlive(name: serverName, definition: definition)
        }
        updateToolMetadata(state: state, serverName: serverName, connection: conn, definition: definition)

        // Clear failure tracker
        state.failureTracker.withLock { $0.removeValue(forKey: serverName) }

        let toolCount = conn.tools.count
        let resourceCount = conn.resources.count
        var msg = "Connected to \"\(serverName)\": \(toolCount) tool(s)"
        if resourceCount > 0 { msg += ", \(resourceCount) resource(s)" }
        return AgentToolResult(content: [.text(TextContent(text: msg))])
    } catch {
        state.failureTracker.withLock { $0[serverName] = Date() }
        return AgentToolResult(content: [.text(TextContent(text: "Failed to connect to \"\(serverName)\": \(mcpFailureMessage(error, serverName: serverName, definition: definition, settings: state.config.settings))"))])
    }
}

private func executeDescribe(toolName: String, serverFilter: String?, state: McpExtensionState) -> AgentToolResult {
    guard let (serverName, metadata) = findToolByName(toolName, serverFilter: serverFilter, state: state) else {
        return AgentToolResult(content: [.text(TextContent(text: "Tool not found: \(toolName)"))])
    }

    var lines: [String] = []
    lines.append("Tool: \(metadata.name)")
    lines.append("Server: \(serverName)")
    lines.append("Original name: \(metadata.originalName)")
    lines.append("Description: \(metadata.description)")

    if let schema = metadata.inputSchema {
        if let data = try? JSONSerialization.data(withJSONObject: schema.value, options: .prettyPrinted),
           let json = String(data: data, encoding: .utf8) {
            lines.append("Parameters:")
            lines.append(json)
        }
    }

    return AgentToolResult(content: [.text(TextContent(text: lines.joined(separator: "\n")))])
}

private func executeInstructions(serverName: String, state: McpExtensionState) async throws -> AgentToolResult {
    guard state.config.mcpServers[serverName] != nil else {
        return AgentToolResult(content: [.text(TextContent(text: "Server \"\(serverName)\" not found."))])
    }
    guard let instructions = await state.manager.getConnection(name: serverName)?.instructions else {
        return AgentToolResult(content: [.text(TextContent(text: "Server \"\(serverName)\" has no cached instructions. Use mcp({ connect: \"\(serverName)\" }) first."))])
    }
    return AgentToolResult(content: [.text(TextContent(text: instructions))])
}

private func executeSearch(query: String, useRegex: Bool, includeSchemas: Bool, serverFilter: String?, state: McpExtensionState) -> AgentToolResult {
    let allMetadata = state.toolMetadata.withLock { $0 }
    var results: [(server: String, tool: ToolMetadata)] = []

    let words = query.lowercased().components(separatedBy: .whitespaces).filter { !$0.isEmpty }

    for (server, tools) in allMetadata {
        if let filter = serverFilter, server != filter { continue }
        for tool in tools {
            let matched: Bool
            if useRegex {
                let regex = try? NSRegularExpression(pattern: query, options: .caseInsensitive)
                let nameRange = NSRange(tool.name.startIndex..., in: tool.name)
                let descRange = NSRange(tool.description.startIndex..., in: tool.description)
                matched = regex?.firstMatch(in: tool.name, range: nameRange) != nil
                    || regex?.firstMatch(in: tool.description, range: descRange) != nil
            } else {
                let searchName = tool.name.lowercased()
                let searchDesc = tool.description.lowercased()
                matched = words.contains { searchName.contains($0) || searchDesc.contains($0) }
            }
            if matched {
                results.append((server, tool))
            }
        }
    }

    if results.isEmpty {
        return AgentToolResult(content: [.text(TextContent(text: "No tools found matching \"\(query)\""))])
    }

    var lines: [String] = ["Found \(results.count) tool(s):"]
    for (server, tool) in results {
        lines.append("")
        lines.append("  \(tool.name) (server: \(server))")
        lines.append("    \(tool.description)")
        if includeSchemas, let schema = tool.inputSchema,
           let data = try? JSONSerialization.data(withJSONObject: schema.value, options: .prettyPrinted),
           let json = String(data: data, encoding: .utf8) {
            lines.append("    Parameters: \(json)")
        }
    }

    return AgentToolResult(content: [.text(TextContent(text: lines.joined(separator: "\n")))])
}

private func executeListServer(serverName: String, state: McpExtensionState) -> AgentToolResult {
    let tools = state.toolMetadata.withLock { $0[serverName] } ?? []
    if tools.isEmpty {
        return AgentToolResult(content: [.text(TextContent(text: "No tools cached for server \"\(serverName)\". Use mcp({ connect: \"\(serverName)\" }) first."))])
    }

    var lines: [String] = ["Server \"\(serverName)\" tools (\(tools.count)):"]
    for tool in tools {
        lines.append("  \(tool.name): \(tool.description)")
    }
    return AgentToolResult(content: [.text(TextContent(text: lines.joined(separator: "\n")))])
}

private func executeStatus(state: McpExtensionState) -> AgentToolResult {
    var lines: [String] = ["MCP Status:"]
    let metadata = state.toolMetadata.withLock { $0 }

    for (name, _) in state.config.mcpServers.sorted(by: { $0.key < $1.key }) {
        let tools = metadata[name] ?? []
        let lifecycle = state.config.mcpServers[name]?.lifecycle ?? "lazy"
        lines.append("  \(name): \(tools.count) tool(s), lifecycle: \(lifecycle)")
    }

    let totalTools = metadata.values.reduce(0) { $0 + $1.count }
    lines.append("")
    lines.append("Total: \(state.config.mcpServers.count) server(s), \(totalTools) tool(s)")
    return AgentToolResult(content: [.text(TextContent(text: lines.joined(separator: "\n")))])
}

// MARK: - Direct Tool Registration

private func registerDirectTool(_ pi: HookAPI, spec: DirectToolSpec, getState: @escaping @Sendable () async -> McpExtensionState?) {
    let schema = spec.inputSchema ?? AnyCodable([
        "type": "object",
        "properties": [String: Any](),
    ] as [String: Any])

    pi.registerTool(CustomTool(
        name: spec.prefixedName,
        label: "MCP: \(spec.originalName)",
        description: spec.description,
        parameters: schemaToParameters(schema)
    ) { _, params, _, _, signal in
        guard let state = await getState() else {
            return AgentToolResult(content: [.text(TextContent(text: "MCP is still initializing."))])
        }
        return try await executeDirectTool(spec: spec, params: params, state: state, signal: signal)
    })
}

// MARK: - Tool Building

func buildMcpProxyTool(getState: @escaping @Sendable () async -> McpExtensionState?, description: String) -> AgentTool {
    AgentTool(
        label: "MCP",
        name: "mcp",
        description: description,
        parameters: proxyToolParameters()
    ) { _, params, signal, _ in
        guard let state = await getState() else {
            return AgentToolResult(content: [.text(TextContent(text: "MCP not initialized. Servers may still be connecting."))])
        }
        return try await executeProxyTool(params: params, state: state, signal: signal)
    }
}

private func proxyToolParameters() -> [String: AnyCodable] {
    [
        "type": AnyCodable("object"),
        "properties": AnyCodable([
            "tool": ["type": "string", "description": "Tool name to call"] as [String: Any],
            "args": ["type": "string", "description": "Arguments as a JSON object string"] as [String: Any],
            "connect": ["type": "string", "description": "Server name to connect"] as [String: Any],
            "describe": ["type": "string", "description": "Tool name to describe"] as [String: Any],
            "instructions": ["type": "string", "description": "Server name for server usage instructions"] as [String: Any],
            "search": ["type": "string", "description": "Search tools by name or description"] as [String: Any],
            "regex": ["type": "boolean", "description": "Treat search as a regular expression"] as [String: Any],
            "includeSchemas": ["type": "boolean", "description": "Include parameter schemas in search results"] as [String: Any],
            "server": ["type": "string", "description": "Filter to one server"] as [String: Any],
        ] as [String: Any]),
    ]
}

/// Accept the two upstream proxy forms: a JSON object or a JSON object encoded
/// as a string. Arrays, scalars, and null are rejected before an MCP request
/// is sent.
func decodeProxyArguments(_ args: AnyCodable?) throws -> [String: AnyCodable] {
    guard let args else { return [:] }
    if let text = args.value as? String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw McpError.protocolError("expected a JSON object")
        }
        return dictionary.mapValues(AnyCodable.init)
    }
    if let dictionary = args.value as? [String: Any] {
        return dictionary.mapValues(AnyCodable.init)
    }
    throw McpError.protocolError("expected a JSON object or JSON object string")
}

func buildDirectTools(getState: @escaping @Sendable () async -> McpExtensionState?, config: McpConfig, cache: MetadataCache?, prefix: String) -> [AgentTool] {
    let specs = resolveDirectTools(config: config, cache: cache, prefix: prefix)
    return specs.map { spec in
        let schema = spec.inputSchema ?? AnyCodable(["type": "object", "properties": [:] as [String: Any]] as [String: Any])
        return AgentTool(
            label: "MCP: \(spec.originalName)",
            name: spec.prefixedName,
            description: spec.description,
            parameters: schemaToParameters(schema)
        ) { _, params, signal, _ in
            guard let state = await getState() else {
                return AgentToolResult(content: [.text(TextContent(text: "MCP not initialized"))])
            }
            return try await executeDirectTool(spec: spec, params: params, state: state, signal: signal)
        }
    }
}

private func executeDirectTool(
    spec: DirectToolSpec,
    params: [String: AnyCodable],
    state: McpExtensionState,
    signal: CancellationToken? = nil
) async throws -> AgentToolResult {
    guard let definition = state.config.mcpServers[spec.serverName] else {
        return AgentToolResult(content: [.text(TextContent(text: "Server \"\(spec.serverName)\" is not configured."))])
    }
    guard definition.disabled != true else {
        return AgentToolResult(content: [.text(TextContent(text: "Server \"\(spec.serverName)\" is disabled."))])
    }

    do {
        try throwIfMcpCancelled(signal)
        await state.manager.incrementInFlight(name: spec.serverName)
        defer { Task { await state.manager.decrementInFlight(name: spec.serverName) } }

        if !(await state.manager.isConnected(name: spec.serverName)) {
            try throwIfMcpCancelled(signal)
            _ = try await state.manager.connect(name: spec.serverName, definition: definition)
            if definition.lifecycle == "lazy-keep-alive" {
                await state.lifecycle.markKeepAlive(name: spec.serverName, definition: definition)
            }
        }
        await state.manager.touch(name: spec.serverName)

        if let resourceUri = spec.resourceUri {
            let contents = try await state.manager.withSessionRecovery(name: spec.serverName) { client in
                try await client.readResource(uri: resourceUri, signal: signal)
            }
            let guarded = await guardMcpOutput(transformMcpContent(contents.map {
                McpContent(type: "resource", resource: $0, uri: $0.uri)
            }), serverName: spec.serverName, settings: state.config.settings, outputStore: state.outputStore)
            return AgentToolResult(content: guarded.content, details: guarded.detailsValue)
        }

        let result = try await state.manager.withSessionRecovery(name: spec.serverName) { client in
            try await client.callTool(name: spec.originalName, arguments: params, signal: signal)
        }
        let guarded = await guardMcpOutput(
            result.isError ? transformMcpContent(result.content) : resolveMcpResultContent(result),
            serverName: spec.serverName,
            settings: state.config.settings,
            outputStore: state.outputStore,
            rawMcpResult: result.rawResult
        )
        if result.isError {
            return AgentToolResult(
                content: guarded.content,
                details: mcpErrorDetails(guarded.detailsValue, code: "tool_error")
            )
        }
        return AgentToolResult(content: guarded.content, details: guarded.detailsValue)
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        return AgentToolResult(
            content: [.text(TextContent(text: "MCP tool \"\(spec.prefixedName)\" failed: \(mcpFailureMessage(error, serverName: spec.serverName, definition: definition, settings: state.config.settings))"))],
            details: mcpErrorDetails(nil, code: "call_failed")
        )
    }
}

private func throwIfMcpCancelled(_ signal: CancellationToken?) throws {
    if signal?.isCancelled == true {
        throw CancellationError()
    }
}

private func mcpFailureMessage(
    _ error: any Error,
    serverName: String,
    definition: ServerEntry,
    settings: McpSettings?
) -> String {
    guard definition.auth == .oauth,
          let mcpError = error as? McpError,
          case .connectionFailed(let message) = mcpError,
          message.contains("authorization provider") else {
        return String(describing: error)
    }
    let fallback = "MCP server \"\(serverName)\" requires OAuth authorization from the host."
    return (settings?.authRequiredMessage ?? fallback)
        .replacingOccurrences(of: "${server}", with: serverName)
}

func shouldMarkMcpToolResultAsError(_ details: AnyCodable?) -> Bool {
    guard let values = details?.value as? [String: Any],
          let code = values["error"] as? String else {
        return false
    }
    return code == "tool_error" || code == "call_failed"
}

private func mcpErrorDetails(_ details: AnyCodable?, code: String) -> AnyCodable {
    var values = details?.value as? [String: Any] ?? [:]
    values["error"] = code
    return AnyCodable(values)
}

// MARK: - Initialization

func initializeMcp(
    config: McpConfig,
    metadataCache: MetadataCache?,
    metadataStore: any McpMetadataStore,
    authorizationProvider: (any McpAuthorizationProvider)?,
    serverRequestHandler: McpServerRequestHandler?,
    outputStore: any McpOutputStore,
    traceSink: (any McpTraceSink)?,
    toolSurfaceChangedHandler: (@Sendable () async -> Void)?
) async throws -> McpExtensionState {
    let prefix = config.settings?.toolPrefix ?? "server"

    let manager = McpServerManager(
        authorizationProvider: authorizationProvider,
        serverRequestHandler: serverRequestHandler,
        defaultRequestTimeoutMs: config.settings?.requestTimeoutMs,
        clientCapabilities: McpClientCapabilities(
            sampling: config.settings?.sampling == true && serverRequestHandler != nil,
            elicitation: config.settings?.elicitation == true && serverRequestHandler != nil
        ),
        traceSettings: config.settings?.trace,
        traceSink: traceSink
    )
    let lifecycle = McpLifecycleManager()
    await lifecycle.setManager(manager)

    let state = McpExtensionState(
        manager: manager,
        lifecycle: lifecycle,
        config: config,
        prefix: prefix,
        metadataCache: metadataCache,
        metadataStore: metadataStore,
        outputStore: outputStore,
        toolSurfaceChangedHandler: toolSurfaceChangedHandler
    )

    await manager.setMetadataChangedHandler { serverName, connection in
        guard let definition = config.mcpServers[serverName] else { return }
        updateToolMetadata(state: state, serverName: serverName, connection: connection, definition: definition)
    }

    // Set global idle timeout
    let globalIdleMinutes = config.settings?.idleTimeout ?? 10
    await lifecycle.setGlobalIdleTimeout(minutes: globalIdleMinutes)

    // Load or bootstrap metadata cache
    let existingCache = metadataCache

    // Register servers with lifecycle
    for (name, definition) in config.mcpServers {
        guard definition.disabled != true else { continue }
        let idleTimeout = getEffectiveIdleTimeoutMinutes(name: name, definition: definition, config: config)
        await lifecycle.registerServer(name: name, definition: definition, idleTimeout: idleTimeout)

        // Reconstruct metadata from cache
        if let cache = existingCache, let entry = cache.servers[name], isServerCacheValid(entry, definition) {
            let tools = reconstructToolMetadata(
                serverName: name,
                entry: entry,
                prefix: prefix,
                exposeResources: definition.exposeResources,
                definition: definition
            )
            state.toolMetadata.withLock { $0[name] = tools }
            state.promptMetadata.withLock { $0[name] = reconstructPromptMetadata(serverName: name, entry: entry, prefix: prefix) }
        }
    }

    // Determine startup servers
    var startupServers: [String] = []
    for (name, definition) in config.mcpServers {
        let lifecycle = definition.lifecycle ?? "lazy"
        if lifecycle == "eager" || lifecycle == "keep-alive" {
            startupServers.append(name)
        }
    }

    // Connect startup servers in parallel (max 10 concurrent)
    await withTaskGroup(of: Void.self) { group in
        var inFlight = 0
        for name in startupServers {
            if inFlight >= maxParallelConnections {
                await group.next()
                inFlight -= 1
            }
            group.addTask {
                guard let definition = config.mcpServers[name] else { return }
                do {
                    let conn = try await manager.connect(name: name, definition: definition)
                    updateToolMetadata(state: state, serverName: name, connection: conn, definition: definition)
                } catch {
                    fputs("[mcp] Failed to connect to \"\(name)\": \(error)\n", stderr)
                }
            }
            inFlight += 1
        }
    }

    // Set lifecycle callbacks
    await lifecycle.setCallbacks(
        onReconnect: { name in
            guard let definition = config.mcpServers[name] else { return }
            if let conn = await manager.getConnection(name: name) {
                updateToolMetadata(state: state, serverName: name, connection: conn, definition: definition)
            }
        },
        onIdleShutdown: { name in
            fputs("[mcp] Idle shutdown: \(name)\n", stderr)
        }
    )

    await lifecycle.startHealthChecks()

    return state
}

// MARK: - Helpers

private func findToolByName(_ name: String, serverFilter: String?, state: McpExtensionState) -> (server: String, metadata: ToolMetadata)? {
    let allMetadata = state.toolMetadata.withLock { $0 }
    let normalized = name.replacingOccurrences(of: "-", with: "_")

    var candidates: [(String, ToolMetadata)] = []

    for (server, tools) in allMetadata {
        if let filter = serverFilter, server != filter { continue }
        for tool in tools {
            if tool.name == name || tool.originalName == name {
                candidates.append((server, tool))
            } else {
                let toolNormalized = tool.name.replacingOccurrences(of: "-", with: "_")
                let origNormalized = tool.originalName.replacingOccurrences(of: "-", with: "_")
                if toolNormalized == normalized || origNormalized == normalized {
                    candidates.append((server, tool))
                }
            }
        }
    }

    if candidates.count == 1 { return candidates[0] }
    if candidates.isEmpty { return nil }

    // Prefer exact match
    if let exact = candidates.first(where: { $0.1.name == name || $0.1.originalName == name }) {
        return exact
    }
    return candidates.first
}

func updateToolMetadata(state: McpExtensionState, serverName: String, connection: ServerConnection, definition: ServerEntry) {
    let prefix = state.prefix
    var tools: [ToolMetadata] = []
    var seenNames: Set<String> = []

    for tool in connection.tools {
        guard isToolAllowed(tool.name, serverName: serverName, prefix: prefix, definition: definition) else { continue }
        let prefixed = formatToolName(tool.name, serverName: serverName, prefix: prefix)
        guard seenNames.insert(prefixed).inserted else { continue }
        tools.append(ToolMetadata(
            name: prefixed,
            originalName: tool.name,
            description: tool.description ?? "(no description)",
            inputSchema: tool.inputSchema
        ))
    }

    if definition.exposeResources != false {
        for resource in connection.resources {
            let toolName = "read_\(resourceNameToToolName(resource.name))"
            guard isToolAllowed(toolName, serverName: serverName, prefix: prefix, definition: definition) else { continue }
            let prefixed = formatToolName(toolName, serverName: serverName, prefix: prefix)
            guard seenNames.insert(prefixed).inserted else { continue }
            tools.append(ToolMetadata(
                name: prefixed,
                originalName: toolName,
                description: resource.description ?? "Read resource: \(resource.uri)",
                resourceUri: resource.uri
            ))
        }
    }

    let preservedPrompts: [CachedPrompt] = state.metadataCache.withLock { cache in
        guard connection.promptDiscoveryFailed,
              let existing = cache.servers[serverName],
              isServerCacheValid(existing, definition) else {
            return []
        }
        return existing.prompts
    }
    let effectivePrompts: [McpPrompt]
    if connection.promptDiscoveryFailed {
        effectivePrompts = preservedPrompts.map {
            McpPrompt(name: $0.name, title: $0.title, description: $0.description, arguments: $0.arguments)
        }
    } else {
        effectivePrompts = connection.prompts
    }

    state.toolMetadata.withLock { $0[serverName] = tools }
    state.promptMetadata.withLock {
        $0[serverName] = effectivePrompts.map { prompt in
            PromptMetadata(
                serverName: serverName,
                originalName: prompt.name,
                commandName: formatPromptCommandName(prompt.name, serverName: serverName, prefix: prefix),
                title: prompt.title,
                description: prompt.description ?? prompt.title ?? "MCP prompt from \(serverName)",
                arguments: prompt.arguments ?? []
            )
        }
    }

    // Update metadata cache
    var entry = buildCacheEntry(from: connection, definition: definition)
    if connection.promptDiscoveryFailed {
        entry.prompts = preservedPrompts
    }
    let cache = state.metadataCache.withLock { cache in
        cache.servers[serverName] = entry
        return cache
    }
    Task { await state.metadataStore.save(cache) }
    if let notify = state.toolSurfaceChangedHandler.withLock({ $0 }) {
        Task { await notify() }
    }
}

func resolveCachedPrompts(config: McpConfig, cache: MetadataCache?, prefix: String) -> [PromptMetadata] {
    guard let cache else { return [] }
    return cache.servers.compactMap { serverName, entry -> [PromptMetadata]? in
        guard let definition = config.mcpServers[serverName],
              definition.disabled != true,
              isServerCacheValid(entry, definition) else {
            return nil
        }
        return reconstructPromptMetadata(serverName: serverName, entry: entry, prefix: prefix)
    }.flatMap { $0 }
}

func flushMetadataCache(_ state: McpExtensionState) async {
    await state.metadataStore.save(state.metadataCache.withLock { $0 })
}

func resolveDirectTools(config: McpConfig, cache: MetadataCache?, prefix: String) -> [DirectToolSpec] {
    var specs: [DirectToolSpec] = []
    var usedNames: Set<String> = Set(builtinToolNames)

    for (serverName, definition) in config.mcpServers {
        guard definition.disabled != true else { continue }
        let shouldExpose: Bool
        var specificTools: [String]? = nil

        switch definition.directTools {
        case .enabled(true):
            shouldExpose = true
        case .tools(let names):
            shouldExpose = true
            specificTools = names
        case .enabled(false):
            shouldExpose = false
        case nil:
            shouldExpose = config.settings?.directTools ?? false
        }

        guard shouldExpose else { continue }
        guard let cache, let entry = cache.servers[serverName], isServerCacheValid(entry, definition) else { continue }

        let tools = entry.tools.filter { tool in
            guard isToolAllowed(tool.name, serverName: serverName, prefix: prefix, definition: definition) else { return false }
            if let specific = specificTools {
                return specific.contains(tool.name)
            }
            return true
        }

        for tool in tools {
            let prefixedName = formatToolName(tool.name, serverName: serverName, prefix: prefix)
            guard !usedNames.contains(prefixedName) else { continue }
            usedNames.insert(prefixedName)

            specs.append(DirectToolSpec(
                prefixedName: prefixedName,
                originalName: tool.name,
                serverName: serverName,
                description: tool.description ?? "(no description)",
                inputSchema: tool.inputSchema
            ))
        }

        if definition.exposeResources != false {
            for resource in entry.resources {
                let toolName = "read_\(resourceNameToToolName(resource.name))"
                guard isToolAllowed(toolName, serverName: serverName, prefix: prefix, definition: definition) else { continue }
                let prefixedName = formatToolName(toolName, serverName: serverName, prefix: prefix)
                guard !usedNames.contains(prefixedName) else { continue }
                usedNames.insert(prefixedName)

                specs.append(DirectToolSpec(
                    prefixedName: prefixedName,
                    originalName: toolName,
                    serverName: serverName,
                    description: resource.description ?? "Read resource: \(resource.uri)",
                    resourceUri: resource.uri
                ))
            }
        }
    }

    return specs
}

private func buildProxyDescription(config: McpConfig, cache: MetadataCache?, directSpecs: [DirectToolSpec]) -> String {
    var parts: [String] = []
    parts.append("MCP tool proxy. Connects to MCP servers and calls their tools.")
    parts.append("")

    // Direct tools summary
    if !directSpecs.isEmpty {
        let byServer = Dictionary(grouping: directSpecs, by: { $0.serverName })
        for (server, tools) in byServer.sorted(by: { $0.key < $1.key }) {
            parts.append("Direct tools from \(server): \(tools.map { $0.prefixedName }.joined(separator: ", "))")
        }
        parts.append("")
    }

    // Proxy-accessible servers
    var proxyServers: [String] = []
    for (name, _) in config.mcpServers.sorted(by: { $0.key < $1.key }) {
        let toolCount = cache?.servers[name]?.tools.count ?? 0
        if toolCount > 0 {
            proxyServers.append("\(name) (\(toolCount) tools)")
        } else {
            proxyServers.append("\(name) (not cached)")
        }
    }
    if !proxyServers.isEmpty {
        parts.append("Servers: \(proxyServers.joined(separator: ", "))")
        parts.append("")
    }

    parts.append("Usage:")
    parts.append("  Search: mcp({ search: \"query\" })")
    parts.append("  Call: mcp({ tool: \"name\", args: \"{...}\" })")
    parts.append("  Connect: mcp({ connect: \"server\" })")
    parts.append("  Describe: mcp({ describe: \"name\" })")
    parts.append("  Status: mcp({})")

    return parts.joined(separator: "\n")
}

private func schemaToParameters(_ schema: AnyCodable) -> [String: AnyCodable] {
    if let dict = schema.value as? [String: Any] {
        return dict.mapValues { AnyCodable($0) }
    }
    return ["type": AnyCodable("object"), "properties": AnyCodable([:] as [String: Any])]
}

private func getEffectiveIdleTimeoutMinutes(name: String, definition: ServerEntry, config: McpConfig) -> Int? {
    if let perServer = definition.idleTimeout { return perServer }
    if definition.lifecycle == "eager" { return 0 }
    return config.settings?.idleTimeout
}

private func buildStatusText(_ state: McpExtensionState) async -> String {
    let result = executeStatus(state: state)
    if case .text(let content) = result.content.first {
        return content.text
    }
    return "MCP status unavailable"
}

private func buildToolsText(state: McpExtensionState, serverName: String?) -> String {
    let metadata = state.toolMetadata.withLock { $0 }
    let selected = serverName.map { [$0] } ?? metadata.keys.sorted()
    var lines: [String] = []
    for name in selected {
        guard let tools = metadata[name] else {
            lines.append("\(name): no cached tools")
            continue
        }
        lines.append("\(name) (\(tools.count) tools):")
        lines.append(contentsOf: tools.map { "  \($0.name): \($0.description)" })
    }
    return lines.isEmpty ? "No MCP tools are cached." : lines.joined(separator: "\n")
}

private func buildPromptsText(state: McpExtensionState, serverName: String?) -> String {
    let metadata = state.promptMetadata.withLock { $0 }
    let selected = serverName.map { [$0] } ?? metadata.keys.sorted()
    var lines: [String] = []
    for name in selected {
        guard let prompts = metadata[name] else {
            lines.append("\(name): no cached prompts")
            continue
        }
        lines.append("\(name) (\(prompts.count) prompts):")
        lines.append(contentsOf: prompts.map { "  /\($0.commandName): \($0.description)" })
    }
    return lines.isEmpty ? "No MCP prompts are cached." : lines.joined(separator: "\n")
}

// MARK: - Lifecycle Manager callback setter

extension McpLifecycleManager {
    func setCallbacks(
        onReconnect: @escaping @Sendable (String) async -> Void,
        onIdleShutdown: @escaping @Sendable (String) async -> Void
    ) {
        self.onReconnect = onReconnect
        self.onIdleShutdown = onIdleShutdown
    }
}
