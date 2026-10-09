import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurable

@Suite("PiSwiftDurableTests.JsonlRecovery")
struct JsonlRecoveryTests {
    @Test func truncatesTornUTF8AtExactByteOffsets() async throws {
        try await jsonlWithStorage { storage, directory, _ in
            try await jsonlRoot(storage)
            let id: DocumentID = try await storage.mintId()
            _ = try await storage.commit([jsonlCreate(id, value: ["text": "kept"])], context: .background)
            let name = jsonlDocName(id)
            let sidecar = try Data(contentsOf: directory.appendingPathComponent(name))
            let main = try Data(contentsOf: directory.appendingPathComponent("main.jsonl"))
            let torn = Array(Array("{\"text\":\"€".utf8).dropLast())
            try jsonlAppendBytes(directory, name, bytes: torn)
            try jsonlAppendBytes(directory, "main.jsonl", bytes: torn)
            let reopened = try await jsonlOpen(directory)
            #expect(try Data(contentsOf: directory.appendingPathComponent(name)).count == sidecar.count)
            #expect(try Data(contentsOf: directory.appendingPathComponent("main.jsonl")).count == main.count)
            #expect(try await reopened.commit([.documentChange(id: id, content: .delta(version: 1, ops: []))], context: .background).rawValue == 3)
            try await reopened.close(context: .background)
        }
    }
    @Test func removesCompleteUnconfirmedTaskTail() async throws {
        try await jsonlWithStorage { storage, directory, _ in
            try await jsonlRoot(storage)
            let id: TaskID = try await storage.mintId()
            _ = try await storage.commit([.task(value: jsonlTask(id))], context: .background)
            _ = try await storage.commit([.task(value: jsonlTask(id, terminal: true))], context: .background)
            let name = jsonlTaskName(id)
            #expect(!jsonlExists(directory, name))
            let line: JSONValue = ["format": 1, "type": "record", "seq": 4, "ordinal": 0,
                                   "payload": ["type": "task", "value": try JSONValue(encoding: jsonlTask(id, phase: "stale"))]]
            try Data((try line.jsonText() + "\n").utf8).write(to: directory.appendingPathComponent(name))
            let reopened = try await jsonlOpen(directory)
            #expect(!jsonlExists(directory, name))
            #expect(try await reopened.task(id, context: .background) == jsonlTask(id, terminal: true))
            #expect(try await reopened.commit([], context: .background).rawValue == 4)
            try await reopened.close(context: .background)
        }
    }
    @Test func rejectsMissingConfirmedSidecar() async throws {
        try await jsonlWithStorage { storage, directory, _ in
            try await jsonlRoot(storage)
            let id: DocumentID = try await storage.mintId()
            _ = try await storage.commit([jsonlCreate(id, value: [:])], context: .background)
            try Data().write(to: directory.appendingPathComponent(jsonlDocName(id)))
            try await jsonlExpectError("Missing confirmed sidecar record") { _ = try await jsonlOpen(directory) }
        }
    }
    @Test func rejectsConfirmedRecordAfterUnconfirmedTail() async throws {
        try await jsonlWithStorage { storage, directory, _ in
            try await jsonlRoot(storage)
            let id: DocumentID = try await storage.mintId()
            _ = try await storage.commit([jsonlCreate(id)], context: .background)
            _ = try await storage.commit([jsonlDelta(id, 1)], context: .background)
            let name = jsonlDocName(id)
            let lines = try jsonlLines(directory, name)
            #expect(lines.count == 2)
            let unconfirmed: JSONValue = ["format": 1, "type": "record", "seq": 2, "ordinal": 999,
                "payload": ["type": "document", "id": .number(Double(id.rawValue)), "content": ["kind": "delta", "version": 1, "ops": []]]]
            let text = try lines[0] + "\n" + unconfirmed.jsonText() + "\n" + lines[1] + "\n"
            try Data(text.utf8).write(to: directory.appendingPathComponent(name))
            try await jsonlExpectError("Confirmed record follows an unconfirmed tail") { _ = try await jsonlOpen(directory) }
        }
    }
    @Test func rejectsNonIncreasingMainSequences() async throws {
        try await jsonlWithStorage { storage, directory, _ in
            try await jsonlRoot(storage)
            let bytes = try Data(contentsOf: directory.appendingPathComponent("main.jsonl"))
            try jsonlAppendBytes(directory, "main.jsonl", bytes: Array(bytes))
            try await jsonlExpectError("Commit sequence does not strictly increase") { _ = try await jsonlOpen(directory) }
        }
    }
    @Test func rejectsInvalidConfirmedDocumentContent() async throws {
        try await jsonlWithStorage { storage, directory, _ in
            try await jsonlRoot(storage)
            let id: DocumentID = try await storage.mintId()
            _ = try await storage.commit([jsonlCreate(id, value: [:])], context: .background)
            let name = jsonlDocName(id)
            var record = try JSONValue(jsonText: #require(jsonlLines(directory, name).first))
            var object = try #require(record.objectValue)
            var payload = try #require(object["payload"]?.objectValue)
            var content = try #require(payload["content"]?.objectValue)
            content["value"] = nil
            payload["content"] = .object(content)
            object["payload"] = .object(payload)
            record = .object(object)
            try Data((try record.jsonText() + "\n").utf8).write(to: directory.appendingPathComponent(name))
            try await jsonlExpectError("Invalid document content") { _ = try await jsonlOpen(directory) }
        }
    }
    @Test func rejectsMalformedCompleteMainAndSidecarLines() async throws {
        try await jsonlWithStorage { storage, directory, _ in
            try await jsonlRoot(storage)
            try jsonlAppendBytes(directory, "main.jsonl", bytes: Array("{bad}\n".utf8))
            try await jsonlExpectError("Malformed complete main.jsonl") { _ = try await jsonlOpen(directory) }
        }
        try await jsonlWithStorage { storage, directory, _ in
            try await jsonlRoot(storage)
            try Data("{bad}\n".utf8).write(to: directory.appendingPathComponent("doc-99.jsonl"))
            try await jsonlExpectError("Malformed complete doc-99.jsonl") { _ = try await jsonlOpen(directory) }
        }
    }
}
