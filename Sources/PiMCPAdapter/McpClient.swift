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

    public init(sampling: Bool = false, elicitation: Bool = false) {
        self.sampling = sampling
        self.elicitation = elicitation
    }

    var value: [String: Any] {
        var capabilities: [String: Any] = [:]
        if sampling { capabilities["sampling"] = [String: Any]() }
        if elicitation { capabilities["elicitation"] = ["form": [String: Any]()] }
        return capabilities
    }
}

public actor McpClient {
    public nonisolated let connectionID: UUID
    private var transport: (any McpTransport)?
    private var nextId: Int = 1
    private var pendingRequests: [Int: CheckedContinuation<AnyCodable?, any Error>] = [:]
    private var receiveTask: Task<Void, Never>?
    private var serverCapabilities: AnyCodable?
    private var serverInfo: AnyCodable?
    private var instructions: String?
    private var outputSchemas: [String: AnyCodable] = [:]
    private var cancelledRequestIDs: Set<Int> = []
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
        capabilities: McpClientCapabilities = McpClientCapabilities()
    ) {
        self.connectionID = connectionID
        self.requestTimeoutMs = requestTimeoutMs.flatMap { $0 > 0 ? $0 : nil }
        self.serverRequestHandler = serverRequestHandler
        self.serverNotificationHandler = serverNotificationHandler
        self.connectionClosedHandler = connectionClosedHandler
        self.capabilities = capabilities
    }

    // MARK: - Connection

    public func connect(transport: any McpTransport) async throws {
        self.transport = transport

        // Start receive loop
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        // Send initialize
        let initResult = try await sendRequest("initialize", params: AnyCodable([
            "protocolVersion": "2024-11-05",
            "capabilities": capabilities.value,
            "clientInfo": [
                "name": "pi",
                "version": "1.0.0",
            ] as [String: Any],
        ] as [String: Any]))

        if let resultDict = initResult?.value as? [String: Any] {
            serverCapabilities = AnyCodable(resultDict["capabilities"] ?? NSNull())
            serverInfo = AnyCodable(resultDict["serverInfo"] ?? NSNull())
            instructions = resultDict["instructions"] as? String
        }

        // Send initialized notification
        let notification = JsonRpcNotification(method: "notifications/initialized")
        let data = try JsonRpc.encodeNotificationToLine(notification)
        try await transport.send(data)
    }

    // MARK: - MCP Operations

    public func listTools(cursor: String? = nil) async throws -> (tools: [McpTool], nextCursor: String?) {
        var params: [String: Any] = [:]
        if let cursor { params["cursor"] = cursor }

        let result = try await sendRequest("tools/list", params: params.isEmpty ? nil : AnyCodable(params))
        guard let dict = result?.value as? [String: Any] else {
            return ([], nil)
        }

        let toolsArray = dict["tools"] as? [[String: Any]] ?? []
        let tools = toolsArray.compactMap { toolDict -> McpTool? in
            guard let name = toolDict["name"] as? String else { return nil }
            return McpTool(
                name: name,
                title: toolDict["title"] as? String,
                description: toolDict["description"] as? String,
                inputSchema: toolDict["inputSchema"].map { AnyCodable($0) },
                outputSchema: toolDict["outputSchema"].map { AnyCodable($0) }
            )
        }

        let nextCursor = dict["nextCursor"] as? String
        return (tools, nextCursor)
    }

    public func listAllTools() async throws -> [McpTool] {
        var all: [McpTool] = []
        var cursor: String? = nil
        repeat {
            let page = try await listTools(cursor: cursor)
            all.append(contentsOf: page.tools)
            cursor = page.nextCursor
        } while cursor != nil
        outputSchemas = all.reduce(into: [:]) { schemas, tool in
            if let outputSchema = tool.outputSchema { schemas[tool.name] = outputSchema }
        }
        return all
    }

    public func callTool(
        name: String,
        arguments: [String: AnyCodable] = [:],
        signal: CancellationToken? = nil
    ) async throws -> McpToolResult {
        let params: [String: Any] = [
            "name": name,
            "arguments": arguments.mapValues { $0.value },
        ]
        let result = try await sendRequest("tools/call", params: AnyCodable(params), signal: signal)
        guard let dict = result?.value as? [String: Any] else {
            return McpToolResult(content: [McpContent(type: "text", text: "(empty response)")])
        }

        let isError = dict["isError"] as? Bool ?? false
        let contentArray = dict["content"] as? [[String: Any]] ?? []
        let content = contentArray.map { c -> McpContent in
            McpContent(
                type: c["type"] as? String ?? "text",
                text: c["text"] as? String,
                data: c["data"] as? String,
                mimeType: c["mimeType"] as? String,
                resource: parseResourceContent(c["resource"]),
                uri: c["uri"] as? String,
                name: c["name"] as? String
            )
        }
        let structuredContent = dict["structuredContent"].map { AnyCodable($0) }
        if let outputSchema = outputSchemas[name], let structuredContent {
            try validateStructuredContent(structuredContent, against: outputSchema)
        }
        return McpToolResult(
            content: content,
            isError: isError,
            structuredContent: structuredContent,
            rawResult: result
        )
    }

    public func listResources(cursor: String? = nil) async throws -> (resources: [McpResource], nextCursor: String?) {
        var params: [String: Any] = [:]
        if let cursor { params["cursor"] = cursor }

        let result = try await sendRequest("resources/list", params: params.isEmpty ? nil : AnyCodable(params))
        guard let dict = result?.value as? [String: Any] else {
            return ([], nil)
        }

        let resourcesArray = dict["resources"] as? [[String: Any]] ?? []
        let resources = resourcesArray.compactMap { rDict -> McpResource? in
            guard let uri = rDict["uri"] as? String, let name = rDict["name"] as? String else { return nil }
            return McpResource(
                uri: uri,
                name: name,
                description: rDict["description"] as? String,
                mimeType: rDict["mimeType"] as? String
            )
        }

        let nextCursor = dict["nextCursor"] as? String
        return (resources, nextCursor)
    }

    public func listAllResources() async throws -> [McpResource] {
        var all: [McpResource] = []
        var cursor: String? = nil
        repeat {
            let page = try await listResources(cursor: cursor)
            all.append(contentsOf: page.resources)
            cursor = page.nextCursor
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
            return []
        }
        return contentsArray.map { c in
            McpResourceContent(
                uri: c["uri"] as? String ?? uri,
                text: c["text"] as? String,
                blob: c["blob"] as? String
            )
        }
    }

    /// Optional server-provided usage instructions from the initialize result.
    public func serverInstructions() -> String? { instructions }

    /// Returns whether the initialized server advertised a capability. The
    /// adapter uses this before optional MCP methods such as resources/list.
    public func supportsServerCapability(_ name: String) -> Bool {
        guard let values = serverCapabilities?.value as? [String: Any] else { return false }
        return values[name] != nil && !(values[name] is NSNull)
    }

    public func close() async {
        receiveTask?.cancel()
        receiveTask = nil
        if let transport {
            await transport.close()
        }
        transport = nil
        for (_, cont) in pendingRequests {
            cont.resume(throwing: McpError.transportClosed)
        }
        pendingRequests.removeAll()
    }

    // MARK: - Internals

    private func sendRequest(
        _ method: String,
        params: AnyCodable?,
        signal: CancellationToken? = nil
    ) async throws -> AnyCodable? {
        guard let transport else { throw McpError.transportClosed }
        if signal?.isCancelled == true { throw CancellationError() }

        let id = nextId
        nextId += 1

        let request = JsonRpcRequest(id: id, method: method, params: params)
        let data = try JsonRpc.encodeToLine(request)

        if let requestTimeoutMs {
            return try await withThrowingTaskGroup(of: AnyCodable?.self) { group in
                group.addTask { try await self.waitForResponse(id: id, data: data, transport: transport, signal: signal) }
                group.addTask {
                    try await Task.sleep(for: .milliseconds(requestTimeoutMs))
                    throw McpError.timeout
                }
                do {
                    guard let response = try await group.next() else {
                        throw McpError.transportClosed
                    }
                    group.cancelAll()
                    return response
                } catch {
                    group.cancelAll()
                    failPendingRequest(id: id, error: error)
                    throw error
                }
            }
        }
        return try await waitForResponse(id: id, data: data, transport: transport, signal: signal)
    }

    private func waitForResponse(
        id: Int,
        data: Data,
        transport: any McpTransport,
        signal: CancellationToken?
    ) async throws -> AnyCodable? {
        guard let signal else {
            return try await sendAndAwait(id: id, data: data, transport: transport)
        }
        if signal.isCancelled { throw CancellationError() }
        return try await withThrowingTaskGroup(of: AnyCodable?.self) { group in
            group.addTask { try await self.sendAndAwait(id: id, data: data, transport: transport) }
            group.addTask {
                while !signal.isCancelled {
                    try await Task.sleep(for: .milliseconds(25))
                }
                throw CancellationError()
            }
            do {
                guard let response = try await group.next() else {
                    throw McpError.transportClosed
                }
                group.cancelAll()
                return response
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func sendAndAwait(id: Int, data: Data, transport: any McpTransport) async throws -> AnyCodable? {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if cancelledRequestIDs.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingRequests[id] = continuation
                Task {
                    do {
                        try await transport.send(data)
                    } catch {
                        failPendingRequest(id: id, error: error)
                    }
                }
            }
        }, onCancel: {
            Task { await self.cancelPendingRequest(id: id) }
        })
    }

    private func failPendingRequest(id: Int, error: any Error) {
        pendingRequests.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func cancelPendingRequest(id: Int) {
        if let continuation = pendingRequests.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        } else {
            cancelledRequestIDs.insert(id)
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
            await connectionClosedHandler?()
        }
    }

    private func handleMessage(_ data: Data) async {
        do {
            switch try JsonRpc.decodeIncoming(data) {
            case .response(let response):
                guard let id = response.id,
                      let cont = pendingRequests.removeValue(forKey: id) else { return }
                if let error = response.error {
                    cont.resume(throwing: McpError.rpcError(code: error.code, message: error.message))
                } else {
                    cont.resume(returning: response.result)
                }
            case .request(let request):
                await respondToServerRequest(request)
            case .notification(let notification):
                await serverNotificationHandler?(notification.method, notification.params)
            }
        } catch {
            // Ignore malformed server notifications. Pending client requests
            // remain active until their response, timeout, or close.
        }
    }

    private func respondToServerRequest(_ request: JsonRpcServerRequest) async {
        guard let transport else { return }
        let response: JsonRpcServerResponse
        do {
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
        return McpResourceContent(uri: uri, text: dict["text"] as? String, blob: dict["blob"] as? String)
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
        }
    }
}
