import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurable

@Suite("PiSwiftDurableTests.MemoryD2Batches")
struct MemoryD2BatchTests {
    @Test func acceptedPrefixAndReceipts() async throws {
        let storage = MemoryStorage()
        let first = StorageWrite.conversation(value: ConversationRecord(id: try ConversationID(1)))
        let entry = StorageWrite.entry(value: EntryRecord(id: try EntryID(2), conversationId: try ConversationID(1), kind: "first"))
        let later = StorageWrite.entry(value: EntryRecord(id: try EntryID(3), conversationId: try ConversationID(1), kind: "later"))
        let receipts = Mutex<[(Int, Seq)]>([])
        let outcome = try await storage.commit([[first], [entry], [entry], [later]], receive: { index, seq in
            receipts.withLock { $0.append((index, seq)) }
        }, context: .background)
        #expect(outcome.stored == 2)
        #expect(outcome.refused as? DurableStorageError == .idAlreadyOwned(id: 2, recordType: "entry"))
        #expect(receipts.withLock { $0.map(\.0) } == [0, 1])
        #expect(receipts.withLock { $0.map { $0.1.rawValue } } == [1, 2])
        #expect(try await storage.entry(EntryID(2), context: .background)?.commitSeq == Seq(2))
        #expect(try await storage.entry(EntryID(3), context: .background) == nil)
        try await storage.close(context: .background)
    }

    @Test func cancelledContextDoesNotInterruptMemoryCommit() async throws {
        let storage = MemoryStorage()
        let cancelled = ChordContext.background.withCancel()
        cancelled.cancel()
        let outcome = try await storage.commit([[.conversation(value: ConversationRecord(id: try ConversationID(1)))]], receive: { _, _ in }, context: cancelled.context)
        #expect(outcome.stored == 1)
        #expect(try await storage.conversation(ConversationID(1), context: .background) != nil)
    }

    @Test(arguments: [true, false])
    func measuresTenThousandWrites(manyBatches: Bool) async throws {
        let storage = MemoryStorage()
        _ = try await storage.commit([[.conversation(value: ConversationRecord(id: try ConversationID(1)))]], receive: { _, _ in }, context: .background)
        let writes = try (2..<10_002).map { raw in
            StorageWrite.entry(value: EntryRecord(id: try EntryID(Int64(raw)), conversationId: try ConversationID(1), kind: "measure"))
        }
        let batches = manyBatches ? writes.map { [$0] } : [writes]
        let received = Mutex(0)
        let start = ContinuousClock.now
        let outcome = try await storage.commit(batches, receive: { _, _ in received.withLock { $0 += 1 } }, context: .background)
        let elapsed = start.duration(to: ContinuousClock.now)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("Memory D2: \(batches.count) batches, 10000 writes, \(elapsed), peak RSS \(usage.ru_maxrss) bytes")
        #expect(outcome.stored == batches.count)
        #expect(received.withLock { $0 } == batches.count)
        #expect(try await storage.entry(EntryID(10_001), context: .background) != nil)
    }
}
