import PiSwiftChord
import Testing
@testable import PiSwiftDurable

@Test func StateCancelledAcquisitionDoesNotAttach() async throws {
    let harness = try await openTestSession()
    let token = try SessionDocToken<JSONObject>(kind: "state.cancel", version: 1, initial: { ["n": 0] })
    try await harness.session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
    try await harness.session.unloadDocuments()
    let gate = await harness.storage.holdFindDocument()
    let context = PiSwiftChord.Context.background.withCancel()
    let acquisition = Task { try await harness.session.documentState(token, context: context.context) }
    await gate.waitUntilEntered()
    context.cancel()
    await gate.release()
    do { _ = try await acquisition.value; Issue.record("Cancelled state acquisition succeeded") }
    catch {}
    let state = try #require(try await harness.session.documentState(token, context: .background))
    #expect(state.value == ["n": 0])
    state.dispose()
    try await harness.session.close(context: .background)
}

@Test func WatchTypedDecodeFailureEndsOnlyWatch() async throws {
    struct Value: Codable, Sendable { let n: Int }
    let harness = try await openTestSession()
    let token = try SessionDocToken<Value>(kind: "watch.decode", version: 1, initial: { Value(n: 0) })
    try await harness.session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
    let watch = try #require(try await harness.session.watchDoc(token, context: .background))
    try watch.start { _, _, _ in }
    try await harness.session.commit({ tx in
        let draft = try await tx.doc(token)
        try draft.set("n", .string("invalid"))
    }, context: .background)
    if case .listenerError = await watch.closed {} else { Issue.record("Decode failure did not end the watch") }
    try await harness.session.commit({ tx in
        let draft = try await tx.doc(token)
        try draft.set("n", .number(1))
    }, context: .background)
    #expect(try await harness.session.snapshot(token, context: .background)?.n == 1)
    try await harness.session.close(context: .background)
}

// Check every observer overload without modifying the D4 compile checks.
func sessionObservationCompileChecks(session: Session, observer: any DocumentObserver,
                                     conversation: ConversationID, task: TaskID) async throws {
    let t = try DefinitionTokens()
    let _: DocumentWatch<DefinitionState>? = try await observer.watchDoc(t.session, context: .background)
    let _ = try await observer.watchDoc(t.latest, conversationId: conversation, context: .background)
    let _ = try await observer.watchDoc(t.rewindable, conversationId: conversation, context: .background)
    let _ = try await observer.watchDoc(t.task, taskId: task, context: .background)
    let _ = try await observer.watchDoc(t.sessionFamily, key: "k", context: .background)
    let _ = try await observer.watchDoc(t.latestFamily, conversationId: conversation, key: "k", context: .background)
    let _ = try await observer.watchDoc(t.rewindableFamily, conversationId: conversation, key: "k", context: .background)
    let _ = try await observer.watchDoc(t.taskFamily, taskId: task, key: "k", context: .background)
    let _: DocumentState<DefinitionState>? = try await session.documentState(t.session, context: .background)
    let _ = try await session.documentState(t.latest, conversationId: conversation, context: .background)
    let _ = try await session.documentState(t.rewindable, conversationId: conversation, context: .background)
    let _ = try await session.documentState(t.task, taskId: task, context: .background)
    let _ = try await session.documentState(t.sessionFamily, key: "k", context: .background)
    let _ = try await session.documentState(t.latestFamily, conversationId: conversation, key: "k", context: .background)
    let _ = try await session.documentState(t.rewindableFamily, conversationId: conversation, key: "k", context: .background)
    let _ = try await session.documentState(t.taskFamily, taskId: task, key: "k", context: .background)
}

@Test func StateTypedDecodeFailureKeepsLastValue() async throws {
    struct Value: Codable, Sendable { let n: Int }
    let harness = try await openTestSession()
    let token = try SessionDocToken<Value>(kind: "state.decode", version: 1, initial: { Value(n: 0) })
    try await harness.session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
    let state = try #require(try await harness.session.documentState(token, context: .background))
    try await harness.session.commit({ tx in try await tx.doc(token).set("n", "invalid") }, context: .background)
    #expect(state.value?.n == 0)
    try await harness.session.commit({ tx in try await tx.doc(token).set("n", 1) }, context: .background)
    #expect(state.value?.n == 0)
    #expect(try await harness.session.snapshot(token, context: .background)?.n == 1)
    state.dispose()
    try await harness.session.close(context: .background)
}

@Test func StateSessionCloseDetachesBeforeAdmittedCommitSettles() async throws {
    let harness = try await openTestSession()
    let token = try SessionDocToken<JSONObject>(kind: "state.close", version: 1, initial: { ["n": 0] })
    try await harness.session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
    let state = try #require(try await harness.session.documentState(token, context: .background))
    let gate = await harness.storage.holdCommits()
    let commit = Task {
        try await harness.session.commit({ tx in try await tx.doc(token).set("n", 1) }, context: .background)
    }
    await gate.waitUntilEntered()
    let closed = SessionTestGate()
    _ = try harness.session.subscribeClose { closed.release() }
    let close = Task { try await harness.session.close(context: .background) }
    await closed.wait()
    await gate.release()
    try await commit.value
    try await close.value
    await state.waitUntilIdle()
    #expect(state.value == ["n": 0])
    state.dispose()
}
