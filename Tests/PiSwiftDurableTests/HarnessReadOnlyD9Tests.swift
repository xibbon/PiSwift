import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private func d9Open(_ storage: any DurableStorage, setup: HarnessChatSetup = HarnessChatSetup(),
                    readOnly: Bool = true, wakes: SessionTestLog<HarnessWake>? = nil) async throws -> Harness {
    try await Harness.open(storage: storage, options: HarnessOptions(models: setup.models,
        registry: setup.registry, readOnly: readOnly,
        onWake: { wakes?.append($0) }, onReport: { setup.reports.appendReport($0) }), context: .background)
}
private func d9Bytes(_ directory: URL) throws -> [String: Data] {
    var result: [String: Data] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
        result[name] = try Data(contentsOf: directory.appendingPathComponent(name))
    }
    return result
}
private func d9Head(_ path: String) throws -> SqliteValue? {
    let db = try AppleSqliteDatabase(path: path)
    defer { try? db.close() }
    return try db.get("SELECT next_seq FROM durable_metadata WHERE singleton = 1")?["next_seq"]
}

@Suite struct HarnessReadOnlyD9Tests {
    // v1.5.2 harness/scheduler.ts:470 and storage/jsonl/storage.ts:298–334.
    @Test func v140JsonlFixtureRemainsByteIdentical() async throws {
        let source = try #require(Bundle.module.url(forResource: "tool-task-upstream-jsonl-v140",
            withExtension: nil, subdirectory: "Fixtures"))
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let copied = directory.appendingPathComponent("v140")
        try FileManager.default.copyItem(at: source, to: copied)
        let before = try d9Bytes(copied)
        let storage = try await JsonlStorage.open(directory: copied.path, options: .init(readOnly: true))
        let viewer = try await d9Open(storage)
        #expect(try await viewer.root(context: .background).id == rootConversationID)
        try await viewer.close(context: .background)
        #expect(try d9Bytes(copied) == before)
    }

    // v1.5.2 harness-read-only.test.ts:73–94: the other Harness remains active.
    @Test(.timeLimit(.minutes(1))) func opensBesideAnActiveSqliteDriverWithoutWrites() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("active.sqlite").path
        let setup = HarnessChatSetup(), busy = HarnessUnanswered()
        setup.models.setResponses([busy.step])
        let driver = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        _ = try await driver.root.submit(.input(content: .text("slow")), context: .background)
        await busy.reached.wait()
        let before = try d9Head(path), wakes = SessionTestLog<HarnessWake>()
        let viewer = try await d9Open(SqliteStorage.open(path: path), wakes: wakes)
        let root = try await viewer.root(context: .background)
        #expect(try await allEntries(root).map(\.kind) == [userEntry.kind])
        let run = try #require(try await viewer.snapshot(LiveDoc, conversationId: root.id, context: .background)?.run)
        #expect(try await viewer.getTask(id: run.taskId, context: .background)?.state.status == "running")
        #expect(try await viewer.getTask(id: run.taskId, context: .background)?.restarts == 0)
        #expect(viewer.wake() == HarnessWake(active: false))
        try await viewer.close(context: .background)
        #expect(try d9Head(path) == before)
        #expect(wakes.values.isEmpty)
        try await driver.harness.close(context: .background)
    }

    // v1.5.2 harness-read-only.test.ts:97–124: active JSONL writer and torn append.
    @Test(.timeLimit(.minutes(1))) func opensBesideAnActiveJsonlDriverAndTornAppendWithoutWrites() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = HarnessChatSetup(), busy = HarnessUnanswered()
        setup.models.setResponses([busy.step])
        let driver = try await openChat(storage: JsonlStorage.open(directory: directory.path), setup: setup)
        _ = try await driver.root.submit(.input(content: .text("slow")), context: .background)
        await busy.reached.wait()
        let file = try FileHandle(forWritingTo: directory.appendingPathComponent("main.jsonl"))
        _ = try file.seekToEnd()
        try file.write(contentsOf: Data("{\"format\":1".utf8))
        try file.close()
        let before = try d9Bytes(directory)
        let viewer = try await d9Open(JsonlStorage.open(directory: directory.path, options: .init(readOnly: true)))
        let root = try await viewer.root(context: .background)
        #expect(try await allEntries(root).map(\.kind) == [userEntry.kind])
        let run = try #require(try await viewer.snapshot(LiveDoc, conversationId: root.id, context: .background)?.run)
        #expect(try await viewer.getTask(id: run.taskId, context: .background)?.state.status == "running")
        try await viewer.close(context: .background)
        #expect(try d9Bytes(directory) == before)
        try await driver.harness.close(context: .background)
    }

    // v1.5.2 harness-read-only.test.ts:167–184; scheduler.ts:452:487.
    @Test func sqliteViewerLeavesRunningRecordAndRecoveryForWriter() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("viewer.sqlite").path
        let driver = try await openChat(storage: SqliteStorage.open(path: path), setup: HarnessChatSetup())
        _ = try await driver.root.commit({ tx in try await tx.appendEntry(driver.root.id, value: EntryDraft(kind: "app.note")) }, context: .background)
        try await driver.harness.close(context: .background)
        let storage = try await SqliteStorage.open(path: path)
        let id = try TaskID(500)
        let record = TaskRecord(id: id, conversationId: rootConversationID, kind: "d9.running", version: 1,
            input: .number(0), state: .running(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint())), restarts: 3)
        _ = try await storage.commit([.task(value: record)], context: .background)
        let before = try d9Head(path)
        let wakes = SessionTestLog<HarnessWake>()
        let viewer = try await d9Open(SqliteStorage.open(path: path), wakes: wakes)
        let root = try await viewer.root(context: .background)
        #expect(try await allEntries(root).map(\.kind) == ["app.note"])
        #expect(try await viewer.getTask(id: id, context: .background) == record)
        #expect(try await viewer.inspect(context: .background).scheduling == .paused)
        #expect(viewer.wake() == HarnessWake(active: false))
        let watch = try await root.watch(context: .background)
        _ = await watch.stop()
        let doc = try #require(try await viewer.watchDoc(LiveDoc, conversationId: root.id, context: .background))
        _ = await doc.stop()
        // Read-only records bypass the Session cache (session.ts:306,320).
        let changed = record.replacing(state: .pending(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint())))
        _ = try await storage.commit([.task(value: changed)], context: .background)
        #expect(try await viewer.getTask(id: id, context: .background) == changed)
        _ = try await storage.commit([.task(value: record)], context: .background)
        let afterExternal = try d9Head(path)
        try await viewer.close(context: .background)
        #expect(try d9Head(path) == afterExternal)
        #expect(before != afterExternal)
        #expect(wakes.values.isEmpty)
        let writer = try await d9Open(SqliteStorage.open(path: path), readOnly: false)
        let recovered = try #require(try await writer.getTask(id: id, context: .background))
        #expect(recovered.state.status == "pending")
        #expect(recovered.restarts == 4)
        try await writer.close(context: .background)
        try await storage.close(context: .background)
    }

    // v1.5.2 harness-read-only.test.ts:126–155, including continue and atomic submit.
    @Test func refusesWritesAndSchedulingAndStaysHealthy() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("refuse.sqlite").path
        let driverSetup = HarnessChatSetup()
        driverSetup.models.setResponses([.message(chatAssistant("one"))])
        let driver = try await openChat(storage: SqliteStorage.open(path: path), setup: driverSetup)
        let submission = try await driver.root.submit(.input(content: .text("hi")), context: .background)
        _ = try await submission.wait(context: .background)
        try await driver.harness.close(context: .background)
        let before = try d9Head(path), setup = HarnessChatSetup()
        let viewer = try await d9Open(SqliteStorage.open(path: path), setup: setup)
        let root = try await viewer.root(context: .background)
        await #expect(throws: ReadOnlySession.self) { _ = try await root.commit({ tx in try await tx.appendEntry(root.id, value: EntryDraft(kind: "refused")) }, context: .background) }
        for draft in [SubmissionDraft.input(content: .text("again")), .continue(), .write(entry: EntryDraft(kind: "refused"))] {
            await #expect(throws: ReadOnlySession("running tasks")) { _ = try await root.submit(draft, context: .background) }
            await #expect(throws: ReadOnlySession("running tasks")) { _ = try await root.commit({ tx in try await root.submit(tx, draft) }, context: .background) }
        }
        #expect(throws: ReadOnlySession("running tasks")) { try viewer.resume() }
        await #expect(throws: ReadOnlySession.self) { try await viewer.waitForIdle(context: .background) }
        await #expect(throws: ReadOnlySession.self) { _ = try await viewer.waitForTask(id: TaskID(999), context: .background) }
        await #expect(throws: ReadOnlySession.self) { try await root.abort(context: .background) }
        await #expect(throws: ReadOnlySession.self) { _ = try await viewer.createConversation(options: .init(ownership: .ownerless()), context: .background) }
        #expect(try await root.commit({ _ in "nothing" }, context: .background) == "nothing")
        #expect(try await allEntries(root).count == 2)
        #expect(viewer.failure == nil)
        #expect(setup.reports.values.isEmpty)
        try await viewer.close(context: .background)
        #expect(try d9Head(path) == before)
    }

    // v1.5.2 harness-read-only.test.ts:157–165.
    @Test func refusesToCreateMissingRoot() async throws {
        let viewer = try await d9Open(MemoryStorage())
        await #expect(throws: ReadOnlySession.self) { _ = try await viewer.root(context: .background) }
        #expect(try await viewer.commit({ _ in 7 }, context: .background) == 7)
        #expect(viewer.failure == nil)
        try await viewer.close(context: .background)
    }

    // v1.5.2 scheduler.ts:470 and storage/jsonl/storage.ts:334 are independent checks.
    @Test(arguments: [false, true], [false, true])
    func jsonlStorageAndHarnessFlagsAreIndependent(harnessReadOnly: Bool, storageReadOnly: Bool) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try await JsonlStorage.open(directory: directory.path)
        let record = TaskRecord(id: try TaskID(20), conversationId: rootConversationID, kind: "d9.running",
            version: 1, input: .number(0), state: .running(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint())))
        _ = try await storage.commit([.conversation(value: ConversationRecord(id: rootConversationID)), .task(value: record)], context: .background)
        try await storage.close(context: .background)
        let before = try d9Bytes(directory)
        let reopened = try await JsonlStorage.open(directory: directory.path, options: .init(readOnly: storageReadOnly))
        if storageReadOnly && !harnessReadOnly {
            // A writable Harness attempts recovery; the storage refuses its commit.
            do {
                _ = try await d9Open(reopened, readOnly: false)
                Issue.record("Writable recovery on read-only JSONL succeeded")
            } catch {
                let cause = (error as? SessionFailed)?.cause ?? error
                #expect(cause is JsonlStorageReadOnlyError)
            }
            #expect(try d9Bytes(directory) == before)
            return
        }
        let harness = try await d9Open(reopened, readOnly: harnessReadOnly)
        let current = try #require(try await harness.getTask(id: record.id, context: .background))
        #expect(current.state.status == (harnessReadOnly ? "running" : "pending"))
        #expect(current.restarts == (harnessReadOnly ? 0 : 1))
        if harnessReadOnly {
            #expect(throws: ReadOnlySession.self) { try harness.resume() }
            #expect(try await harness.commit({ _ in 1 }, context: .background) == 1)
        }
        try await harness.close(context: .background)
        #expect((try d9Bytes(directory) == before) == harnessReadOnly)
    }

    // v1.5.2 scheduler.ts:470,495,1029,1780: no handler, migration or host wake.
    @Test func noMigrationOrHandlerRunsAfterRegistryChange() async throws {
        let storage = MemoryStorage(), setup = HarnessChatSetup()
        let calls = SessionTestLog<String>(), wakes = SessionTestLog<HarnessWake>()
        let definition = HarnessTestTask(name: "d9.migrate", version: 2, initial: { _ in HarnessTaskCheckpoint() },
            phase: { _, _, _ in calls.append("run") }, abort: { _, _, _ in calls.append("abort") },
            migrate: { _, _, _ in calls.append("migrate"); return (0, HarnessTaskCheckpoint()) })
        try setup.registry.install(Extension(name: "d9", tasks: [AnyTaskDefinition(definition)]))
        let record = TaskRecord(id: try TaskID(20), conversationId: rootConversationID, kind: definition.name,
            version: 1, input: .number(0), state: .pending(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint())), abandonOnRestart: true)
        _ = try await storage.commit([.conversation(value: ConversationRecord(id: rootConversationID)), .task(value: record)], context: .background)
        let viewer = try await d9Open(storage, setup: setup, wakes: wakes)
        try setup.registry.install(Extension(name: "d9", tasks: [AnyTaskDefinition(definition)]))
        _ = try await viewer.inspect(context: .background)
        #expect(throws: ReadOnlySession.self) { try viewer.resume() }
        #expect(try await viewer.getTask(id: record.id, context: .background) == record)
        #expect(calls.values.isEmpty)
        #expect(wakes.values.isEmpty)
        #expect(setup.reports.values.isEmpty)
        try await viewer.close(context: .background)
    }
}
