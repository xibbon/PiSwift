import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private struct D7StressDocument: Codable, Sendable, Equatable { var text = "" }
private struct D7StressMismatch: Error {}

private enum StressLineEvent: Sendable {
    case write(EntryRecord, TaskRecord?)
    case read(ConversationID, [EntryID], ConversationRecord?, TaskRecord?, SubmissionRecord?)
    case deferred(ConversationID, String)
}

// v1.5.2 D7 session-deferred-commits.test.ts:521-596,638-652: include deferred
// progress, watches, stored publications, dependent reads, close and crash.
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
        let clock = TestClock(now: 1_000)
        let session = try await Session.openWithDocumentRetention(storage: controlled, now: { clock.now() },
            documentRetentionMs: { nil }, documentTimer: .init(now: { clock.now() }, sleep: { try await clock.sleep(until: $0) }),
            cacheBounds: .init(conversations: 4, tasks: 4, submissions: 4),
            persistWithinMs: { 1_000 },
            context: .background)
        var conversations: [ConversationID] = []
        for _ in 0..<8 {
            conversations.append(try await session.commit({ tx in
                try await tx.createConversation(ownership: .ownerless()).id
            }, context: .background))
        }
        let taskKind = TaskKind<Int, Int>(name: "stress.task", version: 1, initial: { $0 })
        let progress = try ConversationDocToken<D7StressDocument>(kind: "stress.d7.progress", version: 1,
            fork: .initial, initial: { D7StressDocument() }, checkpointWhen: { _, _, _ in false })
        var taskIDs: [TaskID] = []
        var submissionIDs: [SubmissionID] = []
        for conversation in conversations {
            let pair = try await session.commit({ tx in
                let task = try await tx.createTask(taskKind, input: 0,
                    options: .init(ownership: .conversation(), conversationId: conversation))
                let submission = try await tx.createSubmission(.write(conversationId: conversation))
                _ = try await tx.doc(progress, conversationId: conversation)
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
        let heldMemory = SessionTestLog<(ConversationID, String)>()
        let watchFrames = SessionTestLog<(ConversationID, String)>()
        let storedSeqs = SessionTestLog<Seq>()
        let storedCallBefore = await controlled.callBatchCounts.count
        var watches: [Watch<D7StressDocument>] = []
        for id in conversations {
            let watch = try #require(try await session.watchDoc(progress, conversationId: id, context: .background))
            try watch.start { call, _ in
                if case .value(let value, _, _) = call { watchFrames.append((id, value.text)) }
            }
            watches.append(watch)
        }
        let own = try session.observeCommits { (publication: ObservedCommit, _: ChordContext) in
            if case .memory(let documents) = publication {
                for document in documents where document.record.kind == "stress.d7.progress" {
                    if let id = document.conversationId, let text = document.value?["text"]?.stringValue {
                        heldMemory.append((id, text))
                    }
                }
            }
        }
        let subscription = try session.subscribeCommits { publication, _ in
            storedSeqs.append(publication.seq)
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
                        if choice % 8 == 1 {
                            let value = "\(taskIndex).\(operation)"
                            try await session.commit({ tx in
                                try await tx.doc(progress, conversationId: conversation).set("text", .string(value))
                                line.append(.deferred(conversation, value))
                            }, context: .background, persistence: .deferred(withinMs: Double((choice >> 16) % 500 + 1)))
                        } else if choice % 4 == 0 {
                            _ = try await session.commit({ tx in
                                let observed = try await tx.doc(progress, conversationId: conversation).get("text")?.stringValue ?? ""
                                let latest = heldMemory.values.last { $0.0 == conversation }?.1 ?? ""
                                if observed != latest { throw D7StressMismatch() }
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
                        clock.advance(by: 1)
                    }
                }
            }
            try await group.waitForAll()
        }
        var replay: [ConversationID: [EntryRecord]] = [:]
        var taskReplay = Dictionary(uniqueKeysWithValues: zip(taskIDs, initialTasks).compactMap { id, value in value.map { (id, $0) } })
        var order: [EntryRecord] = []
        var reads = 0, deferred = 0
        var expectedFrames: [(ConversationID, String)] = []
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
            case .deferred(let conversation, let value):
                expectedFrames.append((conversation, value)); deferred += 1
            }
        }
        #expect(order.count + reads + deferred == 20_005)
        #expect(publications.values == order.map(\.id))
        for watch in watches { await watch.waitUntilIdle() }
        #expect(watchFrames.values.map { "\($0.0.rawValue):\($0.1)" } == expectedFrames.map { "\($0.0.rawValue):\($0.1)" })
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
        #expect(calls.count < order.count + deferred + conversations.count + taskIDs.count)
        print("D3A-STRESS-D7 \(kind) operations=20000 writes=\(order.count) reads=\(reads) deferred=\(deferred) storageCalls=\(calls.count)")
        #expect(session.recordCacheSizes.conversations <= 4)
        #expect(session.recordCacheSizes.tasks <= 4)
        #expect(session.recordCacheSizes.submissions <= 4)
        own.cancel()
        try await session.close(context: .background)
        #expect(storedSeqs.count == (await controlled.callBatchCounts.dropFirst(storedCallBefore)).reduce(0, +))
        #expect(zip(storedSeqs.values, storedSeqs.values.dropFirst()).allSatisfy { $0.0 < $0.1 })
        subscription.cancel()
        for watch in watches { _ = await watch.stop() }
        if kind != "memory" {
            // v1.5.2 D7 session-deferred-commits.test.ts:638-652: clean close keeps the last watch value.
            let path = directory.appendingPathComponent(kind == "sqlite" ? "store.sqlite" : "store").path
            let resumed = try await Session.open(storage: storage(kind, path: path), context: .background)
            for id in conversations {
                let expected = expectedFrames.last { $0.0 == id }?.1 ?? ""
                #expect(try await resumed.snapshot(progress, conversationId: id, context: .background)?.text == expected)
            }
            let first = conversations[0]
            let stored = try #require(try await resumed.snapshot(progress, conversationId: first, context: .background))
            try await resumed.commit({ tx in
                try await tx.doc(progress, conversationId: first).set("text", "crash-only")
            }, context: .background, persistence: .deferred(withinMs: .infinity))
            resumed.fail(D7StressMismatch())
            _ = await resumed.closed
            let afterCrash = try await Session.open(storage: storage(kind, path: path), context: .background)
            #expect(try await afterCrash.snapshot(progress, conversationId: first, context: .background) == stored)
            try await afterCrash.close(context: .background)
        }
    }
}
