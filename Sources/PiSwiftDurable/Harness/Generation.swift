import Foundation
import PiSwiftAI
import PiSwiftChord

public struct GenerationInput: Codable, Sendable { public init() {} }
public struct GenerationResult: Codable, Sendable, Equatable {
    public let entryId: EntryID
    public init(entryId: EntryID) { self.entryId = entryId }
}
/// Persist the provider handle without adding a retroactive Codable conformance to PiSwiftAI.
public struct GenerationDeferredHandle: Codable, Sendable {
    public var provider: String
    public var modelId: String
    public var api: String
    public var id: String
    public var expiresAt: Int64?
    public var pollAfterMs: Int?
    public var data: AnyCodable?
    public init(_ handle: DeferredHandle) {
        provider = handle.provider; modelId = handle.modelId; api = handle.api; id = handle.id
        expiresAt = handle.expiresAt; pollAfterMs = handle.pollAfterMs; data = handle.data
    }
    public var handle: DeferredHandle {
        DeferredHandle(provider: provider, modelId: modelId, api: api, id: id,
                       expiresAt: expiresAt, pollAfterMs: pollAfterMs, data: data)
    }
}
public struct GenerationCheckpoint: TaskCheckpoint {
    public enum Phase: String, Codable, Sendable { case prepare, request, retry, poll, tools }
    public var phase: Phase
    public var attempt: Int?
    public var compacted: TaskID?
    public var overflow: String?
    public var model: ModelRef?
    public var thinkingLevel: ModelThinkingLevel?
    public var streamOptions: ConversationStreamOptions?
    public var cutoff: EntryID?
    public var until: Int64?
    public var handle: GenerationDeferredHandle?
    public var pollAt: Int64?
    public var assistant: EntryID?
    public var tools: [TaskID]?
    public var pending: [String]?
    public init(phase: Phase, attempt: Int? = nil, compacted: TaskID? = nil, overflow: String? = nil,
                model: ModelRef? = nil, thinkingLevel: ModelThinkingLevel? = nil,
                streamOptions: ConversationStreamOptions? = nil, cutoff: EntryID? = nil,
                until: Int64? = nil, handle: GenerationDeferredHandle? = nil, pollAt: Int64? = nil,
                assistant: EntryID? = nil, tools: [TaskID]? = nil, pending: [String]? = nil) {
        self.phase = phase; self.attempt = attempt; self.compacted = compacted; self.overflow = overflow
        self.model = model; self.thinkingLevel = thinkingLevel; self.streamOptions = streamOptions
        self.cutoff = cutoff; self.until = until; self.handle = handle; self.pollAt = pollAt
        self.assistant = assistant; self.tools = tools; self.pending = pending
    }
}
public let generationTask = TaskDefinition<GenerationInput, GenerationCheckpoint, GenerationResult, GenerationHooks>(
    name: "pi.generation", version: 1, initial: { _ in GenerationCheckpoint(phase: .prepare, attempt: 1) },
    phase: { task, runtime, context in try await runGeneration(task.checkpoint, runtime, context) },
    abort: { task, runtime, context in try await abortGeneration(task.checkpoint, runtime, context) }
)
public func createGeneration(tx: Transaction, conversationId: ConversationID) async throws -> TaskID {
    try await tx.createTask(generationTask, input: GenerationInput(), options: .init(ownership: .conversation(), conversationId: conversationId))
}
private func required<Value>(_ value: Value?, _ key: String) throws -> Value {
    guard let value else { throw TaskDefinitionError("Generation checkpoint is missing \(key)") }; return value
}
private func runGeneration(_ checkpoint: GenerationCheckpoint, _ runtime: TaskRuntime, _ context: ChordContext) async throws {
    switch checkpoint.phase {
    case .prepare: try await prepareGeneration(checkpoint, runtime, context)
    case .request: try await requestGeneration(checkpoint, runtime, context)
    case .retry:
        try await runtime.sleep(until: required(checkpoint.until, "until"), context: context)
        let attempt = try required(checkpoint.attempt, "attempt") + 1
        try await runtime.commit({ tx, _ in
            let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
            try live.set("generation", .object(["attempt": .number(Double(attempt))]))
            return try generationTask.running(GenerationCheckpoint(phase: .prepare, attempt: attempt, compacted: checkpoint.compacted))
        }, context: context)
    case .poll:
        let ref = try required(checkpoint.model, "model")
        guard let model = runtime.models.getModel(provider: ref.provider, modelId: ref.modelId) else {
            return try await failGeneration(runtime, ref: ref, context: context)
        }
        try await runtime.sleep(until: required(checkpoint.pollAt, "pollAt"), context: context)
        let bridge = ContextCancellationBridge(context: context.withAbortSignal(runtime.signal))
        defer { withExtendedLifetime(bridge) {} }
        let message = await runtime.models.fetchDeferred(model: model, handle: try required(checkpoint.handle, "handle").handle,
                                                        options: DeferredFetchOptions(signal: bridge.token))
        try await classifyGeneration(runtime, request: checkpoint, message: message, context: context)
    case .tools:
        let assistant = try required(checkpoint.assistant, "assistant")
        let tools = checkpoint.tools ?? [], pending = checkpoint.pending ?? []
        guard let next = pending.first else { return try await finishToolRound(runtime: runtime, assistant: assistant, tools: tools, context: context) }
        try await runtime.commit({ tx, _ in
            let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
            let taskId = try await createGenerationTool(tx: tx, runtime: runtime, assistant: assistant, callId: next)
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
    guard let ref = agent.model, let model = runtime.models.getModel(provider: ref.provider, modelId: ref.modelId) else {
        return try await failGeneration(runtime, ref: agent.model, context: context)
    }
    let attempt = try required(checkpoint.attempt, "attempt")
    if let compacted = checkpoint.compacted, let overflow = checkpoint.overflow {
        let outcomes = try await runtime.outcomes([compacted], context: context)
        guard case .completed(let result, _) = outcomes.first, result["entryId"] != nil else {
            return try await failGeneration(runtime, modelError: overflow, context: context)
        }
    }
    let view = try await runtime.context(runtime.conversationId, context: context)
    let shown = replaySections(view.messages)
    var env: (any ExecutionEnv)?
    do { env = try await runtime.env(context: context) }
    catch { if context.abortSignal?.aborted == true { throw error }; try runtime.report(error) }
    let input = PromptInput(conversationId: runtime.conversationId, agent: agent, env: env,
                            shown: Dictionary(uniqueKeysWithValues: shown.compactMap { key, value in value.stringValue.map { (key, $0) } }),
                            read: runtime.hookApi.read)
    let desired = try await renderSections(agent.sections, input: input, shown: shown,
                                          report: { runtime.scheduler.report($0) }, context: context)
    let entries = try planSystemEntries(view: view, desired: desired, registrations: agent.tools, timestamp: runtime.now())
    let threshold = checkpoint.compacted == nil ? try generationThresholdCompaction(view: view, planned: entries, contextWindow: model.contextWindow, policy: settings.compaction) : nil
    if threshold == .blocking {
        try await runtime.commit({ tx, _ in
            let child = try await createGenerationCompaction(tx: tx, conversationId: runtime.conversationId, reason: .threshold, owner: runtime.taskId)
            return try generationTask.waiting(GenerationCheckpoint(phase: .prepare, attempt: attempt, compacted: child), on: [child], policy: .allSettled)
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
    guard let model = runtime.models.getModel(provider: ref.provider, modelId: ref.modelId) else { return try await failGeneration(runtime, ref: ref, context: context) }
    let view = try await runtime.context(runtime.conversationId, at: required(checkpoint.cutoff, "cutoff"), context: context)
    var messages = view.messages
    try await runtime.hooks.each(GenerationHooks.self, context: context) { hooks in
        if let hook = hooks.beforeRequest, let replaced = try await hook(GenerationRequest(messages: messages), runtime.hookApi, context) { messages = replaced.messages }
    }
    let sessionId = try await ensureProviderSessionId(runtime: runtime, context: context)
    let bridge = ContextCancellationBridge(context: context.withAbortSignal(runtime.signal))
    defer { withExtendedLifetime(bridge) {} }
    let options = try generationStreamOptions(required(checkpoint.streamOptions, "streamOptions"), thinkingLevel: required(checkpoint.thinkingLevel, "thinkingLevel"), signal: bridge.token, sessionId: sessionId)
    let message = try await streamGeneration(runtime: runtime, model: model, messages: messages, options: options, attempt: attempt, context: context)
    try await classifyGeneration(runtime, request: checkpoint, message: message, messages: view.messages, context: context)
}
func generationStreamOptions(_ options: ConversationStreamOptions, thinkingLevel: ModelThinkingLevel, signal: CancellationToken, sessionId: String) throws -> SimpleStreamOptions {
    var metadata: [String: AnyCodable]?
    if let value = options.metadata { metadata = (try foundationJSON(from: .object(value)) as! [String: Any]).mapValues(AnyCodable.init) }
    return SimpleStreamOptions(signal: signal, transport: options.transport, reasoning: ThinkingLevel(rawValue: thinkingLevel.rawValue),
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
        let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
        try endRun(tx: tx, live: live, taskId: runtime.taskId, settlement: .unanswered(reason: reason, detail: reason == "model_error" ? .string(text) : nil))
        return .terminal(outcome: .failed(error: TaskOutcomeError(message: text, detail: .object(["reason": .string(reason)]))))
    }, context: context)
}
func appendGenerationAssistant(tx: Transaction, conversationId: ConversationID, message: AssistantMessage) async throws -> EntryRecord {
    try await recordUsage(tx: tx, conversationId: conversationId, bucket: .models, key: "\(message.provider)/\(message.model)", usage: message.usage)
    return try await tx.appendEntry(conversationId, value: EntryDraft(kind: assistantEntry.kind, model: EntryRecord.encodeMessages([.assistant(message)])))
}
public func convertPartial(tx: Transaction, live: JSONDraft, conversationId: ConversationID) async throws {
    guard let raw = try live.get("generation")?["message"] else { return }
    guard case .assistant(var message) = try EntryRecord(id: EntryID(1), conversationId: conversationId, kind: assistantEntry.kind, model: [raw]).messages()?.first else { return }
    message.stopReason = .aborted
    _ = try await appendGenerationAssistant(tx: tx, conversationId: conversationId, message: message)
}
private func abortGeneration(_ checkpoint: GenerationCheckpoint, _ runtime: TaskRuntime, _ context: ChordContext) async throws {
    if checkpoint.phase == .poll, let ref = checkpoint.model, let handle = checkpoint.handle,
       let model = runtime.models.getModel(provider: ref.provider, modelId: ref.modelId) {
        do {
            let bridge = ContextCancellationBridge(context: context.withAbortSignal(runtime.signal))
            defer { withExtendedLifetime(bridge) {} }
            try await runtime.models.cancelDeferred(model: model, handle: handle.handle, options: DeferredCancelOptions(signal: bridge.token))
        } catch { try runtime.report(error) }
    }
    let unstarted = checkpoint.phase == .tools ? try await generationCalls(runtime: runtime, assistant: required(checkpoint.assistant, "assistant"), callIds: checkpoint.pending ?? [], context: context) : []
    try await runtime.commit({ tx, _ in
        let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
        try await convertPartial(tx: tx, live: live, conversationId: runtime.conversationId)
        for call in unstarted { _ = try await appendGenerationToolError(tx: tx, conversationId: runtime.conversationId, call: call, code: "aborted", text: "Tool \(call.name) was aborted", now: runtime.now()) }
        try endRun(tx: tx, live: live, taskId: runtime.taskId, settlement: .unanswered(reason: "aborted"))
        return .terminal(outcome: .aborted())
    }, context: context)
}
