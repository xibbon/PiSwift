import Testing
import Synchronization
import PiSwiftChord
@testable import PiSwiftDurable

private enum DocumentTestFailure: Error { case callback, checkpoint }
private struct LiveState: Codable, Sendable, Equatable {
    var message: String?
    var items: [String] = []
    var nested: CountState = CountState(count: 0)
    var other: LabelState = LabelState(label: "x")
}
private struct CountState: Codable, Sendable, Equatable { var count: Int }
private struct LabelState: Codable, Sendable, Equatable { var label: String }
private func liveToken() throws -> ConversationDocToken<LiveState> {
    try ConversationDocToken(kind: "test.live", version: 1, fork: .initial, initial: { LiveState() })
}
private func counterToken() throws -> SessionDocToken<CountState> {
    try SessionDocToken(kind: "test.counter", version: 1, initial: { CountState(count: 0) })
}
private func liveSetup() async throws -> (SessionTestHarness, ConversationID, ConversationDocToken<LiveState>) {
    let harness = try await openTestSession()
    let id = try await createConversation(harness.session)
    let token = try liveToken()
    try await harness.session.commit({ tx in
        let draft = try await tx.doc(token, conversationId: id)
        try draft.child("items")!.append(contentsOf: [.string("a"), .string("b")])
    }, context: .background)
    return (harness, id, token)
}

@Suite struct SessionDocumentTests {
    // session-documents.test.ts:78
    @Test func SessionDocumentsInitialBase() async throws {
        let harness = try await openTestSession(); let id = try await createConversation(harness.session); let token = try liveToken()
        try await harness.session.commit({ tx in try await tx.doc(token, conversationId: id).set("message", .string("hello")) }, context: .background)
        let writes = await harness.storage.commits.last!
        #expect(writes.count == 1)
        guard case .documentCreate(let record, let content, _) = writes[0] else { Issue.record("Expected creation"); return }
        #expect(record.scope == .conversation(conversationId: id)); #expect(record.history == .latest); #expect(record.fork == .initial)
        #expect(content.value["message"] == .string("hello"))
        let publication = harness.publications.values.last!; let document = documentChanges(publication)[0]
        #expect(document.record.createdAt == publication.seq); #expect(document.conversationId == id)
        let snapshot = try await harness.session.snapshot(token, conversationId: id, context: .background)
        #expect(snapshot?.message == "hello"); #expect(document.value == (try documentObject(snapshot!)))
    }

    // :109
    @Test func SessionDocumentsAbsentSnapshots() async throws {
        let harness = try await openTestSession(); let id = try await createConversation(harness.session)
        let family = try SessionDocFamilyToken<JSONObject, String>(kind: "family", version: 1, initial: { ["seed": .string($0)] })
        #expect(try await harness.session.snapshot(liveToken(), conversationId: id, context: .background) == nil)
        #expect(try await harness.session.snapshot(counterToken(), context: .background) == nil)
        #expect(try await harness.session.snapshot(family, key: "k", context: .background) == nil)
        #expect(await harness.storage.commits.count == 1); #expect(await harness.storage.mintCount == 1)
    }

    // :120. Swift uses value equality for immutable revisions.
    @Test func SessionDocumentsPriorRevisionStable() async throws {
        let (harness, id, token) = try await liveSetup()
        let first = try await harness.session.snapshot(token, conversationId: id, context: .background)!
        #expect(try await harness.session.snapshot(token, conversationId: id, context: .background) == first)
        try await harness.session.commit({ tx in try await tx.doc(token, conversationId: id).child("nested")!.set("count", .number(1)) }, context: .background)
        let second = try await harness.session.snapshot(token, conversationId: id, context: .background)!
        #expect(first.nested.count == 0); #expect(second.nested.count == 1); #expect(first.items == second.items); #expect(first.other == second.other)
    }

    // :137. Operation and value equality replace JavaScript pointer identity.
    @Test func SessionDocumentsPublicationOps() async throws {
        let (harness, id, token) = try await liveSetup()
        try await harness.session.commit({ tx in
            let draft = try await tx.doc(token, conversationId: id)
            try draft.set("other", .object(["label": .string("y")])); try draft.child("items")!.append(.string("c"))
        }, context: .background)
        let published = documentChanges(harness.publications.values.last!)[0]
        guard case .documentChange(_, .delta(_, let ops, _), _) = await harness.storage.admittedCommits.last![0] else { Issue.record("Expected delta"); return }
        #expect(published.ops == ops); #expect(ops.contains(.set(["other"], .object(["label": .string("y")]))))
        #expect(published.value == (try documentObject(await harness.session.snapshot(token, conversationId: id, context: .background)!)))
    }

    // :158
    @Test func SessionDocumentsCopyPerPlacement() async throws {
        let (harness, id, token) = try await liveSetup()
        var value: JSONObject = ["label": .string("shared")]
        try await harness.session.commit({ tx in
            let draft = try await tx.doc(token, conversationId: id)
            try draft.set("other", .object(value)); try draft.set("copy", .object(value)); value["label"] = .string("mutated")
            try draft.child("copy")!.set("label", .string("copy-only"))
        }, context: .background)
        let published = documentChanges(harness.publications.values.last!)[0].value!
        #expect(published["other"] == .object(["label": .string("shared")]))
        #expect(published["copy"] == .object(["label": .string("copy-only")]))
    }

    // :174
    @Test func SessionDocumentsEmptyBatch() async throws {
        let (harness, id, token) = try await liveSetup(); let commits = await harness.storage.commits.count; let count = harness.publications.count
        try await harness.session.commit({ tx in
            let draft = try await tx.doc(token, conversationId: id)
            try draft.child("nested")!.set("count", .number(0)); let items = try draft.child("items")!; try items.append(.string("z")); _ = try items.popLast()
        }, context: .background)
        #expect(await harness.storage.commits.count == commits); #expect(harness.publications.count == count)
    }

    // :190
    @Test func SessionDocumentsStructuralNoOp() async throws {
        let (harness, id, token) = try await liveSetup(); let before = try await harness.session.snapshot(token, conversationId: id, context: .background)
        try await harness.session.commit({ tx in let items = try await tx.doc(token, conversationId: id).child("items")!; let first = try items.popFirst()!; try items.prepend(contentsOf: [first]) }, context: .background)
        #expect(try await harness.session.snapshot(token, conversationId: id, context: .background) == before)
        #expect(!documentChanges(harness.publications.values.last!)[0].ops.isEmpty)
        guard case .documentChange(_, .delta, _) = await harness.storage.commits.last![0] else { Issue.record("Expected delta"); return }
    }

    // :207
    @Test func SessionDocumentsEscapedDraftsRevoked() async throws {
        let (harness, id, token) = try await liveSetup()
        let escaped = try await harness.session.commit({ tx in let draft = try await tx.doc(token, conversationId: id); let items = try draft.child("items")!; try draft.set("message", .string("inside")); return (draft, items) }, context: .background)
        let draft = escaped.0
        #expect(throws: TrackerError.self) { try draft.get("message") }; #expect(throws: TrackerError.self) { try draft.set("message", .string("outside")) }
        #expect(throws: TrackerError.self) { try escaped.1.count() }; #expect(throws: TrackerError.self) { try escaped.1.append(.string("outside")) }
        let returned = try await harness.session.commit({ tx in try await tx.doc(token, conversationId: id) }, context: .background)
        #expect(throws: TrackerError.self) { try returned.get("message") }
        #expect(try await harness.session.snapshot(token, conversationId: id, context: .background)?.message == "inside")
    }

    // :228
    @Test func SessionDocumentsCallbackRollback() async throws {
        let (harness, id, token) = try await liveSetup(); let before = try await harness.session.snapshot(token, conversationId: id, context: .background); let count = await harness.storage.commits.count
        let counter = try counterToken()
        await #expect(throws: DocumentTestFailure.self) {
            try await harness.session.commit({ tx in try await tx.doc(token, conversationId: id).set("message", .string("lost")); try await tx.doc(counter).set("count", .number(5)); throw DocumentTestFailure.callback }, context: .background)
        }
        #expect(await harness.storage.commits.count == count); #expect(try await harness.session.snapshot(token, conversationId: id, context: .background) == before); #expect(try await harness.session.snapshot(counter, context: .background) == nil)
        try await harness.session.commit({ tx in try await tx.doc(token, conversationId: id).set("message", .string("kept")) }, context: .background)
    }

    // :250
    @Test func SessionDocumentsConcurrentAcquisitionOnce() async throws {
        let harness = try await openTestSession(); let count = SessionTestLog<Int>()
        let token = try SessionDocToken<CountState>(kind: "once", version: 1, initial: { count.append(1); return CountState(count: 0) })
        try await harness.session.commit({ tx in
            async let first = tx.doc(token); async let second = tx.doc(token)
            let drafts = try await (first, second); try drafts.0.set("count", .number(2)); #expect(try drafts.1.get("count") == .number(2))
        }, context: .background)
        #expect(count.count == 1); #expect(await harness.storage.mintCount == 1); #expect(await harness.storage.commits.last!.count == 1)
    }

    // :266
    @Test func SessionDocumentsFirstFamilySeed() async throws {
        let harness = try await openTestSession(); let seeds = SessionTestLog<String>()
        let token = try SessionDocFamilyToken<JSONObject, String>(kind: "family", version: 1, initial: { seeds.append($0); return ["seed": .string($0), "hits": .number(0)] })
        try await harness.session.commit({ tx in
            let first = try await tx.doc(token, key: "k", seed: "first"); let second = try await tx.doc(token, key: "k", seed: "second"); try first.set("hits", .number(1)); #expect(try second.get("hits") == .number(1))
        }, context: .background)
        try await harness.session.commit({ tx in try await tx.doc(token, key: "k", seed: "third").set("hits", .number(2)); _ = try await tx.doc(token, key: "other", seed: "fourth") }, context: .background)
        #expect(seeds.values == ["first", "fourth"]); #expect(try await harness.session.snapshot(token, key: "k", context: .background)?["seed"] == .string("first"))
    }

    @Test func SessionDocumentsDuplicateFamilySeedIsNotEncoded() async throws {
        let harness = try await openTestSession()
        let token = try SessionDocFamilyToken<JSONObject, JSONValue>(kind: "seed-validation", version: 1, initial: { ["seed": $0] })
        try await harness.session.commit({ tx in
            _ = try await tx.doc(token, key: "member", seed: .string("first"))
            _ = try await tx.doc(token, key: "member", seed: .number(.infinity))
        }, context: .background)
        #expect(try await harness.session.snapshot(token, key: "member", context: .background) == ["seed": .string("first")])
        // A first acquisition in a later transaction still checks its seed, even for a stored member.
        await #expect(throws: JSONValueError.self) { _ = try await harness.session.commit({ tx in try await tx.doc(token, key: "member", seed: .number(.infinity)) }, context: .background) }
    }

    // :284, :311, :337. A gate makes the unawaited Swift operation start before callback settlement.
    @Test(arguments: [0, 1, 2]) func SessionDocumentsPendingAcquisition(_ mode: Int) async throws {
        let harness = try await openTestSession(); let initial = SessionTestLog<Int>()
        let token = try SessionDocToken<CountState>(kind: "late", version: 1, initial: { initial.append(1); return CountState(count: 0) })
        if mode != 1 { _ = try await harness.session.commit({ tx in try await tx.doc(token) }, context: .background); try await harness.session.unloadDocuments() }
        let gate = await harness.storage.holdFindDocument(); let callbackDone = SessionTestGate(); let transactions = SessionTestLog<Transaction>(); let pending = Mutex<Task<JSONDraft, any Error>?>(nil)
        let commits = await harness.storage.commits.count; let mints = await harness.storage.mintCount; let initialCount = initial.count
        let commit = Task {
            try await harness.session.commit({ tx in
                transactions.append(tx)
                let operation = Task { try await tx.doc(token) }; pending.withLock { $0 = operation }
                await gate.waitUntilEntered(); callbackDone.release()
                if mode == 2 { throw DocumentTestFailure.callback }
            }, context: .background)
        }
        await callbackDone.wait()
        await transactions.values[0].waitUntilSettled()
        // A read queued behind the commit cannot run until the pending acquisition is drained.
        let after = Task { try await harness.session.readOnLine { 1 } }
        await gate.release()
        do { try await commit.value; Issue.record("Expected commit rejection") }
        catch { if mode == 2 { #expect(error is DocumentTestFailure) } else { #expect(error as? SessionError == .pendingOperations) } }
        await #expect(throws: SessionError.self) { _ = try await pending.withLock { $0! }.value }
        #expect(try await after.value == 1); #expect(await harness.storage.commits.count == commits)
        #expect(await harness.storage.mintCount == mints); #expect(initial.count == initialCount)
    }

    // :352
    @Test func SessionDocumentsSettledTransaction() async throws {
        let harness = try await openTestSession(); let token = try counterToken()
        let tx = try await harness.session.commit({ $0 }, context: .background)
        await #expect(throws: SessionError.self) { _ = try await tx.doc(token) }
        await #expect(throws: SessionError.self) { _ = try await tx.conversation(rootConversationID) }
        #expect(throws: SessionError.self) { try tx.setTask(TaskRecord(id: try TaskID(999), conversationId: rootConversationID, kind: "settled", version: 1, input: .null, state: .pending(checkpoint: .null))) }
    }

    // :363
    @Test func SessionDocumentsTokenMismatch() async throws {
        let (harness, id, token) = try await liveSetup()
        let wrong = try RewindableConversationDocToken<LiveState>(kind: "test.live", version: 1, fork: .asOf, initial: { LiveState() })
        let newer = try ConversationDocToken<LiveState>(kind: "test.live", version: 2, fork: .initial, initial: { LiveState() })
        await #expect(throws: DocumentDefinitionError.self) { _ = try await harness.session.snapshot(wrong, conversationId: id, context: .background) }
        await #expect(throws: DocumentDefinitionError.self) { _ = try await harness.session.commit({ tx in try await tx.doc(wrong, conversationId: id) }, context: .background) }
        await #expect(throws: DocumentDefinitionError.self) { _ = try await harness.session.commit({ tx in try await tx.doc(newer, conversationId: id) }, context: .background) }
        #expect(try await harness.session.snapshot(token, conversationId: id, context: .background) != nil)
    }

    // :380. Non-finite numbers replace JavaScript Date and undefined values.
    @Test func SessionDocumentsInvalidJSON() async throws {
        let harness = try await openTestSession()
        let invalid = try SessionDocToken<JSONObject>(kind: "invalid", version: 1, initial: { ["value": .number(.infinity)] })
        await #expect(throws: JSONValueError.self) { _ = try await harness.session.commit({ tx in try await tx.doc(invalid) }, context: .background) }
        let token = try counterToken()
        await #expect(throws: TrackerError.self) { try await harness.session.commit({ tx in try await tx.doc(token).set("value", .number(.nan)) }, context: .background) }
        #expect(await harness.storage.commits.count == 0)
    }

    // :405
    @Test func SessionDocumentsAssemblyRollback() async throws {
        let (harness, id, token) = try await liveSetup(); let counter = try counterToken()
        _ = try await harness.session.commit({ tx in try await tx.doc(counter) }, context: .background)
        let before = try await harness.session.snapshot(token, conversationId: id, context: .background); let commits = await harness.storage.commits.count
        await #expect(throws: SessionError.self) {
            try await harness.session.commit({ tx in
                try await tx.doc(token, conversationId: id).set("message", .string("lost")); try await tx.doc(counter).set("count", .number(2))
                try tx.setTask(TaskRecord(id: try TaskID(999), conversationId: id, kind: "missing", version: 1, input: .null, state: .pending(checkpoint: .null)))
            }, context: .background)
        }
        #expect(await harness.storage.commits.count == commits); #expect(try await harness.session.snapshot(token, conversationId: id, context: .background) == before)
    }

    // :459
    @Test func SessionDocumentsStorageSettlementKeepsRevision() async throws {
        let (harness, id, token) = try await liveSetup(); let before = try await harness.session.snapshot(token, conversationId: id, context: .background)
        let gate = await harness.storage.holdCommits()
        let commit = Task { try await harness.session.commit({ tx in try await tx.doc(token, conversationId: id).child("items")!.append(.string("c")) }, context: .background) }
        await gate.waitUntilEntered(); #expect(try await harness.session.snapshot(token, conversationId: id, context: .background) == before)
        await gate.release(); try await commit.value
        #expect(before?.items == ["a", "b"]); #expect(try await harness.session.snapshot(token, conversationId: id, context: .background)?.items == ["a", "b", "c"])
    }

    // :479
    @Test func SessionDocumentsRetireReincarnate() async throws {
        let (harness, id, token) = try await liveSetup(); let old = documentChanges(harness.publications.values.last!)[0].record.id
        try await harness.session.commit({ tx in
            try await tx.doc(token, conversationId: id).set("message", .string("final")); try await tx.retireDoc(token, conversationId: id); try await tx.doc(token, conversationId: id).set("message", .string("new"))
        }, context: .background)
        #expect(await harness.storage.commits.last!.count == 3)
        let publication = harness.publications.values.last!; let changes = documentChanges(publication)
        #expect(changes[0].record.id == old); #expect(changes[0].record.retiredAt == publication.seq); #expect(changes[0].value == nil)
        #expect(changes[1].record.id != old); #expect(changes[1].ops.isEmpty); #expect(changes[1].record.createdAt == publication.seq)
        try await harness.session.commit({ tx in try await tx.retireDoc(token, conversationId: id) }, context: .background)
        #expect(try await harness.session.snapshot(token, conversationId: id, context: .background) == nil)
        try await harness.session.unloadDocuments(); #expect(try await harness.session.snapshot(token, conversationId: id, context: .background) == nil)
        let commits = await harness.storage.commits.count
        try await harness.session.commit({ tx in try await tx.retireDoc(token, conversationId: id) }, context: .background)
        #expect(await harness.storage.commits.count == commits)
    }

    // :519
    @Test func SessionDocumentsRetireWithoutAcquisition() async throws {
        let (harness, id, token) = try await liveSetup(); try await harness.session.unloadDocuments()
        try await harness.session.commit({ tx in try await tx.retireDoc(token, conversationId: id); try await tx.doc(token, conversationId: id).set("message", .string("replacement")) }, context: .background)
        #expect(await harness.storage.commits.last!.count == 2)
        let family = try SessionDocFamilyToken<JSONObject, String>(kind: "absent", version: 1, initial: { ["seed": .string($0)] })
        try await harness.session.commit({ tx in try await tx.retireDoc(family, key: "k"); _ = try await tx.doc(family, key: "k", seed: "seed") }, context: .background)
        #expect(await harness.storage.commits.last!.count == 1)
    }

    // :549. Explicit gates give the acquisition/retirement race a fixed order.
    @Test func SessionDocumentsRetirePendingAcquisition() async throws {
        let (harness, id, token) = try await liveSetup(); let old = documentChanges(harness.publications.values.last!)[0].record.id
        try await harness.session.unloadDocuments(); let gate = await harness.storage.holdFindDocument()
        try await harness.session.commit({ tx in
            let acquisition = Task { try await tx.doc(token, conversationId: id) }
            await gate.waitUntilEntered()
            let retirement = try tx.documents.startRetirement(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: id)), tx: tx)
            try await tx.retireDoc(token, conversationId: id)
            await gate.release(); try await acquisition.value.set("message", .string("final")); try await retirement?.value
        }, context: .background)
        #expect(await harness.storage.commits.last!.contains(.documentRetire(id: old)) == true)
        #expect(try await harness.session.snapshot(token, conversationId: id, context: .background) == nil)
        try await harness.session.commit({ tx in try await tx.doc(token, conversationId: id).set("message", .string("second")) }, context: .background)
        let secondID = documentChanges(harness.publications.values.last!)[0].record.id
        try await harness.session.unloadDocuments(); let secondGate = await harness.storage.holdFindDocument()
        try await harness.session.commit({ tx in
            let acquisition = Task { try await tx.doc(token, conversationId: id) }
            await secondGate.waitUntilEntered()
            let retirement = try tx.documents.startRetirement(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: id)), tx: tx)
            try await tx.retireDoc(token, conversationId: id)
            try await tx.doc(token, conversationId: id).set("message", .string("third"))
            await secondGate.release(); _ = try await acquisition.value; try await retirement?.value
        }, context: .background)
        #expect(await harness.storage.commits.last!.count == 2)
        #expect(await harness.storage.commits.last!.contains(.documentRetire(id: secondID)) == true)
        #expect(try await harness.session.snapshot(token, conversationId: id, context: .background)?.message == "third")
    }

    // :591
    @Test func SessionDocumentsReload() async throws {
        let (harness, id, token) = try await liveSetup(); let before = try await harness.session.snapshot(token, conversationId: id, context: .background)
        try await harness.session.unloadDocuments(); #expect(try await harness.session.snapshot(token, conversationId: id, context: .background) == before)
        try await harness.session.commit({ tx in try await tx.doc(token, conversationId: id).child("items")!.append(.string("c")) }, context: .background)
        try await harness.session.unloadDocuments(); #expect(try await harness.session.snapshot(token, conversationId: id, context: .background)?.items == ["a", "b", "c"])
    }
}
