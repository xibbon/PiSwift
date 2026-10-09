import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

let interactionBlocking = CompactionPolicy(enabled: true, reserveTokens: 500, keepRecentTokens: 150, backgroundTokens: 0)
let interactionBackground = CompactionPolicy(enabled: true, reserveTokens: 500, keepRecentTokens: 150, backgroundTokens: 1000)
func interactionSummary(_ chat: CompactionChat, text: String = "SUMMARY") async throws -> Submission {
    chat.script.appendSummary([.message(chatAssistant(text))])
    return try await compactionSubmission(chat, compactionOutcome(chat, chat.root.compact(context: .background)))
}
func interactionBusy(_ chat: CompactionChat, response: AssistantMessage = chatAssistant("done")) async throws -> (Submission, HarnessGatedResponse) {
    let held = HarnessGatedResponse(message: response)
    chat.script.appendAgent([held.step])
    let input = try await chat.root.submit(.input(content: .text("busy")), context: .background)
    await held.reached.wait()
    return (input, held)
}
func interactionBlockingRun(_ chat: CompactionChat) async throws -> (Submission, HarnessGatedResponse, TaskID) {
    try await compactionHistory(chat)
    chat.setup.updateSettings { $0.compaction = .init(enabled: true, reserveTokens: 500, keepRecentTokens: 150, backgroundTokens: 0) }
    let held = HarnessGatedResponse(message: chatAssistant("BLOCKING"))
    chat.script.appendSummary([held.step])
    let input = try await chat.root.submit(.input(content: .text(compactionText("u4", 200))), context: .background)
    await held.reached.wait()
    return (input, held, try #require(await compactionLive(chat).compactions?.first?.taskId))
}

@Suite struct HarnessCompactionInteractionTests {
    // Upstream :1256, real/fixed clocks. H7 tool execution is replaced by a committed context fixture.
    @Test(arguments: [false, true])
    func estimateExcludesUsageBeforeNewHead(fixed: Bool) throws {
        var measured = chatAssistant("old")
        measured.timestamp = fixed ? 1000 : 1
        measured.usage = Usage(input: 1600, output: 50, cacheRead: 0, cacheWrite: 0, totalTokens: 1650)
        let old = EntryRecord(id: try EntryID(2), conversationId: rootConversationID, kind: "pi.assistant", model: try EntryRecord.encodeMessages([.assistant(measured)]))
        let kept = EntryRecord(id: try EntryID(3), conversationId: rootConversationID, kind: "pi.user", model: try EntryRecord.encodeMessages([.user(UserMessage(content: .text("kept"), timestamp: fixed ? 1000 : 2))]))
        let marker = EntryRecord(id: try EntryID(4), conversationId: rootConversationID, kind: "pi.compaction", model: try EntryRecord.encodeMessages([.user(UserMessage(content: .text("SUMMARY"), timestamp: fixed ? 1000 : 3))]), head: old.id)
        let view = try deriveContext(entries: [old, kept, marker])
        #expect(generationEstimateContext(view: view) == view.messages.reduce(0) { $0 + estimateMessageTokens($1) })
        #expect(generationEstimateContext(view: view) < 1600)
    }
    // Upstream :1305.
    @Test func summaryCausesCompleteSystemBaselineOverKeptDelta() async throws {
        let chat = try await compactionOpen(), mood = Mutex("cheerful")
        try chat.setup.registry.install(Extension(name: "mood", sections: [section("mood", tag: false) { _, _ in mood.withLock { $0 } }]))
        try await compactionTurn(chat, compactionText("u1", 100), compactionText("a1", 100))
        try await compactionTurn(chat, compactionText("u2", 100), compactionText("a2", 100))
        mood.withLock { $0 = "terse" }
        try await compactionTurn(chat, compactionText("u3", 100), compactionText("a3", 100))
        chat.setup.updateSettings { $0.compaction = .init(enabled: false, reserveTokens: 1000, keepRecentTokens: 250, backgroundTokens: 0) }
        _ = try await interactionSummary(chat)
        #expect(try await chat.root.context(context: .background).entries.contains { $0.kind == "pi.system" })
        try await compactionTurn(chat, "next", "ok")
        let systems = try #require(chat.script.agentRequests.last).messages.filter { $0.role == "system" }
        #expect(systems.count == 1)
        if case .system(let system) = systems[0] { #expect(getSystemMessageText(system).contains("terse") && getSystemMessageText(system).contains("You are helpful.")) }
        try await chat.harness.close(context: .background)
    }
    // Upstream :1325.
    @Test func replacementContributionsReachHookAndSummary() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        let first = try #require(await allEntries(chat.root).first)
        let replacement = try EntryRecord.encodeMessages([.user(UserMessage(content: .text("REDACTED"), timestamp: 0))])
        _ = try await chat.root.submit(.write(entry: .init(kind: "app.redact", edits: [.replace(target: first.id, messages: replacement)])), context: .background)
        let seen = Mutex<[Message]>([])
        try chat.setup.registry.install(Extension(name: "replacement-hook", hooks: [hook(CompactionHooks(beforeCompact: { input, _, _ in seen.withLock { $0 = input.messages }; return nil }))]))
        _ = try await interactionSummary(chat)
        #expect(compactionFirstUser(seen.withLock { $0 }) == "REDACTED")
        #expect(textOf(chat.script.summaryRequests[0].messages[1])?.contains("[User]: REDACTED") == true)
        try await chat.harness.close(context: .background)
    }
    // Upstream :1359, H9 view-state assertion adapted to context entries.
    @Test func forkCompactsParentEntriesWithoutChangingParent() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        let entries = try await allEntries(chat.root), last = try #require(entries.last)
        let fork = try await chat.root.fork(at: last.id, options: .init(ownership: .ownerless()), context: .background)
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        let outcome = try await compactionOutcome(chat, fork.compact(context: .background))
        #expect(try await compactionSubmission(chat, outcome).wait(context: .background).status == "done")
        let view = try await fork.context(context: .background)
        let u3 = try #require(entries.first { (try? textOf($0.messages()?.first))?.hasPrefix("u3") == true })
        #expect(view.head?.kind == "pi.compaction" && view.head?.head == u3.id && view.head?.conversationId == fork.id)
        #expect(view.messages.dropFirst().map(textOf) == [compactionText("u3", 100), compactionText("a3", 100)])
        #expect(try await !compactionKinds(chat.root).contains("pi.compaction"))
        try await chat.harness.close(context: .background)
    }
    // Upstream :1381.
    @Test func forkResetMakesInFlightSummaryStale() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        let last = try #require(await allEntries(chat.root).last)
        let fork = try await chat.root.fork(at: last.id, options: .init(ownership: .ownerless()), context: .background)
        let held = HarnessGatedResponse(message: chatAssistant("SUMMARY")); chat.script.appendSummary([held.step])
        let id = try await fork.compact(context: .background); await held.reached.wait()
        try await fork.reset(context: .background); held.release()
        let submission = try await compactionSubmission(chat, compactionOutcome(chat, id))
        #expect(try await submission.status(context: .background).reason == "stale")
        #expect(try await fork.context(context: .background).head?.kind == "pi.reset")
        try await chat.harness.close(context: .background)
    }
    // Upstream :1403.
    @Test func idleAdmissionDrainsOlderAndCurrentSummariesTogether() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        let (input, held) = try await interactionBusy(chat, response: compactionFailure("bad request"))
        let older = try await interactionSummary(chat, text: "OLDER")
        held.release(); _ = try await input.wait(context: .background)
        let current = try await interactionSummary(chat, text: "CURRENT")
        #expect(try await older.status(context: .background).status == "done")
        #expect(try await current.status(context: .background).status == "done")
        #expect(try await compactionFirstUser(chat.root.context(context: .background).messages).contains("CURRENT"))
        try await chat.harness.close(context: .background)
    }
    // Upstream :1428.
    @Test func hookSummaryIsPlacedWhileOwnedChildKeepsTaskCompleting() async throws {
        let chat = try await compactionOpen(), gate = SessionTestGate()
        let child = harnessOneStep("test.compaction-child") { _, runtime, context in
            await gate.wait()
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }
        try chat.setup.registry.install(Extension(name: "child", hooks: [hook(CompactionHooks(beforeCompact: { _, api, context in
            _ = try await chat.harness.commit({ tx in try await tx.createTask(child, input: 0, options: .init(ownership: .task(taskId: api.taskId), conversationId: chat.root.id)) }, context: context)
            return .summary("HOOK")
        }))], tasks: [AnyTaskDefinition(child)]))
        try await compactionHistory(chat)
        let id = try await chat.root.compact(context: .background)
        try await eventually { try await chat.harness.getTask(id: id, context: .background)?.state.status == "completing" }
        #expect(try await compactionKinds(chat.root).last == "pi.compaction")
        #expect(try await compactionLive(chat).compactions == nil)
        gate.release(); #expect(try await compactionOutcome(chat, id).status == "completed")
        try await chat.harness.close(context: .background)
    }
    // Upstream :1456, :1880. A rejected response commit replaces a throwing model call in Swift.
    @Test(arguments: [false, true])
    func faultedCompactionRemovesStatusAndBlockingGenerationContinues(blocking: Bool) async throws {
        let storage = ControlledStorage(), chat = try await compactionOpen(contextWindow: 1000, storage: storage)
        try await compactionHistory(chat)
        chat.script.appendSummary([.factory { _, _, _, _ in
            await storage.failNextCommit(StorageRejected("models broke"))
            return chatAssistant("SUMMARY")
        }])
        if blocking {
            chat.setup.updateSettings { $0.compaction = .init(enabled: true, reserveTokens: 500, keepRecentTokens: 150, backgroundTokens: 0) }
            try await compactionTurn(chat, compactionText("u4", 200), "a4")
        } else {
            #expect(try await compactionOutcome(chat, chat.root.compact(context: .background)).status == "faulted")
        }
        #expect(try await compactionLive(chat).compactions == nil)
        #expect(try await !compactionKinds(chat.root).contains("pi.compaction"))
        try await chat.harness.close(context: .background)
    }
    // Upstream :1492; H9 events adapted to fresh pi.live snapshots.
    @Test func retryStatusIsVisibleToLateReaderAndRemovedOnAbort() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        chat.setup.updateSettings { $0.retry = .init(enabled: true, maxRetries: 2, baseDelayMs: 60_000) }
        chat.script.appendSummary([.message(compactionFailure("overloaded"))])
        let id = try await chat.root.compact(context: .background)
        try await eventually { try await compactionLive(chat).compactions?.first?.retry != nil }
        let status = try #require(await compactionLive(chat).compactions?.first)
        #expect(status.taskId == id && status.reason == .manual && !status.blocking && status.attempt == 1)
        #expect(status.retry?.error == "overloaded" && status.retry?.at == 61000)
        _ = try await chat.harness.abortTask(id: id, context: .background)
        #expect(try await compactionOutcome(chat, id).status == "aborted")
        #expect(try await compactionLive(chat).compactions == nil)
        try await chat.harness.close(context: .background)
    }
    // Upstream :1525 and :2174; the late event snapshot is adapted to the live document.
    @Test func concurrentCompactionsAreListedByTaskIdForLateReader() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        let a = HarnessUnanswered(), b = HarnessUnanswered()
        chat.script.appendSummary([a.step, b.step])
        let first = try await chat.root.compact(context: .background), second = try await chat.root.compact(context: .background)
        await a.reached.wait(); await b.reached.wait()
        #expect(try await compactionLive(chat).compactions == [CompactionStatus(taskId: first, reason: .manual, blocking: false, attempt: 1), CompactionStatus(taskId: second, reason: .manual, blocking: false, attempt: 1)])
        try await chat.root.abort(context: .background)
        #expect(try await compactionLive(chat).compactions == nil)
        try await chat.harness.close(context: .background)
    }

    // Upstream :1730; both queue orders are assertion paths in one case.
    @Test func resetAndSummaryUseInboxOrder() async throws {
        for summaryFirst in [true, false] {
            let chat = try await compactionOpen(); try await compactionHistory(chat)
            let (input, held) = try await interactionBusy(chat)
            let submission: Submission
            if summaryFirst {
                submission = try await interactionSummary(chat)
                try await chat.root.reset(context: .background)
            } else {
                try await chat.root.reset(context: .background)
                submission = try await interactionSummary(chat)
            }
            held.release(); _ = try await input.wait(context: .background)
            let receipt = try await submission.wait(context: .background)
            #expect(receipt.status == (summaryFirst ? "done" : "unanswered"))
            if !summaryFirst { #expect(receipt.reason == "stale") }
            #expect(try await compactionKinds(chat.root).last == "pi.reset")
            #expect(try await chat.root.context(context: .background).head?.kind == "pi.reset")
            try await chat.harness.close(context: .background)
        }
    }
    // Upstream :1753.
    @Test func failedRunLeavesSummaryQueuedUntilNextInput() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        let (input, held) = try await interactionBusy(chat, response: compactionFailure("bad request"))
        let summary = try await interactionSummary(chat)
        held.release(); #expect(try await input.wait(context: .background).status == "unanswered")
        #expect(try await summary.status(context: .background).status == "queued")
        try await compactionTurn(chat, "again", "ok")
        #expect(try await summary.status(context: .background).status == "done")
        let messages = try #require(chat.script.agentRequests.last).messages
        #expect(compactionFirstUser(messages).contains("SUMMARY") && messages.map(textOf).contains("again"))
        try await chat.harness.close(context: .background)
    }
    // Upstream :1769.
    @Test func overflowCompactionPreservesFullRetryBudget() async throws {
        let chat = try await compactionOpen(clock: SystemDurableClock()); try await compactionHistory(chat)
        chat.setup.updateSettings { $0.compaction = .init(enabled: true, reserveTokens: 1000, keepRecentTokens: 150, backgroundTokens: 0) }
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        chat.script.appendAgent([.message(compactionFailure("prompt is too long")), .message(compactionFailure("overloaded")), .message(compactionFailure("overloaded")), .message(chatAssistant("finally"))])
        let input = try await chat.root.submit(.input(content: .text(compactionText("u4", 100))), context: .background)
        #expect(try await input.wait(context: .background).status == "done")
        #expect(chat.script.summaryRequests.count == 1 && chat.script.agentRequests.count == 7)
        try await chat.harness.close(context: .background)
    }
    // Upstream :1785.
    @Test func laterEditIsNotIncludedInPinnedSummaryRange() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        let first = try #require(await allEntries(chat.root).first)
        let held = HarnessGatedResponse(message: chatAssistant("SUMMARY")); chat.script.appendSummary([held.step])
        let id = try await chat.root.compact(context: .background); await held.reached.wait()
        let replacement = try EntryRecord.encodeMessages([.user(UserMessage(content: .text("REDACTED"), timestamp: 0))])
        _ = try await chat.root.submit(.write(entry: .init(kind: "app.redact", edits: [.replace(target: first.id, messages: replacement)])), context: .background)
        held.release(); _ = try await compactionOutcome(chat, id)
        #expect(textOf(chat.script.summaryRequests[0].messages[1])?.contains("[User]: u1 ") == true)
        #expect(try await !chat.root.context(context: .background).messages.map(textOf).contains("REDACTED"))
        try await chat.harness.close(context: .background)
    }
    // Upstream :1804, H9 mounted-view assertion adapted to retained context entries.
    @Test func summaryKeepsRecentRawEntriesInContext() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        let before = try await allEntries(chat.root)
        _ = try await interactionSummary(chat)
        let view = try await chat.root.context(context: .background)
        #expect(view.entries.first?.kind == "pi.compaction")
        #expect(view.entries.dropFirst().allSatisfy { before.contains($0) })
        #expect(view.entries.dropFirst().count == 2)
        try await chat.harness.close(context: .background)
    }
}
