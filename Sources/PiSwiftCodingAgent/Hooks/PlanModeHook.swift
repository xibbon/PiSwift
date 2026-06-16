import Foundation
import PiSwiftAgent

private let planModeTools = ["read", "bash", "grep", "find", "ls"]
private let normalModeTools = ["read", "bash", "edit", "write"]

private let destructivePatterns: [NSRegularExpression] = [
    regex(#"\brm\b"#, [.caseInsensitive]),
    regex(#"\brmdir\b"#, [.caseInsensitive]),
    regex(#"\bmv\b"#, [.caseInsensitive]),
    regex(#"\bcp\b"#, [.caseInsensitive]),
    regex(#"\bmkdir\b"#, [.caseInsensitive]),
    regex(#"\btouch\b"#, [.caseInsensitive]),
    regex(#"\bchmod\b"#, [.caseInsensitive]),
    regex(#"\bchown\b"#, [.caseInsensitive]),
    regex(#"\bchgrp\b"#, [.caseInsensitive]),
    regex(#"\bln\b"#, [.caseInsensitive]),
    regex(#"\btee\b"#, [.caseInsensitive]),
    regex(#"\btruncate\b"#, [.caseInsensitive]),
    regex(#"\bdd\b"#, [.caseInsensitive]),
    regex(#"\bshred\b"#, [.caseInsensitive]),
    regex(#"[^<]>(?!>)"#),
    regex(#">>"#),
    regex(#"\bnpm\s+(install|uninstall|update|ci|link|publish)"#, [.caseInsensitive]),
    regex(#"\byarn\s+(add|remove|install|publish)"#, [.caseInsensitive]),
    regex(#"\bpnpm\s+(add|remove|install|publish)"#, [.caseInsensitive]),
    regex(#"\bpip\s+(install|uninstall)"#, [.caseInsensitive]),
    regex(#"\bapt(-get)?\s+(install|remove|purge|update|upgrade)"#, [.caseInsensitive]),
    regex(#"\bbrew\s+(install|uninstall|upgrade)"#, [.caseInsensitive]),
    regex(#"\bgit\s+(add|commit|push|pull|merge|rebase|reset|checkout\s+-b|branch\s+-[dD]|stash|cherry-pick|revert|tag|init|clone)"#, [.caseInsensitive]),
    regex(#"\bsudo\b"#, [.caseInsensitive]),
    regex(#"\bsu\b"#, [.caseInsensitive]),
    regex(#"\bkill\b"#, [.caseInsensitive]),
    regex(#"\bpkill\b"#, [.caseInsensitive]),
    regex(#"\bkillall\b"#, [.caseInsensitive]),
    regex(#"\breboot\b"#, [.caseInsensitive]),
    regex(#"\bshutdown\b"#, [.caseInsensitive]),
    regex(#"\bsystemctl\s+(start|stop|restart|enable|disable)"#, [.caseInsensitive]),
    regex(#"\bservice\s+\S+\s+(start|stop|restart)"#, [.caseInsensitive]),
    regex(#"\b(vim?|nano|emacs|code|subl)\b"#, [.caseInsensitive]),
]

private let safeCommandPatterns: [NSRegularExpression] = [
    regex(#"^\s*cat\b"#),
    regex(#"^\s*head\b"#),
    regex(#"^\s*tail\b"#),
    regex(#"^\s*less\b"#),
    regex(#"^\s*more\b"#),
    regex(#"^\s*grep\b"#),
    regex(#"^\s*find\b"#),
    regex(#"^\s*ls\b"#),
    regex(#"^\s*pwd\b"#),
    regex(#"^\s*echo\b"#),
    regex(#"^\s*printf\b"#),
    regex(#"^\s*wc\b"#),
    regex(#"^\s*sort\b"#),
    regex(#"^\s*uniq\b"#),
    regex(#"^\s*diff\b"#),
    regex(#"^\s*file\b"#),
    regex(#"^\s*stat\b"#),
    regex(#"^\s*du\b"#),
    regex(#"^\s*df\b"#),
    regex(#"^\s*tree\b"#),
    regex(#"^\s*which\b"#),
    regex(#"^\s*whereis\b"#),
    regex(#"^\s*type\b"#),
    regex(#"^\s*env\b"#),
    regex(#"^\s*printenv\b"#),
    regex(#"^\s*uname\b"#),
    regex(#"^\s*whoami\b"#),
    regex(#"^\s*id\b"#),
    regex(#"^\s*date\b"#),
    regex(#"^\s*cal\b"#),
    regex(#"^\s*uptime\b"#),
    regex(#"^\s*ps\b"#),
    regex(#"^\s*top\b"#),
    regex(#"^\s*htop\b"#),
    regex(#"^\s*free\b"#),
    regex(#"^\s*git\s+(status|log|diff|show|branch|remote|config\s+--get)"#, [.caseInsensitive]),
    regex(#"^\s*git\s+ls-"#, [.caseInsensitive]),
    regex(#"^\s*npm\s+(list|ls|view|info|search|outdated|audit)"#, [.caseInsensitive]),
    regex(#"^\s*yarn\s+(list|info|why|audit)"#, [.caseInsensitive]),
    regex(#"^\s*node\s+--version"#, [.caseInsensitive]),
    regex(#"^\s*python\s+--version"#, [.caseInsensitive]),
    regex(#"^\s*curl\s"#),
    regex(#"^\s*wget\s+-O\s*-"#, [.caseInsensitive]),
    regex(#"^\s*jq\b"#),
    regex(#"^\s*sed\s+-n"#, [.caseInsensitive]),
    regex(#"^\s*awk\b"#),
    regex(#"^\s*rg\b"#),
    regex(#"^\s*fd\b"#),
    regex(#"^\s*bat\b"#),
    regex(#"^\s*exa\b"#),
]

/// A todo item extracted from a plan
struct TodoItem: Sendable {
    var step: Int
    var text: String
    var completed: Bool

    var data: [String: Any] {
        ["step": step, "text": text, "completed": completed]
    }

    init(step: Int, text: String, completed: Bool) {
        self.step = step
        self.text = text
        self.completed = completed
    }

    init?(data: [String: Any]) {
        guard let step = data["step"] as? Int,
              let text = data["text"] as? String,
              let completed = data["completed"] as? Bool else {
            return nil
        }
        self.step = step
        self.text = text
        self.completed = completed
    }
}

private struct PlanModeSnapshot: Sendable {
    var planModeEnabled: Bool
    var toolsCalledThisTurn: Bool
    var executionMode: Bool
    var todoItems: [TodoItem]
}

private actor PlanModeState {
    private var planModeEnabled = false
    private var toolsCalledThisTurn = false
    private var executionMode = false
    private var todoItems: [TodoItem] = []

    func snapshot() -> PlanModeSnapshot {
        PlanModeSnapshot(
            planModeEnabled: planModeEnabled,
            toolsCalledThisTurn: toolsCalledThisTurn,
            executionMode: executionMode,
            todoItems: todoItems
        )
    }

    func togglePlanMode() {
        planModeEnabled.toggle()
        executionMode = false
        todoItems = []
    }

    func setPlanModeEnabled(_ enabled: Bool) {
        planModeEnabled = enabled
    }

    func setExecutionMode(_ enabled: Bool) {
        executionMode = enabled
    }

    func setToolsCalledThisTurn(_ value: Bool) {
        toolsCalledThisTurn = value
    }

    func setTodos(_ items: [TodoItem]) {
        todoItems = items
    }

    func markNextTodoCompleted() -> Bool {
        guard let index = todoItems.firstIndex(where: { !$0.completed }) else { return false }
        todoItems[index].completed = true
        return true
    }

    func markNextTodoCompletedIfNoTools() -> Bool {
        guard !toolsCalledThisTurn else { return false }
        return markNextTodoCompleted()
    }
}

private func renderStatus(_ ctx: HookContext, snapshot: PlanModeSnapshot) async {
    guard ctx.hasUI else { return }
    await MainActor.run {
        if snapshot.executionMode && !snapshot.todoItems.isEmpty {
            let completed = snapshot.todoItems.filter { $0.completed }.count
            ctx.ui.setStatus("plan-mode", ctx.ui.theme.fg(.accent, "plan \(completed)/\(snapshot.todoItems.count)"))
        } else if snapshot.planModeEnabled {
            ctx.ui.setStatus("plan-mode", ctx.ui.theme.fg(.warning, "plan"))
        } else {
            ctx.ui.setStatus("plan-mode", nil)
        }

        if snapshot.executionMode && !snapshot.todoItems.isEmpty {
            var lines: [String] = []
            for item in snapshot.todoItems {
                if item.completed {
                    lines.append(
                        ctx.ui.theme.fg(.success, "[x] ")
                            + ctx.ui.theme.fg(.muted, ctx.ui.theme.strikethrough(item.text))
                    )
                } else {
                    lines.append(ctx.ui.theme.fg(.muted, "[ ] ") + item.text)
                }
            }
            ctx.ui.setWidget("plan-todos", lines)
        } else {
            ctx.ui.setWidget("plan-todos", nil)
        }
    }
}

private func hookContext(from ctx: HookCommandContext) -> HookContext {
    HookContext(
        ui: ctx.ui,
        mode: ctx.mode,
        hasUI: ctx.hasUI,
        cwd: ctx.cwd,
        sessionManager: ctx.sessionManager,
        modelRegistry: ctx.modelRegistry,
        model: { ctx.model },
        systemPrompt: { ctx.getSystemPrompt() },
        isProjectTrusted: { ctx.isProjectTrusted() },
        systemPromptOptions: { ctx.getSystemPromptOptions() },
        isIdle: ctx.isIdle,
        abort: ctx.abort,
        hasPendingMessages: ctx.hasPendingMessages
    )
}

public final class PlanModeHookPlugin: HookPlugin {
    public init() {}

    public func register(_ api: HookAPI) {
        registerPlanModeHook(api)
    }
}

public func planModeHookDefinition(path: String? = "plan-mode") -> HookDefinition {
    HookDefinition(path: path, factory: registerPlanModeHook)
}

public func registerPlanModeHook(_ pi: HookAPI) {
    let state = PlanModeState()

    pi.registerFlag("plan", HookFlagOptions(
        description: "Start in plan mode (read-only exploration)",
        type: .boolean,
        defaultValue: .bool(false)
    ))

    let updateStatus: @Sendable (HookContext) async -> Void = { ctx in
        let snapshot = await state.snapshot()
        await renderStatus(ctx, snapshot: snapshot)
    }

    let togglePlanMode: @Sendable (HookContext) async -> Void = { ctx in
        await state.togglePlanMode()
        let snapshot = await state.snapshot()

        if snapshot.planModeEnabled {
            pi.setActiveTools(planModeTools)
            await MainActor.run {
                ctx.ui.notify("Plan mode enabled. Tools: \(planModeTools.joined(separator: ", "))", nil)
            }
        } else {
            pi.setActiveTools(normalModeTools)
            await MainActor.run {
                ctx.ui.notify("Plan mode disabled. Full access restored.", nil)
            }
        }

        await renderStatus(ctx, snapshot: snapshot)
    }

    pi.registerCommand("plan", description: "Toggle plan mode (read-only exploration)") { _, ctx in
        await togglePlanMode(hookContext(from: ctx))
    }

    pi.registerCommand("todos", description: "Show current plan todo list") { _, ctx in
        let snapshot = await state.snapshot()
        if snapshot.todoItems.isEmpty {
            await MainActor.run {
                ctx.ui.notify("No todos. Create a plan first with /plan", .info)
            }
            return
        }

        let todoList = snapshot.todoItems.enumerated().map { idx, item in
            let checkbox = item.completed ? "x" : " "
            return "\(idx + 1). \(checkbox) \(item.text)"
        }.joined(separator: "\n")

        await MainActor.run {
            ctx.ui.notify("Plan Progress:\n\(todoList)", .info)
        }
    }

    pi.registerShortcut(Key.shift("p"), description: "Toggle plan mode") { ctx in
        await togglePlanMode(ctx)
    }

    pi.on("tool_call") { (event: ToolCallEvent, _ctx) in
        let snapshot = await state.snapshot()
        guard snapshot.planModeEnabled else { return nil }
        guard event.toolName == "bash" else { return nil }
        let command = (event.input["command"]?.value as? String) ?? ""
        if !isSafeCommand(command) {
            return ToolCallEventResult(
                block: true,
                reason: "Plan mode: destructive command blocked. Use /plan to disable plan mode first.\nCommand: \(command)"
            )
        }
        return nil
    }

    pi.on("tool_result") { (_event: ToolResultEvent, ctx) in
        await state.setToolsCalledThisTurn(true)
        let snapshot = await state.snapshot()
        guard snapshot.executionMode, !snapshot.todoItems.isEmpty else { return nil }
        if await state.markNextTodoCompleted() {
            await updateStatus(ctx)
        }
        return nil
    }

    pi.on("context") { (event: ContextEvent, _ctx) in
        let snapshot = await state.snapshot()
        guard !snapshot.planModeEnabled else { return nil }
        let filtered = event.messages.filter { message in
            guard case .custom(let custom) = message, custom.role == "hookMessage" else {
                return true
            }
            guard let payload = custom.payload?.value as? [String: Any] else {
                return true
            }
            if let customType = payload["customType"] as? String, customType == "plan-mode-context" {
                return false
            }
            if let content = payload["content"] as? String, content.contains("[PLAN MODE ACTIVE]") {
                return false
            }
            return true
        }
        return ContextEventResult(messages: filtered)
    }

    pi.on("before_agent_start") { (_event: BeforeAgentStartEvent, _ctx) in
        let snapshot = await state.snapshot()
        if !snapshot.planModeEnabled && !snapshot.executionMode {
            return nil
        }

        if snapshot.planModeEnabled {
            return BeforeAgentStartEventResult(message: HookMessageInput(
                customType: "plan-mode-context",
                content: .text("""
[PLAN MODE ACTIVE]
You are in plan mode - a read-only exploration mode for safe code analysis.

Restrictions:
- You can only use: read, bash, grep, find, ls
- You CANNOT use: edit, write (file modifications are disabled)
- Bash is restricted to READ-ONLY commands
- Focus on analysis, planning, and understanding the codebase

Create a detailed numbered plan:
1. First step description
2. Second step description
...

Do NOT attempt to make changes - just describe what you would do.
"""),
                display: false
            ))
        }

        if snapshot.executionMode && !snapshot.todoItems.isEmpty {
            let remaining = snapshot.todoItems.filter { !$0.completed }
            let todoList = remaining.map { "\($0.step). \($0.text)" }.joined(separator: "\n")
            return BeforeAgentStartEventResult(message: HookMessageInput(
                customType: "plan-execution-context",
                content: .text("""
[EXECUTING PLAN - Full tool access enabled]

Remaining steps:
\(todoList)

Execute each step in order.
"""),
                display: false
            ))
        }

        return nil
    }

    pi.on("agent_end") { (event: AgentEndEvent, ctx) in
        let snapshot = await state.snapshot()
        if snapshot.executionMode && !snapshot.todoItems.isEmpty {
            let allComplete = snapshot.todoItems.allSatisfy { $0.completed }
            if allComplete {
                let completedList = snapshot.todoItems.map { "~~\($0.text)~~" }.joined(separator: "\n")
                pi.sendMessage(HookMessageInput(
                    customType: "plan-complete",
                    content: .text("**Plan Complete!**\n\n\(completedList)"),
                    display: true
                ), options: HookSendMessageOptions(triggerTurn: false))

                await state.setExecutionMode(false)
                await state.setTodos([])
                pi.setActiveTools(normalModeTools)
                await updateStatus(ctx)
            }
            return nil
        }

        guard snapshot.planModeEnabled, ctx.hasUI else { return nil }

        if let lastAssistantText = extractLastAssistantText(from: event.messages) {
            let extracted = extractTodoItems(lastAssistantText)
            if !extracted.isEmpty {
                await state.setTodos(extracted)
            }
        }

        let refreshed = await state.snapshot()
        let hasTodos = !refreshed.todoItems.isEmpty
        if hasTodos {
            let todoList = refreshed.todoItems.enumerated().map { idx, item in
                "\(idx + 1). [ ] \(item.text)"
            }.joined(separator: "\n")
            pi.sendMessage(HookMessageInput(
                customType: "plan-todo-list",
                content: .text("**Plan Steps (\(refreshed.todoItems.count)):**\n\n\(todoList)"),
                display: true
            ), options: HookSendMessageOptions(triggerTurn: false))
        }

        let choice = await ctx.ui.select("Plan mode - what next?", [
            hasTodos ? "Execute the plan (track progress)" : "Execute the plan",
            "Stay in plan mode",
            "Refine the plan",
        ])

        if let choice, choice.hasPrefix("Execute") {
            await state.setPlanModeEnabled(false)
            await state.setExecutionMode(hasTodos)
            pi.setActiveTools(normalModeTools)
            await updateStatus(ctx)

            let execMessage = hasTodos
                ? "Execute the plan. Start with: \(refreshed.todoItems[0].text)"
                : "Execute the plan you just created."

            pi.sendMessage(HookMessageInput(
                customType: "plan-mode-execute",
                content: .text(execMessage),
                display: true
            ), options: HookSendMessageOptions(triggerTurn: true))
        } else if choice == "Refine the plan" {
            if let refinement = await ctx.ui.input("What should be refined?", nil) {
                await MainActor.run {
                    ctx.ui.setEditorText(refinement)
                }
            }
        }

        return nil
    }

    pi.on("session_start") { (_event: SessionStartEvent, ctx) in
        if pi.getFlag("plan")?.boolValue == true {
            await state.setPlanModeEnabled(true)
        }

        let entries = ctx.sessionManager.getEntries()
        if let lastEntry = entries.reversed().compactMap({ entry -> CustomEntry? in
            guard case .custom(let custom) = entry, custom.customType == "plan-mode" else { return nil }
            return custom
        }).first,
           let data = lastEntry.data?.value as? [String: Any] {
            if let enabled = data["enabled"] as? Bool {
                await state.setPlanModeEnabled(enabled)
            }
            if let executing = data["executing"] as? Bool {
                await state.setExecutionMode(executing)
            }
            if let todosData = data["todos"] as? [Any] {
                let parsed = todosData.compactMap { item -> TodoItem? in
                    guard let dict = item as? [String: Any] else { return nil }
                    return TodoItem(data: dict)
                }
                if !parsed.isEmpty {
                    await state.setTodos(parsed)
                }
            }
        }

        let refreshed = await state.snapshot()
        if refreshed.planModeEnabled {
            pi.setActiveTools(planModeTools)
        }
        await updateStatus(ctx)
        return nil
    }

    pi.on("turn_start") { (_event: TurnStartEvent, _ctx) in
        await state.setToolsCalledThisTurn(false)
        let snapshot = await state.snapshot()
        pi.appendEntry("plan-mode", [
            "enabled": snapshot.planModeEnabled,
            "todos": snapshot.todoItems.map { $0.data },
            "executing": snapshot.executionMode,
        ])
        return nil
    }

    pi.on("turn_end") { (_event: TurnEndEvent, ctx) in
        let snapshot = await state.snapshot()
        guard snapshot.executionMode, !snapshot.todoItems.isEmpty else { return nil }
        if await state.markNextTodoCompletedIfNoTools() {
            await updateStatus(ctx)
        }
        return nil
    }
}

private func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
    return try! NSRegularExpression(pattern: pattern, options: options)
}

private func matchesAny(_ regexes: [NSRegularExpression], _ text: String) -> Bool {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regexes.contains { $0.firstMatch(in: text, range: range) != nil }
}

/// Checks if a command is safe to run in plan mode (read-only)
func isSafeCommand(_ command: String) -> Bool {
    if matchesAny(safeCommandPatterns, command) && !matchesAny(destructivePatterns, command) {
        return true
    }
    if matchesAny(destructivePatterns, command) {
        return false
    }
    return true
}

/// Cleans step text by removing markdown, action words, and truncating
func cleanStepText(_ text: String) -> String {
    var cleaned = text
    cleaned = regexReplace(#"\*{1,2}([^*]+)\*{1,2}"#, in: cleaned, with: "$1")
    cleaned = regexReplace(#"`([^`]+)`"#, in: cleaned, with: "$1")
    cleaned = regexReplace(
        #"^(Use|Run|Execute|Create|Write|Read|Check|Verify|Update|Modify|Add|Remove|Delete|Install)\s+(the\s+)?"#,
        in: cleaned,
        with: "",
        options: [.caseInsensitive]
    )
    cleaned = regexReplace(#"\s+"#, in: cleaned, with: " ")
    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

    if let first = cleaned.first {
        cleaned = String(first).uppercased() + cleaned.dropFirst()
    }

    if cleaned.count > 50 {
        let end = cleaned.index(cleaned.startIndex, offsetBy: 47)
        cleaned = String(cleaned[..<end]) + "..."
    }

    return cleaned
}

/// Extracts todo items from a plan message
func extractTodoItems(_ message: String) -> [TodoItem] {
    var items: [TodoItem] = []

    let numberedRegex = regex(#"^\s*(\d+)[.)]\s+\*{0,2}([^*\n]+)"#, [.anchorsMatchLines])
    let matches = numberedRegex.matches(in: message, range: NSRange(message.startIndex..<message.endIndex, in: message))
    for match in matches {
        guard let textRange = Range(match.range(at: 2), in: message) else { continue }
        var text = String(message[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        text = regexReplace(#"\*{1,2}$"#, in: text, with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 5, !text.hasPrefix("`"), !text.hasPrefix("/"), !text.hasPrefix("-") {
            let cleaned = cleanStepText(text)
            if cleaned.count > 3 {
                items.append(TodoItem(step: items.count + 1, text: cleaned, completed: false))
            }
        }
    }

    if items.isEmpty {
        let bulletRegex = regex(#"^\s*[-*]\s*(?:Step\s*\d+[:.])?\s*\*{0,2}([^*\n]+)"#, [.anchorsMatchLines, .caseInsensitive])
        let bulletMatches = bulletRegex.matches(in: message, range: NSRange(message.startIndex..<message.endIndex, in: message))
        for match in bulletMatches {
            guard let textRange = Range(match.range(at: 1), in: message) else { continue }
            var text = String(message[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            text = regexReplace(#"\*{1,2}$"#, in: text, with: "")
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > 10, !text.hasPrefix("`") {
                let cleaned = cleanStepText(text)
                if cleaned.count > 3 {
                    items.append(TodoItem(step: items.count + 1, text: cleaned, completed: false))
                }
            }
        }
    }

    return items
}

/// Extracts step numbers from [DONE:N] markers in a message
func extractDoneSteps(_ message: String) -> [Int] {
    let pattern = #"\[done:(\d+)\]"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return []
    }
    let range = NSRange(message.startIndex..<message.endIndex, in: message)
    let matches = regex.matches(in: message, range: range)
    return matches.compactMap { match -> Int? in
        guard let numRange = Range(match.range(at: 1), in: message) else { return nil }
        return Int(message[numRange])
    }
}

/// Marks todo items as completed based on [DONE:N] markers in a message
/// Returns the count of markers found (not the count of items marked)
func markCompletedSteps(_ message: String, _ items: inout [TodoItem]) -> Int {
    let doneSteps = extractDoneSteps(message)
    for step in doneSteps {
        if let index = items.firstIndex(where: { $0.step == step }) {
            items[index].completed = true
        }
    }
    return doneSteps.count
}

private func extractLastAssistantText(from messages: [AgentMessage]) -> String? {
    for message in messages.reversed() {
        if case .assistant(let assistant) = message {
            let text = assistant.content.compactMap { block -> String? in
                if case .text(let content) = block { return content.text }
                return nil
            }.joined(separator: "\n")
            if !text.isEmpty {
                return text
            }
            return nil
        }
    }
    return nil
}

private func regexReplace(_ pattern: String, in text: String, with replacement: String, options: NSRegularExpression.Options = []) -> String {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
        return text
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return expression.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
}
