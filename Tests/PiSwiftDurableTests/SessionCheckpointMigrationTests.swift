import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private enum CheckpointFailure: Error { case predicate, rollback }
private struct CheckpointCount: Codable, Sendable, Equatable { var count: Int }
private func checkpointToken(kind: String = "checkpoint", version: Int = 1, migrate: (@Sendable (JSONObject, Int) throws -> JSONObject)? = nil, predicate: (@Sendable (JSONObject, [Delta.Op], CheckpointInfo) throws -> Bool)? = nil) throws -> SessionDocToken<CheckpointCount> {
    try SessionDocToken(kind: kind, version: version, initial: { CheckpointCount(count: 0) }, migrate: migrate, checkpointWhen: predicate)
}
private func increment(_ token: SessionDocToken<CheckpointCount>, _ session: Session) async throws {
    try await session.commit({ tx in let draft = try await tx.doc(token); try draft.set("count", .number(try draft.get("count")!.numberValue! + 1)) }, context: .background)
}
private func contentKinds(_ writes: [[StorageWrite]]) -> [String] {
    writes.flatMap { $0.compactMap { write in
        guard case .documentChange(_, let content, _) = write else { return nil }
        switch content { case .base: return "base"; case .delta: return "delta" }
    } }
}

@Suite struct SessionCheckpointMigrationTests {
    // session-checkpoints-migrations.test.ts:20. Swift closures capture the initializer instead of a JavaScript receiver.
    @Test func SessionCheckpointReceiver() async throws {
        let initial: @Sendable () -> CheckpointCount = { CheckpointCount(count: 0) }
        let token = try SessionDocToken<CheckpointCount>(kind: "receiver", version: 1, initial: initial, checkpointWhen: { value, _, _ in value["count"] == .number(Double(initial().count + 2)) })
        let harness = try await openTestSession()
        _ = try await harness.session.commit({ tx in try await tx.doc(token) }, context: .background)
        try await increment(token, harness.session); try await increment(token, harness.session)
        #expect(contentKinds(await harness.storage.commits) == ["delta", "base"])
    }

    // :42. Value and operation equality replace JavaScript identity assertions.
    @Test func SessionCheckpointPreparedValueAndOps() async throws {
        let calls = SessionTestLog<(JSONObject, [Delta.Op])>(); let falseCalls = SessionTestLog<(JSONObject, [Delta.Op])>()
        let base = try checkpointToken(kind: "base", predicate: { value, ops, _ in calls.append((value, ops)); return true })
        let delta = try checkpointToken(kind: "delta", predicate: { value, ops, _ in falseCalls.append((value, ops)); return false })
        let ordinary = try checkpointToken(kind: "ordinary"); let harness = try await openTestSession()
        try await harness.session.commit({ tx in _ = try await tx.doc(base); _ = try await tx.doc(delta); _ = try await tx.doc(ordinary) }, context: .background)
        #expect(calls.count == 0); #expect(falseCalls.count == 0)
        try await harness.session.commit({ tx in try await tx.doc(base).set("count", .number(1)); try await tx.doc(delta).set("count", .number(1)); try await tx.doc(ordinary).set("count", .number(1)) }, context: .background)
        #expect(contentKinds(await harness.storage.commits) == ["base", "delta", "delta"])
        let publication = documentChanges(harness.publications.values.last!)
        #expect(calls.count == 1); #expect(falseCalls.count == 1)
        #expect(calls.values[0].0 == publication[0].value); #expect(calls.values[0].1 == publication[0].ops)
        #expect(falseCalls.values[0].0 == publication[1].value); #expect(falseCalls.values[0].1 == publication[1].ops)
    }

    // :112
    @Test func SessionCheckpointDeltaCount() async throws {
        let seen = SessionTestLog<Int>()
        let v1 = try checkpointToken(predicate: { _, _, info in seen.append(info.deltasSinceBase); return info.deltasSinceBase >= 2 })
        let v2 = try checkpointToken(version: 2, migrate: { value, _ in value }, predicate: { _, _, info in seen.append(info.deltasSinceBase); return false })
        let harness = try await openTestSession(); _ = try await harness.session.commit({ tx in try await tx.doc(v1) }, context: .background)
        for _ in 0..<3 { try await increment(v1, harness.session) }
        try await harness.session.unloadDocuments(); try await increment(v1, harness.session)
        #expect(seen.values == [0, 1, 2, 0]); #expect(contentKinds(await harness.storage.commits) == ["delta", "delta", "base", "delta"])
        try await increment(v2, harness.session); try await increment(v2, harness.session)
        #expect(seen.values == [0, 1, 2, 0, 0]); #expect(contentKinds(await harness.storage.commits).suffix(2) == ["base", "delta"])
    }

    // :160
    @Test func SessionCheckpointEmptyAndStructuralNoOp() async throws {
        let calls = SessionTestLog<Int>(); let token = try SessionDocToken<JSONObject>(kind: "no-op", version: 1, initial: { ["items": .array([.string("a"), .string("b")])] }, checkpointWhen: { _, _, _ in calls.append(1); return false })
        let harness = try await openTestSession(); _ = try await harness.session.commit({ tx in try await tx.doc(token) }, context: .background)
        let commits = await harness.storage.commits.count
        try await harness.session.commit({ tx in let items = try await tx.doc(token).child("items")!; try items.append(.string("x")); _ = try items.popLast() }, context: .background)
        #expect(calls.count == 0); #expect(await harness.storage.commits.count == commits)
        try await harness.session.commit({ tx in let items = try await tx.doc(token).child("items")!; let first = try items.popFirst()!; try items.prepend(contentsOf: [first]) }, context: .background)
        #expect(calls.count == 1); #expect(contentKinds(await harness.storage.commits) == ["delta"])
    }

    // :196
    @Test func SessionCheckpointFailureRollback() async throws {
        let firstCalls = SessionTestLog<Int>(); let fail = SessionTestLog<Bool>(); fail.append(true)
        let first = try checkpointToken(kind: "first", predicate: { _, _, _ in firstCalls.append(1); return false })
        let second = try checkpointToken(kind: "second", predicate: { _, _, _ in if fail.values.last! { throw CheckpointFailure.predicate }; return false })
        let harness = try await openTestSession(); try await harness.session.commit({ tx in _ = try await tx.doc(first); _ = try await tx.doc(second) }, context: .background)
        let publications = harness.publications.count
        await #expect(throws: CheckpointFailure.self) { try await harness.session.commit({ tx in try await tx.doc(first).set("count", .number(1)); try await tx.doc(second).set("count", .number(2)) }, context: .background) }
        #expect(firstCalls.count == 1); #expect(await harness.storage.commits.count == 1); #expect(harness.publications.count == publications)
        #expect(try await harness.session.snapshot(first, context: .background)?.count == 0); #expect(try await harness.session.snapshot(second, context: .background)?.count == 0)
        fail.append(false); try await harness.session.commit({ tx in try await tx.doc(first).set("count", .number(3)); try await tx.doc(second).set("count", .number(4)) }, context: .background)
        #expect(try await harness.session.snapshot(second, context: .background)?.count == 4)
    }

    // :252
    @Test func SessionCheckpointDeltaTailReplay() async throws {
        let calls = SessionTestLog<Int>(); let token = try SessionDocToken<JSONObject>(kind: "tail", version: 1, initial: { ["values": .array([])] }, checkpointWhen: { _, _, _ in calls.append(1); return false })
        let harness = try await openTestSession(); _ = try await harness.session.commit({ tx in try await tx.doc(token) }, context: .background)
        for value in 1...8 { try await harness.session.commit({ tx in try await tx.doc(token).child("values")!.append(.number(Double(value))) }, context: .background) }
        #expect(calls.count == 8); #expect(contentKinds(await harness.storage.commits) == Array(repeating: "delta", count: 8))
        try await harness.session.unloadDocuments(); #expect(try await harness.session.snapshot(token, context: .background)?["values"] == .array((1...8).map { .number(Double($0)) }))
    }

    // :279
    @Test func SessionCheckpointRootReplacementDelta() async throws {
        let initial = JSONObject((0..<4100).map { ("field\($0)", JSONValue.number(0)) })
        let token = try SessionDocToken<JSONObject>(kind: "root", version: 1, initial: { initial }, checkpointWhen: { _, _, _ in false })
        let harness = try await openTestSession(); _ = try await harness.session.commit({ tx in try await tx.doc(token) }, context: .background)
        try await harness.session.commit({ tx in let draft = try await tx.doc(token); for index in 0..<4100 { try draft.set("field\(index)", .number(1)) } }, context: .background)
        guard case .documentChange(_, .delta(_, let ops, _), _) = await harness.storage.commits.last![0] else { Issue.record("Expected delta"); return }
        #expect(ops.count == 1); guard case .replace = ops[0] else { Issue.record("Expected replacement"); return }
        try await harness.session.unloadDocuments(); #expect(try await harness.session.snapshot(token, context: .background)?["field4099"] == .number(1))
    }

    // :306
    @Test func SessionCheckpointBeforeRetirement() async throws {
        let calls = SessionTestLog<Int>(); let token = try checkpointToken(predicate: { _, _, _ in calls.append(1); return true })
        let harness = try await openTestSession(); _ = try await harness.session.commit({ tx in try await tx.doc(token) }, context: .background)
        try await harness.session.commit({ tx in try await tx.doc(token).set("count", .number(1)); try await tx.retireDoc(token) }, context: .background)
        #expect(calls.count == 1); #expect(contentKinds(await harness.storage.commits) == ["base"]); #expect(await harness.storage.commits.last!.last!.type == "document.retire")
    }

    // :333. Swift value types copy callback results.
    @Test func SessionMigrationColdLoadReadOnly() async throws {
        let migrations = SessionTestLog<Int>(); let old = try checkpointToken()
        let current = try checkpointToken(version: 3, migrate: { value, from in migrations.append(from); var result = value; result["count"] = .number(2); return result })
        let harness = try await openTestSession(); _ = try await harness.session.commit({ tx in try await tx.doc(old) }, context: .background); try await harness.session.unloadDocuments()
        #expect(try await harness.session.snapshot(current, context: .background)?.count == 2); #expect(try await harness.session.snapshot(current, context: .background)?.count == 2)
        #expect(migrations.values == [1]); #expect(await harness.storage.commits.count == 1)
        try await harness.session.unloadDocuments(); #expect(try await harness.session.snapshot(current, context: .background)?.count == 2); #expect(migrations.values == [1, 1]); #expect(await harness.storage.commits.count == 1)
    }

    // :376. D7 watch assertions are excluded; the migration publication is tested.
    @Test func SessionMigrationRequiredBaseThenDelta() async throws {
        let calls = SessionTestLog<Int>(); let old = try checkpointToken(); let current = try checkpointToken(version: 3, migrate: { value, _ in value }, predicate: { _, _, _ in calls.append(1); return false })
        let harness = try await openTestSession(); _ = try await harness.session.commit({ tx in try await tx.doc(old) }, context: .background)
        #expect(try await harness.session.snapshot(current, context: .background)?.count == 0)
        _ = try await harness.session.commit({ tx in try await tx.doc(current) }, context: .background)
        #expect(contentKinds(await harness.storage.commits) == ["base"]); #expect(calls.count == 0)
        let published = documentChanges(harness.publications.values.last!)[0]; #expect(published.version == 3); #expect(published.ops.isEmpty)
        try await increment(current, harness.session); #expect(contentKinds(await harness.storage.commits) == ["base", "delta"]); #expect(calls.count == 1)
        try await harness.session.unloadDocuments(); #expect(try await harness.session.snapshot(current, context: .background)?.count == 1)
    }

    // :440
    @Test func SessionMigrationRollbackCoalescesBase() async throws {
        let migrations = SessionTestLog<Int>(); let old = try checkpointToken(); let current = try checkpointToken(version: 2, migrate: { value, from in migrations.append(from); return value })
        let harness = try await openTestSession(); _ = try await harness.session.commit({ tx in try await tx.doc(old) }, context: .background)
        await #expect(throws: CheckpointFailure.self) { try await harness.session.commit({ tx in try await tx.doc(current).set("count", .number(8)); throw CheckpointFailure.rollback }, context: .background) }
        #expect(await harness.storage.commits.count == 1); #expect(try await harness.session.snapshot(current, context: .background)?.count == 0); #expect(migrations.count == 1)
        try await harness.session.commit({ tx in try await tx.doc(current).set("count", .number(9)) }, context: .background)
        #expect(contentKinds(await harness.storage.commits) == ["base"]); #expect(migrations.count == 1)
        #expect(documentChanges(harness.publications.values.last!)[0].ops == [.set(["count"], .number(9))])
    }

    // :496. A non-finite number replaces JavaScript Date.
    @Test func SessionMigrationInvalidJSON() async throws {
        let old = try checkpointToken(); let invalid = try checkpointToken(version: 2, migrate: { _, _ in ["count": .number(.infinity)] })
        let other = try checkpointToken(kind: "other"); let harness = try await openTestSession(); _ = try await harness.session.commit({ tx in try await tx.doc(old) }, context: .background)
        await #expect(throws: JSONValueError.self) { _ = try await harness.session.snapshot(invalid, context: .background) }
        await #expect(throws: JSONValueError.self) { _ = try await harness.session.commit({ tx in try await tx.doc(invalid) }, context: .background) }
        #expect(await harness.storage.commits.count == 1); _ = try await harness.session.commit({ tx in try await tx.doc(other) }, context: .background)
        #expect(try await harness.session.snapshot(other, context: .background)?.count == 0)
    }

    // :529
    @Test func SessionMigrationVersionRejection() async throws {
        let v2 = try checkpointToken(version: 2); let v1 = try checkpointToken(); let v3 = try checkpointToken(version: 3); let harness = try await openTestSession()
        _ = try await harness.session.commit({ tx in try await tx.doc(v2) }, context: .background); try await harness.session.unloadDocuments()
        for token in [v1, v3] {
            await #expect(throws: DocumentDefinitionError.self) { _ = try await harness.session.snapshot(token, context: .background) }
            await #expect(throws: DocumentDefinitionError.self) { _ = try await harness.session.commit({ tx in try await tx.doc(token) }, context: .background) }
        }
        #expect(await harness.storage.commits.count == 1)
    }

    // :564
    @Test func SessionMigrationBaseBeforeRetirement() async throws {
        let old = try checkpointToken(); let current = try checkpointToken(version: 2, migrate: { value, _ in value }, predicate: { _, _, _ in throw CheckpointFailure.predicate }); let harness = try await openTestSession()
        _ = try await harness.session.commit({ tx in try await tx.doc(old) }, context: .background)
        try await harness.session.commit({ tx in _ = try await tx.doc(current); try await tx.retireDoc(current) }, context: .background)
        #expect(contentKinds(await harness.storage.commits) == ["base"]); #expect(await harness.storage.commits.last!.count == 2)
    }

    // :597
    @Test func SessionMigrationUnaccessedUntouched() async throws {
        let first = try checkpointToken(kind: "first"); let second = try checkpointToken(kind: "second"); let firstV2 = try checkpointToken(kind: "first", version: 2, migrate: { value, _ in value }); let migrations = SessionTestLog<Int>()
        _ = try checkpointToken(kind: "second", version: 2, migrate: { value, _ in migrations.append(1); return value })
        let harness = try await openTestSession(); try await harness.session.commit({ tx in _ = try await tx.doc(first); _ = try await tx.doc(second) }, context: .background)
        try await harness.session.unloadDocuments(); #expect(try await harness.session.snapshot(firstV2, context: .background)?.count == 0)
        #expect(migrations.count == 0); #expect(await harness.storage.commits.count == 1)
        let record = try await harness.storage.findDocument(DocumentAddress(kind: "second", scope: .session()), at: .current, context: .background)!
        #expect(try await harness.storage.document(record.id, at: .current, context: .background)?.version == 1)
    }

    // :648. Fork document copies are D6; current and historical migration are tested here.
    @Test func SessionMigrationCurrentAndHistorical() async throws {
        let v1 = try RewindableConversationDocToken<CheckpointCount>(kind: "history", version: 1, fork: .asOf, initial: { CheckpointCount(count: 0) })
        let migrations = SessionTestLog<Int>(); let v3 = try RewindableConversationDocToken<CheckpointCount>(kind: "history", version: 3, fork: .asOf, initial: { CheckpointCount(count: 0) }, migrate: { value, from in migrations.append(from); return value })
        let family = try RewindableConversationDocFamilyToken<JSONObject, String>(kind: "history.family", version: 1, fork: .asOf, initial: { ["seed": .string($0), "count": .number(0)] })
        let harness = try await openTestSession(); let id = try await createConversation(harness.session)
        let first = try await harness.session.commit({ tx in let entry = try await tx.appendEntry(id, value: EntryDraft(kind: "first")); try await tx.doc(v1, conversationId: id).set("count", .number(1)); try await tx.doc(family, conversationId: id, key: "member", seed: "seed").set("count", .number(1)); return entry.id }, context: .background)
        let second = try await harness.session.commit({ tx in let entry = try await tx.appendEntry(id, value: EntryDraft(kind: "second")); try await tx.doc(v1, conversationId: id).set("count", .number(2)); return entry.id }, context: .background)
        #expect(try await harness.session.snapshot(v3, conversationId: id, context: .background)?.count == 2); #expect(migrations.values == [1])
        let third = try await harness.session.commit({ tx in let entry = try await tx.appendEntry(id, value: EntryDraft(kind: "third")); _ = try await tx.doc(v3, conversationId: id); return entry.id }, context: .background)
        #expect(try await harness.session.snapshotAsOf(v3, conversationId: id, at: first, context: .background)?.count == 1)
        #expect(try await harness.session.snapshotAsOf(v3, conversationId: id, at: second, context: .background)?.count == 2)
        #expect(try await harness.session.snapshotAsOf(v3, conversationId: id, at: third, context: .background)?.count == 2)
        #expect(migrations.values == [1, 1, 1]); #expect(try await harness.session.snapshotAsOf(family, conversationId: id, key: "member", at: first, context: .background)?["seed"] == .string("seed"))
    }

    // :735
    @Test func SessionHistoricalIncarnations() async throws {
        let token = try RewindableConversationDocToken<JSONObject>(kind: "incarnation", version: 1, fork: .asOf, initial: { ["value": .string("initial")] })
        let harness = try await openTestSession(); let id = try await createConversation(harness.session)
        let before = try await harness.session.commit({ tx in try await tx.appendEntry(id, value: EntryDraft(kind: "before")).id }, context: .background)
        let create = try await harness.session.commit({ tx in let entry = try await tx.appendEntry(id, value: EntryDraft(kind: "create")); try await tx.doc(token, conversationId: id).set("value", .string("old")); return entry.id }, context: .background)
        let retire = try await harness.session.commit({ tx in let entry = try await tx.appendEntry(id, value: EntryDraft(kind: "retire")); try await tx.retireDoc(token, conversationId: id); return entry.id }, context: .background)
        let recreate = try await harness.session.commit({ tx in let entry = try await tx.appendEntry(id, value: EntryDraft(kind: "recreate")); try await tx.doc(token, conversationId: id).set("value", .string("new")); return entry.id }, context: .background)
        #expect(try await harness.session.snapshotAsOf(token, conversationId: id, at: before, context: .background) == nil)
        #expect(try await harness.session.snapshotAsOf(token, conversationId: id, at: create, context: .background)?["value"] == .string("old"))
        #expect(try await harness.session.snapshotAsOf(token, conversationId: id, at: retire, context: .background) == nil)
        #expect(try await harness.session.snapshotAsOf(token, conversationId: id, at: recreate, context: .background)?["value"] == .string("new"))
        try await harness.session.close(context: .background)
        await #expect(throws: SessionError.self) { _ = try await harness.session.snapshotAsOf(token, conversationId: id, at: recreate, context: .background) }
    }

    // :792
    @Test func SessionMigrationCachedOlderToken() async throws {
        let old = try SessionDocToken<JSONObject>(kind: "cache", version: 1, initial: { ["name": .string("first")] })
        let current = try SessionDocToken<JSONObject>(kind: "cache", version: 2, initial: { ["names": .array([])] }, migrate: { value, _ in ["names": .array([value["name"]!])] })
        let harness = try await openTestSession(); _ = try await harness.session.commit({ tx in try await tx.doc(old) }, context: .background)
        #expect(try await harness.session.snapshot(current, context: .background)?["names"] == .array([.string("first")]))
        try await harness.session.commit({ tx in try await tx.doc(current).child("names")!.append(.string("second")) }, context: .background)
        #expect(contentKinds(await harness.storage.commits) == ["base"])
        await #expect(throws: DocumentDefinitionError.self) { _ = try await harness.session.snapshot(old, context: .background) }
    }

    // :833
    @Test func SessionMigrationOlderTokenReloadsStorage() async throws {
        let old = try SessionDocToken<JSONObject>(kind: "cache", version: 1, initial: { ["name": .string("first")] })
        let current = try SessionDocToken<JSONObject>(kind: "cache", version: 2, initial: { ["names": .array([])] }, migrate: { value, _ in ["names": .array([value["name"]!])] })
        let harness = try await openTestSession(); _ = try await harness.session.commit({ tx in try await tx.doc(old) }, context: .background)
        #expect(try await harness.session.snapshot(current, context: .background)?["names"] == .array([.string("first")]))
        #expect(try await harness.session.snapshot(old, context: .background)?["name"] == .string("first"))
        try await harness.session.commit({ tx in try await tx.doc(old).set("name", .string("renamed")) }, context: .background)
        #expect(try await harness.session.snapshot(current, context: .background)?["names"] == .array([.string("renamed")]))
    }
}
