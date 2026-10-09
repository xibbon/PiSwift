import PiSwiftAI
import PiSwiftChord

public struct GenerationCompactionInput: Codable, Sendable {
    public let reason: CompactionReason
    public init(reason: CompactionReason) { self.reason = reason }
}
let generationCompactionKind = TaskKind<GenerationCompactionInput, JSONObject>(name: "pi.compaction", version: 1, initial: { _ in ["phase": .string("select")] })
func createGenerationCompaction(tx: Transaction, conversationId: ConversationID, reason: CompactionReason, owner: TaskID? = nil) async throws -> TaskID {
    let ownership: TaskOwnership = owner.map { .task(taskId: $0) } ?? .conversation()
    let taskId = try await tx.createTask(generationCompactionKind, input: GenerationCompactionInput(reason: reason),
        options: .init(ownership: ownership, conversationId: conversationId, background: owner == nil && reason != .manual))
    let live = try await tx.doc(LiveDoc, conversationId: conversationId)
    try addCompactionStatus(live: live, status: CompactionStatus(taskId: taskId, reason: reason, blocking: owner != nil, attempt: 1))
    return taskId
}
enum GenerationCompactionThreshold { case blocking, background }
func generationThresholdCompaction(view: ContextView, planned: [EntryDraft], contextWindow: Int, policy: CompactionPolicy) throws -> GenerationCompactionThreshold? {
    guard policy.enabled, contextWindow > 0 else { return nil }
    var extra: [Message] = []
    for entry in planned { extra += try EntryRecord(id: EntryID(1), conversationId: rootConversationID, kind: entry.kind, model: entry.model).messages() ?? [] }
    let tokens = generationEstimateContext(view: view, extra: extra)
    let blocking = contextWindow - policy.reserveTokens, background = blocking - policy.backgroundTokens
    let over: GenerationCompactionThreshold? = tokens > blocking ? .blocking : policy.backgroundTokens > 0 && tokens > background ? .background : nil
    guard over != nil, generationSelectCut(view: view, keepRecentTokens: policy.keepRecentTokens) != nil else { return nil }
    return over
}
/// Same range selection as compaction.ts. H8 can reuse this implementation.
public func generationSelectCut(view: ContextView, keepRecentTokens: Int) -> Int? {
    let contributions = view.contributions, start = view.head == nil ? 0 : 1
    guard start < contributions.count else { return nil }
    let candidates = (start..<contributions.count).filter { generationCutCandidate(contributions, $0) }
    var kept = 0, cut: Int?
    for index in (start..<contributions.count).reversed() {
        kept += contributions[index].reduce(0) { $0 + estimateMessageTokens($1) }
        if kept < keepRecentTokens { continue }
        cut = candidates.first { $0 >= index } ?? candidates.last; break
    }
    guard let cut, (start..<cut).contains(where: { !contributions[$0].isEmpty }) else { return nil }
    return cut
}
private func generationCutCandidate(_ contributions: [[Message]], _ index: Int) -> Bool {
    guard let first = contributions[index].first else { return false }
    if case .assistant = first { return true }
    guard case .user = first else { return false }
    var calls = Set<[UInt16]>()
    if index > 0 {
        for before in (0..<index).reversed() {
            if let assistant = contributions[before].reversed().compactMap({ message -> AssistantMessage? in if case .assistant(let value) = message { return value }; return nil }).first {
                calls = Set(assistant.content.compactMap { block in if case .toolCall(let call) = block { return Array(call.id.utf16) }; return nil }); break
            }
        }
    }
    if calls.isEmpty { return true }
    for after in index..<contributions.count {
        for (position, message) in contributions[after].enumerated() {
            if case .assistant = message, after > index || position > 0 { return true }
            if case .toolResult(let result) = message, calls.contains(Array(result.toolCallId.utf16)) { return false }
        }
    }
    return true
}
public func generationEstimateContext(view: ContextView, extra: [Message] = []) -> Int {
    var measured: AssistantMessage?
    var measuredOrdinal: Int?
    var ordinal = 0
    for index in view.entries.indices {
        for message in view.contributions[index] {
            guard case .assistant(let assistant) = message else { continue }
            if (view.head == nil || view.entries[index].id > view.head!.id), calculateContextTokens(assistant.usage) > 0 {
                measured = assistant; measuredOrdinal = ordinal
            }
            ordinal += 1
        }
    }
    var from = 0, tokens = measured.map { calculateContextTokens($0.usage) } ?? 0
    if let measuredOrdinal {
        var ordinal = 0
        for (index, message) in view.messages.enumerated() {
            guard case .assistant = message else { continue }
            if ordinal == measuredOrdinal { from = index + 1; break }
            ordinal += 1
        }
    }
    for message in view.messages.dropFirst(from) { tokens += estimateMessageTokens(message) }
    for message in extra { tokens += estimateMessageTokens(message) }
    return tokens
}
