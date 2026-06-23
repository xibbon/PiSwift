import Foundation
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

private final class PendingHookRequests: Sendable {
    private let state = LockedState<[String: @Sendable ([String: AnyCodable]) -> Void]>([:])

    func register(_ id: String, handler: @escaping @Sendable ([String: AnyCodable]) -> Void) {
        state.withLock { handlers in
            handlers[id] = handler
        }
    }

    func resolve(_ id: String, response: [String: AnyCodable]) {
        let handler = state.withLock { handlers in
            handlers.removeValue(forKey: id)
        }
        handler?(response)
    }
}

private final class RpcOutput: Sendable {
    private let state = LockedState<Void>(())

    func send(_ object: [String: Any]) {
        state.withLock { _ in
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
                  let json = String(data: data, encoding: .utf8) else {
                return
            }
            print(json)
        }
    }
}

@MainActor
private final class RpcHookUIContext: HookUIContext {
    private let output: RpcOutput
    private let pending: PendingHookRequests

    init(output: RpcOutput, pending: PendingHookRequests) {
        self.output = output
        self.pending = pending
    }

    func select(_ title: String, _ options: [String]) async -> String? {
        let id = UUID().uuidString
        return await withCheckedContinuation { continuation in
            pending.register(id) { response in
                if response["cancelled"]?.value as? Bool == true {
                    continuation.resume(returning: nil)
                } else if let value = response["value"]?.value as? String {
                    continuation.resume(returning: value)
                } else {
                    continuation.resume(returning: nil)
                }
            }
            output.send([
                "type": "hook_ui_request",
                "id": id,
                "method": "select",
                "title": title,
                "options": options,
            ])
        }
    }

    func confirm(_ title: String, _ message: String) async -> Bool {
        let id = UUID().uuidString
        return await withCheckedContinuation { continuation in
            pending.register(id) { response in
                if response["cancelled"]?.value as? Bool == true {
                    continuation.resume(returning: false)
                } else if let confirmed = response["confirmed"]?.value as? Bool {
                    continuation.resume(returning: confirmed)
                } else {
                    continuation.resume(returning: false)
                }
            }
            output.send([
                "type": "hook_ui_request",
                "id": id,
                "method": "confirm",
                "title": title,
                "message": message,
            ])
        }
    }

    func input(_ title: String, _ placeholder: String?) async -> String? {
        let id = UUID().uuidString
        return await withCheckedContinuation { continuation in
            pending.register(id) { response in
                if response["cancelled"]?.value as? Bool == true {
                    continuation.resume(returning: nil)
                } else if let value = response["value"]?.value as? String {
                    continuation.resume(returning: value)
                } else {
                    continuation.resume(returning: nil)
                }
            }
            var payload: [String: Any] = [
                "type": "hook_ui_request",
                "id": id,
                "method": "input",
                "title": title,
            ]
            if let placeholder { payload["placeholder"] = placeholder }
            output.send(payload)
        }
    }

    func notify(_ message: String, _ type: HookNotificationType?) {
        var payload: [String: Any] = [
            "type": "hook_ui_request",
            "id": UUID().uuidString,
            "method": "notify",
            "message": message,
        ]
        if let type { payload["notifyType"] = type.rawValue }
        output.send(payload)
    }

    func setStatus(_ key: String, _ text: String?) {
        output.send([
            "type": "hook_ui_request",
            "id": UUID().uuidString,
            "method": "setStatus",
            "statusKey": key,
            "statusText": text as Any,
        ])
    }

    func setWorkingMessage(_ message: String?) {
        _ = message
    }

    func setWidget(_ key: String, _ content: HookWidgetContent?) {
        switch content {
        case .lines(let lines):
            output.send([
                "type": "hook_ui_request",
                "id": UUID().uuidString,
                "method": "setWidget",
                "widgetKey": key,
                "widgetLines": lines,
            ])
        case .none:
            output.send([
                "type": "hook_ui_request",
                "id": UUID().uuidString,
                "method": "setWidget",
                "widgetKey": key,
                "widgetLines": NSNull(),
            ])
        case .component:
            break
        }
    }

    func setFooter(_ factory: HookFooterFactory?) {
        _ = factory
    }

    func setTitle(_ title: String) {
        output.send([
            "type": "hook_ui_request",
            "id": UUID().uuidString,
            "method": "setTitle",
            "title": title,
        ])
    }

    func custom(_ factory: @escaping HookCustomFactory, options: HookCustomOptions?) async -> HookCustomResult? {
        _ = factory
        _ = options
        return nil
    }

    func setEditorText(_ text: String) {
        output.send([
            "type": "hook_ui_request",
            "id": UUID().uuidString,
            "method": "set_editor_text",
            "text": text,
        ])
    }

    func getEditorText() -> String {
        ""
    }

    func editor(_ title: String, _ prefill: String?) async -> String? {
        let id = UUID().uuidString
        return await withCheckedContinuation { continuation in
            pending.register(id) { response in
                if response["cancelled"]?.value as? Bool == true {
                    continuation.resume(returning: nil)
                } else if let value = response["value"]?.value as? String {
                    continuation.resume(returning: value)
                } else {
                    continuation.resume(returning: nil)
                }
            }
            var payload: [String: Any] = [
                "type": "hook_ui_request",
                "id": id,
                "method": "editor",
                "title": title,
            ]
            if let prefill { payload["prefill"] = prefill }
            output.send(payload)
        }
    }

    func setEditorComponent(_ factory: HookEditorComponentFactory?) {
        _ = factory
    }

    func getAllThemes() -> [HookThemeInfo] {
        []
    }

    func getTheme(_ name: String) -> Theme? {
        _ = name
        return nil
    }

    func setTheme(_ theme: HookThemeInput) -> HookThemeResult {
        _ = theme
        return HookThemeResult(success: false, error: "UI not available")
    }

    var theme: Theme {
        PiSwiftCodingAgent.theme
    }
}

private func makeSuccessResponse(_ id: Any?, _ command: String, _ data: Any? = nil) -> [String: Any] {
    var response: [String: Any] = [
        "type": "response",
        "command": command,
        "success": true,
    ]
    if let id { response["id"] = id }
    if let data { response["data"] = data }
    return response
}

private func makeErrorResponse(_ id: Any?, _ command: String, _ message: String) -> [String: Any] {
    var response: [String: Any] = [
        "type": "response",
        "command": command,
        "success": false,
        "error": message,
    ]
    if let id { response["id"] = id }
    return response
}

public func runRpcMode(_ session: AgentSession) async {
    let output = RpcOutput()

    let pendingHookRequests = PendingHookRequests()
    let uiContext = await MainActor.run {
        RpcHookUIContext(output: output, pending: pendingHookRequests)
    }

    if let hookRunner = session.hookRunner {
        hookRunner.initialize(
            getModel: { [weak session] in session?.agent.state.model },
            getSystemPrompt: { [weak session] in session?.agent.state.systemPrompt },
            getSystemPromptOptions: { [weak session] in
                session?.getCurrentSystemPromptOptions() ?? BuildSystemPromptOptions()
            },
            isProjectTrusted: { [weak session] in session?.projectTrusted ?? true },
            sendMessageHandler: { [weak session] message, options in
                Task {
                    await session?.sendHookMessage(message, options: options)
                }
            },
            appendEntryHandler: { [weak session] customType, data in
                session?.sessionManager.appendCustomEntry(customType, data)
            },
            setSessionNameHandler: { [weak session] name in
                _ = session?.sessionManager.appendSessionInfo(name)
            },
            getSessionNameHandler: { [weak session] in
                session?.sessionManager.getSessionName()
            },
            getActiveToolsHandler: { [weak session] in
                session?.getActiveToolNames() ?? []
            },
            getAllToolsHandler: { [weak session] in
                session?.getAllTools() ?? []
            },
            setActiveToolsHandler: { [weak session] toolNames in
                session?.setActiveToolsByName(toolNames)
            },
            uiContext: uiContext,
            mode: .rpc,
            hasUI: false
        )
        _ = hookRunner.onError { error in
            output.send([
                "type": "hook_error",
                "hookPath": error.hookPath,
                "event": error.event,
                "error": error.error,
                "stack": error.stack as Any,
            ])
        }

        _ = await hookRunner.emit(SessionStartEvent())
    }

    await session.emitCustomToolSessionEvent(.start, previousSessionFile: nil)

    _ = session.subscribe { event in
        output.send(encodeSessionEvent(event))
    }

    while let line = readLine() {
        guard let data = line.data(using: .utf8) else { continue }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = json as? [String: Any] else {
            output.send(makeErrorResponse(nil, "parse", "Failed to parse command"))
            continue
        }

        if let type = dict["type"] as? String, type == "hook_ui_response" {
            if let id = dict["id"] as? String {
                pendingHookRequests.resolve(id, response: mapToAnyCodable(dict))
            }
            continue
        }

        let idValue = dict["id"]
        guard let commandType = dict["type"] as? String else {
            output.send(makeErrorResponse(idValue, "parse", "Missing command type"))
            continue
        }

        let response: [String: Any]
        do {
            response = try await handleRpcCommand(commandType, dict, session, output)
        } catch {
            response = makeErrorResponse(idValue, commandType, error.localizedDescription)
        }
        output.send(response)
    }
}

private func handleRpcCommand(
    _ commandType: String,
    _ dict: [String: Any],
    _ session: AgentSession,
    _ output: RpcOutput
) async throws -> [String: Any] {
    let idValue = dict["id"]

    switch commandType {
    case "prompt":
        guard let message = dict["message"] as? String else {
            return makeErrorResponse(idValue, "prompt", "Missing message")
        }
        let images = decodeImages(dict["images"])
        let idString: String?
        if let idValue {
            idString = (idValue as? String) ?? String(describing: idValue)
        } else {
            idString = nil
        }
        let promptTask = try await session.submitPrompt(
            message,
            options: PromptOptions(expandSlashCommands: nil, images: images)
        )
        Task.detached {
            do {
                try await promptTask.value
            } catch {
                output.send(makeErrorResponse(idString, "prompt", error.localizedDescription))
            }
        }
        return makeSuccessResponse(idValue, "prompt", nil)

    case "steer":
        guard let message = dict["message"] as? String else {
            return makeErrorResponse(idValue, "steer", "Missing message")
        }
        session.steer(message)
        return makeSuccessResponse(idValue, "steer", nil)

    case "follow_up":
        guard let message = dict["message"] as? String else {
            return makeErrorResponse(idValue, "follow_up", "Missing message")
        }
        session.followUp(message)
        return makeSuccessResponse(idValue, "follow_up", nil)

    case "abort":
        await session.abort()
        return makeSuccessResponse(idValue, "abort", nil)

    case "new_session":
        let parentSession = dict["parentSession"] as? String
        let cancelled = !(await session.newSession(NewSessionOptions(parentSession: parentSession)))
        return makeSuccessResponse(idValue, "new_session", ["cancelled": cancelled])

    case "get_state":
        let state: [String: Any] = [
            "model": modelToDict(session.agent.state.model),
            "thinkingLevel": session.agent.state.thinkingLevel.rawValue,
            "isStreaming": session.isStreaming,
            "isCompacting": session.isCompacting,
            "steeringMode": session.steeringMode,
            "followUpMode": session.followUpMode,
            "sessionFile": session.sessionFile as Any,
            "sessionId": session.sessionId,
            "sessionName": session.sessionManager.getSessionName() as Any,
            "autoCompactionEnabled": session.autoCompactionEnabled,
            "messageCount": session.messages.count,
            "pendingMessageCount": session.pendingMessageCount,
        ]
        return makeSuccessResponse(idValue, "get_state", state)

    case "set_session_name":
        guard let name = dict["name"] as? String else {
            return makeErrorResponse(idValue, "set_session_name", "Missing name")
        }
        session.sessionManager.appendSessionInfo(name)
        return makeSuccessResponse(idValue, "set_session_name", nil)

    case "set_model":
        guard let provider = dict["provider"] as? String,
              let modelId = dict["modelId"] as? String else {
            return makeErrorResponse(idValue, "set_model", "Missing provider/modelId")
        }
        guard let model = session.modelRegistry.find(provider, modelId) else {
            return makeErrorResponse(idValue, "set_model", "Model not found: \(provider)/\(modelId)")
        }
        try await session.setModel(model)
        return makeSuccessResponse(idValue, "set_model", modelToDict(model))

    case "cycle_model":
        let result = try await session.cycleModel(direction: .forward)
        if let result {
            return makeSuccessResponse(idValue, "cycle_model", [
                "model": modelToDict(result.model),
                "thinkingLevel": result.thinkingLevel.rawValue,
                "isScoped": result.isScoped,
            ])
        }
        return makeSuccessResponse(idValue, "cycle_model", NSNull())

    case "get_available_models":
        let models = await session.getAvailableModels().map { modelToDict($0) }
        return makeSuccessResponse(idValue, "get_available_models", ["models": models])

    case "set_thinking_level":
        guard let raw = dict["level"] as? String,
              let level = ThinkingLevel(rawValue: raw) else {
            return makeErrorResponse(idValue, "set_thinking_level", "Invalid thinking level")
        }
        session.setThinkingLevel(level)
        return makeSuccessResponse(idValue, "set_thinking_level", nil)

    case "cycle_thinking_level":
        if let level = session.cycleThinkingLevel() {
            return makeSuccessResponse(idValue, "cycle_thinking_level", ["level": level.rawValue])
        }
        return makeSuccessResponse(idValue, "cycle_thinking_level", NSNull())

    case "set_steering_mode":
        guard let raw = dict["mode"] as? String,
              let mode = AgentSteeringMode(rawValue: raw) else {
            return makeErrorResponse(idValue, "set_steering_mode", "Invalid steering mode")
        }
        session.setSteeringMode(mode)
        return makeSuccessResponse(idValue, "set_steering_mode", nil)

    case "set_follow_up_mode":
        guard let raw = dict["mode"] as? String,
              let mode = AgentFollowUpMode(rawValue: raw) else {
            return makeErrorResponse(idValue, "set_follow_up_mode", "Invalid follow-up mode")
        }
        session.setFollowUpMode(mode)
        return makeSuccessResponse(idValue, "set_follow_up_mode", nil)

    case "compact":
        let customInstructions = dict["customInstructions"] as? String
        let result = try await session.compact(customInstructions: customInstructions)
        return makeSuccessResponse(idValue, "compact", [
            "summary": result.summary,
            "firstKeptEntryId": result.firstKeptEntryId,
            "tokensBefore": result.tokensBefore,
            "details": result.details?.jsonValue as Any,
        ])

    case "set_auto_compaction":
        guard let enabled = dict["enabled"] as? Bool else {
            return makeErrorResponse(idValue, "set_auto_compaction", "Missing enabled")
        }
        session.setAutoCompactionEnabled(enabled)
        return makeSuccessResponse(idValue, "set_auto_compaction", nil)

    case "set_auto_retry":
        guard let enabled = dict["enabled"] as? Bool else {
            return makeErrorResponse(idValue, "set_auto_retry", "Missing enabled")
        }
        session.setAutoRetryEnabled(enabled)
        return makeSuccessResponse(idValue, "set_auto_retry", nil)

    case "abort_retry":
        session.abortRetry()
        return makeSuccessResponse(idValue, "abort_retry", nil)

    case "bash":
        guard let command = dict["command"] as? String else {
            return makeErrorResponse(idValue, "bash", "Missing command")
        }
        let result = try await session.executeBash(command)
        return makeSuccessResponse(idValue, "bash", bashResultToDict(result))

    case "abort_bash":
        session.abortBash()
        return makeSuccessResponse(idValue, "abort_bash", nil)

    case "get_session_stats":
        return makeSuccessResponse(idValue, "get_session_stats", sessionStatsToDict(session.getSessionStats()))

    case "export_html":
        let outputPath = dict["outputPath"] as? String
        let path = try session.exportToHtml(outputPath)
        return makeSuccessResponse(idValue, "export_html", ["path": path])

    case "switch_session":
        guard let sessionPath = dict["sessionPath"] as? String else {
            return makeErrorResponse(idValue, "switch_session", "Missing sessionPath")
        }
        let cancelled = !(await session.switchSession(sessionPath))
        return makeSuccessResponse(idValue, "switch_session", ["cancelled": cancelled])

    case "fork":
        guard let entryId = dict["entryId"] as? String else {
            return makeErrorResponse(idValue, "fork", "Missing entryId")
        }
        let result = try await session.fork(entryId)
        return makeSuccessResponse(idValue, "fork", ["text": result.selectedText, "cancelled": result.cancelled])

    case "get_fork_messages":
        let messages = session.getUserMessagesForForking().map { ["entryId": $0.entryId, "text": $0.text] }
        return makeSuccessResponse(idValue, "get_fork_messages", ["messages": messages])

    case "get_last_assistant_text":
        return makeSuccessResponse(idValue, "get_last_assistant_text", ["text": session.getLastAssistantText() as Any])

    case "get_messages":
        let messages = session.messages.map { encodeAgentMessageDict($0) }
        return makeSuccessResponse(idValue, "get_messages", ["messages": messages])

    case "get_commands":
        var commands: [[String: Any]] = []
        if let hookRunner = session.hookRunner {
            for command in hookRunner.getRegisteredCommands() {
                commands.append([
                    "name": command.name,
                    "description": command.description as Any,
                    "source": "extension",
                ])
            }
        }
        for template in session.promptTemplates {
            commands.append([
                "name": template.name,
                "description": template.description,
                "source": "template",
                "location": template.sourceInfo.source,
                "path": template.filePath,
            ])
        }
        for skill in session.resourceLoader.getSkills().skills {
            commands.append([
                "name": "skill:\(skill.name)",
                "description": skill.description,
                "source": "skill",
                "location": skill.sourceInfo.source,
                "path": skill.filePath,
            ])
        }
        return makeSuccessResponse(idValue, "get_commands", ["commands": commands])

    default:
        return makeErrorResponse(idValue, commandType, "Unknown command: \(commandType)")
    }
}

private func decodeImages(_ value: Any?) -> [ImageContent]? {
    guard let list = value as? [[String: Any]] else { return nil }
    let images = list.compactMap { entry -> ImageContent? in
        guard let data = entry["data"] as? String,
              let mimeType = entry["mimeType"] as? String else { return nil }
        return ImageContent(data: data, mimeType: mimeType)
    }
    return images.isEmpty ? nil : images
}

private func mapToAnyCodable(_ dict: [String: Any]) -> [String: AnyCodable] {
    dict.mapValues { AnyCodable($0) }
}

private func modelToDict(_ model: Model) -> [String: Any] {
    var dict: [String: Any] = [
        "id": model.id,
        "name": model.name,
        "api": model.api.rawValue,
        "provider": model.provider,
        "baseUrl": model.baseUrl,
        "reasoning": model.reasoning,
        "input": model.input.map { $0.rawValue },
        "cost": [
            "input": model.cost.input,
            "output": model.cost.output,
            "cacheRead": model.cost.cacheRead,
            "cacheWrite": model.cost.cacheWrite,
        ],
        "contextWindow": model.contextWindow,
        "maxTokens": model.maxTokens,
    ]
    if let headers = model.headers {
        dict["headers"] = headers
    }
    if let compat = model.compat {
        var compatDict: [String: Any] = [:]
        compatDict["supportsStore"] = compat.supportsStore as Any
        compatDict["supportsDeveloperRole"] = compat.supportsDeveloperRole as Any
        compatDict["supportsReasoningEffort"] = compat.supportsReasoningEffort as Any
        compatDict["maxTokensField"] = compat.maxTokensField?.rawValue as Any
        compatDict["requiresToolResultName"] = compat.requiresToolResultName as Any
        compatDict["requiresAssistantAfterToolResult"] = compat.requiresAssistantAfterToolResult as Any
        compatDict["requiresThinkingAsText"] = compat.requiresThinkingAsText as Any
        compatDict["requiresMistralToolIds"] = compat.requiresMistralToolIds as Any
        dict["compat"] = compatDict
    }
    return dict
}

private func bashResultToDict(_ result: BashResult) -> [String: Any] {
    [
        "output": result.output,
        "exitCode": result.exitCode as Any,
        "cancelled": result.cancelled,
        "truncated": result.truncated,
        "fullOutputPath": result.fullOutputPath as Any,
    ]
}

private func sessionStatsToDict(_ stats: SessionStats) -> [String: Any] {
    var dict: [String: Any] = [
        "sessionFile": stats.sessionFile as Any,
        "sessionId": stats.sessionId,
        "userMessages": stats.userMessages,
        "assistantMessages": stats.assistantMessages,
        "toolCalls": stats.toolCalls,
        "toolResults": stats.toolResults,
        "totalMessages": stats.totalMessages,
        "tokens": [
            "input": stats.tokens.input,
            "output": stats.tokens.output,
            "cacheRead": stats.tokens.cacheRead,
            "cacheWrite": stats.tokens.cacheWrite,
            "total": stats.tokens.total,
        ],
        "cost": stats.cost,
    ]
    // v0.70.0: surface contextUsage so RPC clients can read token-budget percentages
    // without computing them from raw usage + model.contextWindow. Matches upstream's
    // ContextUsage shape: { tokens: Int|null, contextWindow: Int, percent: Double|null }.
    if let usage = stats.contextUsage {
        dict["contextUsage"] = [
            "tokens": usage.tokens as Any,
            "contextWindow": usage.contextWindow,
            "percent": usage.percent as Any,
        ]
    }
    return dict
}
