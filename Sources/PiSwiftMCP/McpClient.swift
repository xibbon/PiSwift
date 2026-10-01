import Foundation
import PiSwiftAI

// MARK: - MCP Protocol Client

/// Handles server-initiated MCP requests. Hosts can implement sampling,
/// elicitation, roots, and other interactive methods without a terminal UI.
public typealias McpServerRequestHandler = @Sendable (
    _ method: String,
    _ parameters: AnyCodable?
) async throws -> AnyCodable?

public typealias McpServerNotificationHandler = @Sendable (
    _ method: String,
    _ parameters: AnyCodable?
) async -> Void

public struct McpClientCapabilities: Sendable {
    public var sampling: Bool
    public var elicitation: Bool
    public var roots: Bool

    public init(sampling: Bool = false, elicitation: Bool = false, roots: Bool = false) {
        self.sampling = sampling
        self.elicitation = elicitation
        self.roots = roots
    }

    var value: [String: Any] {
        var capabilities: [String: Any] = [:]
        if sampling { capabilities["sampling"] = [String: Any]() }
        if elicitation { capabilities["elicitation"] = ["form": [String: Any]()] }
        if roots { capabilities["roots"] = [String: Any]() }
        return capabilities
    }
}

public typealias McpProgressHandler = @Sendable (McpProgressNotification) async -> Void
public typealias McpRootsProvider = @Sendable () async -> [McpRoot]

private struct PendingRequest: Sendable {
    let continuation: CheckedContinuation<AnyCodable?, any Error>
    let method: String
    let timeoutMs: Int?
    let legacyTimeout: Bool
    let onProgress: McpProgressHandler?
    var timer: Task<Void, Never>?
    var signalWatcher: Task<Void, Never>?
}

public actor McpClient {
    public nonisolated let connectionID: UUID
    private var transport: (any McpTransport)?
    private var nextId: Int = 1
    private var pendingRequests: [JsonRpcId: PendingRequest] = [:]
    private var receiveTask: Task<Void, Never>?
    private var serverCapabilities: AnyCodable?
    private var serverInfo: AnyCodable?
    private var instructions: String?
    private var outputSchemas: [String: AnyCodable] = [:]
    private var cancelledRequestIDs: Set<JsonRpcId> = []
    private var negotiatedVersion: String?
    private var isClosed = false
    private var roots: [McpRoot]?
    private let rootsProvider: McpRootsProvider?
    private let requestedProtocolVersion: McpProtocolVersion
    private var incomingTasks: [JsonRpcId: Task<Void, Never>] = [:]
    private let clientInfo: McpImplementation
    private let requestTimeoutMs: Int?
    private let serverRequestHandler: McpServerRequestHandler?
    private let serverNotificationHandler: McpServerNotificationHandler?
    private let connectionClosedHandler: (@Sendable () async -> Void)?
    private let capabilities: McpClientCapabilities

    public init(
        connectionID: UUID = UUID(),
        requestTimeoutMs: Int? = nil,
        serverRequestHandler: McpServerRequestHandler? = nil,
        serverNotificationHandler: McpServerNotificationHandler? = nil,
        connectionClosedHandler: (@Sendable () async -> Void)? = nil,
        capabilities: McpClientCapabilities = McpClientCapabilities(),
        roots: [McpRoot]? = nil,
        clientInfo: McpImplementation = McpImplementation(name: "pi", version: "1.0.0"),
        protocolVersion: McpProtocolVersion = .v2025_11_25,
        rootsProvider: McpRootsProvider? = nil
    ) {
        self.connectionID = connectionID
        self.requestTimeoutMs = requestTimeoutMs.flatMap { $0 > 0 ? $0 : nil }
        self.serverRequestHandler = serverRequestHandler
        self.serverNotificationHandler = serverNotificationHandler
        self.connectionClosedHandler = connectionClosedHandler
        self.capabilities = capabilities
        self.roots = roots
        self.clientInfo = clientInfo
        self.requestedProtocolVersion = protocolVersion
        self.rootsProvider = rootsProvider
    }

    // MARK: - Connection

    public func connect(transport: any McpTransport) async throws {
        guard self.transport == nil, !isClosed else {
            throw McpError.connectionFailed("MCP client is already connected or closed")
        }
        self.transport = transport

        do {
            try await transport.start()

            receiveTask = Task { [weak self] in
                await self?.receiveLoop()
            }

            var advertised = capabilities.value
            if roots != nil || rootsProvider != nil { advertised["roots"] = advertised["roots"] ?? [String: Any]() }
            let initResult = try await sendRequest("initialize", params: AnyCodable([
                "protocolVersion": requestedProtocolVersion.rawValue,
                "capabilities": advertised,
                "clientInfo": ["name": clientInfo.name, "version": clientInfo.version],
            ] as [String: Any]))

            guard let resultDict = initResult?.value as? [String: Any] else {
                throw McpError.initializationFailed("Invalid MCP initialize result")
            }
            // Legacy PiMCPAdapter fixtures omit these fields. Explicit unsupported
            // versions are still rejected. Upstream requires all fields.
            let selectedVersion = resultDict["protocolVersion"] as? String ?? "2024-11-05"
            guard SUPPORTED_PROTOCOL_VERSIONS.contains(selectedVersion) else {
                throw McpError.initializationFailed("MCP server selected unsupported protocol version \(selectedVersion)")
            }
            negotiatedVersion = selectedVersion
            serverCapabilities = AnyCodable(resultDict["capabilities"] ?? [String: Any]())
            serverInfo = AnyCodable(resultDict["serverInfo"] ?? ["name": "", "version": ""])
            instructions = resultDict["instructions"] as? String
            await transport.setProtocolVersion(selectedVersion)

            let notification = JsonRpcNotification(method: "notifications/initialized")
            try await transport.send(JsonRpc.encodeNotificationToLine(notification))
        } catch {
            await close()
            throw error
        }
    }

    // MARK: - MCP Operations

    public func listTools(cursor: String? = nil) async throws -> (tools: [McpTool], nextCursor: String?) {
        var params: [String: Any] = [:]
        if let cursor { params["cursor"] = cursor }

        let result = try await sendRequest("tools/list", params: params.isEmpty ? nil : AnyCodable(params))
        guard let dict = result?.value as? [String: Any] else {
            return ([], nil)
        }

        guard let toolsArray = dict["tools"] as? [[String: Any]] else {
            throw McpError.protocolError("Invalid MCP tools/list result")
        }
        let tools = try toolsArray.map { toolDict -> McpTool in
            guard toolDict["name"] is String, toolDict["inputSchema"] is [String: Any] else {
                throw McpError.protocolError("Invalid entry in MCP tools/list result")
            }
            return try decodeObject(McpTool.self, from: toolDict)
        }

        let nextCursor = dict["nextCursor"] as? String
        return (tools, nextCursor)
    }

    public func listAllTools() async throws -> [McpTool] {
        var all: [McpTool] = []
        var cursor: String? = nil
        var seen = Set<String>()
        repeat {
            let page = try await listTools(cursor: cursor)
            all.append(contentsOf: page.tools)
            if let next = page.nextCursor, !seen.insert(next).inserted {
                throw McpError.protocolError("MCP tools/list returned duplicate cursor: \(next)")
            }
            cursor = page.nextCursor
            if seen.count >= 1_000 { throw McpError.protocolError("MCP tools/list exceeded 1000 pages") }
        } while cursor != nil
        outputSchemas = all.reduce(into: [:]) { schemas, tool in
            if let outputSchema = tool.outputSchema { schemas[tool.name] = outputSchema }
        }
        return all
    }

    public func callTool(
        name: String,
        arguments: [String: AnyCodable] = [:],
        signal: CancellationToken? = nil,
        timeoutMs: Int? = nil,
        onProgress: McpProgressHandler? = nil
    ) async throws -> McpToolResult {
        let params: [String: Any] = [
            "name": name,
            "arguments": arguments.mapValues { $0.value },
        ]
        let result = try await sendRequest("tools/call", params: AnyCodable(params), signal: signal, timeoutMs: timeoutMs, onProgress: onProgress)
        guard let dict = result?.value as? [String: Any] else {
            throw McpError.protocolError("Invalid MCP tools/call result")
        }

        let isError = dict["isError"] as? Bool ?? false
        guard dict["content"] == nil || dict["content"] is [[String: Any]] else {
            throw McpError.protocolError("Invalid MCP tools/call result")
        }
        let content = try (dict["content"] as? [[String: Any]] ?? []).map {
            try decodeObject(McpContent.self, from: $0)
        }
        if let structured = dict["structuredContent"], !(structured is [String: Any]) {
            throw McpError.protocolError("Invalid MCP tools/call structured content")
        }
        let structuredContent = dict["structuredContent"].map { AnyCodable($0) }
        if let outputSchema = outputSchemas[name], let structuredContent {
            try validateStructuredContent(structuredContent, against: outputSchema)
        }
        return McpToolResult(
            content: content,
            isError: isError,
            structuredContent: structuredContent,
            rawResult: result,
            meta: dict["_meta"].map(AnyCodable.init)
        )
    }

    public func listResources(cursor: String? = nil) async throws -> (resources: [McpResource], nextCursor: String?) {
        var params: [String: Any] = [:]
        if let cursor { params["cursor"] = cursor }

        let result = try await sendRequest("resources/list", params: params.isEmpty ? nil : AnyCodable(params))
        guard let dict = result?.value as? [String: Any] else {
            return ([], nil)
        }

        guard let resourcesArray = dict["resources"] as? [[String: Any]] else {
            throw McpError.protocolError("Invalid MCP resources/list result")
        }
        let resources = try resourcesArray.map { item -> McpResource in
            guard let uri = item["uri"] as? String else {
                throw McpError.protocolError("Invalid entry in MCP resources/list result")
            }
            var item = item
            item["name"] = item["name"] ?? uri
            return try decodeObject(McpResource.self, from: item)
        }

        let nextCursor = dict["nextCursor"] as? String
        return (resources, nextCursor)
    }

    public func listAllResources() async throws -> [McpResource] {
        var all: [McpResource] = []
        var cursor: String? = nil
        var seen = Set<String>()
        repeat {
            let page = try await listResources(cursor: cursor)
            all.append(contentsOf: page.resources)
            if let next = page.nextCursor, !seen.insert(next).inserted {
                throw McpError.protocolError("MCP resources/list returned duplicate cursor: \(next)")
            }
            cursor = page.nextCursor
            if seen.count >= 1_000 { throw McpError.protocolError("MCP resources/list exceeded 1000 pages") }
        } while cursor != nil
        return all
    }

    public func listResourceTemplates(cursor: String? = nil) async throws -> (resourceTemplates: [McpResourceTemplate], nextCursor: String?) {
        let params = cursor.map { AnyCodable(["cursor": $0]) }
        let result = try await sendRequest("resources/templates/list", params: params)
        guard let dict = result?.value as? [String: Any],
              let values = dict["resourceTemplates"] as? [[String: Any]] else {
            throw McpError.protocolError("Invalid MCP resources/templates/list result")
        }
        let templates = try values.map { item -> McpResourceTemplate in
            guard let uri = item["uriTemplate"] as? String else {
                throw McpError.protocolError("Invalid entry in MCP resources/templates/list result")
            }
            var item = item
            item["name"] = item["name"] ?? uri
            return try decodeObject(McpResourceTemplate.self, from: item)
        }
        return (templates, dict["nextCursor"] as? String)
    }

    public func listAllResourceTemplates() async throws -> [McpResourceTemplate] {
        var all: [McpResourceTemplate] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            let page = try await listResourceTemplates(cursor: cursor)
            all.append(contentsOf: page.resourceTemplates)
            if let next = page.nextCursor, !seen.insert(next).inserted {
                throw McpError.protocolError("MCP resources/templates/list returned duplicate cursor: \(next)")
            }
            cursor = page.nextCursor
            if seen.count >= 1_000 { throw McpError.protocolError("MCP resources/templates/list exceeded 1000 pages") }
        } while cursor != nil
        return all
    }

    public func listPrompts(cursor: String? = nil) async throws -> (prompts: [McpPrompt], nextCursor: String?) {
        var params: [String: Any] = [:]
        if let cursor { params["cursor"] = cursor }
        let result = try await sendRequest("prompts/list", params: params.isEmpty ? nil : AnyCodable(params))
        guard let dictionary = result?.value as? [String: Any] else { return ([], nil) }
        let prompts = (dictionary["prompts"] as? [[String: Any]] ?? []).compactMap { value -> McpPrompt? in
            guard let name = value["name"] as? String else { return nil }
            let arguments = (value["arguments"] as? [[String: Any]])?.compactMap { argument -> McpPromptArgument? in
                guard let name = argument["name"] as? String else { return nil }
                return McpPromptArgument(
                    name: name,
                    title: argument["title"] as? String,
                    description: argument["description"] as? String,
                    required: argument["required"] as? Bool
                )
            }
            return McpPrompt(
                name: name,
                title: value["title"] as? String,
                description: value["description"] as? String,
                arguments: arguments
            )
        }
        return (prompts, dictionary["nextCursor"] as? String)
    }

    public func listAllPrompts() async throws -> [McpPrompt] {
        var prompts: [McpPrompt] = []
        var cursor: String?
        repeat {
            let page = try await listPrompts(cursor: cursor)
            prompts.append(contentsOf: page.prompts)
            cursor = page.nextCursor
        } while cursor != nil
        return prompts
    }

    public func getPrompt(
        name: String,
        arguments: [String: String] = [:],
        signal: CancellationToken? = nil
    ) async throws -> McpPromptResult {
        let result = try await sendRequest("prompts/get", params: AnyCodable([
            "name": name,
            "arguments": arguments,
        ] as [String: Any]), signal: signal)
        guard let dictionary = result?.value as? [String: Any] else { return McpPromptResult(messages: []) }
        let messages = (dictionary["messages"] as? [[String: Any]] ?? []).map { message in
            let contentValue = message["content"]
            let content: [McpContent]
            if let contentValue = contentValue as? [String: Any] {
                content = [parsePromptContent(contentValue)]
            } else if let contentValue = contentValue as? [[String: Any]] {
                content = contentValue.map(parsePromptContent)
            } else {
                content = []
            }
            return McpPromptMessage(role: message["role"] as? String ?? "user", content: content)
        }
        return McpPromptResult(description: dictionary["description"] as? String, messages: messages)
    }

    public func readResource(
        uri: String,
        signal: CancellationToken? = nil
    ) async throws -> [McpResourceContent] {
        let result = try await sendRequest("resources/read", params: AnyCodable(["uri": uri]), signal: signal)
        guard let dict = result?.value as? [String: Any],
              let contentsArray = dict["contents"] as? [[String: Any]] else {
            throw McpError.protocolError("Invalid MCP resources/read result")
        }
        return try contentsArray.map { contents in
            guard contents["uri"] is String,
                  contents["text"] is String || contents["blob"] is String else {
                throw McpError.protocolError("Invalid contents in MCP resources/read result")
            }
            return try decodeObject(McpResourceContent.self, from: contents)
        }
    }

    /// Optional server-provided usage instructions from the initialize result.
    public func serverInstructions() -> String? { instructions }
    public func negotiatedProtocolVersion() -> String? { negotiatedVersion }
    public func serverImplementation() -> AnyCodable? { serverInfo }
    public func advertisedServerCapabilities() -> AnyCodable? { serverCapabilities }

    public func setRoots(_ roots: [McpRoot]) async throws {
        self.roots = roots
        if transport != nil {
            try await notify("notifications/roots/list_changed")
        }
    }

    public func notify(_ method: String, params: AnyCodable? = nil) async throws {
        guard let transport else { throw McpError.transportClosed }
        try await transport.send(JsonRpc.encodeNotificationToLine(JsonRpcNotification(method: method, params: params)))
    }

    /// Returns whether the initialized server advertised a capability. The
    /// adapter uses this before optional MCP methods such as resources/list.
    public func supportsServerCapability(_ name: String) -> Bool {
        guard let values = serverCapabilities?.value as? [String: Any] else { return false }
        return values[name] != nil && !(values[name] is NSNull)
    }

    public func close() async {
        await close(with: .transportClosed)
    }

    private func close(with error: McpError) async {
        guard !isClosed else { return }
        isClosed = true
        receiveTask?.cancel()
        receiveTask = nil
        if let transport {
            await transport.close()
        }
        transport = nil
        for (_, entry) in pendingRequests {
            entry.timer?.cancel()
            entry.signalWatcher?.cancel()
            entry.continuation.resume(throwing: error)
        }
        pendingRequests.removeAll()
        for (_, task) in incomingTasks { task.cancel() }
        incomingTasks.removeAll()
        await connectionClosedHandler?()
    }

    // MARK: - Internals

    private func sendRequest(
        _ method: String,
        params: AnyCodable?,
        signal: CancellationToken? = nil,
        timeoutMs: Int? = nil,
        onProgress: McpProgressHandler? = nil
    ) async throws -> AnyCodable? {
        guard let transport else { throw McpError.transportClosed }
        if signal?.isCancelled == true { throw CancellationError() }
        try Task.checkCancellation()

        let id = JsonRpcId.integer(nextId)
        nextId += 1
        var requestParams = params
        if onProgress != nil {
            var object = params?.value as? [String: Any] ?? [:]
            var meta = object["_meta"] as? [String: Any] ?? [:]
            meta["progressToken"] = nextId - 1
            object["_meta"] = meta
            requestParams = AnyCodable(object)
        }
        let data = try JsonRpc.encodeToLine(JsonRpcRequest(id: id, method: method, params: requestParams))
        let effectiveTimeout = timeoutMs ?? requestTimeoutMs ?? 30_000
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if cancelledRequestIDs.remove(id) != nil {
                    continuation.resume(throwing: McpError.aborted)
                    return
                }
                pendingRequests[id] = PendingRequest(
                    continuation: continuation,
                    method: method,
                    timeoutMs: effectiveTimeout,
                    legacyTimeout: timeoutMs == nil,
                    onProgress: onProgress,
                    timer: nil,
                    signalWatcher: nil
                )
                armTimeout(id)
                if let signal {
                    let watcher = Task { [weak self] in
                        while !Task.isCancelled {
                            if signal.isCancelled {
                                await self?.cancelPendingRequest(id: id, error: CancellationError(), reason: "Aborted")
                                return
                            }
                            try? await Task.sleep(for: .milliseconds(20))
                        }
                    }
                    pendingRequests[id]?.signalWatcher = watcher
                }
                Task { [weak self] in
                    do { try await transport.send(data) }
                    catch { await self?.failPendingRequest(id: id, error: error) }
                }
            }
        }, onCancel: {
            Task { await self.cancelPendingRequest(id: id, error: McpError.aborted, reason: "Aborted") }
        })
    }

    private func armTimeout(_ id: JsonRpcId) {
        guard var entry = pendingRequests[id] else { return }
        entry.timer?.cancel()
        if let timeout = entry.timeoutMs, timeout > 0 {
            entry.timer = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(timeout)) }
                catch { return }
                await self?.timeoutPendingRequest(id)
            }
        }
        pendingRequests[id] = entry
    }

    private func timeoutPendingRequest(_ id: JsonRpcId) async {
        guard let entry = pendingRequests[id] else { return }
        let error: McpError = entry.legacyTimeout ? .timeout : .requestTimeout(entry.timeoutMs ?? 0)
        await cancelPendingRequest(id: id, error: error, reason: "Request timed out")
    }

    private func takePendingRequest(_ id: JsonRpcId) -> PendingRequest? {
        guard let entry = pendingRequests.removeValue(forKey: id) else { return nil }
        entry.timer?.cancel()
        entry.signalWatcher?.cancel()
        return entry
    }

    private func failPendingRequest(id: JsonRpcId, error: any Error) {
        takePendingRequest(id)?.continuation.resume(throwing: error)
    }

    private func cancelPendingRequest(id: JsonRpcId, error: any Error, reason: String) async {
        guard let entry = takePendingRequest(id) else {
            cancelledRequestIDs.insert(id)
            return
        }
        entry.continuation.resume(throwing: error)
        if entry.method != "initialize", let transport {
            let notification = JsonRpcNotification(
                method: "notifications/cancelled",
                params: AnyCodable(["requestId": idValue(id), "reason": reason])
            )
            try? await transport.send(JsonRpc.encodeNotificationToLine(notification))
        }
    }

    private func idValue(_ id: JsonRpcId) -> Any {
        switch id {
        case .integer(let value): value
        case .number(let value): value
        case .string(let value): value
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            do {
                guard let transport else { break }
                let data = try await transport.receive()
                await handleMessage(data)
            } catch is CancellationError {
                break
            } catch {
                break
            }
        }
        if !Task.isCancelled {
            await close(with: .connectionClosed)
        }
    }

    private func handleMessage(_ data: Data) async {
        do {
            switch try JsonRpc.decodeIncoming(data) {
            case .response(let response):
                guard let id = response.id,
                      let entry = takePendingRequest(id) else { return }
                if let error = response.error {
                    entry.continuation.resume(throwing: McpError.rpcError(code: error.code, message: error.message))
                } else {
                    entry.continuation.resume(returning: response.result)
                }
            case .request(let request):
                incomingTasks[request.id] = Task { [weak self] in
                    await self?.respondToServerRequest(request)
                    await self?.removeIncomingTask(request.id)
                }
            case .notification(let notification):
                if notification.method == "notifications/progress" {
                    handleProgress(notification.params)
                } else if notification.method == "notifications/cancelled",
                          let params = notification.params?.value as? [String: Any],
                          let rawID = params["requestId"] {
                    if let string = rawID as? String { incomingTasks[.string(string)]?.cancel() }
                    else if let integer = rawID as? Int { incomingTasks[.integer(integer)]?.cancel() }
                }
                await serverNotificationHandler?(notification.method, notification.params)
            }
        } catch {
            // Ignore malformed server notifications. Pending client requests
            // remain active until their response, timeout, or close.
        }
    }

    private func removeIncomingTask(_ id: JsonRpcId) {
        incomingTasks.removeValue(forKey: id)
    }

    private func handleProgress(_ value: AnyCodable?) {
        guard let value,
              let data = try? JSONEncoder().encode(value),
              let progress = try? JSONDecoder().decode(McpProgressNotification.self, from: data),
              let entry = pendingRequests[progress.progressToken] else { return }
        armTimeout(progress.progressToken)
        if let onProgress = entry.onProgress {
            Task { await onProgress(progress) }
        }
    }

    private func respondToServerRequest(_ request: JsonRpcServerRequest) async {
        guard let transport else { return }
        var response: JsonRpcServerResponse
        do {
            if request.method == "ping" {
                response = JsonRpcServerResponse(id: request.id, result: AnyCodable([String: Any]()), error: nil)
                try await transport.send(JsonRpc.encodeServerResponseToLine(response))
                return
            }
            if request.method == "roots/list", roots != nil || rootsProvider != nil {
                let roots = await rootsProvider?() ?? roots ?? []
                let values: [[String: Any]] = roots.map { root in
                    var value: [String: Any] = ["uri": root.uri]
                    if let name = root.name { value["name"] = name }
                    return value
                }
                response = JsonRpcServerResponse(id: request.id, result: AnyCodable(["roots": values]), error: nil)
                try await transport.send(JsonRpc.encodeServerResponseToLine(response))
                return
            }
            guard let serverRequestHandler else {
                throw McpError.protocolError("No host handler for MCP request \"\(request.method)\"")
            }
            response = JsonRpcServerResponse(
                id: request.id,
                result: try await serverRequestHandler(request.method, request.params),
                error: nil
            )
        } catch let error as McpError {
            response = JsonRpcServerResponse(
                id: request.id,
                result: nil,
                error: JsonRpcError(code: -32601, message: error.description)
            )
        } catch {
            response = JsonRpcServerResponse(
                id: request.id,
                result: nil,
                error: JsonRpcError(code: -32603, message: String(describing: error))
            )
        }
        do {
            try await transport.send(JsonRpc.encodeServerResponseToLine(response))
        } catch {
            // Transport shutdown also closes the pending client requests.
        }
    }

    private func parseResourceContent(_ value: Any?) -> McpResourceContent? {
        guard let dict = value as? [String: Any], let uri = dict["uri"] as? String else { return nil }
        return McpResourceContent(uri: uri, text: dict["text"] as? String, blob: dict["blob"] as? String, mimeType: dict["mimeType"] as? String)
    }

    private func decodeObject<T: Decodable>(_ type: T.Type, from object: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(type, from: data)
    }

    private func validateStructuredContent(_ content: AnyCodable, against schema: AnyCodable) throws {
        guard let schemaValue = schema.value as? [String: Any] else { return }
        let result = JSONSchemaValidator.shared.validate(
            content.value,
            against: schemaValue,
            path: "structuredContent",
            coerceTypes: false
        )
        guard !result.isValid else { return }
        let details = result.errors.map { $0.errorDescription ?? "invalid value" }.joined(separator: "; ")
        throw McpError.protocolError("Structured content does not match the tool's output schema: \(details)")
    }

    private func parsePromptContent(_ value: [String: Any]) -> McpContent {
        McpContent(
            type: value["type"] as? String ?? "text",
            text: value["text"] as? String,
            data: value["data"] as? String,
            mimeType: value["mimeType"] as? String,
            resource: parseResourceContent(value["resource"]),
            uri: value["uri"] as? String,
            name: value["name"] as? String
        )
    }
}

private extension McpError {
    var description: String {
        switch self {
        case .connectionFailed(let message), .protocolError(let message), .initializationFailed(let message):
            return message
        case .rpcError(_, let message):
            return message
        case .timeout:
            return "MCP request timed out"
        case .transportClosed:
            return "MCP transport is closed"
        case .connectionClosed:
            return "MCP connection closed"
        case .requestTimeout(let timeoutMs):
            return "MCP request timed out after \(timeoutMs)ms"
        case .aborted:
            return "MCP request aborted"
        }
    }
}
