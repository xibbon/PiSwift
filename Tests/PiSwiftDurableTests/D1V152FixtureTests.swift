import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite("v1.5.2 TypeScript durable fixtures")
struct D1V152FixtureTests {
    @Test(arguments: ["migration", "harness", "phase-only", "combined"])
    func everyTaggedStorageWriteRoundTrips(name: String) throws {
        let records = try fixture(name)
        for batch in try #require(records["batches"]?.arrayValue) {
            for raw in try #require(batch["writes"]?.arrayValue) {
                let write = try raw.decode(StorageWrite.self)
                #expect(try JSONValue(encoding: write) == raw)
            }
        }
    }

    @Test func swiftV152ExportForUpstreamRead() async throws {
        // D12 may set either path and ask tagged TypeScript to read the export.
        let values = try fixture("migration")
        for (backend, key) in [("sqlite", "PI_DURABLE_V152_SQLITE_EXPORT"),
                               ("jsonl", "PI_DURABLE_V152_JSONL_EXPORT")] {
            guard let path = ProcessInfo.processInfo.environment[key] else { continue }
            let storage: any DurableStorage
            if backend == "sqlite" { storage = try await SqliteStorage.open(path: path) }
            else { storage = try await JsonlStorage.open(directory: path, fileSystem: LocalExecutionEnv(cwd: path)) }
            do {
                for batch in try #require(values["batches"]?.arrayValue) {
                    let writes = try #require(batch["writes"]).decode([StorageWrite].self)
                    #expect(try JSONValue(encoding: await storage.commit(writes, context: .background)) == batch["seq"])
                }
                for read in try #require(values["reads"]?.arrayValue) {
                    let actual = try await PiSwiftDurableTests().sqliteReplayRead(
                        #require(read["method"]?.stringValue), args: #require(read["arguments"]?.arrayValue), storage: storage)
                    #expect(actual == read["result"])
                }
            } catch { try? await storage.close(context: .background); throw error }
            try await storage.close(context: .background)
        }
    }

    @Test func continueSubmissionUsesTxReadAndKeepsPlacedRecord() async throws {
        // v1.5.2 D1: types.ts:573-600; a continue has no entry.
        let test = try await openTestSession()
        let conversation = try await createConversation(test.session)
        let created = try await test.session.commit({ tx in
            try await tx.createSubmission(.continue(conversationId: conversation, requestId: "resume-1"))
        }, context: .background)
        let before = try JSONValue(encoding: created)
        #expect(created.status == "placed")
        #expect(before["entry"] == nil)
        let read = try await test.session.commit({ tx in try await tx.submission(created.id) }, context: .background)
        #expect(read == created)
        let stored = try #require(await test.storage.submission(created.id, context: .background))
        #expect(try JSONValue(encoding: stored) == before)
        #expect(stored.status == "placed")
    }

    @Test func rejectsInvalidContinueAndRunFailureWireValues() throws {
        // v1.5.2 D1: types.ts:573-600 and live.ts:109-136.
        let valid: JSONObject = ["id": 3, "conversationId": 1, "type": "continue", "status": "placed"]
        var withEntry = valid
        withEntry["entry"] = 8
        #expect(throws: (any Error).self) { try JSONValue.object(withEntry).decode(SubmissionRecord.self) }
        var unknown = valid
        unknown["type"] = "advance"
        #expect(throws: (any Error).self) { try JSONValue.object(unknown).decode(SubmissionRecord.self) }
        let badLive: JSONValue = ["runFailure": ["taskId": 7, "inputs": [], "reason": "future_reason"]]
        #expect(throws: (any Error).self) { try badLive.decode(LiveState.self) }
    }

    @Test func liveMigrationDefaultsNonnumericTurns() throws {
        // v1.5.2 D1: live.ts:205-213 uses 0 unless turns is a number.
        let old: JSONObject = ["run": ["taskId": 8, "inputs": [], "turns": "unknown"],
                               "compactions": [["taskId": 9, "reason": "manual", "blocking": false, "attempt": 1]]]
        let migrated = migrateLiveState(old)
        #expect(migrated["run"]?["turns"] == 0)
        #expect(migrated["compactions"]?[0]?["trigger"] == "manual")
        #expect(migrated["compactions"]?[0]?["reason"] == nil)
        #expect(try JSONValue.object(migrated).decode(LiveState.self).run?.turns == 0)
    }

    private func fixture(_ name: String) throws -> JSONValue {
        let url = try #require(Bundle.module.url(forResource: "\(name)-records-v152", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONValue(jsonData: Data(contentsOf: url))
    }

    private func copiedFixture(_ name: String, backend: String) throws -> (directory: URL, path: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("d1-v152-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext: String? = backend == "sqlite" ? "sqlite" : nil
        let suffix = backend == "sqlite" ? "" : "-jsonl"
        let resource = "\(name)-upstream\(suffix)-v152"
        let source = try #require(Bundle.module.url(forResource: resource, withExtension: ext, subdirectory: "Fixtures"))
        let path = directory.appendingPathComponent(backend == "sqlite" ? "fixture.sqlite" : "fixture-jsonl")
        try FileManager.default.copyItem(at: source, to: path)
        return (directory, path)
    }

    private func fileBytes(_ path: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let isDirectory = try path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        if isDirectory {
            let files = try #require(FileManager.default.enumerator(at: path, includingPropertiesForKeys: [.isRegularFileKey]))
            for case let url as URL in files where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(url.path.dropFirst(path.path.count))] = try Data(contentsOf: url)
            }
        } else {
            result[path.lastPathComponent] = try Data(contentsOf: path)
        }
        return result
    }

    private func sqliteRows(_ path: URL) throws -> [String: [SqliteRow]] {
        let db = try AppleSqliteDatabase(path: path.path)
        defer { try? db.close() }
        let names = try db.all("SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
            .map { try $0.sqliteText("name") }
        var rows: [String: [SqliteRow]] = [:]
        for name in names { rows[name] = try db.all("SELECT * FROM \(name) ORDER BY rowid") }
        return rows
    }

    @Test(arguments: ["migration", "harness", "combined"])
    func submissionRecordsRoundTrip(name: String) throws {
        let records = try fixture(name)
        let submissions = try #require(records["reads"]?.arrayValue).filter { $0["method"] == "submission" }
        #expect(!submissions.isEmpty)
        for read in submissions {
            let raw = try #require(read["result"])
            let decoded = try raw.decode(SubmissionRecord.self)
            #expect(try JSONValue(encoding: decoded) == raw)
        }
    }

    @Test func combinedTaggedImageContainsRealRunAndNewShapes() throws {
        let combined = try fixture("combined")
        #expect(combined["provenance"] == "tagged Harness batches, then tagged Session and Storage in one image")
        #expect(combined["harnessConversationId"] == 1)
        #expect(combined["conversationId"] == 20)
        #expect(try #require(combined["batches"]?.arrayValue).count == 48)
        #expect(try #require(combined["reads"]?.arrayValue).count == 34)
        let phases = try #require(combined["phaseCases"]?.objectValue)
        for name in ["finish", "drain", "retryPoll", "toolsPending", "unofferedTool", "newerGenerationVersion"] {
            #expect(phases[name] != nil)
        }
        #expect(try #require(combined["liveCases"]?.arrayValue).count == 6)
    }

    @Test func liveDocumentVersionsMigrate() throws {
        let cases = try #require(fixture("migration")["liveCases"]?.arrayValue)
        #expect(cases.count >= 6)
        for item in cases {
            let stored = try #require(item["stored"]?.objectValue)
            let version = try #require(item["version"]?.intValue)
            let expected = try #require(item["migrated"])
            let value: JSONObject
            if version == LiveDoc.definition.version { value = stored }
            else {
                let migrate = try #require(LiveDoc.definition.migrate)
                value = try migrate(stored, version)
            }
            #expect(JSONValue.object(value) == expected)
            let live = try JSONValue.object(value).decode(LiveState.self)
            #expect(try JSONValue(encoding: live) == expected)
        }
    }

    @Test func builtInTaskMigrationsMatchTypeScript() throws {
        let fixture = try fixture("migration")
        for item in try #require(fixture["taskMigrations"]?.arrayValue) {
            let kind = try #require(item["kind"]?.stringValue)
            let rawID = try #require(item["recordId"])
            let id = try rawID.decode(TaskID.self)
            let reads = try #require(fixture["reads"]?.arrayValue)
            let matching = reads.first { read in
                read["method"] == "task" && read["arguments"]?.arrayValue?.first == item["recordId"]
            }
            let raw = try #require(matching?["result"])
            let record = try raw.decode(TaskRecord.self)
            #expect(record.id == id)
            let definition = try #require(createRegistry().snapshot().task(name: kind))
            #expect(definition.version == item["toVersion"]?.numberValue)
            let migrate = try #require(definition.migrate)
            let checkpoint = try #require(raw["state"]?["checkpoint"])
            let result = try migrate(record.input, checkpoint, try #require(item["fromVersion"]?.numberValue))
            #expect(result.input == item["result"]?["input"])
            #expect(result.checkpoint == item["result"]?["checkpoint"])
            if kind == "pi.generation" {
                #expect(try JSONValue(encoding: result.checkpoint.decode(GenerationCheckpoint.self)) == result.checkpoint)
            } else if kind == "pi.tool" {
                #expect(try JSONValue(encoding: result.input.decode(ToolTaskInput.self)) == result.input)
                #expect(try JSONValue(encoding: result.checkpoint.decode(ToolTaskCheckpoint.self)) == result.checkpoint)
            }
        }
    }

    @Test func currentTaskPhaseAndInputShapesRoundTrip() throws {
        let reads = try #require(fixture("migration")["reads"]?.arrayValue)
        for read in reads where read["method"] == "task" {
            let raw = try #require(read["result"])
            let record = try raw.decode(TaskRecord.self)
            guard let checkpoint = raw["state"]?["checkpoint"] else { continue }
            if checkpoint["phase"] == "future" { continue }
            if record.kind == "pi.generation", record.version == generationTask.version {
                let phase = try checkpoint.decode(GenerationCheckpoint.self)
                #expect(try JSONValue(encoding: phase) == checkpoint)
            } else if record.kind == "pi.tool", record.version == toolTask.version {
                let input = try record.input.decode(ToolTaskInput.self)
                #expect(try JSONValue(encoding: input) == record.input)
                let phase = try checkpoint.decode(ToolTaskCheckpoint.self)
                #expect(try JSONValue(encoding: phase) == checkpoint)
            }
        }
    }

    @Test func taggedNodeResumeOracleHasTypedRecord() throws {
        let url = try #require(Bundle.module.url(forResource: "generation-resume-oracle-v152", withExtension: "json", subdirectory: "Fixtures"))
        let oracle = try JSONValue(jsonData: Data(contentsOf: url))
        #expect(oracle["sourceTag"] == "v1.4.0")
        #expect(oracle["targetTag"] == "v1.5.2")
        let before = try #require(oracle["before"]?["record"])
        let after = try #require(oracle["after"]?["record"])
        let seeded = try before.decode(TaskRecord.self)
        let resumed = try after.decode(TaskRecord.self)
        #expect(seeded.id == resumed.id)
        #expect(seeded.version == 1)
        #expect(resumed.version == generationTask.version)
        #expect(try JSONValue(encoding: resumed) == after)
        #expect(resumed.state.status == "terminal")
    }

    @Test func unsupportedFuturePhaseRemainsOpaque() throws {
        let fixture = try fixture("migration")
        let cases = try #require(fixture["phaseCases"]?.objectValue)
        let futureID = try #require(cases["unsupported"])
        let reads = try #require(fixture["reads"]?.arrayValue)
        let raw = try #require(reads.first { $0["method"] == "task" && $0["arguments"]?.arrayValue?.first == futureID }?["result"])
        let record = try raw.decode(TaskRecord.self)
        #expect(record.kind == "fixture.future")
        #expect(record.version > generationTask.version)
        #expect(try JSONValue(encoding: record) == raw)
        let checkpoint = try #require(raw["state"]?["checkpoint"])
        #expect(checkpoint["phase"] == "future")
        #expect(checkpoint["retained"] == ["marker": "opaque"])
        let unsupportedID = try #require(cases["unsupportedGenerationPhase"])
        let unsupported = try #require(reads.first { $0["method"] == "task" && $0["arguments"]?.arrayValue?.first == unsupportedID }?["result"])
        let unsupportedRecord = try unsupported.decode(TaskRecord.self)
        #expect(unsupportedRecord.kind == generationTask.name)
        #expect(try JSONValue(encoding: unsupportedRecord) == unsupported)
        let unsupportedCheckpoint = try #require(unsupported["state"]?["checkpoint"])
        #expect(throws: (any Error).self) { try unsupportedCheckpoint.decode(GenerationCheckpoint.self) }

        let newerID = try #require(cases["newerGenerationVersion"])
        let newer = try #require(reads.first { $0["method"] == "task" && $0["arguments"]?.arrayValue?.first == newerID }?["result"])
        let newerRecord = try newer.decode(TaskRecord.self)
        #expect(newerRecord.version > generationTask.version)
        #expect(try JSONValue(encoding: newerRecord) == newer)

        let errorID = try #require(cases["errorOutcome"])
        let errorRecord = try #require(reads.first { $0["method"] == "task" && $0["arguments"]?.arrayValue?.first == errorID }?["result"])
        #expect(errorRecord["state"]?["outcome"]?["status"] == "failed")
        #expect(try JSONValue(encoding: errorRecord.decode(TaskRecord.self)) == errorRecord)
    }

    @Test(arguments: ["migration", "harness", "combined"])
    func sqliteOpenReadClosePreservesRows(name: String) async throws {
        let copied = try copiedFixture(name, backend: "sqlite")
        defer { try? FileManager.default.removeItem(at: copied.directory) }
        let before = try sqliteRows(copied.path)
        let storage = try await SqliteStorage.open(path: copied.path.path)
        do {
            for read in try #require(fixture(name)["reads"]?.arrayValue) {
                let actual = try await PiSwiftDurableTests().sqliteReplayRead(
                    #require(read["method"]?.stringValue), args: #require(read["arguments"]?.arrayValue), storage: storage)
                #expect(actual == read["result"])
            }
        } catch { try? await storage.close(context: .background); throw error }
        try await storage.close(context: .background)
        #expect(try sqliteRows(copied.path) == before)
    }

    @Test(arguments: ["migration", "harness", "combined"])
    func jsonlOpenReadClosePreservesBytes(name: String) async throws {
        let copied = try copiedFixture(name, backend: "jsonl")
        defer { try? FileManager.default.removeItem(at: copied.directory) }
        let before = try fileBytes(copied.path)
        let storage = try await JsonlStorage.open(directory: copied.path.path, fileSystem: LocalExecutionEnv(cwd: copied.path.path))
        do {
            for read in try #require(fixture(name)["reads"]?.arrayValue) {
                let actual = try await PiSwiftDurableTests().sqliteReplayRead(
                    #require(read["method"]?.stringValue), args: #require(read["arguments"]?.arrayValue), storage: storage)
                #expect(actual == read["result"])
            }
        } catch { try? await storage.close(context: .background); throw error }
        try await storage.close(context: .background)
        #expect(try fileBytes(copied.path) == before)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["sqlite", "jsonl"])
    func phaseOnlyFileCanResumeWhileNewerTaskStaysBlocked(backend: String) async throws {
        let copied = try copiedFixture("phase-only", backend: backend)
        defer { try? FileManager.default.removeItem(at: copied.directory) }
        let fixture = try fixture("phase-only")
        let cases = try #require(fixture["cases"]?.objectValue)
        let newerRawID = try #require(cases["newerGenerationVersion"])
        let newerID = try newerRawID.decode(TaskID.self)
        let storage: any DurableStorage
        if backend == "sqlite" { storage = try await SqliteStorage.open(path: copied.path.path) }
        else { storage = try await JsonlStorage.open(directory: copied.path.path, fileSystem: LocalExecutionEnv(cwd: copied.path.path)) }
        let harness = try await Harness.open(storage: storage,
            options: .init(models: FakeDurableModels(), registry: createRegistry(), now: { 0 }), context: .background)
        do {
            let initial = try await harness.inspect(context: .background)
            #expect(initial.scheduling == .paused)
            for (name, rawID) in cases {
                let id = try rawID.decode(TaskID.self)
                let saved = try #require(initial.tasks.first { $0.record.id == id })
                if ["finish", "drain", "retryPoll"].contains(name) {
                    // v1.5.2 D5b: the phase runs now (generation.ts:309–345,370–395).
                    guard case .pending = saved.state else { Issue.record("Fixture phase \(name) is not pending"); continue }
                } else if case .blocked(let reason, _) = saved.state {
                    #expect(reason == (name == "newerGenerationVersion" ? .taskTooOld : .migrationFailed))
                } else if name == "toolsPending" {
                    // v1.5.2 D5a harness-inspect.test.ts:97–101: runnable work is pending.
                    guard case .pending = saved.state else { Issue.record("Fixture phase \(name) was neither pending nor blocked"); continue }
                } else { Issue.record("Fixture phase \(name) was not blocked") }
            }
            var recordsBefore: [TaskID: TaskRecord] = [:]
            for rawID in cases.values {
                let id = try rawID.decode(TaskID.self)
                recordsBefore[id] = try await storage.task(id, context: .background)
            }
            try harness.resume()
            // v1.5.2 D5b generation.ts:370–395: wait for the two phase outcomes.
            // A five-second storage polling loop can starve under the full parallel suite.
            _ = try await harness.waitForTask(id: TaskID(2), context: .background)
            _ = try await harness.waitForTask(id: TaskID(3), context: .background)
            let resumed = try await harness.inspect(context: .background)
            for (name, rawID) in cases {
                let id = try rawID.decode(TaskID.self)
                switch name {
                case "finish", "drain":
                    // v1.5.2 D5b: the phase runs now (generation.ts:370–395).
                    #expect(try await storage.task(id, context: .background)?.state.status == "terminal")
                case "retryPoll":
                    // v1.5.2 D5b: retry.poll resumes and sleeps until its tagged deadline (generation.ts:309–323).
                    #expect(try await storage.task(id, context: .background)?.state.status == "sleeping")
                default:
                    let saved = try #require(resumed.tasks.first { $0.record.id == id })
                    guard case .blocked(let reason, _) = saved.state else { Issue.record("Fixture phase \(name) resumed"); continue }
                    #expect(reason == (name == "newerGenerationVersion" ? .taskTooOld : .migrationFailed))
                }
            }
            #expect(try await storage.task(newerID, context: .background) == recordsBefore[newerID])
        } catch { try? await harness.close(context: .background); throw error }
        try await harness.close(context: .background)
        let reopened: any DurableStorage
        if backend == "sqlite" { reopened = try await SqliteStorage.open(path: copied.path.path) }
        else { reopened = try await JsonlStorage.open(directory: copied.path.path, fileSystem: LocalExecutionEnv(cwd: copied.path.path)) }
        #expect(try await reopened.task(newerID, context: .background)?.version == 99)
        try await reopened.close(context: .background)
    }
}
