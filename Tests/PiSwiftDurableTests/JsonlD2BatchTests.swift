import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting

@Suite("PiSwiftDurableTests.JsonlD2Batches")
struct JsonlD2BatchTests {
    @Test func cancelledContextDuringCommitPoisonsBeforeMainAppend() async throws {
        try await jsonlWithStorage { storage, directory, _ in
            try await jsonlRoot(storage)
            let cancelled = ChordContext.background.withCancel()
            cancelled.cancel()
            let entry: EntryID = try EntryID(2)
            let receipts = Mutex(0)
            await #expect(throws: JsonlStoragePoisonedError.self) {
                _ = try await storage.commit([[.entry(value: .init(id: entry, conversationId: rootConversationID, kind: "cancel"))]], receive: { _, _ in
                    receipts.withLock { $0 += 1 }
                }, context: cancelled.context)
            }
            #expect(receipts.withLock { $0 } == 0)
            let reopened = try await jsonlOpen(directory)
            #expect(try await reopened.entry(entry, context: .background) == nil)
            try await reopened.close(context: .background)
        }
    }

    @Test func recoversCompleteMarkersAndReusesTornSequence() async throws {
        try await jsonlWithStorage { storage, directory, _ in
            try await jsonlRoot(storage)
            let document: DocumentID = try await storage.mintId()
            _ = try await storage.commitOne([jsonlCreate(document)], context: .background)
            let before = try Data(contentsOf: directory.appendingPathComponent("main.jsonl")).count
            var entries: [EntryID] = []
            for _ in 0..<3 { entries.append(try await storage.mintId()) }
            let batches = entries.enumerated().map { index, id in
                [StorageWrite.entry(value: .init(id: id, conversationId: rootConversationID, kind: "note")), jsonlDelta(document, index + 1)]
            }
            let receipts = Mutex<[(Int, Seq)]>([])
            let result = try await storage.commit(batches, receive: { index, seq in
                receipts.withLock { $0.append((index, seq)) }
            }, context: .background)
            #expect(result.stored == 3)
            #expect(result.refused == nil)
            #expect(receipts.withLock { $0.map(\.0) } == [0, 1, 2])
            #expect(receipts.withLock { $0.map { $0.1.rawValue } } == [3, 4, 5])
            try await storage.close(context: .background)
            let path = directory.appendingPathComponent("main.jsonl")
            let main = try Data(contentsOf: path)
            let markers = main.dropFirst(before).split(separator: 10)
            #expect(markers.count == 3)
            let finalSize = try #require(markers.last).count
            try main.prefix(main.count - finalSize / 2).write(to: path)
            let reopened = try await jsonlOpen(directory)
            #expect(try await reopened.entry(entries[0], context: .background) != nil)
            #expect(try await reopened.entry(entries[1], context: .background) != nil)
            #expect(try await reopened.entry(entries[2], context: .background) == nil)
            #expect(try await reopened.document(document, at: .current, context: .background)?.value == ["count": 2])
            #expect(try await reopened.commitOne([jsonlDelta(document, 9)], context: .background) == Seq(5))
            try await reopened.close(context: .background)
            let again = try await jsonlOpen(directory)
            #expect(try await again.document(document, at: .current, context: .background)?.value == ["count": 9])
            try await again.close(context: .background)
        }
    }

    @Test(arguments: [false, true])
    func groupsAppendsAndFlushesBeforeReceipts(fsync: Bool) async throws {
        try await jsonlWithStorage(fsync: fsync) { storage, directory, fs in
            try await jsonlRoot(storage)
            let first: DocumentID = try await storage.mintId()
            let second: DocumentID = try await storage.mintId()
            _ = try await storage.commitOne([jsonlCreate(first), jsonlCreate(second, kind: "second")], context: .background)
            fs.clear()
            let receipts = Mutex<[(Int, Seq, [String])]>([])
            let result = try await storage.commit([
                [jsonlBase(first, 1), jsonlDelta(second, 1)],
                [jsonlDelta(first, 2), jsonlDelta(second, 2)],
                [jsonlDelta(first, 3)]
            ], receive: { index, seq in
                receipts.withLock { $0.append((index, seq, fs.operations)) }
            }, context: .background)
            let one = jsonlDocName(first), two = jsonlDocName(second)
            let publication = ["append:\(one)", "append:\(two)"]
                + (fsync ? ["flush:\(one)", "flush:\(two)"] : []) + ["append:main.jsonl"]
            #expect(result.stored == 3)
            #expect(receipts.withLock { $0.map(\.0) } == [0, 1, 2])
            #expect(receipts.withLock { $0.allSatisfy { $0.2 == publication } })
            #expect(fs.operations == publication + (fsync ? ["flush:main.jsonl"] : [])
                + ["write:\(one).reclaim"] + (fsync ? ["flush:\(one).reclaim"] : [])
                + ["rename:\(one).reclaim->\(one)"])
            #expect(try jsonlLines(directory, one).count == 3)
            try await storage.close(context: .background)
            let reopened = try await jsonlOpen(directory)
            #expect(try await reopened.document(first, at: .current, context: .background)?.value == ["count": 3])
            #expect(try await reopened.document(second, at: .current, context: .background)?.value == ["count": 2])
            try await reopened.close(context: .background)
        }
    }

    @Test func refusesLaterBatchWithoutPublishingItsWrites() async throws {
        try await jsonlWithStorage { storage, directory, fs in
            try await jsonlRoot(storage)
            let first: EntryID = try await storage.mintId()
            let after: EntryID = try await storage.mintId()
            let entry = StorageWrite.entry(value: .init(id: first, conversationId: rootConversationID, kind: "first"))
            fs.clear()
            let receipts = Mutex<[Int]>([])
            let result = try await storage.commit([
                [entry], [entry], [.entry(value: .init(id: after, conversationId: rootConversationID, kind: "after"))]
            ], receive: { index, _ in receipts.withLock { $0.append(index) } }, context: .background)
            #expect(result.stored == 1)
            #expect(result.refused != nil)
            #expect(receipts.withLock { $0 } == [0])
            #expect(fs.operations == ["append:main.jsonl"])
            #expect(try jsonlLines(directory, "main.jsonl").count == 2)
            #expect(try await storage.entry(after, context: .background) == nil)
        }
    }

    @Test(arguments: [FaultInjectingFileSystem.Mode.before, .short, .after])
    func unknownOutcomeAfterGroupedMarkerAppend(_ mode: FaultInjectingFileSystem.Mode) async throws {
        try await jsonlWithStorage { storage, directory, fs in
            try await jsonlRoot(storage)
            let entries = try (2...4).map { try EntryID(Int64($0)) }
            let batches = entries.map { id in
                [StorageWrite.entry(value: .init(id: id, conversationId: rootConversationID, kind: "fault"))]
            }
            let receipts = Mutex<[Int]>([])
            fs.fail(.init(operation: .append, call: 1, mode: mode))
            await #expect(throws: JsonlStoragePoisonedError.self) {
                _ = try await storage.commit(batches, receive: { index, _ in
                    receipts.withLock { $0.append(index) }
                }, context: .background)
            }
            #expect(receipts.withLock { $0.isEmpty })
            await #expect(throws: JsonlStoragePoisonedError.self) {
                _ = try await storage.entry(entries[0], context: .background)
            }
            let complete = try Data(contentsOf: directory.appendingPathComponent("main.jsonl"))
                .filter { $0 == 10 }.count - 1
            let reopened = try await jsonlOpen(directory)
            for (index, id) in entries.enumerated() {
                #expect((try await reopened.entry(id, context: .background) != nil) == (index < complete))
            }
            let next: EntryID = try EntryID(5)
            #expect(try await reopened.commitOne([.entry(value: .init(id: next, conversationId: rootConversationID, kind: "next"))], context: .background).rawValue == Int64(complete + 2))
            try await reopened.close(context: .background)
        }
    }

    @Test(arguments: [1, 10_000])
    func measuresTenThousandWrites(batchCount: Int) async throws {
        try await jsonlWithStorage { storage, directory, fs in
            try await jsonlRoot(storage)
            let writes = try (2...10_001).map { raw in
                StorageWrite.entry(value: .init(id: try EntryID(Int64(raw)), conversationId: rootConversationID, kind: "measurement"))
            }
            let batches = batchCount == 1 ? [writes] : writes.map { [$0] }
            let receipts = Mutex(0)
            fs.clear()
            let clock = ContinuousClock()
            let start = clock.now
            let result = try await storage.commit(batches, receive: { _, _ in receipts.withLock { $0 += 1 } }, context: .background)
            let elapsed = start.duration(to: clock.now)
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            print("JSONL D2: \(batchCount) batches, 10000 writes, \(elapsed), peak RSS \(usage.ru_maxrss) bytes")
            #expect(result.stored == batchCount)
            #expect(result.refused == nil)
            #expect(receipts.withLock { $0 } == batchCount)
            #expect(fs.operations == ["append:main.jsonl"])
            #expect(try jsonlLines(directory, "main.jsonl").count == batchCount + 1)
            #expect(try await storage.entry(EntryID(10_001), context: .background) != nil)
        }
    }
}
