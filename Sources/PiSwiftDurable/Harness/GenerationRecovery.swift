import PiSwiftAI
import PiSwiftChord

/// v1.5.2 generation.ts:508–551. A stopped provider request spends one attempt.
func interruptedGeneration(_ checkpoint: GenerationCheckpoint, _ runtime: TaskRuntime, _ context: ChordContext) async throws {
    guard let attempt = checkpoint.attempt else { throw TaskDefinitionError("Generation checkpoint is missing attempt") }
    let policy = runtime.settings.retry
    let retry = policy.enabled && attempt <= policy.maxRetries
    let delay = retryDelayMs(policy: RetryPolicy(enabled: policy.enabled, maxRetries: policy.maxRetries,
        baseDelayMs: Double(policy.baseDelayMs), maxAgentDelayMs: policy.maxAgentDelayMs.map(Double.init)), attempt: attempt)
    let until = retry ? try runtime.now() + Int64(delay) : 0
    let polling = checkpoint.phase == .poll
    let text = polling
        ? "The host stopped while the deferred answer was fetched, on attempt \(attempt)"
        : "The host stopped while the model was answering, on attempt \(attempt)"
    if !retry { try await cancelGenerationDeferred(checkpoint, runtime, context) }
    try await runtime.commit({ tx, _ in
        let failure = retry ? nil : try await prepareFailure(tx: tx, runtime: runtime)
        let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
        try await convertPartial(tx: tx, live: live, conversationId: runtime.conversationId)
        if retry {
            try live.set("generation", JSONValue(encoding: LiveGeneration(attempt: attempt, retry: LiveRetry(at: until, error: text))))
            let poll: GenerationRetryPoll?
            if polling, let model = checkpoint.model, let cutoff = checkpoint.cutoff, let handle = checkpoint.handle {
                poll = GenerationRetryPoll(model: model, thinkingLevel: checkpoint.thinkingLevel, cutoff: cutoff, handle: handle)
            } else { poll = nil }
            return try generationTask.sleeping(GenerationCheckpoint(phase: .retry, attempt: attempt,
                compacted: checkpoint.compacted, until: until, poll: poll), until: Double(until))
        }
        try await endFailedRun(tx: tx, runtime: runtime, live: live, failure: failure!, reason: .interrupted, detail: text)
        return .terminal(outcome: .failed(error: TaskOutcomeError(message: text,
            detail: .object(["reason": .string("interrupted")]))))
    }, context: context)
}

/// v1.5.2 generation.ts:558–578. Cleanup is safe at the limit, but not past it.
func endGenerationCutOff(task: RunningTask<GenerationInput, GenerationCheckpoint>, runtime: TaskRuntime,
                         context: ChordContext) async throws {
    let count = generationCutOffCount(task.record.restarts)
    let text = "The generation was interrupted \(count) in its \(task.checkpoint.phase.rawValue) phase"
    let salvage = task.record.restarts <= runtime.settings.restartLimit
    if salvage { try await cancelGenerationDeferred(task.checkpoint, runtime, context) }
    try await runtime.commit({ tx, _ in
        let failure = try await prepareFailure(tx: tx, runtime: runtime)
        let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
        if salvage { try await convertPartial(tx: tx, live: live, conversationId: runtime.conversationId) }
        try await endFailedRun(tx: tx, runtime: runtime, live: live, failure: failure, reason: .restartLimit, detail: text)
        return .terminal(outcome: .failed(error: TaskOutcomeError(message: text,
            detail: .object(["reason": .string("restart_limit")]))))
    }, context: context)
}

func endAnsweredRun(runtime: TaskRuntime, answer: EntryID, context: ChordContext) async throws {
    try await runtime.commit({ tx, _ in
        let boundary = try await prepareBoundary(tx: tx, conversationId: runtime.conversationId, modes: runtime.settings)
        let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
        let applied = try await applyBoundary(tx: tx, boundary: boundary, at: .final, now: runtime.now())
        try endRun(tx: tx, live: live, taskId: runtime.taskId, settlement: .done(answer: answer))
        if !applied.users.isEmpty {
            try await startRun(tx: tx, conversationId: runtime.conversationId, live: live,
                               inputs: applied.users, first: applied.first)
        }
        return try generationTask.completed(GenerationResult(entryId: answer))
    }, context: context)
}

/// v1.5.2 generation.ts:984–997: the answer survives a cut-off in finish or drain.
func endAnsweredCutOff(task: RunningTask<GenerationInput, GenerationCheckpoint>, runtime: TaskRuntime,
                       context: ChordContext) async throws {
    guard let answer = task.checkpoint.phase == .finish ? task.checkpoint.run?.answer : task.checkpoint.answer else {
        throw TaskDefinitionError("Generation checkpoint is missing answer")
    }
    let text = "The generation was interrupted \(generationCutOffCount(task.record.restarts)) in its \(task.checkpoint.phase.rawValue) phase"
    try await runtime.commit({ tx, _ in
        let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
        try endRun(tx: tx, live: live, taskId: runtime.taskId, settlement: .done(answer: answer))
        return try generationTask.completed(GenerationResult(entryId: answer))
    }, context: context)
    runtime.scheduler.report(SessionError.message(text), .taskInterrupted(task: runtime.invocation.reportTask,
        extension: runtime.phase.installer, reason: .restartLimit, restarts: task.record.restarts))
}

private func generationCutOffCount(_ restarts: Double) -> String {
    if restarts == 1 { return "once" }
    let count = (try? JSONValue.number(restarts).jsonText()) ?? String(restarts)
    return "\(count) times in a row"
}

func cancelGenerationDeferred(_ checkpoint: GenerationCheckpoint, _ runtime: TaskRuntime,
                              _ context: ChordContext) async throws {
    let deferred: (ModelRef, GenerationDeferredHandle)?
    switch checkpoint.phase {
    case .poll: deferred = checkpoint.model.flatMap { model in checkpoint.handle.map { (model, $0) } }
    case .retry: deferred = checkpoint.poll.map { ($0.model, $0.handle) }
    default: deferred = nil
    }
    guard let (ref, handle) = deferred,
          let model = try runtime.generationModels().getModel(provider: ref.provider, modelId: ref.modelId) else { return }
    do {
        let bridge = ContextCancellationBridge(context: context.withAbortSignal(runtime.signal))
        defer { withExtendedLifetime(bridge) {} }
        try await runtime.generationModels().cancelDeferred(model: model, handle: handle.handle,
            options: DeferredCancelOptions(signal: bridge.token, telemetry: context.telemetry))
    } catch { try runtime.report(error, from: .host(callback: .models)) }
}
