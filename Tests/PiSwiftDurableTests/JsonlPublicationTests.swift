import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting

@Suite("PiSwiftDurableTests.JsonlPublication")
struct JsonlPublicationTests {
    @Test func opensThroughLocalAdapter() async throws {
        let directory = try jsonlTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try await openLocalJsonlStorage(directory: directory.path)
        try await jsonlRoot(storage)
        #expect(try await storage.conversation(rootConversationID, context: .background) == ConversationRecord(id: rootConversationID))
        try await storage.close(context: .background)
    }
    @Test func publishesBeforeReclaimingDocumentsAndTasks() async throws {
        try await jsonlWithStorage { storage, directory, _ in
            try await jsonlRoot(storage)
            let task: TaskID = try await storage.mintId()
            let doc: DocumentID = try await storage.mintId()
            _ = try await storage.commit([.task(value: jsonlTask(task))], context: .background)
            _ = try await storage.commit([jsonlCreate(doc)], context: .background)
            _ = try await storage.commit([.documentChange(id: doc, content: .delta(version: 1, ops: []))], context: .background)
            _ = try await storage.commit([jsonlBase(doc, 1)], context: .background)
            #expect(try jsonlLines(directory, jsonlTaskName(task)).count == 1)
            #expect(try jsonlLines(directory, jsonlDocName(doc)).count == 1)
            _ = try await storage.commit([.documentRetire(id: doc)], context: .background)
            _ = try await storage.commit([.task(value: jsonlTask(task, terminal: true))], context: .background)
            let lines = try jsonlLines(directory, "main.jsonl")
            #expect(lines.count == 7)
            #expect(try lines.map { try JSONValue(jsonText: $0)["type"] } == Array(repeating: JSONValue.string("commit"), count: 7))
            #expect(!jsonlExists(directory, jsonlTaskName(task)))
            #expect(!jsonlExists(directory, jsonlDocName(doc)))
        }
    }
    @Test func ordersTaskReplacementsByOrdinal() async throws {
        try await jsonlWithStorage { storage, directory, _ in
            try await jsonlRoot(storage)
            let id: TaskID = try await storage.mintId()
            _ = try await storage.commit([.task(value: jsonlTask(id, phase: "first")), .task(value: jsonlTask(id, phase: "second"))], context: .background)
            #expect(try jsonlLines(directory, jsonlTaskName(id)).count == 2)
            let reopened = try await jsonlOpen(directory)
            #expect(try await reopened.task(id, context: .background) == jsonlTask(id, phase: "second"))
            try await reopened.close(context: .background)
        }
    }
    @Test func removesCompleteAndTornUnconfirmedAppend() async throws {
        try await jsonlWithStorage { storage, directory, fs in
            try await jsonlRoot(storage)
            let id: TaskID = try await storage.mintId()
            fs.fail(.init(operation: .append, call: 1, mode: .short))
            try await jsonlExpectError("poisoned") {
                _ = try await storage.commit([.task(value: jsonlTask(id, phase: "first")), .task(value: jsonlTask(id, phase: "second-" + String(repeating: "x", count: 512)))], context: .background)
            }
            let bytes = try Data(contentsOf: directory.appendingPathComponent(jsonlTaskName(id)))
            #expect(bytes.last != 10)
            #expect(bytes.filter { $0 == 10 }.count == 1)
            let reopened = try await jsonlOpen(directory)
            #expect(try await reopened.task(id, context: .background) == nil)
            #expect(try Data(contentsOf: directory.appendingPathComponent(jsonlTaskName(id))).isEmpty)
            try await reopened.close(context: .background)
        }
    }
    @Test func preparesCompleteCandidateBeforeIO() async throws {
        try await jsonlWithStorage { storage, _, fs in
            try await jsonlRoot(storage)
            fs.clear()
            let id: EntryID = try await storage.mintId()
            // A non-finite number is the nearest invalid JSON value to JavaScript BigInt.
            do {
                _ = try await storage.commit([.entry(value: .init(id: id, conversationId: rootConversationID, kind: "bad", data: .number(.infinity)))], context: .background)
                Issue.record("Expected JSON serialization failure")
            } catch { #expect(!(error is JsonlStoragePoisonedError)) }
            #expect(fs.operations.isEmpty)
            #expect(try await storage.entry(id, context: .background) == nil)
            #expect(try await storage.commit([.entry(value: .init(id: id, conversationId: rootConversationID, kind: "good"))], context: .background).rawValue == 2)
        }
    }
    @Test func ordersPublicationFlushes() async throws {
        for fsync in [false, true] {
            try await jsonlWithStorage(fsync: fsync) { storage, _, fs in
                try await jsonlRoot(storage)
                let first: DocumentID = try await storage.mintId()
                let second: DocumentID = try await storage.mintId()
                let one = jsonlDocName(first), two = jsonlDocName(second)
                fs.clear()
                _ = try await storage.commit([jsonlCreate(second, kind: "second", value: [:]), jsonlCreate(first, kind: "first", value: [:])], context: .background)
                #expect(fs.operations == ["append:\(two)", "append:\(one)"] + (fsync ? ["flush:\(two)", "flush:\(one)"] : []) + ["append:main.jsonl"])
                fs.clear()
                _ = try await storage.commit([.documentChange(id: first, content: .base(version: 1, value: ["checkpoint": true]))], context: .background)
                #expect(fs.operations == ["append:\(one)"] + (fsync ? ["flush:\(one)"] : []) + ["append:main.jsonl"] + (fsync ? ["flush:main.jsonl"] : []) + ["write:\(one).reclaim"] + (fsync ? ["flush:\(one).reclaim"] : []) + ["rename:\(one).reclaim->\(one)"])
                fs.clear()
                let entry: EntryID = try await storage.mintId()
                _ = try await storage.commit([.entry(value: .init(id: entry, conversationId: rootConversationID, kind: "main-only"))], context: .background)
                #expect(fs.operations == ["append:main.jsonl"])
                let task: TaskID = try await storage.mintId()
                _ = try await storage.commit([.task(value: jsonlTask(task))], context: .background)
                fs.clear()
                _ = try await storage.commit([.task(value: jsonlTask(task, terminal: true))], context: .background)
                #expect(fs.operations == ["append:main.jsonl"] + (fsync ? ["flush:main.jsonl"] : []) + ["remove:\(jsonlTaskName(task))"])
            }
        }
    }
}
