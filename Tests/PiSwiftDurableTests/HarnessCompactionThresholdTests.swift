import Testing
import Synchronization
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

let compactionBackgroundPolicy = CompactionPolicy(enabled: true, reserveTokens: 500, keepRecentTokens: 150, backgroundTokens: 1000)
let compactionBlockingPolicy = CompactionPolicy(enabled: true, reserveTokens: 300, keepRecentTokens: 150, backgroundTokens: 0)
let compactionOverflowText = "prompt is too long: 250000 tokens > 200000 maximum"
func compactionSetPolicy(_ chat: CompactionChat, _ policy: CompactionPolicy) {
    chat.setup.updateSettings { $0.compaction = .init(enabled: policy.enabled, reserveTokens: policy.reserveTokens,
        keepRecentTokens: policy.keepRecentTokens, backgroundTokens: policy.backgroundTokens) }
}
func compactionTasks(_ chat: CompactionChat) async throws -> [TaskRecord] {
    try await chat.harness.inspect(context: .background).tasks.map(\.record).filter { $0.kind == "pi.compaction" }
}
func compactionNewInput(_ chat: CompactionChat, tokens: Int = 200) async throws -> Submission {
    try await chat.root.submit(.input(content: .text(compactionText("u4", tokens))), context: .background)
}

@Suite struct HarnessCompactionThresholdTests {
    // Upstream 938.
    @Test func backgroundDoesNotBlockIdleOrOrdinaryAbort() async throws {
        let chat = try await compactionOpen(contextWindow: 2000)
        try await compactionHistory(chat)
        compactionSetPolicy(chat, compactionBackgroundPolicy)
        let gate = HarnessGatedResponse(message: chatAssistant("SUMMARY"))
        chat.script.appendSummary([gate.step])
        try await compactionTurn(chat, compactionText("u4", 100), compactionText("a4", 100))
        await gate.reached.wait()
        let child = try #require(await compactionTasks(chat).first)
        #expect(child.background && child.owner == nil)
        #expect(try await compactionLive(chat).compactions == [.init(taskId: child.id, reason: .threshold, blocking: false, attempt: 1)])
        try await chat.root.waitForIdle(context: .background)
        try await chat.root.abort(context: .background)
        #expect(try await chat.harness.getTask(id: child.id, context: .background)?.state.status == "running")
        gate.release()
        #expect(try await compactionOutcome(chat, child.id).status == "completed")
        #expect(try await compactionKinds(chat.root).last == "pi.compaction")
        #expect(compactionFirstUser(try await chat.root.context(context: .background).messages).contains("SUMMARY"))
        try await chat.harness.close(context: .background)
    }
    // Upstream 970: all three loop cases.
    @Test(arguments: ["disabled", "backgroundTokens is 0", "there is no cut"])
    func backgroundDoesNotStart(name: String) async throws {
        let chat = try await compactionOpen(contextWindow: 2000)
        try await compactionHistory(chat)
        var policy = compactionBackgroundPolicy
        if name == "disabled" { policy.enabled = false }
        if name == "backgroundTokens is 0" { policy.backgroundTokens = 0 }
        if name == "there is no cut" { policy.keepRecentTokens = 100_000 }
        compactionSetPolicy(chat, policy)
        try await compactionTurn(chat, compactionText("u4", 100), compactionText("a4", 100))
        #expect(try await compactionTasks(chat).isEmpty)
        #expect(chat.script.summaryRequests.isEmpty)
        try await chat.harness.close(context: .background)
    }
    // Upstream 981.
    @Test func listedManualPreventsBackgroundCompaction() async throws {
        let chat = try await compactionOpen(contextWindow: 2000)
        try await compactionHistory(chat)
        let gate = HarnessGatedResponse(message: chatAssistant("SUMMARY"))
        chat.script.appendSummary([gate.step])
        let manual = try await chat.root.compact(context: .background)
        await gate.reached.wait()
        compactionSetPolicy(chat, compactionBackgroundPolicy)
        try await compactionTurn(chat, compactionText("u4", 100), compactionText("a4", 100))
        #expect(try await compactionTasks(chat).map(\.id) == [manual])
        _ = try await chat.harness.abortTask(id: manual, context: .background)
        try await chat.harness.close(context: .background)
    }
    // Upstream 995, both internal loop paths.
    @Test(arguments: [false, true])
    func backgroundStopsWithExplicitAbort(conversation: Bool) async throws {
        let chat = try await compactionOpen(contextWindow: 2000)
        try await compactionHistory(chat)
        compactionSetPolicy(chat, compactionBackgroundPolicy)
        let gate = HarnessGatedResponse(message: chatAssistant("SUMMARY"))
        chat.script.appendSummary([gate.step])
        try await compactionTurn(chat, compactionText("u4", 100), compactionText("a4", 100))
        await gate.reached.wait()
        let child = try #require(await compactionTasks(chat).first)
        if conversation { try await chat.root.abort(background: true, context: .background) }
        else { _ = try await chat.harness.abortTask(id: child.id, context: .background) }
        #expect(try await compactionOutcome(chat, child.id).status == "aborted")
        #expect(try await compactionLive(chat).compactions == nil)
        try await chat.harness.close(context: .background)
    }
    // Upstream 1015.
    @Test func blockingWaitsAndAppendsBeforeRequest() async throws {
        let chat = try await compactionOpen(contextWindow: 1000)
        try await compactionHistory(chat)
        compactionSetPolicy(chat, compactionBlockingPolicy)
        try chat.setup.registry.install(Extension(name: "extra", sections: [section("extra") { _, _ in "EXTRA" }]))
        let gate = HarnessGatedResponse(message: chatAssistant("SUMMARY"))
        chat.script.appendSummary([gate.step]); chat.script.appendAgent([.message(chatAssistant("a4"))])
        let input = try await compactionNewInput(chat)
        await gate.reached.wait()
        let child = try #require(await compactionTasks(chat).first)
        let generation = try #require(await compactionLive(chat).run?.taskId)
        #expect(child.owner == generation && !child.background)
        #expect(try await chat.harness.getTask(id: generation, context: .background)?.state.status == "waiting")
        #expect(try await compactionKinds(chat.root).last == "pi.user")
        #expect(try await compactionLive(chat).compactions == [.init(taskId: child.id, reason: .threshold, blocking: true, attempt: 1)])
        gate.release()
        #expect(try await input.wait(context: .background).status == "done")
        #expect(try await compactionKinds(chat.root).suffix(3) == ["pi.compaction", "pi.system", "pi.assistant"])
        let request = try #require(chat.script.agentRequests.last).messages
        #expect(compactionFirstUser(request).contains("SUMMARY"))
        let systems = request.compactMap { message -> SystemMessage? in
            if case .system(let system) = message { return system }; return nil
        }
        #expect(systems.count == 1)
        #expect(systems.first?.sections?["preamble"] == "You are helpful.")
        #expect(systems.first?.sections?["extra"] == "<extra>\nEXTRA\n</extra>")
        #expect(try await compactionOutcome(chat, child.id).status == "completed")
        try await chat.harness.close(context: .background)
    }
    // Upstream 1054.
    @Test func keptPartAboveThresholdDoesNotCompactTwice() async throws {
        let chat = try await compactionOpen(contextWindow: 1000)
        try await compactionHistory(chat)
        var policy = compactionBlockingPolicy; policy.keepRecentTokens = 700
        compactionSetPolicy(chat, policy)
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        try await compactionTurn(chat, compactionText("u4", 400), "a4")
        #expect(chat.script.summaryRequests.count == 1)
        #expect(try await compactionKinds(chat.root).filter { $0 == "pi.compaction" }.count == 1)
        try await chat.harness.close(context: .background)
    }
    // Upstream 1072, 1084: both loop paths and direct abort.
    @Test(arguments: ["declines", "fails", "aborted directly"])
    func failedBlockingCompactionStillSendsRequest(how: String) async throws {
        let chat = try await compactionOpen(contextWindow: 1000)
        try await compactionHistory(chat)
        compactionSetPolicy(chat, compactionBlockingPolicy)
        let gate = HarnessGatedResponse(message: chatAssistant("SUMMARY"))
        if how == "declines" {
            try chat.setup.registry.install(Extension(name: "decline", hooks: [hook(CompactionHooks(beforeCompact: { _, _, _ in .decline }))]))
        } else { chat.script.appendSummary([how == "fails" ? .message(compactionFailure("bad request")) : gate.step]) }
        chat.script.appendAgent([.message(chatAssistant("a4"))])
        let input = try await compactionNewInput(chat)
        if how == "aborted directly" {
            await gate.reached.wait()
            _ = try await chat.harness.abortTask(id: #require(await compactionTasks(chat).first).id, context: .background)
        }
        #expect(try await input.wait(context: .background).status == "done")
        #expect(try await !compactionKinds(chat.root).contains("pi.compaction"))
        #expect(compactionFirstUser(try #require(chat.script.agentRequests.last).messages) == compactionText("u1", 100))
        try await chat.harness.close(context: .background)
    }
    // Upstream 1100: task and run outcomes; H9 event order is not available.
    @Test func conversationAbortStopsOwnedCompactionAndRun() async throws {
        let chat = try await compactionOpen(contextWindow: 1000)
        try await compactionHistory(chat)
        compactionSetPolicy(chat, compactionBlockingPolicy)
        let gate = HarnessGatedResponse(message: chatAssistant("SUMMARY"))
        chat.script.appendSummary([gate.step])
        let input = try await compactionNewInput(chat)
        await gate.reached.wait()
        let child = try #require(await compactionTasks(chat).first)
        let ended = Mutex<[(TaskID, Seq)]>([])
        let subscription = try chat.harness.subscribeCommits { publication, _ in
            for change in publication.changes {
                if case .task(let record) = change, record.state.status == "terminal" {
                    ended.withLock { $0.append((record.id, publication.seq)) }
                }
            }
        }
        defer { subscription.cancel() }
        let generation = try #require(await compactionLive(chat).run?.taskId)
        try await chat.root.abort(context: .background)
        #expect(try await input.wait(context: .background).reason == "aborted")
        #expect(try await compactionOutcome(chat, child.id).status == "aborted")
        let changes = ended.withLock { $0 }
        let childEnd = try #require(changes.first { $0.0 == child.id }?.1)
        let runEnd = try #require(changes.first { $0.0 == generation }?.1)
        #expect(childEnd < runEnd)
        try await chat.harness.close(context: .background)
    }
    // Upstream 1124.
    @Test func blockingMakesOlderBackgroundSummaryStale() async throws {
        let chat = try await compactionOpen(contextWindow: 2000)
        try await compactionHistory(chat)
        compactionSetPolicy(chat, compactionBackgroundPolicy)
        let gate = HarnessGatedResponse(message: chatAssistant("BACKGROUND"))
        chat.script.appendSummary([gate.step])
        try await compactionTurn(chat, compactionText("u4", 100), compactionText("a4", 100))
        await gate.reached.wait()
        let background = try #require(await compactionTasks(chat).first)
        chat.script.appendSummary([.message(chatAssistant("BLOCKING"))])
        try await compactionTurn(chat, compactionText("u5", 1000), "a5")
        #expect(compactionFirstUser(try await chat.root.context(context: .background).messages).contains("BLOCKING"))
        gate.release()
        let submission = try await compactionSubmission(chat, compactionOutcome(chat, background.id))
        #expect(try await submission.wait(context: .background).reason == "stale")
        try await chat.harness.close(context: .background)
    }
}
