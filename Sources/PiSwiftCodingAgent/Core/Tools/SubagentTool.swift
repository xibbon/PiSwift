import Foundation
import PiSwiftAI
import PiSwiftAgent

private let maxParallelTasks = 8
private let maxConcurrency = 4

public struct SubagentToolDependencies: Sendable {
    public var cwd: String
    public var agentDir: String
    public var modelRegistry: ModelRegistry
    public var settingsManager: SettingsManager
    public var defaultModel: Model
    public var defaultThinkingLevel: ThinkingLevel

    public init(
        cwd: String,
        agentDir: String,
        modelRegistry: ModelRegistry,
        settingsManager: SettingsManager,
        defaultModel: Model,
        defaultThinkingLevel: ThinkingLevel
    ) {
        self.cwd = cwd
        self.agentDir = agentDir
        self.modelRegistry = modelRegistry
        self.settingsManager = settingsManager
        self.defaultModel = defaultModel
        self.defaultThinkingLevel = defaultThinkingLevel
    }

}

public final class SubagentToolContext: Sendable {
    private let state = LockedState<SubagentToolDependencies?>(nil)

    public init() {}

    public func update(_ dependencies: SubagentToolDependencies) {
        state.withLock { $0 = dependencies }
    }

    public func get() -> SubagentToolDependencies? {
        state.withLock { $0 }
    }
}

enum SubagentToolError: LocalizedError, Sendable {
    case missingDependencies

    var errorDescription: String? {
        switch self {
        case .missingDependencies:
            return "Subagent tool is not initialized."
        }
    }
}

private struct SubagentTask: Sendable {
    var agent: String
    var task: String
    var cwd: String?
    var step: Int?
}

private struct SubagentUsage: Sendable {
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite: Int
    var totalTokens: Int
    var cost: Double
    var turns: Int

    static let empty = SubagentUsage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: 0, turns: 0)
}

private struct SubagentRunResult: Sendable {
    var agent: String
    var agentSource: String
    var task: String
    var exitCode: Int
    var output: String
    var usage: SubagentUsage
    var model: String?
    var stopReason: String?
    var errorMessage: String?
    var step: Int?
}

private func parseScope(_ value: AnyCodable?) -> SubagentScope {
    guard let raw = value?.value as? String, let scope = SubagentScope(rawValue: raw) else {
        return .user
    }
    return scope
}

private func stringValue(_ value: AnyCodable?) -> String? {
    value?.value as? String
}

private func stringFromAny(_ value: Any?) -> String? {
    if let text = value as? String {
        return text
    }
    if let codable = value as? AnyCodable {
        return codable.value as? String
    }
    return nil
}

private func decodeTasks(_ value: Any?) -> [SubagentTask] {
    guard let raw = value as? [Any] else { return [] }
    return raw.compactMap { item in
        if let dict = item as? [String: AnyCodable] {
            guard let agent = dict["agent"]?.value as? String, let task = dict["task"]?.value as? String else { return nil }
            let cwd = dict["cwd"]?.value as? String
            return SubagentTask(agent: agent, task: task, cwd: cwd, step: nil)
        }
        guard let dict = item as? [String: Any] else { return nil }
        guard let agent = stringFromAny(dict["agent"]), let task = stringFromAny(dict["task"]) else { return nil }
        let cwd = stringFromAny(dict["cwd"])
        return SubagentTask(agent: agent, task: task, cwd: cwd, step: nil)
    }
}

private func extractLastText(_ content: [ContentBlock]) -> String? {
    for block in content.reversed() {
        if case let .text(text) = block {
            return text.text
        }
    }
    return nil
}

private func finalOutput(from messages: [AgentMessage]) -> String {
    for message in messages.reversed() {
        if case let .assistant(assistant) = message, let text = extractLastText(assistant.content) {
            return text
        }
    }
    return ""
}

private func computeUsage(from messages: [AgentMessage]) -> SubagentUsage {
    var usage = SubagentUsage.empty
    for message in messages {
        if case let .assistant(assistant) = message {
            usage.turns += 1
            usage.input += assistant.usage.input
            usage.output += assistant.usage.output
            usage.cacheRead += assistant.usage.cacheRead
            usage.cacheWrite += assistant.usage.cacheWrite
            usage.totalTokens += assistant.usage.totalTokens
            usage.cost += assistant.usage.cost.total
        }
    }
    return usage
}

private func resolveThinkingLevel(_ level: ThinkingLevel, model: Model) -> ThinkingLevel {
    if !model.reasoning {
        return .off
    }
    if level == .xhigh && !supportsXhigh(model: model) {
        return .high
    }
    return level
}

private func resolveModel(
    agent: SubagentConfig,
    dependencies: SubagentToolDependencies
) async -> (model: Model, thinking: ThinkingLevel, error: String?) {
    if let modelPattern = agent.model, !modelPattern.isEmpty {
        let available = await dependencies.modelRegistry.getAvailable()
        let parsed = parseModelPattern(modelPattern, available)
        if let model = parsed.model {
            let thinking = resolveThinkingLevel(parsed.thinkingLevel, model: model)
            return (model, thinking, nil)
        }
        return (dependencies.defaultModel, dependencies.defaultThinkingLevel, "Unknown model: \(modelPattern)")
    }

    let thinking = resolveThinkingLevel(dependencies.defaultThinkingLevel, model: dependencies.defaultModel)
    return (dependencies.defaultModel, thinking, nil)
}

private func agentAuthPath(_ agentDir: String) -> String {
    URL(fileURLWithPath: agentDir).appendingPathComponent("auth.json").path
}

private func resolveTools(
    agent: SubagentConfig,
    cwd: String,
    dependencies: SubagentToolDependencies
) -> (tools: [AgentTool], selected: [ToolName], unknown: [String]) {
    let toolsOptions = ToolsOptions(read: ReadToolOptions(
        autoResizeImages: dependencies.settingsManager.getAutoResizeImages(),
        blockImages: dependencies.settingsManager.getBlockImages()
    ))
    var allTools = createAllTools(cwd: cwd, options: toolsOptions)
    if let _ = allTools[.subagent] {
        allTools[.subagent] = nil
    }

    let rawTools = agent.tools.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    let requested = rawTools.isEmpty ? ["read", "bash", "edit", "write"] : rawTools

    if requested.contains("all") {
        let selectedNames = Array(allTools.keys)
        let tools = selectedNames.compactMap { allTools[$0] }
        return (tools, selectedNames, [])
    }

    var resolved: [AgentTool] = []
    var selected: [ToolName] = []
    var unknown: [String] = []

    for name in requested {
        if name == "subagent" { continue }
        if let toolName = ToolName(rawValue: name), let tool = allTools[toolName] {
            resolved.append(tool)
            selected.append(toolName)
        } else {
            unknown.append(name)
        }
    }

    if resolved.isEmpty {
        let fallback = createCodingTools(cwd: cwd, options: toolsOptions).filter { $0.name != "subagent" }
        let fallbackNames = fallback.compactMap { ToolName(rawValue: $0.name) }
        return (fallback, fallbackNames, unknown)
    }

    return (resolved, selected, unknown)
}

private func isErrorResult(_ result: SubagentRunResult) -> Bool {
    if result.exitCode != 0 { return true }
    if let stopReason = result.stopReason, stopReason == StopReason.error.rawValue || stopReason == StopReason.aborted.rawValue {
        return true
    }
    return false
}

private func subagentResultDict(_ result: SubagentRunResult) -> [String: Any] {
    var dict: [String: Any] = [
        "agent": result.agent,
        "agentSource": result.agentSource,
        "task": result.task,
        "exitCode": result.exitCode,
        "output": result.output,
        "usage": [
            "input": result.usage.input,
            "output": result.usage.output,
            "cacheRead": result.usage.cacheRead,
            "cacheWrite": result.usage.cacheWrite,
            "totalTokens": result.usage.totalTokens,
            "cost": result.usage.cost,
            "turns": result.usage.turns,
        ],
    ]
    if let model = result.model {
        dict["model"] = model
    }
    if let stopReason = result.stopReason {
        dict["stopReason"] = stopReason
    }
    if let errorMessage = result.errorMessage {
        dict["errorMessage"] = errorMessage
    }
    if let step = result.step {
        dict["step"] = step
    }
    return dict
}

private func makeDetails(
    mode: String,
    scope: SubagentScope,
    projectAgentsDir: String?,
    results: [SubagentRunResult]
) -> AnyCodable {
    let details: [String: Any] = [
        "mode": mode,
        "agentScope": scope.rawValue,
        "projectAgentsDir": projectAgentsDir ?? NSNull(),
        "results": results.map { subagentResultDict($0) },
    ]
    return AnyCodable(details)
}

private func runSingleAgent(
    defaultCwd: String,
    agentName: String,
    agent: SubagentConfig?,
    task: String,
    cwd: String?,
    step: Int?,
    signal: CancellationToken?,
    dependencies: SubagentToolDependencies,
    onUpdate: (@Sendable (SubagentRunResult) -> Void)?
) async -> SubagentRunResult {
    guard let agent else {
        return SubagentRunResult(
            agent: agentName,
            agentSource: "unknown",
            task: task,
            exitCode: 1,
            output: "",
            usage: .empty,
            model: nil,
            stopReason: StopReason.error.rawValue,
            errorMessage: "Unknown agent: \(agentName)",
            step: step
        )
    }

    if signal?.isCancelled == true {
        return SubagentRunResult(
            agent: agent.name,
            agentSource: agent.sourceLabel,
            task: task,
            exitCode: 1,
            output: "",
            usage: .empty,
            model: nil,
            stopReason: StopReason.aborted.rawValue,
            errorMessage: "Subagent was aborted",
            step: step
        )
    }

    let effectiveCwd = cwd ?? defaultCwd
    let resolved = await resolveModel(agent: agent, dependencies: dependencies)
    if let error = resolved.error {
        return SubagentRunResult(
            agent: agent.name,
            agentSource: agent.sourceLabel,
            task: task,
            exitCode: 1,
            output: "",
            usage: .empty,
            model: resolved.model.id,
            stopReason: StopReason.error.rawValue,
            errorMessage: error,
            step: step
        )
    }

    let apiKey = await dependencies.modelRegistry.getApiKey(resolved.model.provider)
    if apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
        let message = AgentSessionError.missingApiKeyForProvider(provider: resolved.model.provider, authPath: agentAuthPath(dependencies.agentDir)).localizedDescription
        return SubagentRunResult(
            agent: agent.name,
            agentSource: agent.sourceLabel,
            task: task,
            exitCode: 1,
            output: "",
            usage: .empty,
            model: resolved.model.id,
            stopReason: StopReason.error.rawValue,
            errorMessage: message,
            step: step
        )
    }

    let toolResolution = resolveTools(agent: agent, cwd: effectiveCwd, dependencies: dependencies)
    let contextFiles = loadProjectContextFiles(LoadContextFilesOptions(cwd: effectiveCwd, agentDir: dependencies.agentDir))
    let skills = discoverSkills(cwd: effectiveCwd, agentDir: dependencies.agentDir, settings: dependencies.settingsManager.getSkillsSettings())

    var appendSections: [String] = []
    let trimmedPrompt = agent.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedPrompt.isEmpty {
        appendSections.append(trimmedPrompt)
    }
    if let outputFormat = agent.outputFormat, !outputFormat.isEmpty {
        appendSections.append("Output format:\n\(outputFormat)")
    }
    let appendPrompt = appendSections.joined(separator: "\n\n")

    let systemPrompt = buildSystemPrompt(BuildSystemPromptOptions(
        selectedTools: toolResolution.selected,
        appendSystemPrompt: appendPrompt.isEmpty ? nil : appendPrompt,
        cwd: effectiveCwd,
        agentDir: dependencies.agentDir,
        contextFiles: contextFiles,
        skills: skills
    ))

    let blockImages = dependencies.settingsManager.getBlockImages()
    let convertToLlmWithBlockImages: @Sendable ([AgentMessage]) -> [Message] = { messages in
        let converted = convertToLlm(messages)
        guard blockImages else { return converted }
        let filtered = filterImagesFromMessages(converted)
        if filtered.filtered > 0 {
            if let data = "[blockImages] Defense-in-depth: filtered \(filtered.filtered) image(s) at convertToLlm layer\n".data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
        }
        return filtered.messages
    }

    let agentInstance = Agent(AgentOptions(
        initialState: AgentState(
            systemPrompt: systemPrompt,
            model: resolved.model,
            thinkingLevel: resolved.thinking,
            tools: toolResolution.tools
        ),
        convertToLlm: { messages in
            convertToLlmWithBlockImages(messages)
        },
        thinkingBudgets: dependencies.settingsManager.getThinkingBudgets(),
        getApiKey: { provider in
            await dependencies.modelRegistry.getApiKey(provider)
        }
    ))

    let updateState = LockedState(SubagentRunResult(
        agent: agent.name,
        agentSource: agent.sourceLabel,
        task: task,
        exitCode: -1,
        output: "",
        usage: .empty,
        model: resolved.model.id,
        stopReason: nil,
        errorMessage: nil,
        step: step
    ))

    let unsubscribe = agentInstance.subscribe { event, _ in
        guard let onUpdate else { return }
        switch event {
        case .messageUpdate(let message, _), .messageEnd(let message):
            if case let .assistant(assistant) = message, let text = extractLastText(assistant.content) {
                var snapshot: SubagentRunResult?
                updateState.withLock { state in
                    state.output = text
                    snapshot = state
                }
                if let snapshot {
                    onUpdate(snapshot)
                }
            }
        default:
            break
        }
    }

    let cancelTask = Task {
        guard let signal else { return }
        while !signal.isCancelled && !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                break
            }
        }
        if signal.isCancelled {
            agentInstance.abort()
        }
    }

    var errorMessage: String? = nil
    do {
        try await agentInstance.prompt(AgentMessage.user(UserMessage(content: .text(task))))
    } catch {
        errorMessage = error.localizedDescription
    }

    cancelTask.cancel()
    unsubscribe()

    let messages = agentInstance.state.messages
    let output = finalOutput(from: messages)
    let usage = computeUsage(from: messages)
    let lastAssistant = messages.reversed().compactMap { message -> AssistantMessage? in
        if case let .assistant(assistant) = message { return assistant }
        return nil
    }.first

    let stopReason = lastAssistant?.stopReason.rawValue
    if errorMessage == nil, let messageError = lastAssistant?.errorMessage, !messageError.isEmpty {
        errorMessage = messageError
    }

    var exitCode = 0
    if errorMessage != nil || signal?.isCancelled == true {
        exitCode = 1
    } else if let stopReason, stopReason == StopReason.error.rawValue || stopReason == StopReason.aborted.rawValue {
        exitCode = 1
    }

    return SubagentRunResult(
        agent: agent.name,
        agentSource: agent.sourceLabel,
        task: task,
        exitCode: exitCode,
        output: output,
        usage: usage,
        model: resolved.model.id,
        stopReason: stopReason,
        errorMessage: errorMessage,
        step: step
    )
}

public func createSubagentTool(_ context: SubagentToolContext) -> AgentTool {
    let taskItemSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "agent": ["type": "string", "description": "Name of the agent to invoke"],
            "task": ["type": "string", "description": "Task to delegate to the agent"],
            "cwd": ["type": "string", "description": "Working directory for the agent"],
        ],
    ]

    let properties: [String: Any] = [
        "agent": ["type": "string", "description": "Name of the agent to invoke (single mode)"],
        "task": ["type": "string", "description": "Task to delegate (single mode)"],
        "tasks": ["type": "array", "items": taskItemSchema, "description": "Array of {agent, task} for parallel execution"],
        "chain": ["type": "array", "items": taskItemSchema, "description": "Array of {agent, task} for sequential execution"],
        "agentScope": ["type": "string", "description": "Which agent directories to use: user, project, both"],
        "cwd": ["type": "string", "description": "Working directory for the agent (single mode)"],
    ]

    let parameters: [String: AnyCodable] = [
        "type": AnyCodable("object"),
        "properties": AnyCodable(properties),
    ]

    @Sendable func executeSubagent(
        _ toolCallId: String,
        _ params: [String: AnyCodable],
        _ signal: CancellationToken?,
        _ onUpdate: AgentToolUpdateCallback?
    ) async throws -> AgentToolResult {
        _ = toolCallId
        guard let dependencies = context.get() else {
            throw SubagentToolError.missingDependencies
        }

        let scope = parseScope(params["agentScope"])
        let discovery = loadSubagents(LoadSubagentsOptions(cwd: dependencies.cwd, agentDir: dependencies.agentDir, scope: scope))
        let agents = discovery.agents

        let hasChain = params["chain"]?.value != nil
        let hasTasks = params["tasks"]?.value != nil
        let hasSingle = (stringValue(params["agent"])?.isEmpty == false) && (stringValue(params["task"])?.isEmpty == false)
        let modeCount = (hasChain ? 1 : 0) + (hasTasks ? 1 : 0) + (hasSingle ? 1 : 0)

        let availableAgents = agents.map { "\($0.name) (\($0.sourceLabel))" }.joined(separator: ", ")
        if modeCount != 1 {
            let message = "Invalid parameters. Provide exactly one mode.\nAvailable agents: \(availableAgents.isEmpty ? "none" : availableAgents)"
            let details = makeDetails(mode: "single", scope: scope, projectAgentsDir: discovery.projectAgentsDir, results: [])
            return AgentToolResult(content: [.text(TextContent(text: message))], details: details)
        }

        if let chainRaw = params["chain"]?.value {
            let chain = decodeTasks(chainRaw)
            if chain.isEmpty {
                let message = "Invalid parameters. Chain requires at least one step."
                let details = makeDetails(mode: "chain", scope: scope, projectAgentsDir: discovery.projectAgentsDir, results: [])
                return AgentToolResult(content: [.text(TextContent(text: message))], details: details)
            }

            var results: [SubagentRunResult] = []
            let chainState = LockedState<[SubagentRunResult]>([])
            var previousOutput = ""
            for (index, step) in chain.enumerated() {
                chainState.withLock { state in
                    state = results
                }
                let taskText = step.task.replacingOccurrences(of: "{previous}", with: previousOutput)
                let agentConfig = agents.first { $0.name == step.agent }
                let updateHandler: (@Sendable (SubagentRunResult) -> Void)?
                if let callback = onUpdate {
                    updateHandler = { partial in
                        let combined = chainState.withLock { state in
                            var snapshot = state
                            snapshot.append(partial)
                            return snapshot
                        }
                        let details = makeDetails(mode: "chain", scope: scope, projectAgentsDir: discovery.projectAgentsDir, results: combined)
                        callback(AgentToolResult(content: [.text(TextContent(text: partial.output.isEmpty ? "(running...)" : partial.output))], details: details))
                    }
                } else {
                    updateHandler = nil
                }
                let result: SubagentRunResult = await runSingleAgent(
                    defaultCwd: dependencies.cwd,
                    agentName: step.agent,
                    agent: agentConfig,
                    task: taskText,
                    cwd: step.cwd,
                    step: index + 1,
                    signal: signal,
                    dependencies: dependencies,
                    onUpdate: updateHandler
                )
                results.append(result)
                chainState.withLock { state in
                    state = results
                }
                if isErrorResult(result) {
                    let errorText = result.errorMessage ?? result.output
                    let message = "Chain stopped at step \(index + 1) (\(result.agent)): \(errorText.isEmpty ? "(no output)" : errorText)"
                    let details = makeDetails(mode: "chain", scope: scope, projectAgentsDir: discovery.projectAgentsDir, results: results)
                    return AgentToolResult(content: [.text(TextContent(text: message))], details: details)
                }
                previousOutput = result.output
            }

            let finalOutput = results.last?.output ?? ""
            let details = makeDetails(mode: "chain", scope: scope, projectAgentsDir: discovery.projectAgentsDir, results: results)
            return AgentToolResult(content: [.text(TextContent(text: finalOutput.isEmpty ? "(no output)" : finalOutput))], details: details)
        }

        if let tasksRaw = params["tasks"]?.value {
            let tasks = decodeTasks(tasksRaw)
            if tasks.isEmpty {
                let message = "Invalid parameters. Tasks requires at least one entry."
                let details = makeDetails(mode: "parallel", scope: scope, projectAgentsDir: discovery.projectAgentsDir, results: [])
                return AgentToolResult(content: [.text(TextContent(text: message))], details: details)
            }
            if tasks.count > maxParallelTasks {
                let message = "Too many parallel tasks (\(tasks.count)). Max is \(maxParallelTasks)."
                let details = makeDetails(mode: "parallel", scope: scope, projectAgentsDir: discovery.projectAgentsDir, results: [])
                return AgentToolResult(content: [.text(TextContent(text: message))], details: details)
            }

            let placeholder = tasks.enumerated().map { index, task in
                SubagentRunResult(
                    agent: task.agent,
                    agentSource: "unknown",
                    task: task.task,
                    exitCode: -1,
                    output: "",
                    usage: .empty,
                    model: nil,
                    stopReason: nil,
                    errorMessage: nil,
                    step: index + 1
                )
            }

            let resultsState = LockedState(placeholder)
            let emitParallelUpdate: @Sendable () -> Void = {
                guard let onUpdate else { return }
                let snapshot = resultsState.withLock { $0 }
                let running = snapshot.filter { $0.exitCode == -1 }.count
                let done = snapshot.count - running
                let details = makeDetails(mode: "parallel", scope: scope, projectAgentsDir: discovery.projectAgentsDir, results: snapshot)
                let message = "Parallel: \(done)/\(snapshot.count) done, \(running) running..."
                onUpdate(AgentToolResult(content: [.text(TextContent(text: message))], details: details))
            }

            let limit = max(1, min(maxConcurrency, tasks.count))
            var results = Array(repeating: SubagentRunResult(
                agent: "",
                agentSource: "",
                task: "",
                exitCode: -1,
                output: "",
                usage: .empty,
                model: nil,
                stopReason: nil,
                errorMessage: nil,
                step: nil
            ), count: tasks.count)

            var nextIndex = 0
            await withTaskGroup(of: (Int, SubagentRunResult).self, returning: Void.self) { group in
                for _ in 0..<limit {
                    guard nextIndex < tasks.count else { break }
                    let current = nextIndex
                    nextIndex += 1
                    let task = tasks[current]
                    group.addTask {
                        let agentConfig = agents.first { $0.name == task.agent }
                        let updateHandler: (@Sendable (SubagentRunResult) -> Void)?
                        if onUpdate != nil {
                            updateHandler = { partial in
                                resultsState.withLock { state in
                                    state[current] = partial
                                }
                                emitParallelUpdate()
                            }
                        } else {
                            updateHandler = nil
                        }
                        let result: SubagentRunResult = await runSingleAgent(
                            defaultCwd: dependencies.cwd,
                            agentName: task.agent,
                            agent: agentConfig,
                            task: task.task,
                            cwd: task.cwd,
                            step: current + 1,
                            signal: signal,
                            dependencies: dependencies,
                            onUpdate: updateHandler
                        )
                        return (current, result)
                    }
                }

                while let (index, result) = await group.next() {
                    results[index] = result
                    resultsState.withLock { state in
                        state[index] = result
                    }
                    emitParallelUpdate()

                    if nextIndex < tasks.count {
                        let current = nextIndex
                        nextIndex += 1
                        let task = tasks[current]
                        group.addTask {
                            let agentConfig = agents.first { $0.name == task.agent }
                            let updateHandler: (@Sendable (SubagentRunResult) -> Void)?
                            if onUpdate != nil {
                                updateHandler = { partial in
                                    resultsState.withLock { state in
                                        state[current] = partial
                                    }
                                    emitParallelUpdate()
                                }
                            } else {
                                updateHandler = nil
                            }
                            let result: SubagentRunResult = await runSingleAgent(
                                defaultCwd: dependencies.cwd,
                                agentName: task.agent,
                                agent: agentConfig,
                                task: task.task,
                                cwd: task.cwd,
                                step: current + 1,
                                signal: signal,
                                dependencies: dependencies,
                                onUpdate: updateHandler
                            )
                            return (current, result)
                        }
                    }
                }
            }

            let successCount = results.filter { $0.exitCode == 0 }.count
            let summaries = results.map { result -> String in
                let preview = result.output.prefix(100)
                let suffix = result.output.count > 100 ? "..." : ""
                let status = result.exitCode == 0 ? "completed" : "failed"
                let output = preview.isEmpty ? "(no output)" : "\(preview)\(suffix)"
                return "[\(result.agent)] \(status): \(output)"
            }

            let message = "Parallel: \(successCount)/\(results.count) succeeded\n\n" + summaries.joined(separator: "\n\n")
            let details = makeDetails(mode: "parallel", scope: scope, projectAgentsDir: discovery.projectAgentsDir, results: results)
            return AgentToolResult(content: [.text(TextContent(text: message))], details: details)
        }

        if hasSingle {
            let agentName = stringValue(params["agent"]) ?? ""
            let task = stringValue(params["task"]) ?? ""
            let cwd = stringValue(params["cwd"])
            let agentConfig = agents.first { $0.name == agentName }
            let updateHandler: (@Sendable (SubagentRunResult) -> Void)?
            if let callback = onUpdate {
                updateHandler = { partial in
                    let details = makeDetails(mode: "single", scope: scope, projectAgentsDir: discovery.projectAgentsDir, results: [partial])
                    callback(AgentToolResult(content: [.text(TextContent(text: partial.output.isEmpty ? "(running...)" : partial.output))], details: details))
                }
            } else {
                updateHandler = nil
            }
            let result: SubagentRunResult = await runSingleAgent(
                defaultCwd: dependencies.cwd,
                agentName: agentName,
                agent: agentConfig,
                task: task,
                cwd: cwd,
                step: nil,
                signal: signal,
                dependencies: dependencies,
                onUpdate: updateHandler
            )

            let details = makeDetails(mode: "single", scope: scope, projectAgentsDir: discovery.projectAgentsDir, results: [result])
            if isErrorResult(result) {
                let errorText = result.errorMessage ?? result.output
                let message = "Agent failed: \(errorText.isEmpty ? "(no output)" : errorText)"
                return AgentToolResult(content: [.text(TextContent(text: message))], details: details)
            }

            let output = result.output.isEmpty ? "(no output)" : result.output
            return AgentToolResult(content: [.text(TextContent(text: output))], details: details)
        }

        let message = "Invalid parameters. Available agents: \(availableAgents.isEmpty ? "none" : availableAgents)"
        let details = makeDetails(mode: "single", scope: scope, projectAgentsDir: discovery.projectAgentsDir, results: [])
        return AgentToolResult(content: [.text(TextContent(text: message))], details: details)
    }

    return AgentTool(
        label: "subagent",
        name: "subagent",
        description: "Delegate tasks to specialized subagents with isolated context. Modes: single (agent + task), parallel (tasks array), chain (sequential with {previous} placeholder).",
        parameters: parameters,
        execute: executeSubagent
    )
}
