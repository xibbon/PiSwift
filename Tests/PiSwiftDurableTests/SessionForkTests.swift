import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private func forkAsOf(_ kind: String = "fork.asOf", version: Int = 1,
                      migrate: (@Sendable (JSONObject, Int) throws -> JSONObject)? = nil) throws -> RewindableConversationDocToken<JSONObject> {
    try RewindableConversationDocToken(kind: kind, version: version, fork: .asOf,
                                      initial: { ["value": "initial"] }, migrate: migrate)
}
private func forkCurrent(_ kind: String = "fork.current") throws -> ConversationDocToken<JSONObject> {
    try ConversationDocToken(kind: kind, version: 1, fork: .current, initial: { ["value": "initial"] })
}
private func forkChild(_ session: Session, _ parent: ConversationID, _ entry: EntryID) async throws -> ConversationRecord {
    try await session.commit({ tx in try await tx.forkConversation(parent, at: entry, ownership: .ownerless()) }, context: .background)
}
private func forkPoint(_ session: Session, _ parent: ConversationID) async throws -> EntryID {
    try await session.commit({ tx in try await tx.appendEntry(parent, value: EntryDraft(kind: "point")).id }, context: .background)
}
private func forkExpectError(_ text: String, _ body: () async throws -> Void) async {
    do { try await body(); Issue.record("Expected error: \(text)") }
    catch { #expect(String(describing: error).contains(text)) }
}
private func forkCopies(_ writes: [StorageWrite]) -> [(DocumentCreate, DocumentCopySource)] {
    writes.compactMap { if case .documentCopy(let record, let source, _) = $0 { return (record, source) }; return nil }
}

@Suite struct SessionForkTests {
    // session-forks.test.ts:30
    @Test func ForkCopiesPoliciesAndFamilies() async throws {
        let h = try await openTestSession(); let parent = try await createConversation(h.session)
        let asOf = try forkAsOf(); let current = try forkCurrent()
        let initial = try ConversationDocToken<JSONObject>(kind: "fork.initial", version: 1, fork: .initial, initial: { [:] })
        let asFamily = try RewindableConversationDocFamilyToken<JSONObject, String>(kind: "fork.asFamily", version: 1, fork: .asOf, initial: { ["value": .string($0)] })
        let currentFamily = try ConversationDocFamilyToken<JSONObject, String>(kind: "fork.currentFamily", version: 1, fork: .current, initial: { ["value": .string($0)] })
        let point = try await h.session.commit({ tx in
            let point = try await tx.appendEntry(parent, value: EntryDraft(kind: "point")).id
            try await tx.doc(asOf, conversationId: parent).set("value", "as-at-fork")
            try await tx.doc(current, conversationId: parent).set("value", "current-at-fork")
            _ = try await tx.doc(initial, conversationId: parent)
            _ = try await tx.doc(asFamily, conversationId: parent, key: "a", seed: "family-a")
            _ = try await tx.doc(asFamily, conversationId: parent, key: "b", seed: "family-b")
            _ = try await tx.doc(currentFamily, conversationId: parent, key: "a", seed: "family-current")
            return point
        }, context: .background)
        try await h.session.commit({ tx in
            try await tx.doc(asOf, conversationId: parent).set("value", "as-after")
            try await tx.doc(current, conversationId: parent).set("value", "current-now")
            try await tx.doc(asFamily, conversationId: parent, key: "a", seed: "unused").set("value", "family-after")
            try await tx.doc(currentFamily, conversationId: parent, key: "a", seed: "unused").set("value", "family-now")
        }, context: .background)
        let reads = await h.storage.documentReadCount
        let child = try await forkChild(h.session, parent, point)
        #expect(await h.storage.documentReadCount == reads)
        #expect(try await h.session.snapshot(asOf, conversationId: child.id, context: .background) == ["value": "as-at-fork"])
        #expect(try await h.session.snapshot(current, conversationId: child.id, context: .background) == ["value": "current-now"])
        #expect(try await h.session.snapshot(initial, conversationId: child.id, context: .background) == nil)
        #expect(try await h.session.snapshot(asFamily, conversationId: child.id, key: "a", context: .background) == ["value": "family-a"])
        #expect(try await h.session.snapshot(asFamily, conversationId: child.id, key: "b", context: .background) == ["value": "family-b"])
        #expect(try await h.session.snapshot(currentFamily, conversationId: child.id, key: "a", context: .background) == ["value": "family-now"])
        let copies = forkCopies(await h.storage.admittedCommits.last!)
        let publication = h.publications.values.last!
        #expect(copies.count == 5)
        #expect(documentCopyChanges(publication).count == 5)
        for change in documentCopyChanges(publication) {
            #expect(change.record.createdAt == publication.seq)
            #expect(change.conversationId == child.id)
            #expect(copies.contains { $0.0.id == change.record.id && $0.1 == change.source })
        }
        let parentRecord = try await h.storage.findDocument(DocumentAddress(kind: asOf.definition.kind, scope: .conversation(conversationId: parent)), at: .current, context: .background)!
        let childRecord = try await h.storage.findDocument(DocumentAddress(kind: asOf.definition.kind, scope: .conversation(conversationId: child.id)), at: .current, context: .background)!
        #expect(parentRecord.id != childRecord.id)
        try await h.session.commit({ tx in
            try await tx.doc(asOf, conversationId: child.id).set("value", "child")
            try await tx.doc(initial, conversationId: child.id).set("value", "created")
        }, context: .background)
        #expect(try await h.session.snapshot(asOf, conversationId: parent, context: .background) == ["value": "as-after"])
        #expect(try await h.session.snapshot(asOf, conversationId: child.id, context: .background) == ["value": "child"])
        #expect(try await h.session.snapshot(initial, conversationId: child.id, context: .background) == ["value": "created"])
    }

    // :152
    @Test func ForkCopiesFinalCommitStateAndEntryBoundary() async throws {
        let h = try await openTestSession(); let parent = try await createConversation(h.session); let doc = try forkAsOf()
        let entries = try await h.session.commit({ tx in
            let included = try await tx.appendEntry(parent, value: EntryDraft(kind: "included")).id
            try await tx.doc(doc, conversationId: parent).set("value", "final")
            let excluded = try await tx.appendEntry(parent, value: EntryDraft(kind: "excluded")).id
            return (included, excluded)
        }, context: .background)
        let child = try await forkChild(h.session, parent, entries.0)
        #expect(try await h.session.snapshot(doc, conversationId: child.id, context: .background) == ["value": "final"])
        let visible = try await h.session.commit({ tx in try await tx.scanEntries(EntryQuery(conversationId: child.id), limit: 10) }, context: .background)
        #expect(visible.items.contains { $0.id == entries.0 }); #expect(!visible.items.contains { $0.id == entries.1 })
    }

    // :180
    @Test func ForkCopiesEntryOwnerAndImmediateParent() async throws {
        let h = try await openTestSession(); let root = try await createConversation(h.session)
        let asOf = try forkAsOf(); let current = try forkCurrent()
        let inherited = try await h.session.commit({ tx in
            let point = try await tx.appendEntry(root, value: EntryDraft(kind: "root")).id
            try await tx.doc(asOf, conversationId: root).set("value", "root-at-entry")
            try await tx.doc(current, conversationId: root).set("value", "root-current")
            return point
        }, context: .background)
        let parent = try await forkChild(h.session, root, inherited)
        let own = try await h.session.commit({ tx in
            let point = try await tx.appendEntry(parent.id, value: EntryDraft(kind: "parent")).id
            try await tx.doc(asOf, conversationId: parent.id).set("value", "parent-at-entry")
            try await tx.doc(current, conversationId: parent.id).set("value", "parent-current")
            return point
        }, context: .background)
        let inheritedChild = try await forkChild(h.session, parent.id, inherited)
        let ownChild = try await forkChild(h.session, parent.id, own)
        #expect(try await h.session.snapshot(asOf, conversationId: inheritedChild.id, context: .background) == ["value": "root-at-entry"])
        #expect(try await h.session.snapshot(asOf, conversationId: ownChild.id, context: .background) == ["value": "parent-at-entry"])
        for child in [inheritedChild, ownChild] {
            #expect(try await h.session.snapshot(current, conversationId: child.id, context: .background) == ["value": "parent-current"])
        }
    }

    // :231
    @Test func ForkCopiesStoredVersionWithoutMigration() async throws {
        let h = try await openTestSession(); let parent = try await createConversation(h.session)
        let old = try forkAsOf(); let migrations = SessionTestLog<Int>()
        let current = try forkAsOf(version: 3, migrate: { value, from in migrations.append(from); var value = value; value["migrated"] = true; return value })
        let point = try await h.session.commit({ tx in _ = try await tx.doc(old, conversationId: parent); return try await tx.appendEntry(parent, value: EntryDraft(kind: "point")).id }, context: .background)
        try await h.session.unloadDocuments()
        #expect(try await h.session.snapshot(current, conversationId: parent, context: .background)?["migrated"] == true)
        #expect(migrations.values == [1])
        let child = try await forkChild(h.session, parent, point)
        #expect(migrations.values == [1])
        let record = try await h.storage.findDocument(DocumentAddress(kind: old.definition.kind, scope: .conversation(conversationId: child.id)), at: .current, context: .background)!
        let stored = try await h.storage.document(record.id, at: .current, context: .background)!
        #expect(stored.version == 1); #expect(stored.value == ["value": "initial"])
        #expect(try await h.session.snapshot(current, conversationId: child.id, context: .background)?["migrated"] == true)
        #expect(migrations.values == [1, 1])
    }

    // :281
    @Test func ForkCoalescesMigrationAndOverride() async throws {
        let h = try await openTestSession(); let parent = try await createConversation(h.session); let old = try forkAsOf()
        let checkpoints = SessionTestLog<Int>()
        let current = try RewindableConversationDocToken<JSONObject>(kind: old.definition.kind, version: 2, fork: .asOf, initial: { [:] }, migrate: { value, _ in var value = value; value["migrated"] = true; return value }, checkpointWhen: { _, _, _ in checkpoints.append(1); return false })
        let point = try await h.session.commit({ tx in _ = try await tx.doc(old, conversationId: parent); return try await tx.appendEntry(parent, value: EntryDraft(kind: "point")).id }, context: .background)
        let reads = await h.storage.documentReadCount
        let child = try await h.session.commit({ tx in
            let child = try await tx.forkConversation(parent, at: point, ownership: .ownerless())
            try await tx.doc(current, conversationId: child.id).set("value", "override")
            return child
        }, context: .background)
        #expect(await h.storage.documentReadCount == reads + 1)
        let writes = await h.storage.admittedCommits.last!
        #expect(forkCopies(writes).isEmpty)
        #expect(writes.contains { if case .documentCreate(_, let content, _) = $0 { return content.version == 2 && content.value == ["value": "override", "migrated": true] }; return false })
        #expect(checkpoints.count == 0)
        #expect(documentChanges(h.publications.values.last!).first?.version == 2)
        #expect(try await h.session.snapshot(current, conversationId: child.id, context: .background) == ["value": "override", "migrated": true])
        let record = try await h.storage.findDocument(DocumentAddress(kind: old.definition.kind, scope: .conversation(conversationId: parent)), at: .current, context: .background)!
        #expect(try await h.storage.document(record.id, at: .current, context: .background)?.version == 1)
    }

    // :339
    @Test func ForkCopiesIncarnationAtPoint() async throws {
        let h = try await openTestSession(); let parent = try await createConversation(h.session); let doc = try forkAsOf()
        let old = try await h.session.commit({ tx in try await tx.doc(doc, conversationId: parent).set("value", "old"); return try await tx.appendEntry(parent, value: EntryDraft(kind: "old")).id }, context: .background)
        let retired = try await h.session.commit({ tx in try await tx.retireDoc(doc, conversationId: parent); return try await tx.appendEntry(parent, value: EntryDraft(kind: "retired")).id }, context: .background)
        let new = try await h.session.commit({ tx in try await tx.doc(doc, conversationId: parent).set("value", "new"); return try await tx.appendEntry(parent, value: EntryDraft(kind: "new")).id }, context: .background)
        let oldChild = try await forkChild(h.session, parent, old); let empty = try await forkChild(h.session, parent, retired); let newChild = try await forkChild(h.session, parent, new)
        #expect(try await h.session.snapshot(doc, conversationId: oldChild.id, context: .background) == ["value": "old"])
        #expect(try await h.session.snapshot(doc, conversationId: empty.id, context: .background) == nil)
        #expect(try await h.session.snapshot(doc, conversationId: newChild.id, context: .background) == ["value": "new"])
    }

    // :383
    @Test func ForkRejectsInvisiblePointBeforeAdmission() async throws {
        let h = try await openTestSession(); let root = try await createConversation(h.session)
        let entries = try await h.session.commit({ tx in
            let first = try await tx.appendEntry(root, value: EntryDraft(kind: "visible")).id
            let second = try await tx.appendEntry(root, value: EntryDraft(kind: "hidden")).id
            return (first, second)
        }, context: .background)
        let parent = try await forkChild(h.session, root, entries.0)
        let commits = await h.storage.admittedCommits.count; let publications = h.publications.count
        await forkExpectError("Entry \(entries.1.rawValue) is not visible") { _ = try await forkChild(h.session, parent.id, entries.1) }
        #expect(await h.storage.admittedCommits.count == commits); #expect(h.publications.count == publications)
        let next = try await createConversation(h.session)
        #expect(try await h.storage.conversation(next, context: .background) != nil)
    }

    // :412
    @Test func ForkRejectsDuplicateSelectedAddress() async throws {
        let h = try await openTestSession(); let parent = try await createConversation(h.session)
        let asOf = try forkAsOf("duplicate"); let current = try forkCurrent("duplicate")
        let point = try await h.session.commit({ tx in _ = try await tx.doc(asOf, conversationId: parent); return try await tx.appendEntry(parent, value: EntryDraft(kind: "old")).id }, context: .background)
        try await h.session.commit({ tx in try await tx.retireDoc(asOf, conversationId: parent) }, context: .background)
        try await h.session.commit({ tx in _ = try await tx.doc(current, conversationId: parent) }, context: .background)
        let commits = await h.storage.admittedCommits.count
        await forkExpectError("Fork selects multiple source documents for duplicate") { _ = try await forkChild(h.session, parent, point) }
        #expect(await h.storage.admittedCommits.count == commits)
        _ = try await createConversation(h.session)
    }

    // :450
    @Test func ForkRejectsSourceWrites() async throws {
        let h = try await openTestSession(); let parent = try await createConversation(h.session)
        let current = try forkCurrent(); let asOf = try forkAsOf()
        let point = try await h.session.commit({ tx in _ = try await tx.doc(current, conversationId: parent); _ = try await tx.doc(asOf, conversationId: parent); return try await tx.appendEntry(parent, value: EntryDraft(kind: "point")).id }, context: .background)
        let commits = await h.storage.admittedCommits.count
        for after in [false, true] {
            await forkExpectError("Cannot change fork source document") {
                try await h.session.commit({ tx in
                    if after { _ = try await tx.forkConversation(parent, at: point, ownership: .ownerless()) }
                    try await tx.doc(current, conversationId: parent).set("value", "change")
                    if !after { _ = try await tx.forkConversation(parent, at: point, ownership: .ownerless()) }
                }, context: .background)
            }
        }
        await forkExpectError("Cannot change fork source document") {
            try await h.session.commit({ tx in try await tx.doc(asOf, conversationId: parent).set("value", "change"); _ = try await tx.forkConversation(parent, at: point, ownership: .ownerless()) }, context: .background)
        }
        await forkExpectError("Cannot change fork source document") {
            try await h.session.commit({ tx in _ = try await tx.forkConversation(parent, at: point, ownership: .ownerless()); try await tx.retireDoc(current, conversationId: parent) }, context: .background)
        }
        #expect(await h.storage.admittedCommits.count == commits)
        let child = try await forkChild(h.session, parent, point)
        #expect(try await h.session.snapshot(current, conversationId: child.id, context: .background) == ["value": "initial"])
    }

    // :503
    @Test func ForkRollsBackAssemblyFailure() async throws {
        let h = try await openTestSession(); let parent = try await createConversation(h.session); let copied = try forkAsOf()
        let flag = SessionTestLog<Bool>()
        let failure = try SessionDocToken<JSONObject>(kind: "failure", version: 1, initial: { ["count": 0] }, checkpointWhen: { _, _, _ in if flag.count == 0 { throw SessionError.message("checkpoint failed") }; return false })
        let point = try await h.session.commit({ tx in _ = try await tx.doc(copied, conversationId: parent); _ = try await tx.doc(failure); return try await tx.appendEntry(parent, value: EntryDraft(kind: "point")).id }, context: .background)
        let commits = await h.storage.admittedCommits.count; let published = h.publications.count; let ids = SessionTestLog<ConversationID>()
        await forkExpectError("checkpoint failed") {
            try await h.session.commit({ tx in ids.append(try await tx.forkConversation(parent, at: point, ownership: .ownerless()).id); try await tx.doc(failure).set("count", 1) }, context: .background)
        }
        #expect(await h.storage.admittedCommits.count == commits); #expect(h.publications.count == published)
        #expect(try await h.storage.conversation(ids.values[0], context: .background) == nil)
        flag.append(true)
        try await h.session.commit({ tx in try await tx.doc(failure).set("count", 2) }, context: .background)
        #expect(try await h.session.snapshot(failure, context: .background) == ["count": 2])
        #expect(try await h.session.snapshot(copied, conversationId: parent, context: .background) == ["value": "initial"])
    }

    // :553
    @Test func ForkStorageRejectedKeepsSessionUsable() async throws {
        let h = try await openTestSession(); let parent = try await createConversation(h.session); let copied = try forkAsOf()
        let point = try await h.session.commit({ tx in _ = try await tx.doc(copied, conversationId: parent); return try await tx.appendEntry(parent, value: EntryDraft(kind: "point")).id }, context: .background)
        await h.storage.failNextCommit(StorageRejected("copy rejected"))
        let ids = SessionTestLog<ConversationID>()
        await forkExpectError("copy rejected") {
            try await h.session.commit({ tx in ids.append(try await tx.forkConversation(parent, at: point, ownership: .ownerless()).id) }, context: .background)
        }
        #expect(try await h.storage.conversation(ids.values[0], context: .background) == nil)
        let next = try await createConversation(h.session); #expect(try await h.storage.conversation(next, context: .background) != nil)
    }

    // :581
    @Test func ForkRetiresCopyAndRecreatesAddress() async throws {
        let h = try await openTestSession(); let parent = try await createConversation(h.session); let doc = try forkAsOf()
        let point = try await h.session.commit({ tx in try await tx.doc(doc, conversationId: parent).set("value", "copied"); return try await tx.appendEntry(parent, value: EntryDraft(kind: "point")).id }, context: .background)
        let child = try await h.session.commit({ tx in let child = try await tx.forkConversation(parent, at: point, ownership: .ownerless()); try await tx.retireDoc(doc, conversationId: child.id); try await tx.doc(doc, conversationId: child.id).set("value", "replacement"); return child }, context: .background)
        let writes = await h.storage.admittedCommits.last!
        #expect(forkCopies(writes).count == 1)
        #expect(writes.filter { $0.type == "document.create" }.count == 1)
        #expect(writes.filter { $0.type == "document.retire" }.count == 1)
        #expect(try await h.session.snapshot(doc, conversationId: child.id, context: .background) == ["value": "replacement"])
    }

    // :610
    @Test func ForkCopiesOnlyConversationScope() async throws {
        let h = try await openTestSession(); let parent = try await createConversation(h.session); let copied = try forkCurrent()
        let sessionDoc = try SessionDocToken<JSONObject>(kind: "session", version: 1, initial: { ["value": "session"] })
        let taskDoc = try TaskDocToken<JSONObject>(kind: "task", version: 1, initial: { ["value": "task"] })
        let work = TaskKind<String, JSONObject>(name: "work", version: 1, initial: { _ in [:] })
        let data = try await h.session.commit({ tx in
            let point = try await tx.appendEntry(parent, value: EntryDraft(kind: "point")).id
            let task = try await tx.createTask(work, input: "input", options: TaskOptions(ownership: .conversation(), conversationId: parent))
            _ = try await tx.doc(copied, conversationId: parent); _ = try await tx.doc(sessionDoc); _ = try await tx.doc(taskDoc, taskId: task)
            return (point, task)
        }, context: .background)
        let child = try await forkChild(h.session, parent, data.0)
        #expect(forkCopies(await h.storage.admittedCommits.last!).map { $0.0.kind } == [copied.definition.kind])
        #expect(documentCopyChanges(h.publications.values.last!).map { $0.record.kind } == [copied.definition.kind])
        #expect(try await h.session.snapshot(copied, conversationId: child.id, context: .background) == ["value": "initial"])
        #expect(try await h.session.snapshot(sessionDoc, context: .background) == ["value": "session"])
        #expect(try await h.session.snapshot(taskDoc, taskId: data.1, context: .background) == ["value": "task"])
    }

    // :664
    @Test func ForkCopiesAllScanPages() async throws {
        let h = try await openTestSession(); let parent = try await createConversation(h.session); let point = try await forkPoint(h.session, parent)
        let family = try ConversationDocFamilyToken<JSONObject, Int>(kind: "pagination", version: 1, fork: .current, initial: { ["value": .number(Double($0))] })
        try await h.session.commit({ tx in
            for index in 0..<260 { _ = try await tx.doc(family, conversationId: parent, key: "member-\(index)", seed: index) }
        }, context: .background)
        let child = try await forkChild(h.session, parent, point)
        #expect(forkCopies(await h.storage.admittedCommits.last!).count == 260)
        #expect(try await h.session.snapshot(family, conversationId: child.id, key: "member-0", context: .background) == ["value": 0])
        #expect(try await h.session.snapshot(family, conversationId: child.id, key: "member-259", context: .background) == ["value": 259])
    }

    @Test func ForkRejectsNewCurrentPolicyParentDocuments() async throws {
        let h = try await openTestSession(); let parent = try await createConversation(h.session); let point = try await forkPoint(h.session, parent); let current = try forkCurrent()
        let commits = await h.storage.admittedCommits.count
        await forkExpectError("Cannot fork conversation \(parent.rawValue) while changing its current-policy documents") {
            try await h.session.commit({ tx in _ = try await tx.doc(current, conversationId: parent); _ = try await tx.forkConversation(parent, at: point, ownership: .ownerless()) }, context: .background)
        }
        #expect(await h.storage.admittedCommits.count == commits)
    }

    @Test func ForkRetainsDistinctUnicodeFamilyKeys() async throws {
        let h = try await openTestSession(); let parent = try await createConversation(h.session)
        let point = try await forkPoint(h.session, parent)
        let family = try ConversationDocFamilyToken<JSONObject, Int>(kind: "unicode", version: 1, fork: .current, initial: { ["value": .number(Double($0))] })
        let composed = "\u{00E9}"; let decomposed = "e\u{0301}"
        try await h.session.commit({ tx in
            _ = try await tx.doc(family, conversationId: parent, key: composed, seed: 1)
            _ = try await tx.doc(family, conversationId: parent, key: decomposed, seed: 2)
        }, context: .background)
        let child = try await forkChild(h.session, parent, point)
        let keys = forkCopies(await h.storage.admittedCommits.last!).map { Array($0.0.key!.utf8) }
        #expect(keys.count == 2)
        #expect(keys.contains(Array(composed.utf8))); #expect(keys.contains(Array(decomposed.utf8)))
        #expect(try await h.session.snapshot(family, conversationId: child.id, key: composed, context: .background) == ["value": 1])
        #expect(try await h.session.snapshot(family, conversationId: child.id, key: decomposed, context: .background) == ["value": 2])
    }

    // session-checkpoints-migrations.test.ts:648, fork ancestry assertions.
    @Test func ForkMigrationHistoricalAncestry() async throws {
        let h = try await openTestSession(); let parent = try await createConversation(h.session)
        let old = try forkAsOf("history.migration"); let migrated = try forkAsOf("history.migration", version: 3, migrate: { value, _ in var value = value; value["version"] = 3; return value })
        let family = try RewindableConversationDocFamilyToken<JSONObject, String>(kind: "history.family", version: 1, fork: .asOf, initial: { ["seed": .string($0), "count": 0] })
        let first = try await h.session.commit({ tx in try await tx.doc(old, conversationId: parent).set("count", 1); try await tx.doc(family, conversationId: parent, key: "member", seed: "seed").set("count", 1); return try await tx.appendEntry(parent, value: EntryDraft(kind: "first")).id }, context: .background)
        let second = try await h.session.commit({ tx in try await tx.doc(old, conversationId: parent).set("count", 2); return try await tx.appendEntry(parent, value: EntryDraft(kind: "second")).id }, context: .background)
        let third = try await h.session.commit({ tx in _ = try await tx.doc(migrated, conversationId: parent); return try await tx.appendEntry(parent, value: EntryDraft(kind: "third")).id }, context: .background)
        let child = try await forkChild(h.session, parent, second)
        #expect(try await h.session.snapshotAsOf(migrated, conversationId: child.id, at: first, context: .background)?["count"] == 1)
        #expect(try await h.session.snapshotAsOf(migrated, conversationId: child.id, at: second, context: .background)?["count"] == 2)
        #expect(try await h.session.snapshotAsOf(family, conversationId: child.id, key: "member", at: first, context: .background) == ["seed": "seed", "count": 1])
        await forkExpectError("Entry \(third.rawValue) is not visible") { _ = try await h.session.snapshotAsOf(migrated, conversationId: child.id, at: third, context: .background) }
    }
}
