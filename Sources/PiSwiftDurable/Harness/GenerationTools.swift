import PiSwiftAI
import PiSwiftChord

public struct GenerationToolInput: Codable, Sendable {
    public var assistant: EntryID
    public var callId: String
    public init(assistant: EntryID, callId: String) { self.assistant = assistant; self.callId = callId }
}
/// H7 will supply the handler for this source-compatible initial record.
let generationToolKind = TaskKind<GenerationToolInput, JSONObject>(name: "pi.tool", version: 1, initial: { _ in ["phase": .string("call")] })
func createGenerationTool(tx: Transaction, runtime: TaskRuntime, assistant: EntryID, callId: String) async throws -> TaskID {
    try await tx.createTask(generationToolKind, input: GenerationToolInput(assistant: assistant, callId: callId),
                           options: .init(ownership: .task(taskId: runtime.taskId)))
}
func generationCalls(runtime: TaskRuntime, assistant: EntryID, callIds: [String], context: PiSwiftChord.Context) async throws -> [ToolCall] {
    guard let entry = try await runtime.entry(assistant, context: context), case .assistant(let message) = try entry.messages()?.first else { return [] }
    let calls = message.content.compactMap { block -> ToolCall? in if case .toolCall(let call) = block { return call }; return nil }
    return callIds.compactMap { id in calls.first { harnessNamesEqual($0.id, id) } }
}
func appendGenerationToolError(tx: Transaction, conversationId: ConversationID, call: ToolCall, code: String, text: String, now: Int64) async throws -> EntryRecord {
    let diagnostics = [ToolDiagnostic(severity: .error, message: text, code: code)]
    let message = ToolResultMessage(toolCallId: call.id, toolName: call.name,
        content: [.text(TextContent(text: "<harness>\n[error] \(text)\n</harness>"))], isError: true, timestamp: now)
    return try await tx.appendEntry(conversationId, value: EntryDraft(kind: toolResultEntry.kind,
        model: EntryRecord.encodeMessages([.toolResult(message)]), data: JSONValue(encoding: ToolResultEntryData(diagnostics: diagnostics))))
}
func startGenerationToolRound(runtime: TaskRuntime, request: GenerationCheckpoint, message: AssistantMessage, calls: [ToolCall],
                              messages: [Message]?, context: PiSwiftChord.Context) async throws {
    let offeredMessages: [Message]
    if let messages { offeredMessages = messages }
    else { offeredMessages = try await runtime.context(runtime.conversationId, at: request.cutoff, context: context).messages }
    let offered = Set(getCurrentTools(offeredMessages).map { Array($0.name.utf16) })
    let registrations = try await runtime.agent(context: context).tools
    let sequential = runtime.settings.toolExecution == .sequential || calls.contains { call in
        offered.contains(Array(call.name.utf16)) && registrations.first { harnessNamesEqual($0.name, call.name) }?.executionMode == .sequential
    }
    try await runtime.commit({ tx, _ in
        let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
        let entry = try await appendGenerationAssistant(tx: tx, conversationId: runtime.conversationId, message: message)
        var slots: [ToolSlot] = [], tools: [TaskID] = [], pending: [String] = []
        for call in calls {
            if !offered.contains(Array(call.name.utf16)) {
                let result = try await appendGenerationToolError(tx: tx, conversationId: runtime.conversationId, call: call,
                    code: "tool_unavailable", text: "Tool \(call.name) is not available", now: runtime.now())
                slots.append(ToolSlot(callId: call.id, name: call.name, status: .done, entry: result.id))
            } else if sequential && !tools.isEmpty {
                pending.append(call.id); slots.append(ToolSlot(callId: call.id, name: call.name))
            } else {
                let id = try await createGenerationTool(tx: tx, runtime: runtime, assistant: entry.id, callId: call.id)
                tools.append(id); slots.append(ToolSlot(callId: call.id, name: call.name, taskId: id))
            }
        }
        try live.remove("generation"); try live.set("tools", JSONValue(encoding: slots))
        return try generationTask.waiting(GenerationCheckpoint(phase: .tools, assistant: entry.id, tools: tools, pending: pending), on: tools, policy: .allSettled)
    }, context: context)
}
public func finishToolRound(runtime: TaskRuntime, assistant: EntryID, tools: [TaskID], context: PiSwiftChord.Context) async throws {
    let outcomes = try await runtime.outcomes(tools, context: context)
    var controls: [ToolControl?] = []
    for outcome in outcomes {
        if case .completed(let result, _) = outcome { controls.append(try result["control"]?.decode(ToolControl.self)) }
        else { controls.append(nil) }
    }
    let slots = try await runtime.snapshot(LiveDoc, conversationId: runtime.conversationId, context: context)?.tools ?? []
    let results = slots.compactMap(\.entry)
    try await runtime.hooks.each(GenerationHooks.self, context: context) { hooks in try await hooks.afterTools?(assistant, results, runtime.hookApi, context) }
    let byTask = Dictionary(uniqueKeysWithValues: zip(tools, controls))
    let terminate = !slots.isEmpty && slots.allSatisfy { slot in slot.taskId.map { byTask[$0]??.terminate == true } ?? false }
    let added = controls.flatMap { $0?.addTools ?? [] }
    let handoff = controls.reversed().compactMap { $0?.handoff }.first
    try await runtime.commit({ tx, _ in
        var boundary = try await prepareBoundary(tx: tx, conversationId: runtime.conversationId, modes: runtime.settings)
        if !added.isEmpty {
            try await addGenerationTools(tx: tx, conversationId: runtime.conversationId, added: added)
        }
        let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId), now = try runtime.now()
        if terminate || handoff != nil {
            if let handoff {
                let message = UserMessage(content: .text(handoff), timestamp: now)
                let entry = try await tx.appendEntry(runtime.conversationId, value: EntryDraft(kind: resetEntry.kind,
                    model: EntryRecord.encodeMessages([.user(message)]), head: .self))
                boundary.head = entry.id
            }
            let applied = try await applyBoundary(tx: tx, boundary: boundary, at: .final, now: now)
            try endRun(tx: tx, live: live, taskId: runtime.taskId, settlement: .done(answer: assistant))
            if !applied.users.isEmpty { try await startRun(tx: tx, conversationId: runtime.conversationId, live: live, inputs: applied.users) }
        } else {
            let applied = try await applyBoundary(tx: tx, boundary: boundary, at: .postTools, now: now)
            if applied.reset {
                try endRun(tx: tx, live: live, taskId: runtime.taskId, settlement: .unanswered(reason: "reset"))
                if !applied.users.isEmpty { try await startRun(tx: tx, conversationId: runtime.conversationId, live: live, inputs: applied.users) }
            } else {
                try live.remove("tools")
                if let run = try live.child("run"), try run.get("taskId")?.decode(TaskID.self) == runtime.taskId {
                    try run.child("inputs")!.append(contentsOf: applied.users.map { try JSONValue(encoding: $0) })
                }
                try handOver(live: live, from: runtime.taskId, to: await createGeneration(tx: tx, conversationId: runtime.conversationId))
            }
        }
        return try generationTask.completed(GenerationResult(entryId: assistant))
    }, context: context)
}

/// Append selected tools in place, as agent.ts:85-97 requires.
func addGenerationTools(tx: Transaction, conversationId: ConversationID, added: [String]) async throws {
    let agent = try await tx.doc(AgentDoc, conversationId: conversationId)
    guard let tools = try agent.get("tools") else { return }
    if let values = tools.arrayValue, let draft = try agent.child("tools") {
        var names = values.compactMap(\.stringValue)
        for name in added where !names.contains(where: { harnessNamesEqual($0, name) }) {
            try draft.append(.string(name)); names.append(name)
        }
    } else if let removed = tools["remove"]?.arrayValue {
        let names = removed.compactMap(\.stringValue)
        if names.contains(where: { name in added.contains { harnessNamesEqual($0, name) } }) {
            try agent.set("tools", .object(["remove": .array(names.filter { name in !added.contains { harnessNamesEqual($0, name) } }.map(JSONValue.string))]))
        }
    }
}
