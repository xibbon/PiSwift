import PiSwiftAI
import PiSwiftChord

/// The saved tool call and model context required for a tool task.
public typealias GenerationToolInput = ToolTaskInput
let generationToolKind = toolTask.kind
func createGenerationTool(tx: Transaction, runtime: TaskRuntime, assistant: EntryID, callId: String,
                          unoffered: Bool = false) async throws -> TaskID {
    let input: GenerationToolInput = unoffered ? .unofferedModel(assistant: assistant, callId: callId) : .model(assistant: assistant, callId: callId)
    return try await tx.createTask(generationToolKind, input: input,
                           options: .init(ownership: .task(taskId: runtime.taskId)))
}
func generationCalls(runtime: TaskRuntime, assistant: EntryID, callIds: [String], context: ChordContext) async throws -> [ToolCall] {
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
                              messages: [Message]?, context: ChordContext) async throws {
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
            let unoffered = !offered.contains(Array(call.name.utf16))
            if sequential && !tools.isEmpty {
                pending.append(call.id)
                var slot = ToolSlot(callId: call.id, name: call.name)
                if unoffered { slot.unoffered = true }
                slots.append(slot)
            } else {
                let id = try await createGenerationTool(tx: tx, runtime: runtime, assistant: entry.id, callId: call.id, unoffered: unoffered)
                tools.append(id)
                var slot = ToolSlot(callId: call.id, name: call.name, taskId: id)
                if unoffered { slot.unoffered = true }
                slots.append(slot)
            }
        }
        try live.remove("generation"); try live.set("tools", JSONValue(encoding: slots))
        if let run = try live.child("run"), try run.get("taskId")?.decode(TaskID.self) == runtime.taskId {
            let turns = try run.get("turns")?.decode(Int.self) ?? 0
            try run.set("turns", .number(Double(turns + 1)))
            if try run.get("first") == nil { try run.set("first", JSONValue(encoding: entry.id)) }
        }
        return try generationTask.waiting(GenerationCheckpoint(phase: .tools, assistant: entry.id, tools: tools, pending: pending), on: tools, policy: .allSettled)
    }, context: context)
}
internal func finishToolRound(runtime: TaskRuntime, assistant: EntryID, tools: [TaskID], context: ChordContext) async throws {
    let slots = try await runtime.snapshot(LiveDoc, conversationId: runtime.conversationId, context: context)?.tools ?? []
    let results = slots.compactMap(\.entry)
    var prepared: [PreparedHookTask] = []
    try await runtime.hooks.each(GenerationHooks.self, context: context) { hooks in
        guard let asked = try await hooks.afterTools?(assistant, results, runtime.hookApi, context) else { return }
        try prepareHookTasks(asked.tasks, runtime: runtime, prepared: &prepared)
    }
    if !prepared.isEmpty {
        try await runtime.commit({ tx, _ in
            let ids = try await createHookTasks(tx: tx, runtime: runtime, prepared: prepared)
            return try generationTask.waiting(GenerationCheckpoint(phase: .afterTools, assistant: assistant, tools: tools, tasks: ids),
                                              on: ids, policy: .allSettled)
        }, context: context)
        return
    }
    try await endToolRound(runtime: runtime, assistant: assistant, tools: tools, taskTerminates: false, context: context)
}

/// Applies every completed afterTools decision after its child tasks settle.
internal func finishAfterTools(runtime: TaskRuntime, assistant: EntryID, tools: [TaskID], tasks: [TaskID], context: ChordContext) async throws {
    let outcomes = try await runtime.outcomes(tasks, context: context)
    var terminates = false
    for (index, outcome) in outcomes.enumerated() {
        guard case .completed(let result, _) = outcome else { continue }
        if result == .null || result == .object([:]) { continue }
        if result == .object(["terminate": .bool(true)]) { terminates = true; continue }
        let record = try await runtime.getTask(tasks[index], context: context)
        let kind = record?.kind ?? "undefined"
        let owner = runtime.registry.installed().last { item in item.tasks.contains { $0.name == kind } }?.name
        try runtime.report(TaskDefinitionError("afterTools task \(tasks[index]) (\(kind)) completed with no AfterToolsDecision"), from: .extension(owner))
    }
    try await endToolRound(runtime: runtime, assistant: assistant, tools: tools, taskTerminates: terminates, context: context)
}

internal func endToolRound(runtime: TaskRuntime, assistant: EntryID, tools: [TaskID], taskTerminates: Bool, context: ChordContext) async throws {
    let outcomes = try await runtime.outcomes(tools, context: context)
    var controls: [ToolControl?] = []
    for outcome in outcomes {
        if case .completed(let result, _) = outcome {
            // Nested receipts never control a model round. Held v1 model receipts can omit the tag.
            if result["kind"] == .string("nested") { controls.append(nil); continue }
            guard result["kind"] == nil || result["kind"] == .string("model") else {
                throw TaskDefinitionError("Invalid tool task result kind")
            }
            controls.append(try result["control"]?.decode(ToolControl.self))
        } else { controls.append(nil) }
    }
    let slots = try await runtime.snapshot(LiveDoc, conversationId: runtime.conversationId, context: context)?.tools ?? []
    let results = slots.compactMap(\.entry)
    let byTask = Dictionary(uniqueKeysWithValues: zip(tools, controls))
    let ordered: [ToolControl?] = slots.map { $0.taskId.flatMap { byTask[$0] ?? nil } }
    let terminate = taskTerminates || (!slots.isEmpty && ordered.allSatisfy { $0?.terminate == true })
    let added = ordered.flatMap { $0?.addTools ?? [] }
    let handoff = ordered.reversed().compactMap { $0?.handoff }.first
    let agent = try await runtime.agent(context: context)
    let maxTurns = agent.maxTurns
    let asksAfterRun = terminate && agentHooks(agent, taskName: generationTask.name, as: GenerationHooks.self)
        .contains { $0.handlers.afterRun != nil }
    try await runtime.commit({ tx, _ in
        var boundary = try await prepareBoundary(tx: tx, conversationId: runtime.conversationId, modes: runtime.settings)
        if !added.isEmpty {
            try await addGenerationTools(tx: tx, conversationId: runtime.conversationId, added: added)
        }
        let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId), now = try runtime.now()
        var last = results.max() ?? assistant
        if let handoff {
            let message = UserMessage(content: .text(handoff), timestamp: now)
            let entry = try await tx.appendEntry(runtime.conversationId, value: EntryDraft(kind: resetEntry.kind,
                model: EntryRecord.encodeMessages([.user(message)]), head: .self))
            boundary.head = entry.id
            last = entry.id
        }
        if asksAfterRun, let held = try holdRun(tx: tx, live: live, runtime: runtime,
                                               reason: .terminate, answer: assistant, last: last) { return held }
        let turns = try live.get("run")?.decode(LiveRun.self).turns ?? 0
        if terminate {
            let applied = try await applyBoundary(tx: tx, boundary: boundary, at: .final, now: now)
            try endRun(tx: tx, live: live, taskId: runtime.taskId, settlement: .done(answer: assistant))
            if !applied.users.isEmpty { try await startRun(tx: tx, conversationId: runtime.conversationId, live: live, inputs: applied.users, first: applied.first) }
        } else if let maxTurns, turns >= maxTurns {
            let detail = turns == 1 ? "1 turn" : "\(turns) turns"
            let policy = runtime.settings.afterFailedRun
            let failure = GenerationFailure(policy: policy, boundary: policy == .continue ? boundary : nil)
            try await endFailedRun(tx: tx, runtime: runtime, live: live, failure: failure, reason: .turnLimit, detail: detail)
        } else {
            let applied = try await applyBoundary(tx: tx, boundary: boundary, at: .postTools, now: now)
            if applied.reset {
                try endRun(tx: tx, live: live, taskId: runtime.taskId, settlement: .unanswered(reason: "reset"), failure: .reset)
                if !applied.users.isEmpty { try await startRun(tx: tx, conversationId: runtime.conversationId, live: live,
                    inputs: applied.users, first: applied.first, keepFailure: true) }
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

/// Updates both stored tool filters, as agent.ts:90-108 requires.
func addGenerationTools(tx: Transaction, conversationId: ConversationID, added: [String]) async throws {
    try await addTools(tx: tx, conversationId: conversationId, added: added)
}
