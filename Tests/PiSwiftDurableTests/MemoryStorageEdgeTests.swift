import Testing
import PiSwiftChord
import PiSwiftDurable

extension PiSwiftDurableTests {
    @Test func memoryStorageRejectsAllReadsAndWritesAfterClose() async throws {
        let storage = MemoryStorage()
        let conversation = rootConversationID
        let entry = try EntryID(2), task = try TaskID(3)
        let submission = try SubmissionID(4), document = try DocumentID(5)
        try await storage.close(context: .background)
        let operations: [@Sendable () async throws -> Void] = [
            { _ = try await storage.commit([], context: .background) },
            { let _: EntryID = try await storage.mintId() },
            { _ = try await storage.prepareCommit([]) },
            { _ = try await storage.conversation(conversation, context: .background) },
            { _ = try await storage.scanConversations(.init(), limit: 2, cursor: nil, context: .background) },
            { _ = try await storage.entry(entry, context: .background) },
            { _ = try await storage.entry(conversation, id: entry, context: .background) },
            { _ = try await storage.findLatestHeadMarker(conversation, atOrBeforeEntryId: nil, context: .background) },
            { _ = try await storage.scanEntries(.init(conversationId: conversation), limit: 2, cursor: nil, context: .background) },
            { _ = try await storage.task(task, context: .background) },
            { _ = try await storage.scanTasks(.init(), limit: 2, cursor: nil, context: .background) },
            { _ = try await storage.submission(submission, context: .background) },
            { _ = try await storage.scanSubmissions(.init(), limit: 2, cursor: nil, context: .background) },
            { _ = try await storage.submissionByRequest(conversation, requestId: "closed", context: .background) },
            { _ = try await storage.findDocument(.init(kind: "closed", scope: .session()), at: .current, context: .background) },
            { _ = try await storage.document(document, at: .current, context: .background) },
            { _ = try await storage.scanDocuments(.init(scope: .session(), at: .current), limit: 2, cursor: nil, context: .background) },
        ]
        for operation in operations {
            do { try await operation(); Issue.record("A closed operation did not reject") }
            catch { #expect(error as? DurableStorageError == .closed(backend: "MemoryStorage")) }
        }
        // Upstream close() has no open check.
        try await storage.close(context: .background)
    }

    @Test func memoryStoragePreparationHasNoEffectsAndSupportsSequenceGaps() async throws {
        let storage = MemoryStorage()
        let record = ConversationRecord(id: rootConversationID)
        let prepared = try await storage.prepareCommit([.conversation(value: record)], seq: Seq(7))
        #expect(try await storage.conversation(rootConversationID, context: .background) == nil)
        #expect(await prepared.apply() == (try Seq(7)))
        let results = await withTaskGroup(of: Seq.self, returning: [Seq].self) { group in
            for _ in 0..<16 { group.addTask { await prepared.apply() } }
            var results: [Seq] = []
            for await result in group { results.append(result) }
            return results
        }
        #expect(results.allSatisfy { $0 == prepared.seq })
        #expect(try await storage.scanConversations(.init(), limit: 2, cursor: nil, context: .background).items == [record])
        #expect(try await storage.commit([], context: .background) == Seq(8))
        do {
            _ = try await storage.prepareCommit([], seq: Seq(8))
            Issue.record("A non-increasing sequence did not reject")
        } catch { #expect(error as? DurableStorageError == .commitSequenceDoesNotIncrease(8)) }
    }
}
