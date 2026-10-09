import PiSwiftAI
import PiSwiftChord

func classifyGeneration(_ runtime: TaskRuntime, request: GenerationCheckpoint, message: AssistantMessage,
                        messages: [Message]? = nil, context: PiSwiftChord.Context) async throws {
    try runtime.signal.throwIfAborted()
    let attempt = request.attempt ?? 1
    if message.stopReason == .deferred, let handle = message.deferred {
        let now = try runtime.now()
        let pollAt = max(now + Int64(handle.pollAfterMs ?? 5000), request.pollAt.map { $0 + 1 } ?? Int64.min)
        try await runtime.commit({ tx, _ in
            let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
            try live.set("generation", JSONValue(encoding: LiveGeneration(attempt: attempt, deferred: LiveDeferred(pollAt: pollAt))))
            return try generationTask.running(GenerationCheckpoint(phase: .poll, attempt: attempt, compacted: request.compacted,
                model: request.model, cutoff: request.cutoff, handle: GenerationDeferredHandle(handle), pollAt: pollAt))
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
    let overflow = message.stopReason == .error && isContextOverflow(message)
    if overflow && request.compacted == nil && settings.compaction.enabled {
        let view = try await runtime.context(runtime.conversationId, at: request.cutoff, context: context)
        if generationSelectCut(view: view, keepRecentTokens: settings.compaction.keepRecentTokens) != nil {
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
        let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
        _ = try await appendGenerationAssistant(tx: tx, conversationId: runtime.conversationId, message: message)
        if retry {
            try live.set("generation", JSONValue(encoding: LiveGeneration(attempt: attempt, retry: LiveRetry(at: until, error: message.errorMessage ?? ""))))
            return try generationTask.running(GenerationCheckpoint(phase: .retry, attempt: attempt, compacted: request.compacted, until: until))
        }
        let text = message.errorMessage ?? "Model response ended with stop reason \(message.stopReason.rawValue)"
        try endRun(tx: tx, live: live, taskId: runtime.taskId, settlement: .unanswered(reason: "model_error", detail: .string(text)))
        return .terminal(outcome: .failed(error: TaskOutcomeError(message: text, detail: .object(["reason": .string("model_error")]))))
    }, context: context)
}
private func answerGeneration(runtime: TaskRuntime, message: AssistantMessage, context: PiSwiftChord.Context) async throws {
    var continuation: UserContent?
    try await runtime.hooks.each(GenerationHooks.self, context: context) { hooks in
        guard continuation == nil, let hook = hooks.onYield else { return }
        continuation = try await hook(message, runtime.hookApi, context)?.continue
    }
    try await runtime.commit({ tx, _ in
        let boundary = try await prepareBoundary(tx: tx, conversationId: runtime.conversationId, modes: runtime.settings)
        let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
        let entry = try await appendGenerationAssistant(tx: tx, conversationId: runtime.conversationId, message: message)
        let result = try generationTask.completed(GenerationResult(entryId: entry.id))
        let applied = try await applyBoundary(tx: tx, boundary: boundary, at: .final, now: runtime.now())
        if let continuation, applied.users.isEmpty && !applied.reset {
            let user = UserMessage(content: continuation, timestamp: try runtime.now())
            _ = try await tx.appendEntry(runtime.conversationId, value: EntryDraft(kind: userEntry.kind, model: EntryRecord.encodeMessages([.user(user)])))
            try handOver(live: live, from: runtime.taskId, to: await createGeneration(tx: tx, conversationId: runtime.conversationId))
            try live.remove("generation")
            return result
        }
        try endRun(tx: tx, live: live, taskId: runtime.taskId, settlement: .done(answer: entry.id))
        if !applied.users.isEmpty { try await startRun(tx: tx, conversationId: runtime.conversationId, live: live, inputs: applied.users) }
        return result
    }, context: context)
}
