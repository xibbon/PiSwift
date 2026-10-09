import PiSwiftChord
@testable import PiSwiftDurable

// Compile-only checks for all owner, key, and seed overloads. Swift rejects
// absent owners, wrong owner ID types, absent seeds, and wrong seed types.
// snapshotAsOf is available only for rewindable conversation tokens.
// documentState and watchDoc checks belong to D7.
func sessionDefinitionCompileChecks(
    session: Session, tx: Transaction, conversation: ConversationID,
    task: TaskID, entry: EntryID
) async throws {
    let tokens = try DefinitionTokens()
    let _: JSONDraft = try await tx.doc(tokens.session)
    let _: JSONDraft = try await tx.doc(tokens.latest, conversationId: conversation)
    let _: JSONDraft = try await tx.doc(tokens.rewindable, conversationId: conversation)
    let _: JSONDraft = try await tx.doc(tokens.task, taskId: task)
    let _: JSONDraft = try await tx.doc(tokens.sessionFamily, key: "k", seed: 1)
    let _: JSONDraft = try await tx.doc(tokens.latestFamily, conversationId: conversation, key: "k", seed: 1)
    let _: JSONDraft = try await tx.doc(tokens.rewindableFamily, conversationId: conversation, key: "k", seed: 1)
    let _: JSONDraft = try await tx.doc(tokens.taskFamily, taskId: task, key: "k", seed: 1)
    try await tx.retireDoc(tokens.session)
    try await tx.retireDoc(tokens.latest, conversationId: conversation)
    try await tx.retireDoc(tokens.rewindable, conversationId: conversation)
    try await tx.retireDoc(tokens.task, taskId: task)
    try await tx.retireDoc(tokens.sessionFamily, key: "k")
    try await tx.retireDoc(tokens.latestFamily, conversationId: conversation, key: "k")
    try await tx.retireDoc(tokens.rewindableFamily, conversationId: conversation, key: "k")
    try await tx.retireDoc(tokens.taskFamily, taskId: task, key: "k")
    let _: DefinitionState? = try await session.snapshotAsOf(tokens.rewindable, conversationId: conversation, at: entry, context: .background)
    let _: DefinitionState? = try await session.snapshotAsOf(tokens.rewindableFamily, conversationId: conversation, key: "k", at: entry, context: .background)
    let note = try EntryKind<DefinitionState>("t.note")
    let _: EntryRecord? = try await tx.entry(entry)
    let _: TypedEntry<DefinitionState>? = try await tx.entry(note, id: entry)
    let _: EntryRecord = try await tx.appendEntry(conversation, value: EntryDraft(kind: "t.raw"))
    let typed: TypedEntry<DefinitionState> = try await tx.appendEntry(note, conversationId: conversation, value: TypedEntryDraft(data: DefinitionState(value: 1)))
    let _: Int? = typed.data?.value
}
