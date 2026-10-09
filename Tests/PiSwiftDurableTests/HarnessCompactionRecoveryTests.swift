import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private func compactionRecoveryPath() throws -> URL {
    try sqliteTestDirectory().appendingPathComponent("compaction.sqlite")
}
private func compactionReopen(_ chat: CompactionChat, path: URL) async throws -> CompactionChat {
    let opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: chat.setup)
    try opened.harness.resume()
    return CompactionChat(harness: opened.harness, root: opened.root, setup: chat.setup, script: chat.script)
}
private func compactionStoredCheckpoint(_ chat: CompactionChat, _ id: TaskID) async throws -> JSONValue {
    let record = try #require(await chat.harness.getTask(id: id, context: .background))
    switch record.state {
    case .pending(let value, _), .running(let value, _), .waiting(let value, _, _, _): return value
    default: throw TaskDefinitionError("Expected stored compaction checkpoint")
    }
}
@Suite struct HarnessCompactionRecoveryTests {
    // Upstream harness-compaction.test.ts:1563.
    @Test func placedSummaryIsNotRepeatedAfterReopen() async throws {
        let path = try compactionRecoveryPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        var chat = try await compactionOpen(storage: SqliteStorage.open(path: path.path))
        try await compactionHistory(chat)
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        _ = try await compactionOutcome(chat, chat.root.compact(context: .background))
        let entries = try await allEntries(chat.root)
        let usage = try JSONValue(encoding: await chat.harness.snapshot(UsageDoc, conversationId: chat.root.id, context: .background))
        try await chat.harness.close(context: .background)
        chat = try await compactionReopen(chat, path: path)
        try await chat.harness.waitForIdle(context: .background)
        #expect(chat.script.summaryRequests.count == 1)
        #expect(try await allEntries(chat.root) == entries)
        let reopenedUsage = try JSONValue(encoding: await chat.harness.snapshot(UsageDoc, conversationId: chat.root.id, context: .background))
        #expect(reopenedUsage == usage)
        let inspection = try await chat.harness.inspect(context: .background)
        #expect(inspection.tasks.isEmpty && inspection.submissions.isEmpty)
        try await chat.harness.close(context: .background)
    }
    // Upstream :1581.
    @Test func failedCompactionAfterReopenRetainsOverflowText() async throws {
        let path = try compactionRecoveryPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        var chat = try await compactionOpen(storage: SqliteStorage.open(path: path.path))
        try await compactionHistory(chat)
        chat.setup.updateSettings { $0.compaction = .init(enabled: true, reserveTokens: 1000, keepRecentTokens: 150, backgroundTokens: 0) }
        let held = HarnessUnanswered(), overflow = "prompt is too long: 250000 tokens > 200000 maximum"
        chat.script.appendSummary([held.step]); chat.script.appendAgent([.message(compactionFailure(overflow))])
        let input = try await chat.root.submit(.input(content: .text(compactionText("u4", 100))), context: .background)
        await held.reached.wait()
        let run = try #require(await compactionLive(chat).run?.taskId)
        #expect(try await compactionStoredCheckpoint(chat, run)["overflow"] == .string(overflow))
        try await chat.harness.close(context: .background)
        chat.script.appendSummary([.message(compactionFailure("bad request"))])
        chat = try await compactionReopen(chat, path: path)
        let receipt = try await #require(chat.harness.submission(id: input.id, context: .background)).wait(context: .background)
        let record = try JSONValue(encoding: receipt.record)
        #expect(receipt.status == "unanswered" && receipt.reason == "model_error" && record["detail"] == .string(overflow))
        try await chat.harness.close(context: .background)
    }
    // Upstream :1603.
    @Test func interruptedSelectionRunsHookAgainAfterReopen() async throws {
        let path = try compactionRecoveryPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        var chat = try await compactionOpen(storage: SqliteStorage.open(path: path.path))
        try await compactionHistory(chat)
        let calls = Mutex(0), reached = HarnessChatSignal()
        try chat.setup.registry.install(Extension(name: "recovery-hook", hooks: [hook(CompactionHooks(beforeCompact: { _, _, context in
            let count = calls.withLock { $0 += 1; return $0 }
            if count == 1 {
                reached.signal()
                let cancelled = HarnessChatSignal(), signal = try #require(context.abortSignal)
                let registration = signal.addAbortListener { _ in cancelled.signal() }
                defer { signal.removeAbortListener(registration) }
                if signal.aborted { cancelled.signal() }
                await cancelled.wait(); try signal.throwIfAborted()
            }
            return nil
        }))]))
        let id = try await chat.root.compact(context: .background)
        await reached.wait()
        try await chat.harness.close(context: .background)
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        chat = try await compactionReopen(chat, path: path)
        #expect(try await compactionOutcome(chat, id).status == "completed")
        #expect(calls.withLock { $0 } == 2)
        try await chat.harness.close(context: .background)
    }
    // Upstream :1628.
    @Test func interruptedSummaryIsResentAndOnlyAnsweredAttemptIsCounted() async throws {
        let path = try compactionRecoveryPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        var chat = try await compactionOpen(storage: SqliteStorage.open(path: path.path))
        try await compactionHistory(chat)
        let held = HarnessUnanswered(); chat.script.appendSummary([held.step])
        let id = try await chat.root.compact(context: .background)
        await held.reached.wait()
        let before = try #require(await chat.harness.usage(context: .background).models["faux/faux-1"])
        #expect(try await compactionStoredCheckpoint(chat, id)["phase"] == .string("summarize"))
        try await chat.harness.close(context: .background)
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        chat = try await compactionReopen(chat, path: path)
        #expect(try await compactionOutcome(chat, id).status == "completed")
        let requests = chat.script.summaryRequests
        #expect(requests.count == 2)
        #expect(requests[0].messages.map(textOf) == requests[1].messages.map(textOf))
        #expect(requests[0].model == requests[1].model)
        let after = try #require(await chat.harness.usage(context: .background).models["faux/faux-1"])
        #expect(after.input > before.input && after.output - before.output == 2)
        try await chat.harness.close(context: .background)
    }
    // Upstream :1652.
    @Test func durableRetryDeadlineSurvivesReopen() async throws {
        let path = try compactionRecoveryPath(), clock = TestClock(now: 1000)
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        var chat = try await compactionOpen(storage: SqliteStorage.open(path: path.path), clock: clock)
        try await compactionHistory(chat)
        chat.setup.updateSettings { $0.retry = .init(enabled: true, maxRetries: 2, baseDelayMs: 60_000) }
        chat.script.appendSummary([.message(compactionFailure("overloaded"))])
        let id = try await chat.root.compact(context: .background), first = chat
        try await eventually { try await compactionLive(first).compactions?.first?.retry != nil }
        let checkpoint = try await compactionStoredCheckpoint(chat, id)
        #expect(checkpoint["phase"] == .string("retry") && checkpoint["attempt"] == .number(1))
        try await chat.harness.close(context: .background)
        clock.advance(by: 120_000)
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        chat = try await compactionReopen(chat, path: path)
        #expect(try await compactionOutcome(chat, id).status == "completed")
        #expect(chat.script.summaryRequests.count == 2)
        try await chat.harness.close(context: .background)
    }
    // Upstream :1673.
    @Test func generationWaitsOnBlockingCompactionAcrossReopen() async throws {
        let path = try compactionRecoveryPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        var chat = try await compactionOpen(contextWindow: 2000, storage: SqliteStorage.open(path: path.path))
        try await compactionHistory(chat)
        chat.setup.updateSettings { $0.compaction = .init(enabled: true, reserveTokens: 1300, keepRecentTokens: 150, backgroundTokens: 0) }
        let held = HarnessUnanswered(); chat.script.appendSummary([held.step])
        let input = try await chat.root.submit(.input(content: .text(compactionText("u4", 200))), context: .background)
        await held.reached.wait()
        try await chat.harness.close(context: .background)
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))]); chat.script.appendAgent([.message(chatAssistant("a4"))])
        chat = try await compactionReopen(chat, path: path)
        let reacquired = try #require(await chat.harness.submission(id: input.id, context: .background))
        #expect(try await reacquired.wait(context: .background).status == "done")
        #expect(try await Array(compactionKinds(chat.root).suffix(3)) == ["pi.compaction", "pi.system", "pi.assistant"])
        try await chat.harness.close(context: .background)
    }
    // Upstream :1692.
    @Test func queuedSummarySurvivesReopenAndLandsAtBoundary() async throws {
        let path = try compactionRecoveryPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        var chat = try await compactionOpen(storage: SqliteStorage.open(path: path.path))
        try await compactionHistory(chat)
        let held = HarnessUnanswered(); chat.script.appendAgent([held.step])
        let input = try await chat.root.submit(.input(content: .text("busy")), context: .background)
        await held.reached.wait()
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        let outcome = try await compactionOutcome(chat, chat.root.compact(context: .background))
        let summary = try await compactionSubmission(chat, outcome)
        #expect(try await summary.status(context: .background).status == "queued")
        try await chat.harness.close(context: .background)
        chat.script.appendAgent([.message(chatAssistant("answered"))])
        chat = try await compactionReopen(chat, path: path)
        let reacquired = try #require(await chat.harness.submission(id: input.id, context: .background))
        #expect(try await reacquired.wait(context: .background).status == "done")
        let placed = try #require(await chat.harness.submission(id: summary.id, context: .background))
        #expect(try await placed.wait(context: .background).status == "done")
        try await chat.harness.close(context: .background)
    }
    // Upstream :2238; H9 event assertion uses the underlying status document.
    @Test func newerBlockedCompactionSurvivesReopenAndAbortRemovesStatus() async throws {
        let path = try compactionRecoveryPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        var chat = try await compactionOpen(storage: SqliteStorage.open(path: path.path), resume: false)
        let newer = TaskKind<GenerationCompactionInput, JSONObject>(name: "pi.compaction", version: 2, initial: { _ in ["phase": .string("select")] })
        let rootId = chat.root.id
        let id = try await chat.root.commit({ tx in
            let id = try await tx.createTask(newer, input: .init(reason: .manual), options: .init(ownership: .conversation()))
            let live = try await tx.doc(LiveDoc, conversationId: rootId)
            try live.set("compactions", JSONValue(encoding: [CompactionStatus(taskId: id, reason: .manual, blocking: false, attempt: 1)]))
            return id
        }, context: .background)
        try await chat.harness.close(context: .background)
        chat = try await compactionReopen(chat, path: path)
        let inspection = try await chat.harness.inspect(context: .background)
        if case .blocked(let reason, _) = inspection.tasks.first(where: { $0.record.id == id })?.state { #expect(reason == .taskTooOld) }
        else { Issue.record("Expected blocked newer compaction") }
        _ = try await chat.harness.abortTask(id: id, context: .background)
        #expect(try await chat.harness.waitForTask(id: id, context: .background).outcome.status == "orphaned")
        #expect(try await compactionLive(chat).compactions == nil)
        try await chat.harness.close(context: .background)
    }
}
