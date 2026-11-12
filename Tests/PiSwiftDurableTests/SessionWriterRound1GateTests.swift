import Testing
import PiSwiftChord
@testable import PiSwiftDurable

// The test names are the v1.5.2 session-group-commit.test.ts gate cases.
@Suite("PiSwiftDurableTests.SessionWriterRound1Gates", .timeLimit(.minutes(2)))
struct SessionWriterRound1GateTests {
    private func turns() async { for _ in 0..<1_000 { await Task.yield() } }

    @Test("makes a job wait for an unpublished creation at a document address instead of creating it again")
    func unpublishedDocumentCreation() async throws {
        let h = try await openTestSession()
        let token = try SessionDocToken<JSONObject>(kind: "d3a.r1.shared", version: 1,
            initial: { ["n": .number(0)] }, checkpointWhen: { _, _, _ in false })
        let hold = await h.storage.holdCommits()
        let first = Task {
            try await h.session.commit({ tx in try await tx.doc(token).set("n", .number(1)) }, context: .background)
        }
        await hold.waitUntilEntered()
        let before = await h.storage.findDocumentReadCount
        let entered = SessionTestGate()
        let second = Task {
            try await h.session.commit({ tx in
                entered.release()
                let doc = try await tx.doc(token)
                let number = try doc.get("n")?.numberValue ?? -1
                try doc.set("n", .number(number + 1))
                return number + 1
            }, context: .background)
        }
        await entered.wait()
        await turns()
        #expect(await h.storage.findDocumentReadCount == before)
        await hold.release()
        try await first.value
        #expect(try await second.value == 2)
        let writes = await h.storage.commits.flatMap { $0 }
        #expect(writes.filter { if case .documentCreate = $0 { return true }; return false }.count == 1)
        #expect(try await h.session.snapshot(token, context: .background)?["n"] == .number(2))
        try await h.session.close(context: .background)
    }

    @Test("makes a write to a conversation an unpublished commit creates wait for it")
    func unpublishedConversationCreation() async throws {
        let h = try await openTestSession()
        let leaked = SessionTestLog<ConversationID>()
        let hold = await h.storage.holdCommits()
        let first = Task {
            try await h.session.commit({ tx in
                let id = try await tx.createConversation(ownership: .ownerless()).id
                leaked.append(id)
                return id
            }, context: .background)
        }
        await hold.waitUntilEntered()
        let id = try #require(leaked.values.first)
        let before = await h.storage.conversationReadCount
        let entered = SessionTestGate()
        let second = Task {
            try await h.session.commit({ tx in
                entered.release()
                return try await tx.appendEntry(id, value: EntryDraft(kind: "note"))
            }, context: .background)
        }
        await entered.wait()
        await turns()
        #expect(await h.storage.conversationReadCount == before)
        await hold.release()
        #expect(try await first.value == id)
        #expect(try await second.value.conversationId == id)
        try await h.session.close(context: .background)
    }

    @Test("makes each read of the entries of a conversation an unpublished commit creates wait for its creation",
          arguments: ["latestEntryId", "latestHeadMarker", "tx.scanEntries", "line scanEntries", "line findLatestHeadMarker"])
    func entryReadsOfNewConversation(_ form: String) async throws {
        let h = try await openTestSession()
        let leaked = SessionTestLog<ConversationID>()
        let hold = await h.storage.holdCommits()
        let first = Task {
            try await h.session.commit({ tx in
                let id = try await tx.createConversation(ownership: .ownerless()).id
                leaked.append(id)
            }, context: .background)
        }
        await hold.waitUntilEntered()
        let id = try #require(leaked.values.first)
        let scans = await h.storage.entryScanCount
        let heads = await h.storage.headMarkerReadCount
        let entered = SessionTestGate()
        let reading = Task { () throws -> Bool in
            switch form {
            case "latestEntryId":
                return try await h.session.commit({ tx in
                    entered.release(); return try await tx.latestEntryId(id) == nil
                }, context: .background)
            case "latestHeadMarker":
                return try await h.session.commit({ tx in
                    entered.release(); return try await tx.latestHeadMarker(id) == nil
                }, context: .background)
            case "tx.scanEntries":
                return try await h.session.commit({ tx in
                    entered.release(); return try await tx.scanEntries(.init(conversationId: id), limit: 1).items.isEmpty
                }, context: .background)
            case "line scanEntries":
                return try await h.session.readOnLine {
                    entered.release()
                    return try await h.session.storage.scanEntries(.init(conversationId: id), limit: 1,
                                                                   cursor: nil, context: .background).items.isEmpty
                }
            default:
                return try await h.session.readOnLine {
                    entered.release()
                    return try await h.session.storage.findLatestHeadMarker(id, atOrBeforeEntryId: nil,
                                                                            context: .background) == nil
                }
            }
        }
        await entered.wait()
        await turns()
        #expect(await h.storage.entryScanCount == scans)
        #expect(await h.storage.headMarkerReadCount == heads)
        await hold.release()
        try await first.value
        #expect(try await reading.value)
        try await h.session.close(context: .background)
    }

    @Test("makes a scan that cannot be keyed wait for every unpublished commit")
    func globalScanWaits() async throws {
        let h = try await openTestSession()
        let hold = await h.storage.holdCommits()
        let first = Task {
            try await h.session.commit({ tx in try await tx.createConversation(ownership: .ownerless()).id },
                                       context: .background)
        }
        await hold.waitUntilEntered()
        let before = await h.storage.conversationScanCount
        let entered = SessionTestGate()
        let scan = Task {
            try await h.session.commit({ tx in
                entered.release()
                return try await tx.scanConversations(.init(), limit: 10).items.map(\.id)
            }, context: .background)
        }
        await entered.wait()
        await turns()
        #expect(await h.storage.conversationScanCount == before)
        await hold.release()
        let id = try await first.value
        #expect(try await scan.value.contains(id))
        try await h.session.close(context: .background)
    }

    @Test("makes a line read after an un-awaited commit see it")
    func unawaitedEntryReadWaits() async throws {
        let h = try await openTestSession()
        let conversation = try await createConversation(h.session)
        let leaked = SessionTestLog<EntryID>()
        let hold = await h.storage.holdCommits()
        let first = Task {
            try await h.session.commit({ tx in
                let entry = try await tx.appendEntry(conversation, value: EntryDraft(kind: "note"))
                leaked.append(entry.id)
            }, context: .background)
        }
        await hold.waitUntilEntered()
        let id = try #require(leaked.values.first)
        let before = await h.storage.entryReadCount
        let entered = SessionTestGate()
        let reading = Task {
            try await h.session.readOnLine {
                entered.release()
                return try await h.session.storage.entry(id, context: .background)
            }
        }
        await entered.wait()
        await turns()
        #expect(await h.storage.entryReadCount == before)
        await hold.release()
        try await first.value
        #expect(try await reading.value?.entry.id == id)
        try await h.session.close(context: .background)
    }
}
