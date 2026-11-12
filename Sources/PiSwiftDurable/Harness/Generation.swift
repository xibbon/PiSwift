import Foundation
import PiSwiftAI
import PiSwiftChord

/// The empty input of a built-in generation task.
public struct GenerationInput: Codable, Sendable {
    /// Creates the empty input of a built-in generation task.
    public init() {}
}
/// The answer entry produced by a completed generation.
public struct GenerationResult: Codable, Sendable, Equatable {
    /// The ID of the saved result entry.
    public let entryId: EntryID
    /// Records the final assistant answer entry.
    public init(entryId: EntryID) { self.entryId = entryId }
}
/// Persist the provider handle without adding a retroactive Codable conformance to PiSwiftAI.
public struct GenerationDeferredHandle: Codable, Sendable {
    /// The provider identifier used to resolve the model.
    public var provider: String
    /// The model identifier within its provider.
    public var modelId: String
    /// The model API used for this saved request.
    public var api: String
    /// The stable identifier of this record or handle.
    public var id: String
    /// The time after which cached request state expires.
    public var expiresAt: Int64?
    /// The delay before the next deferred request poll, in milliseconds.
    public var pollAfterMs: Int?
    /// Application data retained with the durable entry.
    public var data: AnyCodable?
    /// Copies a provider handle into Codable checkpoint state.
    public init(_ handle: DeferredHandle) {
        provider = handle.provider; modelId = handle.modelId; api = handle.api; id = handle.id
        expiresAt = handle.expiresAt; pollAfterMs = handle.pollAfterMs; data = handle.data
    }
    /// The provider handle used to poll or cancel a deferred request.
    public var handle: DeferredHandle {
        DeferredHandle(provider: provider, modelId: modelId, api: api, id: id,
                       expiresAt: expiresAt, pollAfterMs: pollAfterMs, data: data)
    }
}
/// Deferred request saved while a failed poll waits for retry.
public struct GenerationRetryPoll: Codable, Sendable {
    public var model: ModelRef
    public var thinkingLevel: ModelThinkingLevel?
    public var cutoff: EntryID
    public var handle: GenerationDeferredHandle
    public init(model: ModelRef, thinkingLevel: ModelThinkingLevel? = nil, cutoff: EntryID, handle: GenerationDeferredHandle) {
        self.model = model; self.thinkingLevel = thinkingLevel; self.cutoff = cutoff; self.handle = handle
    }
}
/// Answered or terminated run saved for afterRun hooks.
public struct GenerationRunSummary: Codable, Sendable {
    public enum Reason: String, Codable, Sendable { case answer, terminate }
    public var reason: Reason
    public var first: EntryID
    public var answer: EntryID
    public var last: EntryID
    public init(reason: Reason, first: EntryID, answer: EntryID, last: EntryID) {
        self.reason = reason; self.first = first; self.answer = answer; self.last = last
    }
}
/// The persisted phase, request, and tool state of a generation task.
public struct GenerationCheckpoint: TaskCheckpoint {
    /// The persisted phase used to resume this built-in task.
    public enum Phase: String, Codable, Sendable {
        /// Saves request or execution intent before the external effect.
        case prepare
        /// Starts or resumes the saved model request.
        case request
        /// Waits until the saved retry deadline before another request.
        case retry
        /// Polls the saved deferred model request.
        case poll
        /// Selects the usage totals of tool execution.
        case tools
        /// The answer was saved and afterRun hooks have not yet created tasks.
        case finish
        /// The run waits for tasks created by afterRun hooks.
        case drain
    }
    /// The saved generation phase used on resume.
    public var phase: Phase
    /// The current request attempt number.
    public var attempt: Int?
    /// The compaction task awaited by this generation.
    public var compacted: TaskID?
    /// Whether the model context exceeded the request limit.
    public var overflow: String?
    /// Whether this generation waited for a blocking threshold compaction.
    public var threshold: Bool?
    /// The stored provider and model reference or entry model contribution.
    public var model: ModelRef?
    /// The reasoning effort selected for the model.
    public var thinkingLevel: ModelThinkingLevel?
    /// The saved provider options used for this request.
    public var streamOptions: ConversationStreamOptions?
    /// The inclusive entry boundary used for this context.
    public var cutoff: EntryID?
    /// The clock deadline in milliseconds.
    public var until: Int64?
    /// A deferred request retained when its poll failed.
    public var poll: GenerationRetryPoll?
    /// The provider handle used to poll or cancel a deferred request.
    public var handle: GenerationDeferredHandle?
    /// The next deferred request poll time, in milliseconds.
    public var pollAt: Int64?
    /// The saved assistant answer or tool-call entry.
    public var assistant: EntryID?
    /// The tool registrations or live tool slots in this value.
    public var tools: [TaskID]?
    /// The work waiting for execution or publication.
    public var pending: [String]?
    /// The run summary saved for afterRun hooks.
    public var run: GenerationRunSummary?
    /// The answer saved while afterRun tasks drain.
    public var answer: EntryID?
    /// The tasks saved while an answered run drains.
    public var tasks: [TaskID]?
    /// Saves the generation phase and optional request, retry, and tool state.
    public init(phase: Phase, attempt: Int? = nil, compacted: TaskID? = nil, overflow: String? = nil, threshold: Bool? = nil,
                model: ModelRef? = nil, thinkingLevel: ModelThinkingLevel? = nil,
                streamOptions: ConversationStreamOptions? = nil, cutoff: EntryID? = nil,
                until: Int64? = nil, poll: GenerationRetryPoll? = nil, handle: GenerationDeferredHandle? = nil, pollAt: Int64? = nil,
                assistant: EntryID? = nil, tools: [TaskID]? = nil, pending: [String]? = nil,
                run: GenerationRunSummary? = nil, answer: EntryID? = nil, tasks: [TaskID]? = nil) {
        self.phase = phase; self.attempt = attempt; self.compacted = compacted; self.overflow = overflow; self.threshold = threshold
        self.model = model; self.thinkingLevel = thinkingLevel; self.streamOptions = streamOptions
        self.cutoff = cutoff; self.until = until; self.poll = poll; self.handle = handle; self.pollAt = pollAt
        self.assistant = assistant; self.tools = tools; self.pending = pending; self.run = run; self.answer = answer; self.tasks = tasks
    }
}
/// The built-in generation definition installed in every registry.
public let generationTask = TaskDefinition<GenerationInput, GenerationCheckpoint, GenerationResult, GenerationHooks>(
    name: "pi.generation", version: 2, initial: { _ in GenerationCheckpoint(phase: .prepare, attempt: 1) },
    phase: { task, runtime, context in try await runGeneration(task, runtime, context) },
    abort: { task, runtime, context in try await abortGeneration(task.checkpoint, runtime, context) },
    migrate: { input, checkpoint, _ in
        // v1.5.2 generation.ts:171-174 preserves both values.
        (try input.decode(GenerationInput.self), try checkpoint.decode(GenerationCheckpoint.self))
    }
)
/// Creates the built-in generation task for the conversation.
public func createGeneration(tx: Transaction, conversationId: ConversationID) async throws -> TaskID {
    try await tx.createTask(generationTask, input: GenerationInput(), options: .init(ownership: .conversation(), conversationId: conversationId))
}
private func required<Value>(_ value: Value?, _ key: String) throws -> Value {
    guard let value else { throw TaskDefinitionError("Generation checkpoint is missing \(key)") }; return value
}
private func runGeneration(_ task: RunningTask<GenerationInput, GenerationCheckpoint>, _ runtime: TaskRuntime, _ context: ChordContext) async throws {
    let checkpoint = task.checkpoint
    if let restarts = task.record.storedRestarts, restarts >= runtime.settings.restartLimit {
        if checkpoint.phase == .finish || checkpoint.phase == .drain {
            return try await endAnsweredCutOff(task: task, runtime: runtime, context: context)
        }
        return try await endGenerationCutOff(task: task, runtime: runtime, context: context)
    }
    switch checkpoint.phase {
    case .prepare: try await prepareGeneration(checkpoint, runtime, context)
    case .request:
        if task.record.storedRestarts != nil { try await interruptedGeneration(checkpoint, runtime, context) }
        else { try await requestGeneration(checkpoint, runtime, context) }
    case .finish:
        try await finishAnsweredRun(runtime: runtime, run: required(checkpoint.run, "run"), context: context)
    case .drain:
        try await endAnsweredRun(runtime: runtime, answer: required(checkpoint.answer, "answer"), context: context)
    case .retry:
        let until = try required(checkpoint.until, "until")
        if until > (try runtime.now()) {
            try await runtime.sleepUntil(Double(until), checkpoint: JSONValue(encoding: checkpoint), context: context)
            return
        }
        let attempt = try required(checkpoint.attempt, "attempt") + 1
        try await runtime.commit({ tx, _ in
            let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
            try live.set("generation", .object(["attempt": .number(Double(attempt))]))
            if let poll = checkpoint.poll {
                let now = try runtime.now()
                try live.set("generation", JSONValue(encoding: LiveGeneration(attempt: attempt, deferred: LiveDeferred(pollAt: now))))
                return try generationTask.running(GenerationCheckpoint(phase: .poll, attempt: attempt, compacted: checkpoint.compacted,
                    model: poll.model, thinkingLevel: poll.thinkingLevel, cutoff: poll.cutoff, handle: poll.handle, pollAt: now))
            }
            return try generationTask.running(GenerationCheckpoint(phase: .prepare, attempt: attempt, compacted: checkpoint.compacted))
        }, context: context)
    case .poll:
        if task.record.storedRestarts != nil { return try await interruptedGeneration(checkpoint, runtime, context) }
        let pollAt = try required(checkpoint.pollAt, "pollAt")
        if pollAt > (try runtime.now()) {
            try await runtime.sleepUntil(Double(pollAt), checkpoint: JSONValue(encoding: checkpoint), context: context)
            return
        }
        let ref = try required(checkpoint.model, "model")
        let models = try runtime.generationModels()
        guard let model = models.getModel(provider: ref.provider, modelId: ref.modelId) else {
            return try await failGeneration(runtime, ref: ref, context: context)
        }
        let bridge = ContextCancellationBridge(context: context.withAbortSignal(runtime.signal))
        defer { withExtendedLifetime(bridge) {} }
        let message = await models.fetchDeferred(model: model, handle: try required(checkpoint.handle, "handle").handle,
                                                        options: DeferredFetchOptions(signal: bridge.token, telemetry: context.telemetry))
        try await classifyGeneration(runtime, request: checkpoint, message: message, context: context)
    case .tools:
        let assistant = try required(checkpoint.assistant, "assistant")
        let tools = checkpoint.tools ?? [], pending = checkpoint.pending ?? []
        guard let next = pending.first else { return try await finishToolRound(runtime: runtime, assistant: assistant, tools: tools, context: context) }
        try await runtime.commit({ tx, _ in
            let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
            let slots = try live.child("tools")
            var unoffered = false
            if let slots {
                for index in 0..<(try slots.count()) {
                    guard let slot = try slots.child(index), try slot.get("callId") == .string(next) else { continue }
                    unoffered = try slot.get("unoffered") == true
                    break
                }
            }
            let taskId = try await createGenerationTool(tx: tx, runtime: runtime, assistant: assistant, callId: next, unoffered: unoffered)
            if let slots = try live.child("tools") {
                for index in 0..<(try slots.count()) {
                    guard let slot = try slots.child(index), try slot.get("callId") == .string(next), try slot.get("taskId") == nil else { continue }
                    try slot.set("taskId", JSONValue(encoding: taskId)); break
                }
            }
            let nextCheckpoint = GenerationCheckpoint(phase: .tools, assistant: assistant, tools: tools + [taskId], pending: Array(pending.dropFirst()))
            return try generationTask.waiting(nextCheckpoint, on: [taskId], policy: .allSettled)
        }, context: context)
    }
}
private func prepareGeneration(_ checkpoint: GenerationCheckpoint, _ runtime: TaskRuntime, _ context: ChordContext) async throws {
    let agent = try await runtime.agent(context: context), settings = runtime.settings
    guard let ref = agent.model else {
        return try await failGeneration(runtime, ref: agent.model, context: context)
    }
    let models = try runtime.generationModels()
    guard let model = models.getModel(provider: ref.provider, modelId: ref.modelId) else {
        return try await failGeneration(runtime, ref: ref, context: context)
    }
    let attempt = try required(checkpoint.attempt, "attempt")
    if let compacted = checkpoint.compacted, let overflow = checkpoint.overflow {
        let outcomes = try await runtime.outcomes([compacted], context: context)
        guard case .completed(let result, _) = outcomes.first, result["entryId"] != nil else {
            return try await failGeneration(runtime, modelError: overflow, context: context)
        }
    }
    if let compacted = checkpoint.compacted, checkpoint.threshold == true,
       let outcome = try await runtime.outcomes([compacted], context: context).first {
        if let text = blockingCompactionFailure(outcome) {
            return try await failGeneration(runtime, modelError: text, context: context)
        }
    }
    let view = try await runtime.context(runtime.conversationId, context: context)
    let last = view.messages.last { message in
        if case .system = message { return false }
        return true
    }
    switch last {
    case .user, .toolResult: break
    default: return try await failGeneration(runtime, reason: "nothing_to_answer", text: "The conversation has nothing to answer", context: context)
    }
    let shown = replaySections(view.messages)
    var env: (any ExecutionEnv)?
    do { env = try await runtime.env(context: context) }
    catch { if context.abortSignal?.aborted == true { throw error }; try runtime.report(error, from: .host(callback: .env)) }
    let input = PromptInput(conversationId: runtime.conversationId, agent: agent, env: env,
                            shown: Dictionary(uniqueKeysWithValues: shown.compactMap { key, value in value.stringValue.map { (key, $0) } }),
                            read: runtime.hookApi.read)
    let desired = try await renderSections(agent.sections, input: input, shown: shown,
                                          report: { error, section in
                                              runtime.scheduler.report(error, .extensionError(extension: sectionExtension(agent, key: section.key), task: runtime.invocation.reportTask))
                                          }, context: context)
    let entries = try planSystemEntries(view: view, desired: desired, registrations: agent.tools, timestamp: runtime.now())
    let threshold = checkpoint.compacted == nil ? try generationThresholdCompaction(view: view, planned: entries, contextWindow: model.contextWindow,
        policy: compactionPolicy(settings: settings, model: ref)) : nil
    if threshold == .blocking {
        try await runtime.commit({ tx, _ in
            let child = try await createGenerationCompaction(tx: tx, conversationId: runtime.conversationId, reason: .threshold, owner: runtime.taskId)
            return try generationTask.waiting(GenerationCheckpoint(phase: .prepare, attempt: attempt, compacted: child, threshold: true), on: [child], policy: .allSettled)
        }, context: context)
        return
    }
    try await runtime.commit({ tx, _ in
        var cutoff = try await tx.scanEntries(.init(conversationId: runtime.conversationId), limit: 1).items.first?.id
        for entry in entries { cutoff = try await tx.appendEntry(runtime.conversationId, value: entry).id }
        guard let cutoff else { throw TaskDefinitionError("Conversation \(runtime.conversationId.rawValue) has no entries to send") }
        if threshold == .background {
            let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
            if try live.get("compactions") == nil { _ = try await createGenerationCompaction(tx: tx, conversationId: runtime.conversationId, reason: .threshold) }
        }
        return try generationTask.running(GenerationCheckpoint(phase: .request, attempt: attempt, compacted: checkpoint.compacted,
            model: ref, thinkingLevel: agent.thinkingLevel, streamOptions: settings.stream, cutoff: cutoff))
    }, context: context)
}
private func requestGeneration(_ checkpoint: GenerationCheckpoint, _ runtime: TaskRuntime, _ context: ChordContext) async throws {
    let attempt = try required(checkpoint.attempt, "attempt"), ref = try required(checkpoint.model, "model")
    try await runtime.commit({ tx, _ in
        let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
        try await convertPartial(tx: tx, live: live, conversationId: runtime.conversationId)
        try live.set("generation", .object(["attempt": .number(Double(attempt))])); return nil
    }, context: context)
    let models = try runtime.generationModels()
    guard let model = models.getModel(provider: ref.provider, modelId: ref.modelId) else { return try await failGeneration(runtime, ref: ref, context: context) }
    let view = try await runtime.context(runtime.conversationId, at: required(checkpoint.cutoff, "cutoff"), context: context)
    var messages = view.messages
    try await runtime.hooks.each(GenerationHooks.self, context: context) { hooks in
        if let hook = hooks.beforeRequest, let replaced = try await hook(GenerationRequest(messages: messages), runtime.hookApi, context) { messages = replaced.messages }
    }
    let sessionId = try await ensureProviderSessionId(runtime: runtime, context: context)
    let bridge = ContextCancellationBridge(context: context.withAbortSignal(runtime.signal))
    defer { withExtendedLifetime(bridge) {} }
    let options = try generationStreamOptions(required(checkpoint.streamOptions, "streamOptions"), thinkingLevel: required(checkpoint.thinkingLevel, "thinkingLevel"), signal: bridge.token, sessionId: sessionId, context: context)
    let message = try await streamGeneration(runtime: runtime, model: model, messages: messages, options: options, attempt: attempt,
                                             thinkingLevel: checkpoint.thinkingLevel, context: context)
    try await classifyGeneration(runtime, request: checkpoint, message: message, messages: view.messages, context: context)
}
func generationStreamOptions(_ options: ConversationStreamOptions, thinkingLevel: ModelThinkingLevel, signal: CancellationToken, sessionId: String, context: ChordContext = .background) throws -> SimpleStreamOptions {
    var metadata: [String: AnyCodable]?
    if let value = options.metadata { metadata = (try foundationJSON(from: .object(value)) as! [String: Any]).mapValues(AnyCodable.init) }
    return SimpleStreamOptions(signal: signal, telemetry: context.telemetry, transport: options.transport, reasoning: ThinkingLevel(rawValue: thinkingLevel.rawValue),
        cacheRetention: options.cacheRetention, sessionId: sessionId, headers: options.headers, maxRetryDelayMs: options.maxRetryDelayMs,
        metadata: metadata, timeoutMs: options.timeoutMs, maxRetries: options.maxRetries, deferred: options.deferred)
}
private func failGeneration(_ runtime: TaskRuntime, ref: ModelRef?, context: ChordContext) async throws {
    let text = ref.map { "Model \($0.provider)/\($0.modelId) is not available" } ?? "No model is configured"
    try await failGeneration(runtime, reason: "no_model", text: text, context: context)
}
private func failGeneration(_ runtime: TaskRuntime, modelError: String, context: ChordContext) async throws {
    try await failGeneration(runtime, reason: "model_error", text: modelError, context: context)
}
private func failGeneration(_ runtime: TaskRuntime, reason: String, text: String, context: ChordContext) async throws {
    try await runtime.commit({ tx, _ in
        let failure = try await prepareFailure(tx: tx, runtime: runtime)
        let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
        try await endFailedRun(tx: tx, runtime: runtime, live: live, failure: failure,
            reason: RunFailureReason(rawValue: reason)!, detail: reason == "nothing_to_answer" ? nil : text,
            settlement: reason == "model_error" ? .unanswered(reason: reason, detail: .string(text)) : .unanswered(reason: reason))
        return .terminal(outcome: .failed(error: TaskOutcomeError(message: text, detail: .object(["reason": .string(reason)]))))
    }, context: context)
}
func appendGenerationAssistant(tx: Transaction, conversationId: ConversationID, message: AssistantMessage) async throws -> EntryRecord {
    try await recordUsage(tx: tx, conversationId: conversationId, bucket: .models, key: "\(message.provider)/\(message.model)", usage: message.usage)
    return try await tx.appendEntry(conversationId, value: EntryDraft(kind: assistantEntry.kind, model: EntryRecord.encodeMessages([.assistant(message)])))
}
internal func convertPartial(tx: Transaction, live: JSONDraft, conversationId: ConversationID) async throws {
    guard let raw = try live.get("generation")?["message"] else { return }
    guard case .assistant(var message) = try EntryRecord(id: EntryID(1), conversationId: conversationId, kind: assistantEntry.kind, model: [raw]).messages()?.first else { return }
    message.stopReason = .aborted
    _ = try await appendGenerationAssistant(tx: tx, conversationId: conversationId, message: message)
}
private func abortGeneration(_ checkpoint: GenerationCheckpoint, _ runtime: TaskRuntime, _ context: ChordContext) async throws {
    let deferred = checkpoint.phase == .retry ? checkpoint.poll.map { ($0.model, $0.handle) } :
        (checkpoint.phase == .poll ? checkpoint.model.flatMap { model in checkpoint.handle.map { (model, $0) } } : nil)
    if let (ref, handle) = deferred,
       let model = try runtime.generationModels().getModel(provider: ref.provider, modelId: ref.modelId) {
        do {
            let bridge = ContextCancellationBridge(context: context.withAbortSignal(runtime.signal))
            defer { withExtendedLifetime(bridge) {} }
            try await runtime.generationModels().cancelDeferred(model: model, handle: handle.handle, options: DeferredCancelOptions(signal: bridge.token, telemetry: context.telemetry))
        } catch { try runtime.report(error, from: .host(callback: .models)) }
    }
    let unstarted = checkpoint.phase == .tools ? try await generationCalls(runtime: runtime, assistant: required(checkpoint.assistant, "assistant"), callIds: checkpoint.pending ?? [], context: context) : []
    try await runtime.commit({ tx, _ in
        let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
        try await convertPartial(tx: tx, live: live, conversationId: runtime.conversationId)
        for call in unstarted {
            let unoffered = try live.child("tools")?.snapshot().decode([ToolSlot].self).first { $0.callId == call.id }?.unoffered == true
            _ = try await appendGenerationToolError(tx: tx, conversationId: runtime.conversationId, call: call,
                code: unoffered ? "tool_unavailable" : "aborted",
                text: unoffered ? "Tool \(call.name) is not available" : "Tool \(call.name) was aborted", now: runtime.now())
        }
        try endRun(tx: tx, live: live, taskId: runtime.taskId, settlement: .unanswered(reason: "aborted"), failure: .aborted)
        return .terminal(outcome: .aborted())
    }, context: context)
}

/// Maps a blocking compaction outcome to the generation failure text.
internal func blockingCompactionFailure(_ outcome: TaskOutcome) -> String? {
    switch outcome {
    case .completed: nil
    case .failed(let error, _, _), .faulted(let error, _): "Compaction failed: \(error.message)"
    case .orphaned(let reason, _): "Compaction failed: \(reason)"
    case .aborted: "Compaction was aborted"
    }
}
