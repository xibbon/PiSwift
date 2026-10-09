import PiSwiftAI
import PiSwiftChord

public let ProviderDoc = try! ConversationDocToken<ProviderState>(kind: "pi.provider", version: 1, fork: .initial,
    initial: { try ProviderState.fresh() }, checkpointWhen: { _, _, _ in true })
public func ensureProviderSessionId(runtime: TaskRuntime, context: PiSwiftChord.Context) async throws -> String {
    if let state = try await runtime.snapshot(ProviderDoc, conversationId: runtime.conversationId, context: context) { return state.sessionId }
    var created: String?
    try await runtime.commit({ tx, _ in
        created = try await tx.doc(ProviderDoc, conversationId: runtime.conversationId).get("sessionId")?.stringValue
        return nil
    }, context: context)
    guard let created else { throw SessionError.message("Conversation \(runtime.conversationId.rawValue) has no provider session ID") }
    return created
}
