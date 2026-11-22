import PiSwiftAI
import PiSwiftChord

func classifyGeneration(_ runtime: TaskRuntime, request: GenerationCheckpoint, message rawMessage: AssistantMessage,
                        messages: [Message]? = nil, context: ChordContext) async throws {
    try runtime.signal.throwIfAborted()
    // v1.5.2 generation.ts:774–776: the saved request level belongs to its answer.
    var message = rawMessage
    if let level = request.thinkingLevel { message.thinkingLevel = level }
    let attempt = request.attempt ?? 1
    if message.stopReason == .deferred, let handle = message.deferred {
        let now = try runtime.now()
        let pollAt = max(now + Int64(handle.pollAfterMs ?? 5000), request.pollAt.map { $0 + 1 } ?? Int64.min)
        try await runtime.commit({ tx, _ in
            let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
            try live.set("generation", JSONValue(encoding: LiveGeneration(attempt: attempt, deferred: LiveDeferred(pollAt: pollAt))))
            return try generationTask.sleeping(GenerationCheckpoint(phase: .poll, attempt: attempt, compacted: request.compacted,
                model: request.model, thinkingLevel: request.thinkingLevel, cutoff: request.cutoff,
                handle: GenerationDeferredHandle(handle), pollAt: pollAt), until: Double(pollAt))
        }, context: context)
        return
    }
    try await runtime.hooks.each(GenerationHooks.self, context: context) { hooks in
        try await hooks.afterResponse?(message, runtime.hookApi, context)
    }
    let calls = message.content.compactMap { block -> ToolCall? in if case .toolCall(let call) = block { return call }; return nil }
    if message.stopReason == .toolUse && !calls.isEmpty {
        return try await startGenerationToolRound(runtime: runtime, request: request, message: message, calls: calls, messages: messages, context: context)
    }
    if [.stop, .length, .toolUse].contains(message.stopReason) { return try await answerGeneration(runtime: runtime, message: message, context: context) }
    let settings = runtime.settings
    let conversationPolicy = try await runtime.agent(context: context).compaction
    let compact = request.model.map { compactionPolicy(settings: settings, model: $0, conversation: conversationPolicy) } ?? settings.compaction
    let overflow = message.stopReason == .error && isContextOverflow(message)
    if overflow && request.compacted == nil && compact.enabled {
        let view = try await runtime.context(runtime.conversationId, at: request.cutoff, context: context)
        if generationSelectCut(view: view, keepRecentTokens: compact.keepRecentTokens) != nil {
            try await runtime.commit({ tx, _ in
                let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
                _ = try await appendGenerationAssistant(tx: tx, conversationId: runtime.conversationId, message: message)
                try live.remove("generation")
                let child = try await createGenerationCompaction(tx: tx, conversationId: runtime.conversationId, reason: .overflow, owner: runtime.taskId)
                return try generationTask.waiting(GenerationCheckpoint(phase: .prepare, attempt: attempt, compacted: child,
                    overflow: message.errorMessage ?? "Context overflow"), on: [child], policy: .allSettled)
            }, context: context)
            return
        }
    }
    let policy = settings.retry
    let retry = message.stopReason == .error && !overflow && isRetryableAssistantError(message) && policy.enabled && attempt <= policy.maxRetries
    let delay = retryDelayMs(policy: RetryPolicy(enabled: policy.enabled, maxRetries: policy.maxRetries,
        baseDelayMs: Double(policy.baseDelayMs), maxAgentDelayMs: policy.maxAgentDelayMs.map(Double.init)), attempt: attempt)
    let until = retry ? try runtime.now() + Int64(delay) : 0
    try await runtime.commit({ tx, _ in
        let failure = retry ? nil : try await prepareFailure(tx: tx, runtime: runtime)
        let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
        _ = try await appendGenerationAssistant(tx: tx, conversationId: runtime.conversationId, message: message)
        if retry {
            try live.set("generation", JSONValue(encoding: LiveGeneration(attempt: attempt, retry: LiveRetry(at: until, error: message.errorMessage ?? ""))))
            return try generationTask.sleeping(GenerationCheckpoint(phase: .retry, attempt: attempt, compacted: request.compacted, until: until), until: Double(until))
        }
        let text = message.errorMessage ?? "Model response ended with stop reason \(message.stopReason.rawValue)"
        try await endFailedRun(tx: tx, runtime: runtime, live: live, failure: failure!, reason: .modelError, detail: text)
        return .terminal(outcome: .failed(error: TaskOutcomeError(message: text, detail: .object(["reason": .string("model_error")]))))
    }, context: context)
}
private func answerGeneration(runtime: TaskRuntime, message: AssistantMessage, context: ChordContext) async throws {
    var continuation: UserContent?
    var decided = false
    var prepared: [PreparedHookTask] = []
    try await runtime.hooks.each(GenerationHooks.self, context: context) { hooks in
        guard !decided, let hook = hooks.onYield,
              let decision = try await hook(message, runtime.hookApi, context) else { return }
        decided = true
        if let tasks = decision.tasks { try prepareHookTasks(tasks, runtime: runtime, prepared: &prepared) }
        else { continuation = decision.continue }
    }
    if !prepared.isEmpty {
        try await runtime.commit({ tx, _ in
            let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
            let entry = try await appendGenerationAssistant(tx: tx, conversationId: runtime.conversationId, message: message)
            let ids = try await createHookTasks(tx: tx, runtime: runtime, prepared: prepared)
            try live.remove("generation")
            if let run = try live.child("run"), try run.get("taskId")?.decode(TaskID.self) == runtime.taskId {
                try run.set("yield", JSONValue(encoding: LiveYield(answer: entry.id, tasks: ids)))
            }
            return try generationTask.waiting(GenerationCheckpoint(phase: .yield, answer: entry.id, tasks: ids),
                                              on: ids, policy: .allSettled)
        }, context: context)
        return
    }
    let agent = try await runtime.agent(context: context)
    let asksAfterRun = agentHooks(agent, taskName: generationTask.name, as: GenerationHooks.self)
        .contains { $0.handlers.afterRun != nil }
    try await runtime.commit({ tx, _ in
        let boundary = try await prepareBoundary(tx: tx, conversationId: runtime.conversationId, modes: runtime.settings)
        let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
        let entry = try await appendGenerationAssistant(tx: tx, conversationId: runtime.conversationId, message: message)
        return try await concludeAnswer(tx: tx, runtime: runtime, live: live, boundary: boundary,
                                        answer: entry.id, continuation: continuation, asksAfterRun: asksAfterRun)
    }, context: context)
}

/// Reads a task's untrusted result and accepts only a valid user input.
func validYieldInput(_ value: JSONValue) -> UserContent? {
    if case .string(let text) = value { return .text(text) }
    guard case .array(let values) = value, !values.isEmpty else { return nil }
    var blocks: [ContentBlock] = []
    for value in values {
        guard case .object(let item) = value else { return nil }
        if item["type"] == .string("text"), case .string(let text)? = item["text"] {
            blocks.append(.text(TextContent(text: text)))
        } else if item["type"] == .string("image"), case .string(let data)? = item["data"],
                  case .string(let mime)? = item["mimeType"] {
            blocks.append(.image(ImageContent(data: data, mimeType: mime)))
        } else { return nil }
    }
    return .blocks(blocks)
}

/// Settles an answer or appends a continuation at the final boundary.
private func concludeAnswer(tx: Transaction, runtime: TaskRuntime, live: JSONDraft, boundary: Boundary,
                            answer: EntryID, continuation: UserContent?, asksAfterRun: Bool) async throws -> TaskState {
        let result = try generationTask.completed(GenerationResult(entryId: answer))
        let queued = try boundary.inbox.snapshot().decode(InboxState.self).items
        let takesContinuation = continuation != nil && !hasQueuedReset(queued) &&
            !queued.contains { $0.mode == .steer || $0.mode == .followUp }
        if !takesContinuation && asksAfterRun,
           let held = try holdRun(tx: tx, live: live, runtime: runtime, reason: .answer,
                                  answer: answer, last: answer) {
            return held
        }
        let applied = try await applyBoundary(tx: tx, boundary: boundary, at: .final, now: runtime.now())
        if let continuation, takesContinuation {
            let user = UserMessage(content: continuation, timestamp: try runtime.now())
            _ = try await tx.appendEntry(runtime.conversationId, value: EntryDraft(kind: userEntry.kind, model: EntryRecord.encodeMessages([.user(user)])))
            if let run = try live.child("run"), try run.get("taskId")?.decode(TaskID.self) == runtime.taskId {
                try run.set("turns", .number(0))
            }
            try handOver(live: live, from: runtime.taskId, to: await createGeneration(tx: tx, conversationId: runtime.conversationId))
            try live.remove("generation")
            return result
        }
        try endRun(tx: tx, live: live, taskId: runtime.taskId, settlement: .done(answer: answer))
        if !applied.users.isEmpty { try await startRun(tx: tx, conversationId: runtime.conversationId, live: live, inputs: applied.users, first: applied.first) }
        return result
}

/// The first valid continuation in task creation order wins after all tasks are terminal.
func finishYield(runtime: TaskRuntime, answer: EntryID, tasks: [TaskID], context: ChordContext) async throws {
    let outcomes = try await runtime.outcomes(tasks, context: context)
    let continuation = outcomes.compactMap { outcome -> UserContent? in
        guard case .completed(let result, _) = outcome else { return nil }
        return result.objectValue?["continue"].flatMap(validYieldInput)
    }.first
    let agent = try await runtime.agent(context: context)
    let asksAfterRun = agentHooks(agent, taskName: generationTask.name, as: GenerationHooks.self)
        .contains { $0.handlers.afterRun != nil }
    try await runtime.commit({ tx, _ in
        let boundary = try await prepareBoundary(tx: tx, conversationId: runtime.conversationId, modes: runtime.settings)
        let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
        if let run = try live.child("run"), try run.get("taskId")?.decode(TaskID.self) == runtime.taskId {
            try run.remove("yield")
        }
        return try await concludeAnswer(tx: tx, runtime: runtime, live: live, boundary: boundary,
                                        answer: answer, continuation: continuation, asksAfterRun: asksAfterRun)
    }, context: context)
}
