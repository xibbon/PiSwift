import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessCompactionEdgeTests {
    // Upstream :1818.
    @Test func declinedBlockingCompactionIsNotRepeatedDuringRetry() async throws {
        let chat = try await compactionOpen(contextWindow: 1000, clock: SystemDurableClock())
        try await compactionHistory(chat)
        chat.setup.updateSettings { $0.compaction = compactionOverrides(interactionBlocking) }
        let asked = Mutex(0)
        try chat.setup.registry.install(Extension(name: "decline", hooks: [hook(CompactionHooks(beforeCompact: { _, _, _ in asked.withLock { $0 += 1 }; return .decline }))]))
        chat.script.appendAgent([.message(compactionFailure("overloaded"))])
        try await compactionTurn(chat, compactionText("u4", 200), "a4")
        #expect(asked.withLock { $0 } == 1 && chat.script.agentRequests.count == 5)
        try await chat.harness.close(context: .background)
    }
    // Upstream :1837.
    @Test func manualAdmissionDuringPreparationPreventsBackgroundAdmission() async throws {
        let chat = try await compactionOpen(contextWindow: 2000); try await compactionHistory(chat)
        chat.setup.updateSettings { $0.compaction = compactionOverrides(interactionBackground) }
        let rendering = HarnessChatSignal(), release = HarnessChatSignal(), first = Mutex(true)
        try chat.setup.registry.install(Extension(name: "slow", sections: [section("slow") { _, _ in
            let hold = first.withLock { value in let old = value; value = false; return old }
            if hold { rendering.signal(); await release.wait() }
            return "slow"
        }]))
        let held = HarnessUnanswered(); chat.script.appendSummary([held.step]); chat.script.appendAgent([.message(chatAssistant("a4"))])
        let input = try await chat.root.submit(.input(content: .text(compactionText("u4", 100))), context: .background)
        await rendering.wait()
        let manual = try await chat.root.compact(context: .background); await held.reached.wait()
        release.signal()
        #expect(try await input.wait(context: .background).status == "done")
        #expect(try await compactionLive(chat).compactions?.map(\.taskId) == [manual])
        #expect(chat.script.summaryRequests.count == 1)
        _ = try await chat.harness.abortTask(id: manual, context: .background)
        try await chat.harness.close(context: .background)
    }
    // Upstream :1868.
    @Test func blockingCompactionPreventsLaterBackgroundInSameGeneration() async throws {
        let chat = try await compactionOpen(contextWindow: 2000); try await compactionHistory(chat)
        chat.setup.updateSettings { $0.compaction = .init(enabled: true, reserveTokens: 500, keepRecentTokens: 400, backgroundTokens: 1300) }
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        try await compactionTurn(chat, compactionText("u4", 1000), "a4")
        #expect(chat.script.summaryRequests.count == 1)
        #expect(try await compactionLive(chat).compactions == nil)
        try await chat.harness.close(context: .background)
    }
    // Upstream :1895, both assertion paths.
    @Test func overflowKeepsOriginalTextWhenSummaryAbortsOrOverflows() async throws {
        for abort in [true, false] {
            let chat = try await compactionOpen(); try await compactionHistory(chat)
            chat.setup.updateSettings { $0.compaction = .init(enabled: true, reserveTokens: 1000, keepRecentTokens: 150, backgroundTokens: 0) }
            let held = HarnessUnanswered(), overflow = "prompt is too long: 250000 tokens > 200000 maximum"
            chat.script.appendSummary(abort ? [held.step] : [.message(compactionFailure("prompt is too long for the summary"))])
            chat.script.appendAgent([.message(compactionFailure(overflow))])
            let input = try await chat.root.submit(.input(content: .text(compactionText("u4", 100))), context: .background)
            if abort {
                await held.reached.wait()
                let child = try #require(await compactionLive(chat).compactions?.first?.taskId)
                _ = try await chat.harness.abortTask(id: child, context: .background)
            }
            let receipt = try await input.wait(context: .background)
            let record = try JSONValue(encoding: receipt.record)
            #expect(receipt.status == "unanswered" && receipt.reason == "model_error" && record["detail"] == .string(overflow))
            #expect(try await compactionLive(chat).compactions == nil)
            try await chat.harness.close(context: .background)
        }
    }
    // Upstream :1920.
    @Test func lengthAnswerIsNotContextOverflow() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        chat.setup.updateSettings { $0.compaction = .init(enabled: true, reserveTokens: 1000, keepRecentTokens: 150, backgroundTokens: 0) }
        chat.script.appendAgent([.message(chatAssistant("cut short", reason: .length, error: "prompt is too long"))])
        let input = try await chat.root.submit(.input(content: .text("go")), context: .background)
        #expect(try await input.wait(context: .background).status == "done")
        #expect(chat.script.summaryRequests.isEmpty)
        try await chat.harness.close(context: .background)
    }
    // Upstream :1970.
    @Test func blockingRetryMakesQueuedBackgroundSummaryStale() async throws {
        let clock = TestClock(now: 1000), chat = try await compactionOpen(contextWindow: 2000, clock: clock)
        try await compactionHistory(chat)
        chat.setup.updateSettings { $0.compaction = compactionOverrides(interactionBackground); $0.retry = .init(enabled: true, maxRetries: 2, baseDelayMs: 60_000) }
        let held = HarnessGatedResponse(message: chatAssistant("BACKGROUND"))
        chat.script.appendSummary([held.step, .message(chatAssistant("BLOCKING"))])
        chat.script.appendAgent([.message(compactionFailure("overloaded")), .message(chatAssistant("a4"))])
        let input = try await chat.root.submit(.input(content: .text(compactionText("u4", 100))), context: .background)
        await held.reached.wait()
        try await eventually { try await compactionLive(chat).generation?.retry != nil }
        let background = try #require(await compactionLive(chat).compactions?.first?.taskId)
        held.release()
        let queued = try await compactionSubmission(chat, compactionOutcome(chat, background))
        #expect(try await queued.status(context: .background).status == "queued")
        chat.setup.updateSettings { $0.compaction = .init(enabled: true, reserveTokens: 1500, keepRecentTokens: 50, backgroundTokens: 1000) }
        clock.advance(by: 120_000)
        #expect(try await input.wait(context: .background).status == "done")
        #expect(compactionFirstUser(try #require(chat.script.agentRequests.last).messages).contains("BLOCKING"))
        #expect(try await queued.wait(context: .background).reason == "stale")
        try await chat.harness.close(context: .background)
    }
    // Upstream :2004.
    @Test func secondCompactionIncludesPreviousSummary() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        _ = try await interactionSummary(chat, text: "FIRST")
        try await compactionTurn(chat, compactionText("u4", 100), compactionText("a4", 100))
        try await compactionTurn(chat, compactionText("u5", 100), compactionText("a5", 100))
        _ = try await interactionSummary(chat, text: "SECOND")
        let prompt = try #require(textOf(chat.script.summaryRequests[1].messages[1]))
        #expect(prompt.hasPrefix("<conversation>\n[User]: The conversation history before this point was compacted"))
        #expect(prompt.contains("FIRST"))
        #expect(try await compactionFirstUser(chat.root.context(context: .background).messages).contains("SECOND"))
        try await chat.harness.close(context: .background)
    }
    // Upstream :2020.
    @Test func rejectedClassificationCommitsNoUsageOrSummarySubmission() async throws {
        let storage = ControlledStorage(), chat = try await compactionOpen(storage: storage)
        try await compactionHistory(chat)
        let before = try await chat.harness.usage(context: .background)
        chat.script.appendSummary([.factory { _, _, _, _ in
            await storage.failNextCommit(StorageRejected("rejected")); return chatAssistant("SUMMARY")
        }])
        let id = try await chat.root.compact(context: .background)
        #expect(try await compactionOutcome(chat, id).status == "faulted")
        #expect(try JSONValue(encoding: await chat.harness.usage(context: .background)) == JSONValue(encoding: before))
        #expect(try await !compactionKinds(chat.root).contains("pi.compaction"))
        #expect(try await chat.harness.inspect(context: .background).submissions.isEmpty)
        #expect(try await storage.submissionByRequest(chat.root.id, requestId: "compaction:\(id.rawValue)", context: .background) == nil)
        #expect(try await compactionLive(chat).compactions == nil)
        try await chat.harness.close(context: .background)
    }
    // Upstream :2056.
    @Test func manualEqualCutReplacesBlockingSummaryAtFinalBoundary() async throws {
        let chat = try await compactionOpen(contextWindow: 1000)
        let (input, held, _) = try await interactionBlockingRun(chat)
        let manual = try await interactionSummary(chat, text: "MANUAL")
        #expect(try await manual.status(context: .background).status == "queued")
        chat.script.appendAgent([.message(chatAssistant("a4"))]); held.release()
        #expect(try await input.wait(context: .background).status == "done")
        #expect(compactionFirstUser(try #require(chat.script.agentRequests.last).messages).contains("BLOCKING"))
        #expect(try await manual.wait(context: .background).status == "done")
        let markers = try await allEntries(chat.root).filter { $0.kind == "pi.compaction" }
        #expect(markers.count == 2 && markers[0].head == markers[1].head)
        let messages = try await chat.root.context(context: .background).messages
        #expect(compactionFirstUser(messages).contains("MANUAL"))
        #expect(!messages.contains { textOf($0)?.contains("BLOCKING") == true })
        try await chat.harness.close(context: .background)
    }
    // Upstream :2082.
    @Test func manualSelectedAfterBlockingPlacementHasNothingToCompact() async throws {
        let chat = try await compactionOpen(contextWindow: 1000)
        let (input, held, _) = try await interactionBlockingRun(chat)
        let answer = HarnessGatedResponse(message: chatAssistant("a4")); chat.script.appendAgent([answer.step])
        held.release(); await answer.reached.wait()
        let outcome = try await compactionOutcome(chat, chat.root.compact(context: .background))
        if case .completed(let result, _) = outcome { #expect(result == .object([:])) }
        else { Issue.record("Expected empty completed compaction") }
        #expect(chat.script.summaryRequests.count == 1)
        answer.release(); #expect(try await input.wait(context: .background).status == "done")
        try await chat.harness.close(context: .background)
    }
    // Upstream :2100.
    @Test func abortEndsBlockingAndManualCompactionsWithoutSummary() async throws {
        let chat = try await compactionOpen(contextWindow: 1000)
        let (input, _, blocking) = try await interactionBlockingRun(chat)
        let held = HarnessUnanswered(); chat.script.appendSummary([held.step])
        let manual = try await chat.root.compact(context: .background); await held.reached.wait()
        #expect(try await compactionLive(chat).compactions?.map(\.blocking) == [true, false])
        try await chat.root.abort(context: .background)
        #expect(try await input.wait(context: .background).reason == "aborted")
        #expect(try await compactionOutcome(chat, blocking).status == "aborted")
        #expect(try await compactionOutcome(chat, manual).status == "aborted")
        let live = try await compactionLive(chat)
        #expect(live.compactions == nil && live.run == nil)
        #expect(try await !compactionKinds(chat.root).contains("pi.compaction"))
        #expect(try await chat.harness.inspect(context: .background).submissions.isEmpty)
        try await chat.harness.close(context: .background)
    }
    // Upstream :2119.
    @Test func summaryQueuedBeforeAbortLandsBeforeNextInput() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        let held = HarnessUnanswered(); chat.script.appendAgent([held.step])
        let busy = try await chat.root.submit(.input(content: .text("busy")), context: .background)
        await held.reached.wait()
        let summary = try await interactionSummary(chat)
        try await chat.root.abort(context: .background)
        #expect(try await busy.wait(context: .background).reason == "aborted")
        #expect(try await summary.status(context: .background).status == "queued")
        try await compactionTurn(chat, "u5", "a5")
        #expect(try await summary.status(context: .background).status == "done")
        let request = try #require(chat.script.agentRequests.last).messages
        #expect(compactionFirstUser(request).contains("SUMMARY") && request.map(textOf).contains("u5"))
        #expect(try await Array(compactionKinds(chat.root).suffix(4)) == ["pi.compaction", "pi.user", "pi.system", "pi.assistant"])
        try await chat.harness.close(context: .background)
    }
    // Upstream :2147.
    @Test func retryKeepsPinnedModelAndAdvancesLiveAttempt() async throws {
        let setup = HarnessChatSetup(options: .init(models: [.init(id: "faux-1", contextWindow: 100_000, maxTokens: 900), .init(id: "faux-2", contextWindow: 100_000, maxTokens: 900)]), clock: SystemDurableClock())
        let chat = try await compactionOpen(setup: setup); try await compactionHistory(chat)
        let attempt = Mutex<Int?>(nil)
        chat.script.appendSummary([
            .factory { _, _, _, _ in
                try await chat.root.configure(change: .init(model: .set(.init(provider: "faux", modelId: "faux-2"))), context: .background)
                return compactionFailure("overloaded")
            },
            .factory { _, _, _, _ in
                let live = try await compactionLive(chat)
                attempt.withLock { $0 = live.compactions?.first?.attempt }
                return chatAssistant("SUMMARY")
            }
        ])
        #expect(try await compactionOutcome(chat, chat.root.compact(context: .background)).status == "completed")
        #expect(chat.script.summaryRequests.map(\.model) == ["faux-1", "faux-1"])
        #expect(attempt.withLock { $0 } == 2)
        #expect(try await Set(chat.harness.usage(context: .background).models.keys) == ["faux/faux-1"])
        try await chat.harness.close(context: .background)
    }
    // Upstream :2192, both registered variants.
    @Test(arguments: [StopReason.stop, .length])
    func silentOverflowIsAnOrdinaryAnswer(reason: StopReason) async throws {
        let chat = try await compactionOpen(contextWindow: 300); try await compactionHistory(chat)
        chat.setup.updateSettings { $0.compaction = .init(enabled: true, reserveTokens: -100_000, keepRecentTokens: 150, backgroundTokens: 0) }
        chat.script.appendAgent([.message(chatAssistant(reason == .stop ? "fine" : "", reason: reason))])
        let input = try await chat.root.submit(.input(content: .text("go")), context: .background)
        #expect(try await input.wait(context: .background).status == "done")
        let last = try #require(await allEntries(chat.root).last)
        if case .assistant(let message) = try last.messages()?.first { #expect(message.usage.input >= 300) }
        else { Issue.record("Expected assistant answer") }
        #expect(chat.script.summaryRequests.isEmpty)
        try await chat.harness.close(context: .background)
    }
    // Upstream :2213.
    @Test func policyChangedDuringPreparationCanMakeBlockingSelectionEmpty() async throws {
        let chat = try await compactionOpen(contextWindow: 1000); try await compactionHistory(chat)
        chat.setup.updateSettings { $0.compaction = compactionOverrides(interactionBlocking) }
        let changed = Mutex(false)
        try chat.setup.registry.install(Extension(name: "policy", sections: [section("policy") { _, _ in
            let first = changed.withLock { value in let old = value; value = true; return !old }
            if first { chat.setup.updateSettings { $0.compaction = .init(enabled: true, reserveTokens: 500, keepRecentTokens: 100_000, backgroundTokens: 0) } }
            return "p"
        }]))
        try await compactionTurn(chat, compactionText("u4", 200), "a4")
        #expect(try await !chat.harness.inspect(context: .background).tasks.contains { $0.record.kind == "pi.compaction" })
        #expect(chat.script.summaryRequests.isEmpty)
        #expect(try await !compactionKinds(chat.root).contains("pi.compaction"))
        try await chat.harness.close(context: .background)
    }
    // Upstream :2277.
    @Test func olderHeadMarkerEditsApplyToSummaryContributions() async throws {
        let chat = try await compactionOpen(), rootId = chat.root.id
        func model(_ value: String) throws -> [JSONValue] { try EntryRecord.encodeMessages([.user(UserMessage(content: .text(value), timestamp: 0))]) }
        let ids = try await chat.root.commit({ tx in
            let a = try await tx.appendEntry(rootId, value: .init(kind: "app.note", model: model("a")))
            let b = try await tx.appendEntry(rootId, value: .init(kind: "app.note", model: model("b")))
            _ = try await tx.appendEntry(rootId, value: .init(kind: "app.head", head: .entry(a.id), edits: [.omit(target: b.id)]))
            let c = try await tx.appendEntry(rootId, value: .init(kind: "app.note", model: model("c")))
            _ = try await tx.appendEntry(rootId, value: .init(kind: "app.head", model: model("H"), head: .entry(a.id)))
            return [a.id, b.id, c.id]
        }, context: .background)
        let view = try await chat.root.context(context: .background)
        #expect(Array(view.entries.dropFirst().map(\.id)) == ids)
        #expect(view.contributions.map { $0.map(textOf) } == [["H"], ["a"], [], ["c"]])
        #expect(view.messages.map(textOf) == ["H", "a", "c"])
        chat.setup.updateSettings { $0.compaction = .init(enabled: false, reserveTokens: 1000, keepRecentTokens: 1, backgroundTokens: 0) }
        _ = try await interactionSummary(chat)
        #expect(textOf(chat.script.summaryRequests[0].messages[1])?.contains("<conversation>\n[User]: H\n\n[User]: a\n</conversation>") == true)
        try await chat.harness.close(context: .background)
    }
}
