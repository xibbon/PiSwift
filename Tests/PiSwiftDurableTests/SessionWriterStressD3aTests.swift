import Foundation
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private enum StressLineEvent: Sendable {
    case write(EntryRecord, TaskRecord?)
    case read(ConversationID, [EntryID], ConversationRecord?, TaskRecord?, SubmissionRecord?)
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
        let session = try await Session.openWithDocumentRetention(storage: controlled, now: { 1_000 },
            documentRetentionMs: { nil }, cacheBounds: .init(conversations: 4, tasks: 4, submissions: 4),
            context: .background)
        var conversations: [ConversationID] = []
        for _ in 0..<8 {
            conversations.append(try await session.commit({ tx in
                try await tx.createConversation(ownership: .ownerless()).id
            }, context: .background))
        }
        let taskKind = TaskKind<Int, Int>(name: "stress.task", version: 1, initial: { $0 })
        var taskIDs: [TaskID] = []
        var submissionIDs: [SubmissionID] = []
        for conversation in conversations {
            let pair = try await session.commit({ tx in
                let task = try await tx.createTask(taskKind, input: 0,
                    options: .init(ownership: .conversation(), conversationId: conversation))
                let submission = try await tx.createSubmission(.write(conversationId: conversation))
                return (task, submission.id)
            }, context: .background)
            taskIDs.append(pair.0); submissionIDs.append(pair.1)
        }
        var initialTasks: [TaskRecord?] = []
        var initialSubmissions: [SubmissionRecord?] = []
        for id in taskIDs { initialTasks.append(try await session.storage.task(id, context: .background)) }
        for id in submissionIDs { initialSubmissions.append(try await session.storage.submission(id, context: .background)) }
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
                line.append(.write(entry, nil))
                return entry
            }, context: .background)
        }
        await firstCall.waitUntilEntered()
        var queued: [Task<EntryRecord, any Error>] = []
        for index in 1...4 {
            queued.append(Task {
                try await session.commit({ tx in
                    let entry = try await tx.appendEntry(preflightIDs[index], value: EntryDraft(kind: "preflight.\(index)"))
                    line.append(.write(entry, nil))
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
        let tasks = taskIDs
        let submissions = submissionIDs
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
                        let index = Int((choice >> 8) % UInt32(ids.count))
                        let conversation = ids[index]
                        if choice % 4 == 0 {
                            _ = try await session.commit({ tx in
                                let page = try await tx.scanEntries(.init(conversationId: conversation, order: .descending), limit: 64)
                                let record = try await tx.conversation(conversation)
                                let task = try await tx.task(tasks[index])
                                let submission = try await tx.submission(submissions[index])
                                line.append(.read(conversation, page.items.map(\.id), record, task, submission))
                            }, context: .background)
                        } else {
                            _ = try await session.commit({ tx in
                                let current = try #require(try await tx.task(tasks[index]))
                                let entry = try await tx.appendEntry(conversation,
                                    value: EntryDraft(kind: "stress.\(taskIndex).\(operation)"))
                                let next = TaskRecord(id: current.id, conversationId: current.conversationId,
                                    kind: current.kind, version: current.version, input: current.input,
                                    state: .pending(checkpoint: .number(Double(operation + taskIndex * 1_250))))
                                try tx.setTask(next)
                                line.append(.write(entry, next))
                                return entry
                            }, context: .background)
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
        var replay: [ConversationID: [EntryRecord]] = [:]
        var taskReplay = Dictionary(uniqueKeysWithValues: zip(taskIDs, initialTasks).compactMap { id, value in value.map { (id, $0) } })
        var order: [EntryRecord] = []
        var reads = 0
        for event in line.values {
            switch event {
            case .write(let entry, let task):
                replay[entry.conversationId, default: []].append(entry)
                order.append(entry)
                if let task { taskReplay[task.id] = task }
            case .read(let conversation, let observed, let record, let task, let submission):
                let expected = Array((replay[conversation] ?? []).suffix(64).reversed().map(\.id))
                #expect(observed == expected)
                #expect(record?.id == conversation)
                let index = try #require(conversations.firstIndex(of: conversation))
                #expect(task == taskReplay[taskIDs[index]])
                #expect(submission == initialSubmissions[index])
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
        #expect(calls.count < order.count + conversations.count + taskIDs.count)
        print("D3A-STRESS \(kind) operations=20000 writes=\(order.count) reads=\(reads) storageCalls=\(calls.count)")
        #expect(session.recordCacheSizes.conversations <= 4)
        #expect(session.recordCacheSizes.tasks <= 4)
        #expect(session.recordCacheSizes.submissions <= 4)
        subscription.cancel()
        try await session.close(context: .background)
    }
}
