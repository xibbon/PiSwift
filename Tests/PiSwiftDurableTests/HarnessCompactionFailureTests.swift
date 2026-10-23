import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private struct CompactionHookFailure: Error, CustomStringConvertible {
    var description: String { "no credentials" }
}

@Suite struct HarnessCompactionFailureTests {
    // Upstream harness-compaction.test.ts:264. Empty contributions are not cuts.
    @Test func displayOnlyEntryIsNotACompactionCut() throws {
        let contributions: [[Message]] = [
            [.user(UserMessage(content: .text(compactionText("u1", 100)), timestamp: 0))],
            [.assistant(chatAssistant(compactionText("a1", 100)))],
            [],
            [.assistant(chatAssistant(compactionText("a2", 100)))],
        ]
        let kinds = ["pi.user", "pi.assistant", "chat.message", "pi.assistant"]
        let entries = try contributions.enumerated().map { index, messages in
            EntryRecord(id: try EntryID(Int64(index + 2)), conversationId: rootConversationID,
                        kind: kinds[index], model: try EntryRecord.encodeMessages(messages))
        }
        let view = ContextView(entries: entries, contributions: contributions,
                               messages: orderToolResults(contributions.flatMap { $0 }))
        #expect(generationSelectCut(view: view, keepRecentTokens: 150) == 1)
        #expect(generationSelectCut(view: view, keepRecentTokens: 50) == 3)
    }

    // Upstream harness-compaction.test.ts:1008–1042; intake D19.
    @Test func failureRemainsInLiveSnapshotAndEndEventUntilSummary() async throws {
        let chat = try await compactionOpen(contextWindow: 2000)
        try await compactionHistory(chat)
        compactionSetPolicy(chat, compactionBackgroundPolicy)
        let (stream, log) = try await eventListen(chat.opened)
        chat.script.appendSummary([.message(compactionFailure("bad request"))])
        try await compactionTurn(chat, compactionText("u4", 100), compactionText("a4", 100))
        try await log.waitForType("compaction_end")
        let failure = try #require(await compactionLive(chat).compactionFailure)
        #expect(failure.reason == .threshold && failure.error == "Summarization failed: bad request")
        #expect(log.events.first { $0["type"] == "compaction_end" } == [
            "type": "compaction_end", "taskId": .number(Double(failure.taskId.rawValue)),
            "reason": "threshold", "error": "Summarization failed: bad request"])
        let late = try await chat.harness.watchEvents(conversationId: chat.root.id, context: .background)
        #expect(late.snapshot.compactionFailure == failure)
        #expect(try JSONValue(encoding: late.snapshot).decode(DurableAgentSnapshot.self).compactionFailure == failure)
        _ = await late.stop()
        compactionSetPolicy(chat, compactionManualPolicy)
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        let manual = try await chat.root.compact(context: .background)
        #expect(try await compactionOutcome(chat, manual).status == "completed")
        #expect(try await compactionLive(chat).compactionFailure == nil)
        try await log.waitForType("compaction_end", count: 2)
        #expect(log.events.first { $0["type"] == "compaction_end" && $0["taskId"] == .number(Double(manual.rawValue)) }?["error"] == nil)
        _ = await stream.stop()
        try await chat.harness.close(context: .background)
    }

    // Intake D19: decline, abort, and empty completion retain the newest failure.
    @Test func noSummaryRetainsNewestFailure() async throws {
        let chat = try await compactionOpen()
        try await compactionHistory(chat)
        for text in ["bad request", "second failure"] {
            chat.script.appendSummary([.message(compactionFailure(text))])
            let id = try await chat.root.compact(context: .background)
            #expect(try await compactionOutcome(chat, id).status == "failed")
            #expect(try await compactionLive(chat).compactionFailure == .init(taskId: id, reason: .manual, error: "Summarization failed: \(text)"))
        }
        let failure = try #require(await compactionLive(chat).compactionFailure)
        let held = HarnessUnanswered()
        chat.script.appendSummary([held.step])
        let aborted = try await chat.root.compact(context: .background)
        await held.reached.wait()
        _ = try await chat.harness.abortTask(id: aborted, context: .background)
        #expect(try await compactionOutcome(chat, aborted).status == "aborted")
        #expect(try await compactionLive(chat).compactionFailure == failure)
        try chat.setup.registry.install(Extension(name: "decline-failure", hooks: [hook(CompactionHooks(beforeCompact: { _, _, _ in .decline }))]))
        #expect(try await compactionOutcome(chat, chat.root.compact(context: .background)).status == "completed")
        #expect(try await compactionLive(chat).compactionFailure == failure)
        chat.setup.updateSettings { $0.compaction?.keepRecentTokens = 100_000 }
        #expect(try await compactionOutcome(chat, chat.root.compact(context: .background)).status == "completed")
        #expect(try await compactionLive(chat).compactionFailure == failure)
        try await chat.harness.close(context: .background)
    }

    // Upstream :1956–1975; a throwing task exercises Swift's scheduler fault path.
    @Test(arguments: [false, true])
    func faultRecordsFailureAndBlocksOnlyItsGeneration(blocking: Bool) async throws {
        let faulting = TaskDefinition<CompactionInput, CompactionCheckpoint, CompactionResult, CompactionHooks>(
            name: "pi.compaction", version: 1, initial: { _ in .select },
            phase: { _, _, _ in throw CompactionHookFailure() }, abort: compactionTask.abort)
        let definitions = AnyTaskDefinition.builtins.filter { $0.name != "pi.compaction" } + [AnyTaskDefinition(faulting)]
        let setup = HarnessChatSetup(options: .init(models: [.init(id: "faux-1", contextWindow: 1000, maxTokens: 900)]), registry: Registry(builtins: definitions))
        let chat = try await compactionOpen(setup: setup)
        try await compactionHistory(chat)
        let requests = chat.script.agentRequests.count
        if blocking {
            compactionSetPolicy(chat, compactionBlockingPolicy)
            let input = try await compactionNewInput(chat)
            let receipt = try await input.wait(context: .background)
            #expect(receipt.status == "unanswered" && receipt.reason == "model_error")
            #expect(try JSONValue(encoding: receipt.record)["detail"] == "Compaction failed: no credentials")
            #expect(chat.script.agentRequests.count == requests)
            #expect(try await compactionKinds(chat.root).last == "pi.user")
        } else {
            #expect(try await compactionOutcome(chat, chat.root.compact(context: .background)).status == "faulted")
            try await compactionTurn(chat, "next", "answer")
            #expect(chat.script.agentRequests.count == requests + 1)
        }
        let live = try await compactionLive(chat)
        #expect(live.compactions == nil)
        #expect(live.compactionFailure?.reason == (blocking ? .threshold : .manual))
        #expect(live.compactionFailure?.error == "no credentials")
        try await chat.harness.close(context: .background)
    }

    // Intake D22: a stored threshold wait must fail after its child is orphaned.
    @Test func orphanedBlockingCompactionStopsRequestAfterReopen() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("threshold-orphan.sqlite").path
        let chat = try await compactionOpen(contextWindow: 1000, storage: SqliteStorage.open(path: path))
        try await compactionHistory(chat)
        compactionSetPolicy(chat, compactionBlockingPolicy)
        let held = HarnessUnanswered()
        chat.script.appendSummary([held.step])
        let requests = chat.script.agentRequests.count
        let input = try await compactionNewInput(chat)
        await held.reached.wait()
        let child = try #require(await compactionTasks(chat).first)
        let run = try #require(await compactionLive(chat).run?.taskId)
        let generation = try #require(await chat.harness.getTask(id: run, context: .background))
        #expect(generation.state.checkpoint?["threshold"] == true)
        try await chat.harness.close(context: .background)
        let reopened = try await compactionOpen(storage: SqliteStorage.open(path: path), setup: chat.setup, script: chat.script, resume: false)
        try await reopened.root.commit({ tx in
            let record = try #require(await tx.task(child.id))
            try tx.setTask(record.replacing(version: 2))
        }, context: .background)
        _ = try await reopened.harness.abortTask(id: child.id, context: .background)
        let outcome = try await compactionOutcome(reopened, child.id)
        guard case .orphaned(let reason, _) = outcome else {
            Issue.record("Expected orphaned compaction"); try await reopened.harness.close(context: .background); return
        }
        try reopened.harness.resume()
        let submission = try #require(await reopened.harness.submission(id: input.id, context: .background))
        let receipt = try await submission.wait(context: .background)
        #expect(receipt.status == "unanswered" && receipt.reason == "model_error")
        #expect(try JSONValue(encoding: receipt.record)["detail"] == .string("Compaction failed: \(reason)"))
        #expect(chat.script.agentRequests.count == requests)
        #expect(try await compactionKinds(reopened.root).last == "pi.user")
        let live = try await compactionLive(reopened)
        #expect(live.compactions == nil && live.compactionFailure == .init(taskId: child.id, reason: .threshold, error: reason))
        try await reopened.harness.close(context: .background)
    }

    // Intake D22: optional threshold survives typed checkpoint coding.
    @Test func checkpointAndOutcomeFailureMapping() throws {
        let value: JSONValue = ["phase": "prepare", "attempt": 1, "compacted": 7, "threshold": true]
        let checkpoint = try value.decode(GenerationCheckpoint.self)
        #expect(checkpoint.threshold == true)
        #expect(try JSONValue(encoding: checkpoint) == value)
        #expect(try JSONValue.object(["phase": "prepare", "attempt": 1]).decode(GenerationCheckpoint.self).threshold == nil)
        #expect(throws: (any Error).self) { try JSONValue.object(["phase": "prepare", "threshold": "true"]).decode(GenerationCheckpoint.self) }
        #expect(blockingCompactionFailure(.completed(result: [:])) == nil)
        #expect(blockingCompactionFailure(.failed(error: .init(message: "failed"))) == "Compaction failed: failed")
        #expect(blockingCompactionFailure(.faulted(error: .init(message: "fault"))) == "Compaction failed: fault")
        #expect(blockingCompactionFailure(.orphaned(reason: "unknown")) == "Compaction failed: unknown")
        #expect(blockingCompactionFailure(.aborted()) == "Compaction was aborted")
        let end = DurableAgentEvent.compactionEnd(taskId: try TaskID(7), reason: .threshold, error: "failed")
        #expect(try JSONValue(encoding: end).decode(DurableAgentEvent.self) == end)
    }
}
