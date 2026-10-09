import PiSwiftAI
import PiSwiftChord

public struct CompactionInput: Codable, Sendable {
    public let reason: CompactionReason
    public let instructions: String?
    public init(reason: CompactionReason, instructions: String? = nil) {
        self.reason = reason; self.instructions = instructions
    }
}

public struct CompactionResult: Codable, Sendable, Equatable {
    public let entryId: EntryID?
    public let submissionId: SubmissionID?
    public init(entryId: EntryID? = nil, submissionId: SubmissionID? = nil) {
        self.entryId = entryId; self.submissionId = submissionId
    }
}

/// Keep the request fixed after range selection.
public struct SummaryRequest: Codable, Sendable {
    public var attempt: Int
    public let model: ModelRef
    public let thinkingLevel: ModelThinkingLevel
    public let streamOptions: ConversationStreamOptions
    public let maxTokens: Int
    public let tail: EntryID
    public let firstKept: EntryID
    public init(attempt: Int, model: ModelRef, thinkingLevel: ModelThinkingLevel,
                streamOptions: ConversationStreamOptions, maxTokens: Int, tail: EntryID, firstKept: EntryID) {
        self.attempt = attempt; self.model = model; self.thinkingLevel = thinkingLevel
        self.streamOptions = streamOptions; self.maxTokens = maxTokens; self.tail = tail; self.firstKept = firstKept
    }
}

public enum CompactionCheckpoint: TaskCheckpoint {
    public enum Phase: String, Codable, Sendable { case select, summarize, retry }
    case select
    case summarize(SummaryRequest)
    case retry(SummaryRequest, until: Int64)
    public var phase: Phase {
        switch self { case .select: .select; case .summarize: .summarize; case .retry: .retry }
    }
    private enum CodingKeys: String, CodingKey { case phase, until }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Phase.self, forKey: .phase) {
        case .select: self = .select
        case .summarize: self = .summarize(try SummaryRequest(from: decoder))
        case .retry: self = .retry(try SummaryRequest(from: decoder), until: try container.decode(Int64.self, forKey: .until))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(phase, forKey: .phase)
        switch self {
        case .select: break
        case .summarize(let request): try request.encode(to: encoder)
        case .retry(let request, let until):
            try request.encode(to: encoder)
            try container.encode(until, forKey: .until)
        }
    }
}

public let compactionTask = TaskDefinition<CompactionInput, CompactionCheckpoint, CompactionResult, CompactionHooks>(
    name: "pi.compaction", version: 1, initial: { _ in .select },
    phase: { task, runtime, context in
        switch task.checkpoint {
        case .select: try await selectCompaction(task, runtime, context)
        case .summarize(let request): try await summarizeCompaction(task, request, runtime, context)
        case .retry(var request, let until):
            try await runtime.sleep(until: until, context: context)
            request.attempt += 1
            let next = request
            try await runtime.commit({ tx, _ in
                let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
                if let status = try compactionStatus(live: live, taskId: runtime.taskId) {
                    try status.set("attempt", .number(Double(next.attempt)))
                    try status.remove("retry")
                }
                return try compactionTask.running(.summarize(next))
            }, context: context)
        }
    },
    abort: { _, runtime, context in
        try await runtime.commit({ tx, _ in
            try removeCompactionStatus(live: await tx.doc(LiveDoc, conversationId: runtime.conversationId), taskId: runtime.taskId)
            return .terminal(outcome: .aborted())
        }, context: context)
    }
)

/// Add the task and its live status in the same commit.
public func createCompaction(tx: Transaction, conversationId: ConversationID,
                             input: CompactionInput, owner: TaskID? = nil) async throws -> TaskID {
    let ownership: TaskOwnership = owner.map { .task(taskId: $0) } ?? .conversation()
    let id = try await tx.createTask(compactionTask, input: input,
        options: .init(ownership: ownership, conversationId: conversationId, background: owner == nil && input.reason != .manual))
    let live = try await tx.doc(LiveDoc, conversationId: conversationId)
    try addCompactionStatus(live: live, status: .init(taskId: id, reason: input.reason, blocking: owner != nil, attempt: 1))
    return id
}

public func selectCut(view: ContextView, keepRecentTokens: Int) -> Int? {
    generationSelectCut(view: view, keepRecentTokens: keepRecentTokens)
}
public func estimateContext(view: ContextView, extra: [Message] = []) -> Int {
    generationEstimateContext(view: view, extra: extra)
}
public func summarizedMessages(view: ContextView, cut: Int) -> [Message] {
    let end = cut < 0 ? max(0, view.contributions.count + cut) : cut
    return orderToolResults(view.contributions.prefix(end).flatMap { $0 })
}

private func selectCompaction(_ task: RunningTask<CompactionInput, CompactionCheckpoint>,
                              _ runtime: TaskRuntime, _ context: ChordContext) async throws {
    let agent = try await runtime.agent(context: context), settings = runtime.settings
    guard let ref = agent.model, let model = runtime.models.getModel(provider: ref.provider, modelId: ref.modelId) else {
        return try await failCompactionNoModel(runtime, ref: agent.model, context: context)
    }
    let view = try await runtime.context(runtime.conversationId, context: context)
    guard let cut = selectCut(view: view, keepRecentTokens: settings.compaction.keepRecentTokens) else {
        return try await completeCompaction(runtime, context: context)
    }
    let firstKept = view.entries[cut].id
    let input = CompactionHookInput(reason: task.input.reason, entries: Array(view.entries.prefix(cut)),
        messages: summarizedMessages(view: view, cut: cut), firstKept: firstKept, instructions: task.input.instructions)
    var decision: CompactionHookDecision?
    try await runtime.hooks.each(CompactionHooks.self, context: context) { hooks in
        if decision == nil { decision = try await hooks.beforeCompact?(input, runtime.hookApi, context) }
    }
    if let decision {
        switch decision {
        case .decline: return try await completeCompaction(runtime, context: context)
        case .summary(let summary):
            try await runtime.commit({ tx, current in
                try await placeCompactionSummary(tx, runtime, current, firstKept: firstKept, summary: summary)
            }, context: context)
            return
        }
    }
    let budget = Int((0.8 * Double(settings.compaction.reserveTokens)).rounded(.down))
    let request = SummaryRequest(attempt: 1, model: ref, thinkingLevel: agent.thinkingLevel,
        streamOptions: settings.stream, maxTokens: model.maxTokens > 0 ? min(budget, model.maxTokens) : budget,
        tail: view.entries.reduce(firstKept) { max($0, $1.id) }, firstKept: firstKept)
    try await runtime.commit({ _, _ in try compactionTask.running(.summarize(request)) }, context: context)
}

private func summarizeCompaction(_ task: RunningTask<CompactionInput, CompactionCheckpoint>, _ request: SummaryRequest,
                                 _ runtime: TaskRuntime, _ context: ChordContext) async throws {
    let ref = request.model
    guard let model = runtime.models.getModel(provider: ref.provider, modelId: ref.modelId) else {
        return try await failCompactionNoModel(runtime, ref: ref, context: context)
    }
    let view = try await runtime.context(runtime.conversationId, at: request.tail, context: context)
    let cut = view.entries.firstIndex { $0.id == request.firstKept } ?? -1
    let now = try runtime.now()
    let messages: [Message] = [
        .system(SystemMessage(content: .text(summarizationSystemPrompt), timestamp: now)),
        .user(UserMessage(content: .blocks([.text(TextContent(text: summaryPrompt(
            messages: summarizedMessages(view: view, cut: cut), instructions: task.input.instructions)))]), timestamp: now))
    ]
    let bridge = ContextCancellationBridge(context: context.withAbortSignal(runtime.signal))
    defer { withExtendedLifetime(bridge) {} }
    let options = try compactionStreamOptions(request, signal: bridge.token,
        sessionId: await ensureProviderSessionId(runtime: runtime, context: context))
    let message = await runtime.models.completeSimple(model: model, context: .init(messages: messages), options: options)
    try runtime.signal.throwIfAborted()
    let summary = compactionSummaryText(message), policy = runtime.settings.retry
    let retry = message.stopReason == .error && isRetryableAssistantError(message) && policy.enabled && request.attempt <= policy.maxRetries
    let until = retry ? try runtime.now() + Int64(retryDelayMs(policy: RetryPolicy(enabled: policy.enabled,
        maxRetries: policy.maxRetries, baseDelayMs: Double(policy.baseDelayMs), maxAgentDelayMs: policy.maxAgentDelayMs.map(Double.init)),
        attempt: request.attempt)) : 0
    try await runtime.commit({ tx, current in
        try await recordUsage(tx: tx, conversationId: runtime.conversationId, bucket: .models,
            key: "\(message.provider)/\(message.model)", usage: message.usage)
        if let summary { return try await placeCompactionSummary(tx, runtime, current, firstKept: request.firstKept, summary: summary) }
        let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
        if retry {
            if let status = try compactionStatus(live: live, taskId: runtime.taskId) {
                try status.set("retry", JSONValue(encoding: LiveRetry(at: until, error: message.errorMessage ?? "")))
            }
            return try compactionTask.running(.retry(request, until: until))
        }
        try removeCompactionStatus(live: live, taskId: runtime.taskId)
        return .terminal(outcome: .failed(error: TaskOutcomeError(message: compactionSummaryFailure(message),
            detail: .object(["reason": .string("model_error")]))))
    }, context: context)
}

private func compactionStreamOptions(_ request: SummaryRequest, signal: CancellationToken, sessionId: String) throws -> SimpleStreamOptions {
    let source = request.streamOptions
    var metadata: [String: AnyCodable]?
    if let value = source.metadata, let object = try foundationJSON(from: .object(value)) as? [String: Any] {
        metadata = object.mapValues(AnyCodable.init)
    }
    return SimpleStreamOptions(maxTokens: request.maxTokens, signal: signal, transport: source.transport,
        reasoning: request.thinkingLevel == .off ? nil : ThinkingLevel(rawValue: request.thinkingLevel.rawValue),
        cacheRetention: CacheRetention.none, sessionId: sessionId, headers: source.headers, maxRetryDelayMs: source.maxRetryDelayMs,
        metadata: metadata, timeoutMs: source.timeoutMs, maxRetries: source.maxRetries)
}

private func placeCompactionSummary(_ tx: Transaction, _ runtime: TaskRuntime, _ current: TaskRecord,
                                    firstKept: EntryID, summary: String) async throws -> TaskState {
    try removeCompactionStatus(live: await tx.doc(LiveDoc, conversationId: runtime.conversationId), taskId: runtime.taskId)
    let text = "The conversation history before this point was compacted into the following summary:\n\n<summary>\n\(summary)\n</summary>"
    let input = try current.input.decode(CompactionInput.self)
    let entry = try EntryDraft(kind: compactionEntry.kind,
        model: EntryRecord.encodeMessages([.user(UserMessage(content: .blocks([.text(TextContent(text: text))]), timestamp: runtime.now()))]),
        data: JSONValue(encoding: CompactionEntryData(reason: input.reason)), head: .entry(firstKept))
    let result: CompactionResult
    if current.owner == nil {
        result = try await CompactionResult(submissionId: admitSubmission(tx: tx, conversationId: runtime.conversationId,
            draft: .write(entry: entry, requestId: "compaction:\(runtime.taskId.rawValue)"), now: runtime.now(), queueModes: runtime.settings))
    } else {
        result = try await CompactionResult(entryId: tx.appendEntry(runtime.conversationId, value: entry).id)
    }
    return try compactionTask.completed(result)
}

private func completeCompaction(_ runtime: TaskRuntime, context: ChordContext) async throws {
    try await runtime.commit({ tx, _ in
        try removeCompactionStatus(live: await tx.doc(LiveDoc, conversationId: runtime.conversationId), taskId: runtime.taskId)
        return try compactionTask.completed(CompactionResult())
    }, context: context)
}

private func failCompactionNoModel(_ runtime: TaskRuntime, ref: ModelRef?, context: ChordContext) async throws {
    let message = ref.map { "Model \($0.provider)/\($0.modelId) is not available" } ?? "No model is configured"
    try await runtime.commit({ tx, _ in
        try removeCompactionStatus(live: await tx.doc(LiveDoc, conversationId: runtime.conversationId), taskId: runtime.taskId)
        return .terminal(outcome: .failed(error: TaskOutcomeError(message: message, detail: .object(["reason": .string("no_model")]))))
    }, context: context)
}
