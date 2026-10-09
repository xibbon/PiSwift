import PiSwiftChord
import Synchronization

private struct EventParts {
    let live: LiveState
    let inbox: InboxState?
    let agent: AgentState?
    let usage: JSONObject?
    init(_ view: ConversationView) throws {
        live = try view.docs["pi.live"].map { try JSONValue.object($0).decode(LiveState.self) } ?? .init()
        inbox = try view.docs["pi.inbox"].map { try JSONValue.object($0).decode(InboxState.self) }
        agent = try view.docs["pi.agent"].map { try JSONValue.object($0).decode(AgentState.self) }
        usage = view.docs["pi.usage"]
    }
}
private func queuedEvents(_ inbox: InboxState?) -> [DurableQueuedItem] {
    (inbox?.items ?? []).map { .init(id: $0.id, mode: $0.mode) }
}
internal func durableEventSnapshot(_ view: ConversationView) throws -> DurableAgentSnapshot {
    let parts = try EventParts(view)
    return DurableAgentSnapshot(entries: view.entries, run: parts.live.run.map { .init(inputs: $0.inputs) },
        generation: parts.live.generation, tools: parts.live.tools ?? [], compactions: parts.live.compactions ?? [],
        inbox: queuedEvents(parts.inbox), agent: parts.agent ?? .init(), usage: parts.usage ?? ["models": [:], "tools": [:]])
}

extension Harness {
    /// Attach atomically on the Session line. Only later commits produce batches.
    public func watchEvents(conversationId: ConversationID, context: ChordContext) async throws -> DurableAgentEventWatch {
        try await withTaskCancellationContext(context) { context in
            try await acquireEvents(conversationId: conversationId, context: context)
        }
    }
    private func acquireEvents(conversationId: ConversationID, context: ChordContext) async throws -> DurableAgentEventWatch {
        try assertOpen()
        try context.abortSignal?.throwIfAborted()
        let result = Mutex<DurableAgentEventWatch?>(nil)
        let backing = Mutex<CommittedWatch<[DurableAgentEvent]>?>(nil)
        _ = try await views.attach(id: conversationId, context: context) { initial, release, storage in
            let completing = try await scanAll { cursor in
                try await storage.scanTasks(.init(conversationId: conversationId, kind: "pi.generation", status: .completing),
                    limit: 100, cursor: cursor, context: context)
            }
            let held = Mutex(Set(completing.map(\.id)))
            let initialSnapshot = try durableEventSnapshot(initial)
            let current = Mutex(initialSnapshot)
            let watch = CommittedWatch<[DurableAgentEvent]>(value: [], replacement: { _ in .array([]) }, detach: release,
                replace: { [.snapshot(current.withLock { $0 })] })
            backing.withLock { $0 = watch }
            result.withLock { $0 = DurableAgentEventWatch(snapshot: initialSnapshot, watch: watch) }
            return ConversationViewObserver(publication: { before, after, ops, publication, context in
                do {
                    let snapshot = try durableEventSnapshot(after)
                    current.withLock { $0 = snapshot }
                    let events = try held.withLock {
                        try translateDurableEvents(conversationId: conversationId, before: before, after: after,
                            viewOps: ops, publication: publication, held: &$0)
                    }
                    if !events.isEmpty { watch.advance(value: events, ops: [], context: context) }
                } catch { watch.fail(error) }
            }, closeSession: { watch.closeSession() })
        }
        let watch = backing.withLock { $0! }
        do {
            if let signal = context.abortSignal { try watch.observeCancellation(signal) }
            try context.abortSignal?.throwIfAborted()
            return result.withLock { $0! }
        } catch { watch.cancel(); throw error }
    }
}

/// Experimental event adapter for a durable conversation.
public func watchEvents(_ harness: Harness, conversationId: ConversationID,
                        context: ChordContext) async throws -> DurableAgentEventWatch {
    try await harness.watchEvents(conversationId: conversationId, context: context)
}

/// Translate one publication in upstream order. The held set suppresses a second turn end at terminal.
internal func translateDurableEvents(conversationId: ConversationID, before: ConversationView, after: ConversationView,
    viewOps: [Delta.Op], publication: CommitPublication, held: inout Set<TaskID>
) throws -> [DurableAgentEvent] {
    var entries: [EntryRecord] = []; var tasks: [TaskID: TaskRecord] = [:]; var taskOrder: [TaskID] = []
    var submissions: [SubmissionRecord] = []
    for change in publication.changes {
        switch change {
        case .entry(let record) where record.conversationId == conversationId: entries.append(record)
        case .task(let record) where record.conversationId == conversationId:
            if tasks[record.id] == nil { taskOrder.append(record.id) }; tasks[record.id] = record
        case .submission(let record) where record.conversationId == conversationId: submissions.append(record)
        default: break
        }
    }
    if viewOps.isEmpty && entries.isEmpty && tasks.isEmpty && submissions.isEmpty { return [] }
    submissions.sort { $0.id < $1.id }
    let was = try EventParts(before); let now = try EventParts(after)
    var events: [DurableAgentEvent] = []
    let oldSlots = was.live.tools ?? []; let slots = now.live.tools ?? []
    var slotsBefore: [[UInt16]: ToolSlot] = [:]; var slotOrder: [[UInt16]] = []
    for slot in oldSlots {
        let key = Array(slot.callId.utf16)
        if slotsBefore[key] == nil { slotOrder.append(key) }
        slotsBefore[key] = slot
    }
    for slot in slots where slot.status == .running && slotsBefore[Array(slot.callId.utf16)]?.status != .running {
        var args: JSONObject = [:]
        if let id = slot.taskId, let task = tasks[id] {
            switch task.state {
            case .pending(let cp, _), .running(let cp, _), .waiting(let cp, _, _, _): args = cp.objectValue?["arguments"]?.objectValue ?? [:]
            default: break
            }
        }
        events.append(.toolExecutionStart(toolCallId: slot.callId, toolName: slot.name, args: args))
    }
    let partialBefore = was.live.generation?.message; let partial = now.live.generation?.message
    if let partial, partialBefore == nil { events.append(.messageStart(message: partial)) }
    else if let partial, partial != partialBefore {
        events.append(.messageUpdate(usage: partial["usage"]?.objectValue ?? [:],
            changes: try durableMessageChanges(viewOps, message: partial)))
    }
    for (index, slot) in slots.enumerated() {
        guard slot.status == .running, let previous = slotsBefore[Array(slot.callId.utf16)], previous.status == .running,
              let update = durableToolUpdate(viewOps, index: index, slot: slot, previous: previous) else { continue }
        events.append(.toolExecutionUpdate(toolCallId: slot.callId, toolName: slot.name, output: update.output,
            details: update.details, diagnostics: update.diagnostics))
    }
    let generation = now.live.generation; let generationBefore = was.live.generation
    if let retry = generation?.retry, generationBefore?.retry == nil {
        events.append(.autoRetryStart(attempt: generation!.attempt, at: retry.at, errorMessage: retry.error))
    }
    if generationBefore?.retry != nil, generation?.retry == nil { events.append(.autoRetryEnd(attempt: generationBefore!.attempt)) }
    if let deferred = generation?.deferred, deferred.pollAt != generationBefore?.deferred?.pollAt { events.append(.deferredPoll(pollAt: deferred.pollAt)) }

    struct ToolEnd { let id: String; let name: String; let entry: EntryRecord? }
    var toolEnds: [ToolEnd] = []
    func endTool(_ id: String, _ name: String, _ entryId: EntryID?) {
        toolEnds.append(ToolEnd(id: id, name: name, entry: entries.first { $0.id == entryId }))
    }
    for id in slotOrder {
        let previous = slotsBefore[id]!
        if previous.status == .done { continue }
        let slot = slots.first { harnessNamesEqual($0.callId, previous.callId) }
        if slot?.status == .done { endTool(previous.callId, previous.name, slot?.entry) }
        else if slot == nil {
            let result = entries.first { $0.model?.first?.objectValue?["role"] == .string("toolResult") && $0.model?.first?.objectValue?["toolCallId"] == .string(previous.callId) }
            endTool(previous.callId, previous.name, result?.id)
        }
    }
    for slot in slots where slot.status == .done && slotsBefore[Array(slot.callId.utf16)] == nil { endTool(slot.callId, slot.name, slot.entry) }
    var assistantAppended = false
    for entry in entries {
        for end in toolEnds where end.entry?.id == entry.id { events.append(.toolExecutionEnd(toolCallId: end.id, toolName: end.name, entry: end.entry)) }
        guard let message = entry.model?.first?.objectValue else { events.append(.entryAppended(entry: entry)); continue }
        let assistant = message["role"] == .string("assistant")
        let streamed = assistant && partialBefore != nil && !assistantAppended
        if assistant { assistantAppended = true }
        if !streamed { events.append(.messageStart(message: message)) }
        events.append(.messageEnd(entry: entry))
    }
    for end in toolEnds where end.entry == nil { events.append(.toolExecutionEnd(toolCallId: end.id, toolName: end.name)) }
    let compactionsBefore = was.live.compactions ?? []; let compactions = now.live.compactions ?? []
    for old in compactionsBefore where !compactions.contains(where: { $0.taskId == old.taskId }) { events.append(.compactionEnd(taskId: old.taskId, reason: old.reason)) }
    var turnEnded = false
    for id in taskOrder {
        let task = tasks[id]!
        if task.kind == "pi.generation", task.state.status == "completing", held.insert(task.id).inserted { turnEnded = true }
        guard case .terminal(let outcome, _) = task.state else { continue }
        if task.kind == "pi.generation", held.remove(task.id) == nil { turnEnded = true }
        switch outcome {
        case .faulted(let error, _): events.append(.taskFailed(taskId: task.id, kind: task.kind, message: error.message))
        case .orphaned(let reason, _): events.append(.taskFailed(taskId: task.id, kind: task.kind, message: reason))
        default: break
        }
    }
    if turnEnded { events.append(.turnEnd) }
    let run = now.live.run; let runBefore = was.live.run
    let runChanged = run?.inputs.first != runBefore?.inputs.first
    if let runBefore, runChanged { events.append(.runEnd(inputs: runBefore.inputs)) }
    for record in submissions { events.append(.submission(record: record)) }
    if after.docs["pi.inbox"] != before.docs["pi.inbox"] { events.append(.inboxUpdate(items: queuedEvents(now.inbox))) }
    if after.docs["pi.agent"] != before.docs["pi.agent"] { events.append(.agentChanged(agent: now.agent ?? .init())) }
    if after.docs["pi.usage"] != before.docs["pi.usage"] { events.append(.usageChanged(usage: now.usage ?? ["models": [:], "tools": [:]])) }
    for status in compactions where !compactionsBefore.contains(where: { $0.taskId == status.taskId }) { events.append(.compactionStart(taskId: status.taskId, reason: status.reason, blocking: status.blocking)) }
    if let run, runChanged { events.append(.runStart(inputs: run.inputs)) }
    if let run, run.taskId != runBefore?.taskId, tasks[run.taskId]?.kind == "pi.generation" { events.append(.turnStart) }
    return events
}

private let partialEventPath: Delta.Path = ["docs", "pi.live", "generation", "message"]
private func eventOpPath(_ op: Delta.Op) -> Delta.Path {
    switch op {
    case .replace: []
    case .set(let p, _), .delete(let p), .append(let p, _), .trim(let p, _), .splice(let p, _, _, _), .move(let p, _): p
    }
}
private func eventPathStarts(_ path: Delta.Path, _ prefix: Delta.Path) -> Bool {
    path.count >= prefix.count && path.prefix(prefix.count).elementsEqual(prefix)
}

/// Use exact Chord operations, with whole-message fallback for a parent replacement.
internal func durableMessageChanges(_ ops: [Delta.Op], message: JSONObject) throws -> [DurableMessageChange] {
    var changes: [DurableMessageChange] = []; var whole = Set<Int>()
    for op in ops {
        let path = eventOpPath(op)
        if !eventPathStarts(path, partialEventPath) {
            if eventPathStarts(partialEventPath, path) { return [.message(message: message)] }
            continue
        }
        let rest = Array(path.dropFirst(partialEventPath.count))
        if rest.first == .key("usage") { continue }
        if rest.first != .key("content") { return [.message(message: message)] }
        if rest.count == 1 {
            guard case let .splice(_, index, remove, items) = op, remove == 0 else { return [.message(message: message)] }
            for (offset, item) in items.enumerated() {
                guard let block = item.objectValue else { throw SessionError.message("Message block is not an object") }
                let index = index + offset
                switch block["type"]?.stringValue {
                case "text": changes.append(.textStart(contentIndex: index, block: block))
                case "thinking": changes.append(.thinkingStart(contentIndex: index, block: block))
                default: changes.append(.toolCallStart(contentIndex: index, block: block))
                }
            }
            continue
        }
        guard case .index(let index) = rest[1] else { throw SessionError.message("Message content index is not an integer") }
        let field = rest.count > 2 ? rest[2] : nil
        if whole.contains(index) { continue }
        if case .append(_, let delta) = op, rest.count == 3, field == .key("text") || field == .key("thinking") {
            if field == .key("text") { changes.append(.textDelta(contentIndex: index, delta: delta)) }
            else { changes.append(.thinkingDelta(contentIndex: index, delta: delta)) }
        } else if case .append(_, let delta) = op, field == .key("arguments") {
            changes.append(.toolCallDelta(contentIndex: index, path: Array(rest.dropFirst(3)), delta: delta))
        } else {
            whole.insert(index)
            guard let content = message["content"]?.arrayValue, content.indices.contains(index), let block = content[index].objectValue else { throw SessionError.message("Message content block is absent") }
            changes.append(.block(contentIndex: index, block: block))
        }
    }
    return changes
}

internal struct DurableToolUpdate: Sendable {
    let output: DurableToolOutputChange?
    let details: JSONValue?
    let diagnostics: [ToolDiagnostic]?
}
internal func durableToolUpdate(_ ops: [Delta.Op], index: Int, slot: ToolSlot, previous: ToolSlot) -> DurableToolUpdate? {
    let path: Delta.Path = ["docs", "pi.live", "tools", .index(index), "output"]
    var trim = 0; var append = ""; var set = false
    for op in ops where eventPathStarts(eventOpPath(op), path) {
        switch op { case .trim(_, let n): trim += n; case .append(_, let text): append += text; default: set = true }
    }
    let output: DurableToolOutputChange?
    if set || (slot.output.map(JSONValue.string) != previous.output.map(JSONValue.string) && trim == 0 && append.isEmpty) { output = .set(slot.output ?? "") }
    else if trim > 0 || !append.isEmpty { output = .delta(trimStart: trim > 0 ? trim : nil, append: append.isEmpty ? nil : append) }
    else { output = nil }
    let details: JSONValue? = slot.details == previous.details ? Optional<JSONValue>.none : .some(slot.details ?? .null)
    func diagnosticValue(_ values: [ToolDiagnostic]?) -> JSONValue? {
        values.map { .array($0.map { value in
            var object: JSONObject = ["severity": .string(value.severity.rawValue), "message": .string(value.message)]
            if let code = value.code { object["code"] = .string(code) }
            return .object(object)
        }) }
    }
    let diagnostics = diagnosticValue(slot.diagnostics) == diagnosticValue(previous.diagnostics) ? nil : slot.diagnostics ?? []
    if output == nil && details == nil && diagnostics == nil { return nil }
    return DurableToolUpdate(output: output, details: details, diagnostics: diagnostics)
}
