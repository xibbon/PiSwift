import Foundation
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private enum StressLineEvent: Sendable {
    case write(EntryRecord)
    case read(ConversationID, [EntryID])
}

// v1.5.2 D3a: run this load test alone with PI_D3A_STRESS=1. Running it
// alongside deadline-sensitive harness suites starves their gate witnesses.
@Suite("PiSwiftDurableTests.SessionWriterStressD3a", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PI_D3A_STRESS"] == "1"),
       .timeLimit(.minutes(10)))
struct SessionWriterStressD3aTests {
    private func storage(_ kind: String, path: String) async throws -> any DurableStorage {
        switch kind {
        case "sqlite": try await SqliteStorage.open(path: path)
        case "jsonl": try await JsonlStorage.open(directory: path)
        default: MemoryStorage()
        }
    }

    @Test(arguments: ["memory", "sqlite", "jsonl"])
    func seededTwentyThousandOperations(_ kind: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("d3a-stress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = try await storage(kind, path: directory.appendingPathComponent(kind == "sqlite" ? "store.sqlite" : "store").path)
        let controlled = ControlledStorage(backend)
        await controlled.enableCommitGateDelays(seed: 0x5a17c0de)
        let session = try await Session.open(storage: controlled, now: { 1_000 }, context: .background)
        var conversations: [ConversationID] = []
        for _ in 0..<8 {
            conversations.append(try await session.commit({ tx in
                try await tx.createConversation(ownership: .ownerless()).id
            }, context: .background))
        }
        let line = SessionTestLog<StressLineEvent>()
        let publications = SessionTestLog<EntryID>()
        let subscription = try session.subscribeCommits { publication, _ in
            for change in publication.changes {
                if case .entry(let entry) = change { publications.append(entry.id) }
            }
        }
        let preflightIDs = conversations
        let firstCall = await controlled.holdCommits()
        let first = Task {
            try await session.commit({ tx in
                let entry = try await tx.appendEntry(preflightIDs[0], value: EntryDraft(kind: "preflight.0"))
                line.append(.write(entry))
                return entry
            }, context: .background)
        }
        await firstCall.waitUntilEntered()
        var queued: [Task<EntryRecord, any Error>] = []
        for index in 1...4 {
            queued.append(Task {
                try await session.commit({ tx in
                    let entry = try await tx.appendEntry(preflightIDs[index], value: EntryDraft(kind: "preflight.\(index)"))
                    line.append(.write(entry))
                    return entry
                }, context: .background)
            })
            for _ in 0..<50_000 {
                if session.writerUnpublished >= (index + 1) * 2 { break }
                await Task.yield()
            }
            #expect(session.writerUnpublished >= (index + 1) * 2)
        }
        await firstCall.release()
        _ = try await first.value
        for part in queued { _ = try await part.value }
        let ids = conversations
        try await withThrowingTaskGroup(of: Void.self) { group in
            for taskIndex in 0..<16 {
                group.addTask {
                    var seed = UInt32(0x9e3779b9) &+ UInt32(taskIndex &* 97)
                    func next() -> UInt32 {
                        seed = seed &* 1_664_525 &+ 1_013_904_223
                        return seed
                    }
                    for operation in 0..<1_250 {
                        let choice = next()
                        let conversation = ids[Int((choice >> 8) % UInt32(ids.count))]
                        if choice % 4 == 0 {
                            _ = try await session.commit({ tx in
                                let page = try await tx.scanEntries(.init(conversationId: conversation, order: .descending), limit: 64)
                                line.append(.read(conversation, page.items.map(\.id)))
                            }, context: .background)
                        } else {
                            _ = try await session.commit({ tx in
                                let entry = try await tx.appendEntry(conversation,
                                    value: EntryDraft(kind: "stress.\(taskIndex).\(operation)"))
                                line.append(.write(entry))
                                return entry
                            }, context: .background)
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
        var replay: [ConversationID: [EntryRecord]] = [:]
        var order: [EntryRecord] = []
        var reads = 0
        for event in line.values {
            switch event {
            case .write(let entry):
                replay[entry.conversationId, default: []].append(entry)
                order.append(entry)
            case .read(let conversation, let observed):
                let expected = Array((replay[conversation] ?? []).suffix(64).reversed().map(\.id))
                #expect(observed == expected)
                reads += 1
            }
        }
        #expect(order.count + reads == 20_005)
        #expect(publications.values == order.map(\.id))
        var prior: Seq?
        for entry in order {
            let stored = try #require(try await backend.entry(entry.id, context: .background))
            #expect(stored.entry == entry)
            if let prior { #expect(stored.commitSeq > prior) }
            prior = stored.commitSeq
        }
        for conversation in conversations {
            var cursor: Cursor?
            var stored: [EntryRecord] = []
            repeat {
                let page = try await backend.scanEntries(.init(conversationId: conversation, order: .ascending),
                    limit: 256, cursor: cursor, context: .background)
                stored.append(contentsOf: page.items)
                cursor = page.next
            } while cursor != nil
            #expect(stored == (replay[conversation] ?? []))
        }
        let calls = await controlled.callBatchCounts
        #expect(calls.count < order.count + conversations.count)
        print("D3A-STRESS \(kind) operations=20000 writes=\(order.count) reads=\(reads) storageCalls=\(calls.count)")
        subscription.cancel()
        try await session.close(context: .background)
    }
}
