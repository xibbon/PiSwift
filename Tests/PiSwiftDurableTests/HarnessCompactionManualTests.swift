import Foundation
import Testing
import Synchronization
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

struct HarnessCompactionManualTests {
    // harness-compaction.test.ts:359
    @Test func idleSummaryPreservesHistoryAndRecordsUsage() async throws {
        let chat = try await compactionOpen()
        try await compactionHistory(chat)
        let before = try await allEntries(chat.root), usageBefore = try await compactionInputUsage(chat)
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        let outcome = try await compactionOutcome(chat, chat.root.compact(instructions: "focus on files", context: .background))
        #expect(outcome.status == "completed")
        let submission = try await compactionSubmission(chat, outcome), placed = try await submission.wait(context: .background)
        #expect(placed.status == "done")
        let after = try await allEntries(chat.root), marker = try #require(after.last)
        #expect(Array(after.prefix(before.count)) == before)
        let u3 = try #require(before.first { (try? textOf($0.messages()?.first))?.hasPrefix("u3") == true })
        #expect(marker.kind == "pi.compaction" && marker.head == u3.id && marker.data?["reason"] == .string("manual"))
        #expect(placed.entry == marker.id)
        let summaryText = "The conversation history before this point was compacted into the following summary:\n\n<summary>\nSUMMARY\n</summary>"
        #expect(try textOf(marker.messages()?.first) == summaryText)
        #expect(try await chat.root.context(context: .background).messages.map { textOf($0) ?? "" } == [summaryText, compactionText("u3", 100), compactionText("a3", 100)])
        let request = try #require(chat.script.summaryRequests.first), prompt = textOf(request.messages.last) ?? ""
        #expect(request.messages.count == 2)
        #expect(prompt.hasPrefix("<conversation>\n[User]: u1 ") && prompt.contains("[Assistant]: a2 ") && !prompt.contains("u3 "))
        #expect(prompt.contains("## Goal") && prompt.hasSuffix("\n\nAdditional focus: focus on files"))
        let provider = try #require(await chat.harness.snapshot(ProviderDoc, conversationId: chat.root.id, context: .background))
        #expect(request.options?.cacheRetention == CacheRetention.none && request.options?.maxTokens == 800 && request.options?.sessionId == provider.sessionId && request.options?.deferred == nil)
        #expect(try await compactionInputUsage(chat) > usageBefore)
        try await compactionTurn(chat, "next", "done")
        let agent = try #require(chat.script.agentRequests.last).messages
        #expect(agent.map(\.role) == ["user", "user", "assistant", "user", "system"])
        if case .system(let system) = agent[4] { #expect(system.sections?["preamble"] == "You are helpful.") }
        else { Issue.record("The last message must be the system baseline") }
        try await chat.harness.close(context: .background)
    }
    // harness-compaction.test.ts:416
    @Test func legacyConversationCreatesProviderBeforeSummary() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        try await chat.root.commit({ tx in try await tx.retireDoc(ProviderDoc, conversationId: chat.root.id) }, context: .background)
        #expect(try await chat.harness.snapshot(ProviderDoc, conversationId: chat.root.id, context: .background) == nil)
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        #expect(try await compactionOutcome(chat, chat.root.compact(context: .background)).status == "completed")
        let stored = try #require(await chat.harness.snapshot(ProviderDoc, conversationId: chat.root.id, context: .background))
        #expect(stored.sessionId.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil)
        #expect(chat.script.summaryRequests.first?.options?.sessionId == stored.sessionId)
        try await chat.harness.close(context: .background)
    }
    // harness-compaction.test.ts:429
    @Test func busyRunQueuesSummaryUntilFinalBoundary() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        let gate = HarnessGatedResponse(message: chatAssistant("late answer")); chat.script.appendAgent([gate.step])
        let input = try await chat.root.submit(.input(content: .text("busy")), context: .background); await gate.reached.wait()
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        let submission = try await compactionSubmission(chat, compactionOutcome(chat, chat.root.compact(context: .background)))
        #expect(try await submission.status(context: .background).status == "queued")
        gate.release()
        #expect(try await input.wait(context: .background).status == "done")
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(try await compactionKinds(chat.root).suffix(3) == ["pi.user", "pi.assistant", "pi.compaction"])
        try await chat.harness.close(context: .background)
    }
    // harness-compaction.test.ts:450. H7 supplies the real tool runtime.
    @Test(.disabled("H7 dependency: the real pi.tool task handler is not available"))
    func queuedSummaryAtPostToolsChangesContinuationContext() async throws {
        let chat = try await compactionOpen()
        let tool = try ToolRegistration(name: "wait", description: "wait", parameters: [:]) { _, _, _ in ToolExecutionResult(content: [.text(TextContent(text: "waited"))]) }
        try chat.setup.registry.install(Extension(name: "wait-tool", tools: [tool]))
        try await chat.root.configure(change: .init(tools: .set(.exact([tool]))), context: .background)
        try await compactionHistory(chat)
        var call = chatAssistant("", reason: .toolUse); call.content = [.toolCall(ToolCall(id: "wait-call", name: "wait", arguments: [:]))]
        let gate = HarnessGatedResponse(message: call); chat.script.appendAgent([gate.step, .message(chatAssistant("after tools"))])
        let input = try await chat.root.submit(.input(content: .text("use a tool")), context: .background); await gate.reached.wait()
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        _ = try await compactionOutcome(chat, chat.root.compact(context: .background)); gate.release()
        #expect(try await input.wait(context: .background).status == "done")
        #expect(compactionFirstUser(try #require(chat.script.agentRequests.last).messages).contains("<summary>\nSUMMARY\n</summary>"))
        #expect(try await compactionKinds(chat.root).suffix(4) == ["pi.tool-result", "pi.compaction", "pi.system", "pi.assistant"])
        try await chat.harness.close(context: .background)
    }
    // harness-compaction.test.ts:487
    @Test func summaryRestartsFollowUpFromFailedRun() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        let gate = HarnessGatedResponse(message: compactionFailure("bad request")); chat.script.appendAgent([gate.step])
        let failed = try await chat.root.submit(.input(content: .text("fails")), context: .background); await gate.reached.wait()
        let followUp = try await chat.root.submit(.input(content: .text("follow-up")), context: .background); gate.release()
        #expect(try await failed.wait(context: .background).status == "unanswered")
        #expect(try await followUp.status(context: .background).status == "queued")
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))]); chat.script.appendAgent([.message(chatAssistant("followed"))])
        _ = try await compactionOutcome(chat, chat.root.compact(context: .background))
        #expect(try await followUp.wait(context: .background).status == "done")
        let messages = try #require(chat.script.agentRequests.last).messages
        #expect(compactionFirstUser(messages).contains("SUMMARY") && messages.contains { textOf($0) == "follow-up" })
        try await chat.harness.close(context: .background)
    }
    // harness-compaction.test.ts:510
    @Test func resetMakesRunningSummaryStale() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        let gate = HarnessGatedResponse(message: chatAssistant("SUMMARY")); chat.script.appendSummary([gate.step])
        let id = try await chat.root.compact(context: .background); await gate.reached.wait()
        try await chat.root.reset(context: .background); gate.release()
        let submission = try await compactionSubmission(chat, compactionOutcome(chat, id)), state = try await submission.status(context: .background)
        #expect(state.status == "unanswered" && state.reason == "stale")
        #expect(try await compactionKinds(chat.root).last == "pi.reset")
        try await chat.harness.close(context: .background)
    }
    // harness-compaction.test.ts:530
    @Test func summaryDoesNotBlockNewRun() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        let summaryGate = HarnessGatedResponse(message: chatAssistant("SUMMARY")); chat.script.appendSummary([summaryGate.step])
        let id = try await chat.root.compact(context: .background); await summaryGate.reached.wait()
        let answerGate = HarnessGatedResponse(message: chatAssistant("a4")); chat.script.appendAgent([answerGate.step])
        let input = try await chat.root.submit(.input(content: .text("u4")), context: .background)
        #expect(try await input.status(context: .background).status == "placed"); await answerGate.reached.wait()
        #expect(compactionFirstUser(try #require(chat.script.agentRequests.last).messages) == compactionText("u1", 100))
        summaryGate.release()
        let submission = try await compactionSubmission(chat, compactionOutcome(chat, id))
        #expect(try await submission.status(context: .background).status == "queued"); answerGate.release()
        #expect(try await input.wait(context: .background).status == "done")
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(try await compactionKinds(chat.root).suffix(3) == ["pi.user", "pi.assistant", "pi.compaction"])
        try await chat.harness.close(context: .background)
    }
    // harness-compaction.test.ts:561
    @Test func staleSummaryRecordsUsageWithoutEntry() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        let before = try await compactionInputUsage(chat), gate = HarnessGatedResponse(message: chatAssistant("SUMMARY"))
        chat.script.appendSummary([gate.step]); let id = try await chat.root.compact(context: .background); await gate.reached.wait()
        try await chat.root.reset(context: .background); gate.release()
        let state = try await compactionSubmission(chat, compactionOutcome(chat, id)).status(context: .background)
        #expect(state.status == "unanswered" && state.reason == "stale")
        #expect(try await compactionInputUsage(chat) > before)
        #expect(try await !compactionKinds(chat.root).contains("pi.compaction"))
        try await chat.harness.close(context: .background)
    }
    // harness-compaction.test.ts:585
    @Test func laterCutWinsWhenItFinishesFirst() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        let gate = HarnessGatedResponse(message: chatAssistant("FIRST")); chat.script.appendSummary([gate.step])
        let early = try await chat.root.compact(context: .background); await gate.reached.wait()
        try await compactionTurn(chat, compactionText("u4", 100), compactionText("a4", 100))
        chat.script.appendSummary([.message(chatAssistant("SECOND"))])
        #expect(try await compactionOutcome(chat, chat.root.compact(context: .background)).status == "completed"); gate.release()
        let state = try await compactionSubmission(chat, compactionOutcome(chat, early)).status(context: .background)
        #expect(state.status == "unanswered" && state.reason == "stale")
        #expect(try await compactionFirstUser(chat.root.context(context: .background).messages).contains("SECOND"))
        try await chat.harness.close(context: .background)
    }
    // harness-compaction.test.ts:609
    @Test func olderSelectionWithLaterCutCanReplaceNewerSummary() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        let gate = HarnessGatedResponse(message: chatAssistant("A")); chat.script.appendSummary([gate.step])
        let id = try await chat.root.compact(context: .background); await gate.reached.wait()
        chat.setup.updateSettings { $0.compaction?.keepRecentTokens = 350 }; chat.script.appendSummary([.message(chatAssistant("B"))])
        _ = try await compactionOutcome(chat, chat.root.compact(context: .background))
        #expect(try await compactionFirstUser(chat.root.context(context: .background).messages).contains("B")); gate.release()
        #expect(try await compactionSubmission(chat, compactionOutcome(chat, id)).status(context: .background).status == "done")
        let messages = try await chat.root.context(context: .background).messages
        #expect(compactionFirstUser(messages).contains("<summary>\nA\n</summary>"))
        #expect(messages.dropFirst().map { textOf($0) ?? "" } == [compactionText("u3", 100), compactionText("a3", 100)])
        try await chat.harness.close(context: .background)
    }
    // harness-compaction.test.ts:638; before=[150,350], at=[150,150], after=[350,150].
    @Test(arguments: ["before", "at", "after"]) func twoQueuedSummariesUseCutOrder(order: String) async throws {
        let keeps = order == "before" ? [150, 350] : order == "after" ? [350, 150] : [150, 150]
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        let gate = HarnessGatedResponse(message: chatAssistant("done")); chat.script.appendAgent([gate.step])
        let input = try await chat.root.submit(.input(content: .text("busy")), context: .background); await gate.reached.wait()
        var submissions: [Submission] = []
        for (index, keep) in keeps.enumerated() {
            chat.setup.updateSettings { $0.compaction?.keepRecentTokens = keep }; chat.script.appendSummary([.message(chatAssistant("S\(index)"))])
            submissions.append(try await compactionSubmission(chat, compactionOutcome(chat, chat.root.compact(context: .background))))
        }
        gate.release(); _ = try await input.wait(context: .background)
        var statuses: [String] = []; for submission in submissions { statuses.append(try await submission.wait(context: .background).status) }
        #expect(statuses == ["done", order == "before" ? "unanswered" : "done"])
        try await chat.harness.close(context: .background)
    }
    // harness-compaction.test.ts:663
    @Test func abortStopsRunningCompactionButKeepsQueuedSummary() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        let summaryGate = HarnessGatedResponse(message: chatAssistant("SUMMARY")); chat.script.appendSummary([summaryGate.step])
        let id = try await chat.root.compact(context: .background); await summaryGate.reached.wait()
        #expect(try await compactionLive(chat).compactions?.count == 1)
        try await chat.root.abort(context: .background)
        #expect(try await compactionOutcome(chat, id).status == "aborted")
        #expect(try await compactionLive(chat).compactions == nil)
        #expect(try await !compactionKinds(chat.root).contains("pi.compaction"))
        let gate = HarnessGatedResponse(message: chatAssistant("never")); chat.script.appendAgent([gate.step])
        _ = try await chat.root.submit(.input(content: .text("busy")), context: .background); await gate.reached.wait()
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        let submission = try await compactionSubmission(chat, compactionOutcome(chat, chat.root.compact(context: .background)))
        try await chat.root.abort(context: .background)
        #expect(try await submission.status(context: .background).status == "queued")
        #expect(try await submission.abort(context: .background) == .aborted)
        try await compactionTurn(chat, "next", "ok")
        let state = try await submission.status(context: .background)
        #expect(state.status == "unanswered" && state.reason == "aborted")
        #expect(try await !compactionKinds(chat.root).contains("pi.compaction"))
        try await chat.harness.close(context: .background)
    }
    // harness-compaction.test.ts:695
    @Test func idleWaitIncludesManualCompaction() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        let gate = HarnessGatedResponse(message: chatAssistant("SUMMARY")); chat.script.appendSummary([gate.step])
        let id = try await chat.root.compact(context: .background); await gate.reached.wait()
        let entered = HarnessChatSignal(), idle = settled { entered.signal(); try await chat.root.waitForIdle(context: .background) }
        await entered.wait()
        #expect(!idle.isSettled)
        #expect(try await chat.harness.getTask(id: id, context: .background)?.state.status == "running")
        gate.release(); try await eventually { idle.isSettled }
        #expect(try await chat.harness.getTask(id: id, context: .background)?.state.status == "terminal")
        try await chat.harness.close(context: .background)
    }
    // harness-compaction.test.ts:715
    @Test func compactEnablesSchedulingAfterOpen() async throws {
        let chat = try await compactionOpen(resume: false)
        chat.setup.updateSettings { $0.compaction?.keepRecentTokens = 10 }
        let id = try await chat.root.compact(context: .background)
        try await eventually { try await chat.harness.getTask(id: id, context: .background)?.state.status == "terminal" }
        #expect(try await compactionOutcome(chat, id) == .completed(result: .object([:])))
        #expect(chat.script.summaryRequests.isEmpty)
        try await chat.harness.close(context: .background)
    }
}
