import Foundation
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private let d4RecordCaseNames = ["integerSleep", "fractionalSleep", "parked", "retried", "progress",
    "carriers", "cleanClose", "retrySleep", "pollSleep", "legacyRunningRetry"]

@Suite("PiSwiftDurableTests.D4RecordFixtures")
struct D4RecordFixtureTests {
    private func fixture(_ name: String = "lifecycle-records-v140") throws -> JSONValue {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONValue(jsonData: Data(contentsOf: url))
    }

    private func compare(_ storage: any DurableStorage, reads: [JSONValue]) async throws {
        for read in reads {
            let method = try #require(read["method"]?.stringValue)
            let arguments = try #require(read["arguments"]?.arrayValue)
            let actual = try await PiSwiftDurableTests().sqliteReplayRead(method, args: arguments, storage: storage)
            #expect(actual == read["result"], "D4 complete read: \(method), \(arguments)")
        }
    }

    private func replay(_ batches: [JSONValue], storage: any DurableStorage, checkpoints: [JSONValue] = []) async throws {
        for batch in batches {
            let raw = try #require(batch["writes"])
            let writes = try raw.decode([StorageWrite].self)
            #expect(try JSONValue(encoding: writes) == raw)
            #expect(try JSONValue(encoding: await storage.commit(writes, context: .background)) == batch["seq"])
            for checkpoint in checkpoints where checkpoint["seq"] == batch["seq"] {
                try await compare(storage, reads: #require(checkpoint["reads"]?.arrayValue))
            }
        }
    }

    // Every field in every write, final read, and intermediate read is compared.
    @Test(arguments: ["records", "lifecycle-records-v140"])
    func memoryReplaysAllCurrentRecordsAndIntermediateStates(name: String) async throws {
        let data = try fixture(name)
        #expect(data["tag"] == "v1.4.0")
        let storage = MemoryStorage()
        try await replay(#require(data["batches"]?.arrayValue), storage: storage,
                         checkpoints: data["checkpoints"]?.arrayValue ?? [])
        try await compare(storage, reads: #require(data["reads"]?.arrayValue))
        try await storage.close(context: .background)
    }

    @Test(arguments: d4RecordCaseNames)
    func eachCaseKeepsItsCompleteRecordAndIsolatedSeed(name: String) async throws {
        let data = try fixture()
        let cases = try #require(data["cases"]?.objectValue)
        #expect(Set(cases.keys) == Set(d4RecordCaseNames))
        let item = try #require(cases[name])
        let final = try #require(item["final"])
        let record = try final.decode(TaskRecord.self)
        #expect(try JSONValue(encoding: record) == final)
        #expect(final["id"] == item["taskId"])
        let index = try #require(item["readIndex"]?.intValue)
        let reads = try #require(data["reads"]?.arrayValue)
        #expect(reads[index]["result"] == final)
        for snapshot in try #require(item["snapshots"]?.objectValue).values {
            let raw = try #require(snapshot["record"])
            #expect(try JSONValue(encoding: raw.decode(TaskRecord.self)) == raw)
        }
        let seed = MemoryStorage()
        try await replay(#require(item["seedBatches"]?.arrayValue), storage: seed)
        try await compare(seed, reads: #require(item["seedReads"]?.arrayValue))
        let seedPoint = try #require(item["seedPoint"]?.stringValue)
        let expected = try #require(item["snapshots"]?[seedPoint]?["record"])
        let actual = try #require(await seed.task(record.id, context: .background))
        #expect(try JSONValue(encoding: actual) == expected)
        try await seed.close(context: .background)
        if let terminal = item["terminalDue"] {
            #expect(try JSONValue(encoding: terminal.decode(TaskRecord.self)) == terminal)
            #expect(terminal["state"] == ["status": "terminal", "outcome": ["status": "completed", "result": try #require(item["dueClock"])]] )
            #expect(terminal["endedAt"] == item["dueClock"])
        }
    }

    @Test func lifecycleStatesUseTheUpstreamDeadlinesAndCounts() throws {
        let data = try fixture()
        let cases = try #require(data["cases"])
        #expect(data["batches"]?.arrayValue?.count == 42)
        #expect(data["reads"]?.arrayValue?.count == 38)
        #expect(data["checkpoints"]?.arrayValue?.count == 11)
        #expect(cases["integerSleep"]?["final"]?["state"] == ["status": "sleeping", "checkpoint": ["phase": "after", "slept": 1000], "until": 2000])
        #expect(cases["fractionalSleep"]?["final"]?["state"] == ["status": "sleeping", "checkpoint": ["phase": "after", "slept": 0.125], "until": 1000.125])
        #expect(cases["retrySleep"]?["final"]?["state"] == ["status": "sleeping", "checkpoint": ["phase": "retry", "attempt": 1, "until": 61000], "until": 61000])
        #expect(cases["legacyRunningRetry"]?["final"]?["state"] == ["status": "running", "checkpoint": ["phase": "retry", "attempt": 1, "until": 61000]])
        let poll = try #require(cases["pollSleep"]?["final"]?["state"])
        #expect(poll == ["status": "sleeping", "checkpoint": ["phase": "poll", "attempt": 1,
            "model": ["provider": "faux", "modelId": "faux-1"], "cutoff": 30,
            "handle": ["provider": "faux", "modelId": "faux-1", "api": "fixture-faux",
                       "id": "deferred:1700000000000:i", "pollAfterMs": 60000], "pollAt": 61000], "until": 61000])
        #expect(cases["parked"]?["final"]?["restarts"] == 3)
        #expect(cases["retried"]?["snapshots"]?["parked"]?["record"]?["restarts"] == 3)
        #expect(cases["retried"]?["snapshots"]?["cleared"]?["record"]?["restarts"] == nil)
        #expect(cases["retried"]?["final"]?["restarts"] == nil)
        #expect(cases["cleanClose"]?["final"]?["state"] == ["status": "pending", "checkpoint": ["phase": "run"]])
        #expect(cases["cleanClose"]?["final"]?["restarts"] == nil)
        let progress = try #require(cases["progress"]?["snapshots"])
        #expect(progress["cutoff"]?["record"]?["restarts"] == 1)
        #expect(progress["progressed"]?["record"]?["restarts"] == nil)
        #expect(progress["progressed"]?["record"]?["state"] == ["status": "running", "checkpoint": ["phase": "two"]])
        #expect(progress["cutoffAfterProgress"]?["record"]?["restarts"] == 1)
        #expect(progress["cutoffAfterProgress"]?["record"]?["state"] == ["status": "pending", "checkpoint": ["phase": "two"]])
    }

    @Test func carrierMapsKeepEveryScalarDistinctKeyAndSubmissionField() throws {
        let data = try fixture()
        let item = try #require(data["cases"]?["carriers"])
        let raw = try #require(item["final"])
        let carrier: JSONValue = .object(JSONObject([
            ("traceparent", "opaque-parent"), ("vendor", "a,b=opaque"), ("__proto__", "kept"),
            ("\u{e9}", "composed"), ("e\u{301}", "decomposed")]))
        #expect(raw["trace"] == carrier)
        #expect(raw["links"] == [carrier, [:], ["vendor": "second"]])
        #expect(item["terminalDue"]?["trace"] == carrier)
        #expect(item["terminalDue"]?["links"] == raw["links"])
        let ids = try #require(item["submissionIds"]?.arrayValue)
        #expect(ids.count == 2)
        for id in ids {
            let read = try #require(data["reads"]?.arrayValue?.first { $0["method"] == "submission" && $0["arguments"]?.arrayValue == [id] })
            let submission = try #require(read["result"])
            #expect(submission["trace"] == carrier)
            #expect(try JSONValue(encoding: submission.decode(SubmissionRecord.self)) == submission)
        }
    }

    @Test(arguments: ["sqlite", "jsonl"])
    func currentUpstreamLifecycleFilesKeepEveryReadAcrossReopen(backend: String) async throws {
        let data = try fixture()
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(backend == "sqlite" ? "lifecycle.sqlite" : "lifecycle-jsonl")
        let source = try #require(Bundle.module.url(forResource: backend == "sqlite" ? "lifecycle-upstream-v140" : "lifecycle-upstream-jsonl-v140",
            withExtension: backend == "sqlite" ? "sqlite" : nil, subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: source, to: path)
        for _ in 0..<2 {
            let storage: any DurableStorage
            if backend == "sqlite" { storage = try await SqliteStorage.open(path: path.path) }
            else { storage = try await jsonlOpen(path) }
            try await compare(storage, reads: #require(data["reads"]?.arrayValue))
            try await storage.close(context: .background)
        }
    }
}
