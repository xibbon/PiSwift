import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private func d2SleepRecord(_ harness: Harness, _ id: TaskID) async throws -> TaskRecord {
    try #require(await harness.getTask(id: id, context: .background))
}

private func d2SleepingCheckpoint(_ record: TaskRecord, until expected: Double) throws -> JSONValue {
    guard case .sleeping(let checkpoint, let until, _) = record.state else {
        throw TaskDefinitionError("Expected a stored sleeping task")
    }
    #expect(until == expected)
    return checkpoint
}

// v1.3 stored the same retry or poll checkpoint in a running task.
private func d2StoreLegacyRunning(_ path: URL, _ id: TaskID) async throws {
    let storage = try await SqliteStorage.open(path: path.path)
    let record = try #require(await storage.task(id, context: .background))
    guard case .sleeping(let checkpoint, _, _) = record.state else {
        throw TaskDefinitionError("Expected sleep before legacy conversion")
    }
    _ = try await storage.commit([.task(value: record.replacing(state: .running(checkpoint: checkpoint)))], context: .background)
    try await storage.close(context: .background)
}

@Suite struct D2BuiltInSleepRecoveryTests {
    // Upstream v1.4.0 harness-generation-recovery.test.ts:212.
    @Test func legacyRunningGenerationRetrySleepsAgainBeforeDeadline() async throws {
        let directory = try sqliteTestDirectory(), path = directory.appendingPathComponent("generation.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(now: 1000), setup = HarnessChatSetup(clock: clock)
        setup.updateSettings { $0.retry = .init(enabled: true, maxRetries: 2, baseDelayMs: 60_000) }
        setup.models.setResponses([
            .message(chatAssistant("", reason: .error, error: "503 Service Unavailable")),
            .message(chatAssistant("recovered"))
        ])
        var opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        let input = try await generationSubmit(opened)
        let first = opened
        try await eventually { try await generationLive(first)?.generation?.retry != nil }
        let id = try #require(await generationLive(opened)?.run?.taskId)
        let original = try d2SleepingCheckpoint(await d2SleepRecord(opened.harness, id), until: 61_000)
        #expect(original["until"] == .number(61_000) && original["attempt"] == .number(1))
        try await opened.harness.close(context: .background)
        try await d2StoreLegacyRunning(path, id)

        opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        try opened.harness.resume()
        let resumed = opened.harness
        try await eventually { try await resumed.getTask(id: id, context: .background)?.state.status == "sleeping" }
        #expect(try d2SleepingCheckpoint(await d2SleepRecord(resumed, id), until: 61_000) == original)
        #expect(setup.models.calls().streamSimple == 1)
        #expect(try await generationLive(opened)?.generation?.attempt == 1)
        clock.advance(by: 60_000)
        let submission = try #require(await opened.harness.submission(id: input.id, context: .background))
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(setup.models.calls().streamSimple == 2)
        #expect(try await allEntries(opened.root).map(\.kind) == ["pi.user", "pi.assistant", "pi.assistant"])
        try await opened.harness.close(context: .background)
    }

    // Upstream v1.4.0 generation.ts:252 and harness-generation-recovery.test.ts:322.
    @Test(arguments: [false, true])
    func missingPollModelIsCheckedOnlyAtDeadline(legacyRunning: Bool) async throws {
        let directory = try sqliteTestDirectory(), path = directory.appendingPathComponent("poll.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(now: 1000)
        let setup = HarnessChatSetup(options: .init(deferred: .init(pollAfterMs: 60_000)), clock: clock)
        setup.updateSettings { $0.stream = .init(deferred: .init()) }
        setup.models.setResponses([.message(chatAssistant("deferred answer"))])
        var opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        let input = try await generationSubmit(opened), first = opened
        try await eventually { try await generationLive(first)?.generation?.deferred != nil }
        let id = try #require(await generationLive(opened)?.run?.taskId)
        let checkpoint = try d2SleepingCheckpoint(await d2SleepRecord(opened.harness, id), until: 61_000)
        #expect(checkpoint["phase"] == .string("poll") && checkpoint["pollAt"] == .number(61_000))
        try await opened.harness.close(context: .background)
        if legacyRunning { try await d2StoreLegacyRunning(path, id) }

        let empty = FakeDurableModels(options: .init(provider: "empty"))
        opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup, models: empty)
        try opened.harness.resume()
        let resumed = opened.harness
        try await eventually { try await resumed.getTask(id: id, context: .background)?.state.status == "sleeping" }
        #expect(try d2SleepingCheckpoint(await d2SleepRecord(resumed, id), until: 61_000) == checkpoint)
        #expect(empty.calls().getModel == 0 && empty.calls().fetchDeferred == 0)
        let submission = try #require(await opened.harness.submission(id: input.id, context: .background))
        #expect(try await submission.status(context: .background).status == "placed")
        clock.advance(by: 60_000)
        let result = try await submission.wait(context: .background)
        #expect(result.status == "unanswered" && result.reason == "no_model")
        #expect(empty.calls().getModel == 1 && empty.calls().fetchDeferred == 0)
        try await opened.harness.close(context: .background)
    }

    // Upstream v1.4.0 harness-compaction.test.ts:1739.
    @Test(arguments: [false, true])
    func compactionRetrySleepsAcrossEarlyAndDueReopen(legacyRunning: Bool) async throws {
        let directory = try sqliteTestDirectory(), path = directory.appendingPathComponent("compaction.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(now: 1000)
        var chat = try await compactionOpen(storage: SqliteStorage.open(path: path.path), clock: clock)
        try await compactionHistory(chat)
        chat.setup.updateSettings { $0.retry = .init(enabled: true, maxRetries: 2, baseDelayMs: 60_000) }
        chat.script.appendSummary([.message(compactionFailure("overloaded"))])
        let id = try await chat.root.compact(context: .background), first = chat
        try await eventually { try await first.harness.getTask(id: id, context: .background)?.state.status == "sleeping" }
        let checkpoint = try d2SleepingCheckpoint(await d2SleepRecord(chat.harness, id), until: 61_000)
        #expect(checkpoint["phase"] == .string("retry") && checkpoint["attempt"] == .number(1))
        #expect(checkpoint["until"] == .number(61_000))
        try await chat.harness.close(context: .background)
        if legacyRunning { try await d2StoreLegacyRunning(path, id) }

        var opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: chat.setup)
        try opened.harness.resume()
        chat = CompactionChat(harness: opened.harness, root: opened.root, setup: chat.setup, script: chat.script)
        let resumed = chat.harness
        try await eventually { try await resumed.getTask(id: id, context: .background)?.state.status == "sleeping" }
        #expect(try d2SleepingCheckpoint(await d2SleepRecord(resumed, id), until: 61_000) == checkpoint)
        #expect(chat.script.summaryRequests.count == 1)
        #expect(try await compactionLive(chat).compactions?.first?.attempt == 1)
        try await chat.harness.close(context: .background)

        clock.advance(by: 120_000)
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: chat.setup)
        try opened.harness.resume()
        chat = CompactionChat(harness: opened.harness, root: opened.root, setup: chat.setup, script: chat.script)
        #expect(try await compactionOutcome(chat, id).status == "completed")
        #expect(chat.script.summaryRequests.count == 2)
        #expect(try await compactionLive(chat).compactions == nil)
        try await chat.harness.close(context: .background)
    }
}
