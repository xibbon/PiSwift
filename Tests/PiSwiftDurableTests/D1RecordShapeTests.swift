import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private let d1Carrier: [String: String] = ["traceparent": "opaque-parent", "vendor": "a,b=opaque", "__proto__": "kept"]
private let d1Links: [[String: String]] = [["traceparent": "first"], [:], ["vendor": "second"]]

private func d1TaskJSON(_ id: Int = 2, until: Double = 1_234.125) throws -> JSONValue {
    ["id": .number(Double(id)), "conversationId": 1, "kind": "test.d1", "version": 1,
     "input": ["value": true], "background": false, "abortRequested": false,
     "state": ["status": "sleeping", "checkpoint": ["phase": "resume", "payload": [1, nil, "x"]],
               "until": .number(until), "futureState": ["retained": true]],
     "restarts": 3, "trace": try JSONValue(encoding: d1Carrier), "links": try JSONValue(encoding: d1Links),
     "memos": ["effect": "saved"], "futureRecord": ["retained": [1, 2]]]
}

private func d1SubmissionJSON(_ type: String) throws -> JSONValue {
    ["id": .number(type == "input" ? 4 : 5), "conversationId": 1, "type": .string(type), "status": "queued",
     "requestId": .string(type), "trace": try JSONValue(encoding: d1Carrier), "futureSubmission": ["retained": true]]
}

private func d1ScalarCarrierTaskJSON(empty: Bool = false) throws -> JSONValue {
    var fields = try #require(d1TaskJSON().objectValue)
    let carrier = JSONValue.object(JSONObject([("\u{e9}", .string("composed")),
        ("e\u{301}", .string("decomposed")), ("vendor", .string("kept"))]))
    fields["trace"] = empty ? [:] : carrier
    fields["links"] = empty ? [] : [carrier, [:], ["last": "kept"]]
    return .object(fields)
}

@Suite struct D1RecordShapeTests {
    // Upstream v1.4.0 types.ts:619,644,678 and harness/task-graph.ts:29.
    @Test(arguments: [0.0, 0.125, 1_234.125, 9_007_199_254_740_990.0])
    func sleepingRecordsRetainDeadlinesCarriersAndUnknownFields(until: Double) throws {
        let json = try d1TaskJSON(until: until)
        let record = try json.decode(TaskRecord.self)
        #expect(record.restarts == 3 && record.storedRestarts == 3)
        #expect(record.trace == d1Carrier && record.links == d1Links)
        #expect(record.state.status == "sleeping")
        #expect(try JSONValue(encoding: record) == json)
        #expect(try JSONValue(jsonText: JSONValue(encoding: record).jsonText()).decode(TaskRecord.self) == record)
        #expect(try JSONValue(encoding: TaskQuery(status: .sleeping)) == ["status": "sleeping"])
    }

    @Test func absentRestartCountIsZeroAndRemainsAbsent() throws {
        var object = try #require(d1TaskJSON().objectValue)
        object["restarts"] = nil
        let record = try JSONValue.object(object).decode(TaskRecord.self)
        #expect(record.restarts == 0 && record.storedRestarts == nil)
        #expect(try JSONValue(encoding: record) == .object(object))
        object["restarts"] = 0
        let explicitZero = try JSONValue.object(object).decode(TaskRecord.self)
        #expect(explicitZero.restarts == 0 && explicitZero.storedRestarts == 0)
        #expect(try JSONValue(encoding: explicitZero) == .object(object))
    }

    @Test(arguments: [-0.5, 0.0, 3.25])
    func restartNumbersRetainTheUpstreamWireValue(count: Double) throws {
        var object = try #require(d1TaskJSON().objectValue)
        object["restarts"] = .number(count)
        let record = try JSONValue.object(object).decode(TaskRecord.self)
        #expect(record.restarts == count)
        #expect(try JSONValue(encoding: record) == .object(object))
    }

    @Test func fieldsFromThePreviousExtensionAPIRemainAvailable() throws {
        let source = try d1TaskJSON()
        let record = try source.decode(TaskRecord.self)
        var fields = record.extensionFields
        fields["restarts"] = 3
        fields["trace"] = try JSONValue(encoding: d1Carrier)
        fields["links"] = try JSONValue(encoding: d1Links)
        let oldAPI = TaskRecord(id: record.id, conversationId: record.conversationId, kind: record.kind,
            version: record.version, input: record.input, state: record.state, memos: record.memos, extensionFields: fields)
        #expect(oldAPI.restarts == 3 && oldAPI.trace == d1Carrier && oldAPI.links == d1Links)
        #expect(try JSONValue(encoding: oldAPI) == source)
        #expect(oldAPI == record)
    }

    @Test(arguments: [false, true])
    func carrierKeysAndEmptyValuesSurviveRecordCopies(empty: Bool) throws {
        let json = try d1ScalarCarrierTaskJSON(empty: empty)
        let record = try json.decode(TaskRecord.self)
        #expect(record.trace != nil && record.links != nil)
        #expect(try JSONValue(encoding: record) == json)
        let oldAPI = TaskRecord(id: record.id, conversationId: record.conversationId, kind: record.kind,
            version: record.version, input: record.input, state: record.state, memos: record.memos,
            restarts: record.storedRestarts, extensionFields: record.carrierCopyFields)
        #expect(try JSONValue(encoding: oldAPI) == json)
        for copy in [record.replacing(), record.withAbortMark()] {
            let encoded = try JSONValue(encoding: copy)
            #expect(encoded["trace"] == json["trace"])
            #expect(encoded["links"] == json["links"])
        }
        if !empty {
            let trace = try #require(json["trace"]?.objectValue)
            #expect(trace.count == 3)
            #expect(trace["\u{e9}"] == "composed" && trace["e\u{301}"] == "decomposed")
        }
    }

    @Test(arguments: ["input", "write"])
    func submissionCarrierIsTypedAndRetained(type: String) throws {
        let json = try d1SubmissionJSON(type)
        let record = try json.decode(SubmissionRecord.self)
        #expect(record.trace == d1Carrier)
        #expect(try JSONValue(encoding: record) == json)
    }

    @Test(arguments: [-1.0, Double.infinity, -Double.infinity, Double.nan])
    func rejectsInvalidSleepDeadlines(until: Double) throws {
        #expect(throws: (any Error).self) {
            try JSONValue(encoding: TaskState.sleeping(checkpoint: ["phase": "resume"], until: until))
        }
        #expect(throws: (any Error).self) {
            try JSONValue(encoding: TaskGraphState.sleeping(phase: "resume", until: until))
        }
        let definition = harnessOneStep("test.d1") { _, _, _ in }
        #expect(throws: (any Error).self) { try definition.sleeping(HarnessTaskCheckpoint(), until: until) }
        if until.isFinite {
            #expect(throws: (any Error).self) { try d1TaskJSON(until: until).decode(TaskRecord.self) }
            let graph: JSONValue = ["status": "sleeping", "phase": "resume", "until": .number(until)]
            #expect(throws: (any Error).self) { try graph.decode(TaskGraphState.self) }
        }
    }

    @Test func typedSleepFactoryUsesTheCheckpointAndFractionalDeadline() throws {
        let definition = harnessOneStep("test.d1") { _, _, _ in }
        let checkpoint = HarnessTaskCheckpoint(phase: .joined, count: 7)
        let state = try definition.sleeping(checkpoint, until: 0.25)
        #expect(state == .sleeping(checkpoint: try JSONValue(encoding: checkpoint), until: 0.25))
        let json: JSONValue = ["status": "sleeping", "phase": "joined", "until": 0.25]
        let graph = try json.decode(TaskGraphState.self)
        #expect(graph == .sleeping(phase: "joined", until: 0.25))
        #expect(try JSONValue(encoding: graph) == json)
    }

    @Test(arguments: ["jsonl", "sqlite"])
    func persistentStoresRetainNewFieldsAndFilterSleepingTasks(backend: String) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        func open() async throws -> any DurableStorage {
            if backend == "sqlite" { return try await SqliteStorage.open(path: directory.appendingPathComponent("d1.sqlite").path) }
            return try await JsonlStorage.open(directory: directory.path, fileSystem: LocalExecutionEnv(cwd: directory.path))
        }
        var storage = try await open()
        let sleepJSON = try d1ScalarCarrierTaskJSON(), task = try sleepJSON.decode(TaskRecord.self)
        let inputJSON = try d1SubmissionJSON("input"), writeJSON = try d1SubmissionJSON("write")
        let running = TaskRecord(id: try TaskID(3), conversationId: rootConversationID, kind: "test.running", version: 1,
                                 input: .null, state: .running(checkpoint: ["phase": "work"]))
        _ = try await storage.commit([.conversation(value: .init(id: rootConversationID)), .task(value: task),
            .task(value: running), .submission(value: inputJSON.decode()), .submission(value: writeJSON.decode())], context: .background)
        try await storage.close(context: .background)
        storage = try await open()
        let saved = try #require(await storage.task(task.id, context: .background))
        #expect(try JSONValue(encoding: saved) == sleepJSON)
        let sleeping = try await storage.scanTasks(.init(status: .sleeping), limit: 1, cursor: nil, context: .background)
        #expect(sleeping.items == [task] && sleeping.next == nil)
        let runningPage = try await storage.scanTasks(.init(status: .running), limit: 1, cursor: nil, context: .background)
        #expect(runningPage.items == [running])
        for json in [inputJSON, writeJSON] {
            let id = try #require(json["id"]).decode(SubmissionID.self)
            let submission = try #require(await storage.submission(id, context: .background))
            #expect(submission.trace == d1Carrier)
            #expect(try JSONValue(encoding: submission) == json)
        }
        try await storage.close(context: .background)
    }

    @Test func transactionCopiesRetainDistinctUnicodeCarrierKeys() async throws {
        let json = try d1ScalarCarrierTaskJSON(), record = try json.decode(TaskRecord.self)
        let storage = MemoryStorage()
        _ = try await storage.commit([.conversation(value: .init(id: rootConversationID)), .task(value: record)], context: .background)
        let harness = try await harnessOpen([], storage: storage)
        let root = try await harness.root(context: .background)
        try await root.commit({ tx in try tx.setTask(record.replacing().withAbortMark()) }, context: .background)
        let saved = try #require(await harness.getTask(id: record.id, context: .background))
        let encoded = try JSONValue(encoding: saved)
        #expect(encoded["trace"] == json["trace"])
        #expect(encoded["links"] == json["links"])
        try await harness.close(context: .background)
    }

    @Test func graphBuildAndCommitFramesIncludeSleepingTasks() async throws {
        let storage = MemoryStorage()
        let record = try d1TaskJSON().decode(TaskRecord.self)
        _ = try await storage.commit([.conversation(value: .init(id: rootConversationID)), .task(value: record)], context: .background)
        let input = try d1SubmissionJSON("input").decode(SubmissionRecord.self)
        let write = try d1SubmissionJSON("write").decode(SubmissionRecord.self)
        _ = try await storage.commit([.submission(value: input), .submission(value: write)], context: .background)
        let harness = try await harnessOpen([], storage: storage)
        let graph = try await harness.taskGraph(context: .background)
        #expect(graph.value.tasks["2"]?.state == .sleeping(phase: "resume", until: 1_234.125))
        let root = try await harness.root(context: .background)
        let changed = TaskRecord(id: record.id, conversationId: rootConversationID, kind: record.kind, version: record.version,
            input: record.input, state: .sleeping(checkpoint: ["phase": "later"], until: 2_000.875),
            memos: record.memos, restarts: record.storedRestarts, trace: record.trace, links: record.links,
            extensionFields: record.extensionFields)
        try await root.commit({ tx in
            try tx.setTask(changed)
            try tx.placeSubmission(input.id, entry: EntryID(100))
            try tx.placeSubmission(write.id, entry: EntryID(101))
        }, context: .background)
        try await root.commit({ tx in
            try tx.settleSubmission(input.id, settlement: .done(answer: EntryID(102)))
        }, context: .background)
        let saved = try #require(await harness.getTask(id: changed.id, context: .background))
        #expect(saved == changed)
        for id in [input.id, write.id] {
            let submission = try #require(await storage.submission(id, context: .background))
            #expect(submission.trace == d1Carrier)
            #expect(try JSONValue(encoding: submission)["futureSubmission"] == ["retained": true])
        }
        await graph.waitUntilIdle()
        #expect(graph.value.tasks["2"]?.state == .sleeping(phase: "later", until: 2_000.875))
        let advanced = graph.value
        graph.dispose()
        let rebuilt = try await harness.taskGraph(context: .background)
        #expect(rebuilt.value == advanced)
        rebuilt.dispose()
        try await harness.close(context: .background)
    }
}
