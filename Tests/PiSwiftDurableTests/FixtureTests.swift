import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable

@Suite struct PiSwiftDurableTests {
    func fixture() throws -> JSONValue {
        let url = try #require(Bundle.module.url(forResource: "records", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONValue(jsonData: Data(contentsOf: url))
    }

    private func roundTrip<T: Codable>(_ value: JSONValue, as type: T.Type) throws {
        let decoded = try value.decode(type)
        #expect(try JSONValue(encoding: decoded) == value)
    }

    @Test func upstreamWritesAndReads() throws {
        let fixture = try fixture()
        let batches = try #require(fixture["batches"]?.arrayValue)
        #expect(!batches.isEmpty)
        var writeKinds = Set<String>()
        var taskStates = Set<String>()
        var outcomes = Set<String>()
        var submissionStates = Set<String>()
        var entryKinds = Set<String>()
        var contentKinds = Set<String>()
        var scopes = Set<String>()
        var policies = Set<String>()
        var editActions = Set<String>()
        var ownerships = Set<String>()
        for batch in batches {
            try roundTrip(try #require(batch["seq"]), as: Seq.self)
            for write in try #require(batch["writes"]?.arrayValue) {
                try roundTrip(write, as: StorageWrite.self)
                let kind = try #require(write["type"]?.stringValue)
                writeKinds.insert(kind)
                switch kind {
                case "conversation":
                    let value = try #require(write["value"])
                    if value["id"] == 1 { ownerships.insert("root") }
                    if value["parent"] != nil { ownerships.insert("forked") }
                    if value["owner"] != nil { ownerships.insert("task-owned") }
                    else { ownerships.insert("ownerless") }
                case "task":
                    taskStates.insert(try #require(write["value"]?["state"]?["status"]?.stringValue))
                    if let outcome = write["value"]?["state"]?["outcome"]?["status"]?.stringValue { outcomes.insert(outcome) }
                case "submission":
                    submissionStates.insert(try #require(write["value"]?["type"]?.stringValue) + ":" + (try #require(write["value"]?["status"]?.stringValue)))
                case "entry":
                    entryKinds.insert(try #require(write["value"]?["kind"]?.stringValue))
                    for edit in write["value"]?["edits"]?.arrayValue ?? [] {
                        editActions.insert(try #require(edit["action"]?.stringValue))
                    }
                default: break
                }
                if let content = write["content"]?["kind"]?.stringValue { contentKinds.insert(content) }
                if let scope = write["record"]?["scope"]?["kind"]?.stringValue { scopes.insert(scope) }
                if let history = write["record"]?["history"]?.stringValue,
                   let fork = write["record"]?["fork"]?.stringValue { policies.insert(history + ":" + fork) }
            }
        }
        #expect(writeKinds == ["conversation", "entry", "task", "submission", "document.create", "document.copy", "document.change", "document.retire"])
        #expect(taskStates == ["pending", "running", "waiting", "completing", "terminal"])
        #expect(outcomes == ["completed", "failed", "aborted", "orphaned", "faulted"])
        #expect(submissionStates == ["input:queued", "input:placed", "input:done", "input:unanswered", "write:queued", "write:done", "write:unanswered"])
        #expect(entryKinds.isSuperset(of: ["pi.user", "pi.assistant", "pi.system", "pi.reset"]))
        #expect(contentKinds == ["base", "delta"])
        #expect(scopes == ["session", "conversation", "task"])
        #expect(policies == ["latest:initial", "latest:current", "rewindable:initial", "rewindable:current", "rewindable:asOf"])
        #expect(editActions == ["omit", "replace"])
        #expect(ownerships == ["root", "ownerless", "task-owned", "forked"])

        for read in try #require(fixture["reads"]?.arrayValue) {
            let method = try #require(read["method"]?.stringValue)
            let args = try #require(read["arguments"]?.arrayValue)
            let result = try #require(read["result"])
            switch method {
            case "conversation": if !result.isNull { try roundTrip(result, as: ConversationRecord.self) }
            case "entry": if !result.isNull { try roundTrip(result, as: EntryLookup.self) }
            case "findLatestHeadMarker": if !result.isNull { try roundTrip(result, as: EntryRecord.self) }
            case "task": if !result.isNull { try roundTrip(result, as: TaskRecord.self) }
            case "submission", "submissionByRequest": if !result.isNull { try roundTrip(result, as: SubmissionRecord.self) }
            case "findDocument":
                try roundTrip(args[0], as: DocumentAddress.self)
                try roundTrip(args[1], as: DocumentPoint.self)
                if !result.isNull { try roundTrip(result, as: DocumentRecord.self) }
            case "document":
                try roundTrip(args[1], as: DocumentPoint.self)
                if !result.isNull { try roundTrip(result, as: StoredDocument.self) }
            case "scanConversations":
                try roundTrip(args[0], as: ConversationQuery.self)
                try roundTrip(result, as: Page<ConversationRecord, Cursor>.self)
            case "scanEntries":
                try roundTrip(args[0], as: EntryQuery.self)
                try roundTrip(result, as: Page<EntryRecord, Cursor>.self)
            case "scanTasks":
                try roundTrip(args[0], as: TaskQuery.self)
                try roundTrip(result, as: Page<TaskRecord, Cursor>.self)
            case "scanSubmissions":
                try roundTrip(args[0], as: SubmissionQuery.self)
                try roundTrip(result, as: Page<SubmissionRecord, Cursor>.self)
            case "scanDocuments":
                try roundTrip(args[0], as: DocumentQuery.self)
                try roundTrip(result, as: Page<DocumentRecord, Cursor>.self)
            default: Issue.record("Unknown fixture read method: \(method)")
            }
            if method.hasPrefix("scan"), args.count > 2, !args[2].isNull {
                try roundTrip(args[2], as: Cursor.self)
            }
        }
    }

    @Test func fixtureMessages() throws {
        let fixture = try fixture()
        var count = 0
        for batch in try #require(fixture["batches"]?.arrayValue) {
            for write in try #require(batch["writes"]?.arrayValue) where write["type"]?.stringValue == "entry" {
                let entry = try #require(write["value"]).decode(EntryRecord.self)
                if let model = entry.model {
                    let messages = try #require(try entry.messages())
                    #expect(try EntryRecord.encodeMessages(messages) == model)
                    let encoded = try EntryRecord.encodeMessages(messages)
                    for (original, encoded) in zip(model, encoded) {
                        #expect(original["sections"]?.objectValue?.keys == encoded["sections"]?.objectValue?.keys)
                        for (block, encodedBlock) in zip(original["content"]?.arrayValue ?? [], encoded["content"]?.arrayValue ?? []) {
                            #expect(block["arguments"]?.objectValue?.keys == encodedBlock["arguments"]?.objectValue?.keys)
                        }
                    }
                    let built = try EntryRecord.withMessages(id: entry.id, conversationId: entry.conversationId,
                                                            kind: entry.kind, messages: messages)
                    #expect(built.model == model)
                    count += model.count
                } else { #expect(try entry.messages() == nil) }
            }
        }
        #expect(count >= 6)
    }

    @Test func unknownRecordFieldsSurvive() throws {
        func addFields(_ value: JSONValue) -> JSONValue {
            switch value {
            case .object(let object):
                var copy = JSONObject(object.map { ($0.key, addFields($0.value)) })
                copy["futureField"] = ["opaque": [true, nil, 1.25]]
                return .object(copy)
            case .array(let values): return .array(values.map(addFields))
            default: return value
            }
        }
        for batch in try #require(try fixture()["batches"]?.arrayValue) {
            for write in try #require(batch["writes"]?.arrayValue) {
                let extended = addFields(write)
                #expect(try JSONValue(encoding: extended.decode(StorageWrite.self)) == extended)
            }
        }
    }

    @Test func JSONBridges() throws {
        let value: JSONValue = ["sections": ["z": "last", "a": "first"], "bool": true, "null": nil,
                                "numbers": [0, -0.25, 9_007_199_254_740_991, 1e21]]
        #expect(try durableJSON(fromOrdered: orderedJSON(from: value)) == value)
        #expect(try durableJSON(fromFoundation: foundationJSON(from: value)) == value)
        #expect(throws: (any Error).self) { try durableJSON(fromOrdered: .number("1e999")) }
        #expect(throws: (any Error).self) { try durableJSON(fromOrdered: .number("true")) }
        #expect(throws: (any Error).self) { try durableJSON(fromFoundation: Date()) }
        let invalid: JSONValue = ["id": 2, "conversationId": 1, "kind": "custom", "model": [["role": "future"]]]
        #expect(throws: DurableJSONBridgeError.invalidMessage(index: 0)) { try invalid.decode(EntryRecord.self).messages() }
    }
}
