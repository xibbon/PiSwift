import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

@Suite struct HarnessCompactionEventTests {
    // Upstream harness-compaction.test.ts:1100.
    @Test func abortedOwnedCompactionEndsBeforeRun() async throws {
        let chat = try await compactionOpen(contextWindow: 1000); try await compactionHistory(chat); compactionSetPolicy(chat, compactionBlockingPolicy)
        let held = HarnessGatedResponse(message: chatAssistant("SUMMARY")); chat.script.appendSummary([held.step])
        let (stream, log) = try await eventListen(chat.opened), input = try await compactionNewInput(chat)
        await held.reached.wait(); try await log.waitForType("compaction_start"); try await chat.root.abort(context: .background)
        _ = try await input.wait(context: .background); try await log.waitForType("run_end")
        #expect(try #require(log.types.firstIndex(of: "compaction_end")) < #require(log.types.firstIndex(of: "run_end")))
        _ = await stream.stop(); try await chat.harness.close(context: .background)
    }
    // Upstream :1492.
    @Test func retryBackoffSnapshotAndCompactionStartEnd() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        chat.setup.updateSettings { $0.retry = .init(enabled: true, maxRetries: 2, baseDelayMs: 60_000) }
        let (stream, log) = try await eventListen(chat.opened); chat.script.appendSummary([.message(compactionFailure("overloaded"))])
        let id = try await chat.root.compact(context: .background)
        try await eventually { try await compactionLive(chat).compactions?.first?.retry != nil }
        let late = try await chat.harness.watchEvents(conversationId: chat.root.id, context: .background)
        #expect(late.snapshot.compactions == [.init(taskId: id, reason: .manual, blocking: false, attempt: 1, retry: .init(at: 61000, error: "overloaded"))])
        _ = await late.stop(); _ = try await chat.harness.abortTask(id: id, context: .background); _ = try await compactionOutcome(chat, id); try await log.waitForType("compaction_end")
        #expect(log.events.filter { ($0["type"]?.stringValue ?? "").hasPrefix("compaction_") } == [["type": "compaction_start", "taskId": .number(Double(id.rawValue)), "reason": "manual", "blocking": false], ["type": "compaction_end", "taskId": .number(Double(id.rawValue)), "reason": "manual"]])
        _ = await stream.stop(); try await chat.harness.close(context: .background)
    }
    // Upstream :1931.
    @Test func immediatelyPlacedSummaryHasExactEventOrder() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        let (stream, log) = try await eventListen(chat.opened); chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        let id = try await chat.root.compact(context: .background), outcome = try await compactionOutcome(chat, id)
        _ = try await compactionSubmission(chat, outcome).wait(context: .background); try await log.waitForType("compaction_end")
        let end = try #require(log.types.firstIndex(of: "compaction_end"))
        #expect(Array(log.types[(end - 2)...].prefix(5)) == ["message_start", "message_end", "compaction_end", "submission", "usage_changed"])
        _ = await stream.stop(); try await chat.harness.close(context: .background)
    }
    // Upstream :1949.
    @Test func preparationBatchPutsCompactionStartLast() async throws {
        let chat = try await compactionOpen(contextWindow: 2000); try await compactionHistory(chat); compactionSetPolicy(chat, compactionBackgroundPolicy)
        let (stream, log) = try await eventListen(chat.opened), held = HarnessUnanswered(); chat.script.appendSummary([held.step])
        try chat.setup.registry.install(Extension(name: "event-extra", sections: [section("extra") { _, _ in "extra" }]))
        try await compactionTurn(chat, compactionText("u4", 100), "a4"); await held.reached.wait(); try await log.waitForType("compaction_start")
        let batch = try #require(log.batches.first { $0.contains { $0["type"] == "compaction_start" } })
        #expect(batch.compactMap { $0["type"]?.stringValue } == ["message_start", "message_end", "compaction_start"])
        let id = try #require(await compactionTasks(chat).first).id; _ = try await chat.harness.abortTask(id: id, context: .background); _ = try await compactionOutcome(chat, id)
        _ = await stream.stop(); try await chat.harness.close(context: .background)
    }
    // Upstream :2174 and example 21-late-join.
    @Test func lateJoinerSeesCompactionInProgress() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        let held = HarnessUnanswered(); chat.script.appendSummary([held.step]); let id = try await chat.root.compact(context: .background); await held.reached.wait()
        let stream = try await chat.harness.watchEvents(conversationId: chat.root.id, context: .background)
        #expect(stream.snapshot.compactions == [.init(taskId: id, reason: .manual, blocking: false, attempt: 1)])
        _ = await stream.stop(); _ = try await chat.harness.abortTask(id: id, context: .background); _ = try await compactionOutcome(chat, id)
        try await chat.harness.close(context: .background)
    }
    // Upstream :2238.
    @Test func blockedCompactionReopensThenOrphanAbortEmitsEnd() async throws {
        let directory = try sqliteTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }; let path = directory.appendingPathComponent("events-compaction.sqlite").path
        let chat = try await compactionOpen(storage: SqliteStorage.open(path: path), resume: false)
        let newer = TaskKind<GenerationCompactionInput, JSONObject>(name: "pi.compaction", version: 2, initial: { _ in ["phase": "select"] })
        let id = try await chat.root.commit({ tx in
            let id = try await tx.createTask(newer, input: .init(reason: .manual), options: .init(ownership: .conversation()))
            let live = try await tx.doc(LiveDoc, conversationId: chat.root.id); try live.set("compactions", JSONValue(encoding: [CompactionStatus(taskId: id, reason: .manual, blocking: false, attempt: 1)])); return id
        }, context: .background)
        try await chat.harness.close(context: .background)
        let reopened = try await openChat(storage: SqliteStorage.open(path: path), setup: chat.setup), (stream, log) = try await eventListen(reopened)
        #expect(stream.snapshot.compactions.map(\.taskId) == [id]); _ = try await reopened.harness.abortTask(id: id, context: .background)
        #expect(try await reopened.harness.waitForTask(id: id, context: .background).outcome.status == "orphaned"); try await log.waitForType("compaction_end")
        #expect(log.events.contains { $0["type"] == "compaction_end" && $0["taskId"] == .number(Double(id.rawValue)) })
        #expect(log.types.contains("task_failed")); _ = await stream.stop(); try await reopened.harness.close(context: .background)
    }
}
