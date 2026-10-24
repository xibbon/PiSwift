import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private actor CodemodeFixtureTrace {
    var fingerprint: String?
    var calls: [CodemodeHostCall] = []
    var idles: [CodemodeDuring] = []
    func started(_ fingerprint: String) { self.fingerprint = fingerprint }
    func called(_ call: CodemodeHostCall) { calls.append(call) }
    func idle(_ seq: Int, _ issued: Int) { idles.append(.init(seq: seq, issued: issued)) }
}

@Suite("PiSwiftDurableTests.CodemodeFixtures")
struct CodemodeFixtureTests {
    private func fixture() throws -> JSONValue {
        let url = try #require(Bundle.module.url(forResource: "codemode-v130", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONValue(jsonData: Data(contentsOf: url))
    }

    @Test func documentDefinitionsMatchTheUpstreamTag() throws {
        let fixture = try fixture()
        #expect(fixture["tag"] == "v1.3.0")
        let definitions = [CodemodeRunDoc.definition, CodemodeJournalDoc.definition, CodemodeStoreDoc.definition]
        let expected = try #require(fixture["definitions"]?.arrayValue)
        #expect(definitions.count == expected.count)
        for (definition, item) in zip(definitions, expected) {
            #expect(definition.kind == item["kind"]?.stringValue)
            #expect(try JSONValue(encoding: definition.version) == item["version"])
            let semantics = try JSONValue(encoding: definition.semantics)
            #expect(semantics["scope"] == item["scope"])
            #expect(semantics["history"] == item["history"])
            #expect(semantics["fork"] == item["fork"])
            #expect(try JSONValue.object(definition.initial(nil)) == item["initial"])
        }
    }

    @Test func upstreamDocumentCommitsKeepJournalOrderAndForkValues() async throws {
        let fixture = try fixture()
        let conversationId = try #require(fixture["conversationId"]).decode(ConversationID.self)
        let taskId = try #require(fixture["taskId"]).decode(TaskID.self)
        let forkId = try #require(fixture["forkId"]).decode(ConversationID.self)
        let snapshots = try #require(fixture["snapshots"]?.arrayValue)
        #expect(snapshots.count == 4)
        let storage = MemoryStorage()
        let definitions = [("run", CodemodeRunDoc.definition, DocumentScope.task(taskId: taskId)),
                           ("journal", CodemodeJournalDoc.definition, DocumentScope.task(taskId: taskId)),
                           ("store", CodemodeStoreDoc.definition, DocumentScope.conversation(conversationId: conversationId))]
        for batch in try #require(fixture["batches"]?.arrayValue) {
            let writesJSON = try #require(batch["writes"])
            let writes = try writesJSON.decode([StorageWrite].self)
            #expect(try JSONValue(encoding: writes) == writesJSON)
            let seq = try await storage.commit(writes, context: .background)
            #expect(try JSONValue(encoding: seq) == batch["seq"])
            for snapshot in snapshots where snapshot["seq"] == batch["seq"] {
                for (key, definition, scope) in definitions {
                    let address = DocumentAddress(kind: definition.kind, scope: scope)
                    let record = try #require(try await storage.findDocument(address, at: .current, context: .background))
                    let document = try #require(try await storage.document(record.id, at: .current, context: .background))
                    #expect(try JSONValue.object(definition.materialize(document)) == snapshot[key],
                            "Snapshot \(snapshot["name"]?.stringValue ?? ""): \(key)")
                }
            }
        }
        // Read the same data through public tokens after the storage replay.
        let session = try await Session.open(storage: storage, context: .background)
        let decided = try #require(snapshots.last)
        #expect(try await session.snapshot(CodemodeRunDoc, taskId: taskId, context: .background) == decided["run"]?.objectValue)
        #expect(try await session.snapshot(CodemodeJournalDoc, taskId: taskId, context: .background) == decided["journal"]?.objectValue)
        #expect(try await session.snapshot(CodemodeStoreDoc, conversationId: conversationId, context: .background) == decided["store"]?.objectValue)
        #expect(try await session.snapshot(CodemodeStoreDoc, conversationId: forkId, context: .background) == fixture["forkStore"]?.objectValue)
        let journal = try #require(decided["journal"]?["entries"]?.arrayValue)
        #expect(journal.map { $0["id"] } == [2, 1, 3])
        #expect(journal[0]["global"]?["outcome"]?["value"] == nil)
        #expect(journal[2]["global"]?["outcome"]?["ok"] == false)
        try await session.close(context: .background)
    }

    @Test func typedStartAndJournalReplayTheUpstreamDocumentValues() async throws {
        let fixture = try fixture()
        let snapshots = try #require(fixture["snapshots"]?.arrayValue)
        for snapshot in snapshots {
            if let start = snapshot["run"]?["start"] {
                #expect(try JSONValue(encoding: start.decode(CodemodeStart.self)) == start)
            }
            let journal = try #require(snapshot["journal"])
            #expect(try JSONValue(encoding: journal.decode(CodemodeJournal.self)) == journal)
        }
        let decided = try #require(snapshots.last)
        let start = try #require(decided["run"]?["start"]).decode(CodemodeStart.self)
        let journal = try #require(decided["journal"]).decode(CodemodeJournal.self)
        #expect(start.version == CODEMODE_MODULE_VERSION)
        #expect(journal.firstIssued == 3)
        #expect(journal.entries.map(\.issuedAfter) == [3, 4, 4])
        let fingerprint = try #require(start.fingerprint)
        let sandbox = DeterministicCodemodeSandbox(fingerprint: fingerprint) { state in
            switch state.seq {
            case 0:
                .init(calls: [.init(name: "read-file", args: ["path": "first"]),
                              .init(target: .global, name: "fixtureGlobal", args: ["key", .null]),
                              .init(target: .global, name: "fixtureGlobal")])
            case 2:
                .init(calls: [.init(name: "read-file", args: ["path": "next"])])
            case 4:
                .init(result: .init(value: .array(state.deliveries.map { .number(Double($0.id)) })))
            default: .init()
            }
        }
        let trace = CodemodeFixtureTrace()
        let run = try await sandbox.start(source: "fixture plan", name: "codemode", options: .init(
            startedAt: start.startedAt, seed: start.seed,
            tools: start.tools.filter { $0.hidden != true }.map { .init(name: $0.name, jsName: $0.jsName, description: $0.description) },
            globals: start.globals, store: start.store,
            onStarted: { value, _ in await trace.started(value) },
            onCall: { call, _ in await trace.called(call) },
            onIdle: { seq, issued, _ in await trace.idle(seq, issued) }))
        #expect(await trace.fingerprint == start.fingerprint)
        for (offset, entry) in journal.entries.enumerated() {
            // The fixture has no nested tool result document. Use a host value for call 1.
            let outcome = entry.global?.outcome ?? .success(["read": "constructed host result"])
            try await run.deliver(seq: offset + 1, now: entry.at, id: entry.id, outcome: outcome)
        }
        #expect(await trace.idles == [.init(seq: 0, issued: 3), .init(seq: 1, issued: 3),
                                      .init(seq: 2, issued: 4), .init(seq: 3, issued: 4)])
        #expect(await trace.calls.map(\.id) == [1, 2, 3, 4])
        #expect(journal.entries[0].global?.outcome == .success(nil))
        #expect(journal.entries[2].global?.outcome == .failure(message: "Fixture failure", properties: ["retry": false]))
        // Call 4 is beyond the recorded journal. This delivery represents new live work.
        try await run.deliver(seq: 4, now: journal.entries.last!.at + 1, id: 4, outcome: .success("live"))
        let result = await run.result
        #expect(result.value == [2, 1, 3, 4])
        #expect(result.during == .init(seq: 4, issued: 4))
        let recordedStart = try #require(await sandbox.starts.first)
        #expect(recordedStart.options.seed == start.seed)
        #expect(recordedStart.options.startedAt == start.startedAt)
        #expect(recordedStart.options.store == start.store)
        #expect(recordedStart.options.tools.map(\.name) == ["read-file"])
    }

}
