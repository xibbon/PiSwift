import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessInboxIntegrationTests {
    @Test(arguments: [QueueMode.oneAtATime, .all])
    func finalBoundaryOrdersWritesBeforeUsersAndRespectsFollowUpMode(_ mode: QueueMode) async throws {
        let setup = HarnessChatSetup(settings: HarnessSettings(followUpMode: mode))
        let first = HarnessGatedResponse(message: chatAssistant("first"))
        setup.models.setResponses([first.step, .message(chatAssistant("second")), .message(chatAssistant("third"))])
        let chat = try await openChat(setup: setup)
        let input = try await chat.root.submit(.input(content: .text("a")), context: .background); await first.reached.wait()
        let f1 = try await chat.root.submit(.input(content: .text("f1")), context: .background)
        let write = try await chat.root.submit(.write(entry: EntryDraft(kind: "note", data: .string("w"))), context: .background)
        let f2 = try await chat.root.submit(.input(content: .text("f2"), whenBusy: .followUp), context: .background)
        first.release()
        let original = try await input.wait(context: .background), one = try await f1.wait(context: .background), two = try await f2.wait(context: .background)
        #expect(original.answer != one.answer)
        #expect((one.answer == two.answer) == (mode == .all))
        #expect(try await write.wait(context: .background).status == "done")
        let entries = try await allEntries(chat.root)
        #expect(Array(entries.prefix(5)).map(\.kind) == ["pi.user", "pi.assistant", "note", "pi.user", mode == .all ? "pi.user" : "pi.assistant"])
        #expect(try await chat.harness.snapshot(InboxDoc, conversationId: chat.root.id, context: .background)?.items.isEmpty == true)
        try await chat.harness.close(context: .background)
    }
    @Test func queueModeIsReadWhenBoundaryCommitRuns() async throws {
        let setup = HarnessChatSetup()
        let first = HarnessGatedResponse(message: chatAssistant("first"))
        setup.models.setResponses([first.step, .message(chatAssistant("second"))])
        let chat = try await openChat(setup: setup)
        _ = try await chat.root.submit(.input(content: .text("a")), context: .background); await first.reached.wait()
        let f1 = try await chat.root.submit(.input(content: .text("f1")), context: .background)
        let f2 = try await chat.root.submit(.input(content: .text("f2")), context: .background)
        let entered = SessionTestGate(), release = SessionTestGate()
        let occupying = Task { try await chat.root.commit({ _ in entered.release(); await release.wait() }, context: .background) }
        await entered.wait(); first.release()
        try await eventually { chat.harness.session.line.queuedCount > 0 }
        setup.updateSettings { $0.followUpMode = .all }; release.release(); try await occupying.value
        #expect(try await f1.wait(context: .background).answer == f2.wait(context: .background).answer)
        #expect(setup.models.state().callCount == 2)
        try await chat.harness.close(context: .background)
    }
    @Test func queuedResetIsPlacedAfterAnswer() async throws {
        let setup = HarnessChatSetup(); let first = HarnessGatedResponse(message: chatAssistant("answer"))
        setup.models.setResponses([first.step]); let chat = try await openChat(setup: setup)
        let input = try await chat.root.submit(.input(content: .text("a")), context: .background); await first.reached.wait()
        try await chat.root.reset(handoff: "new", context: .background)
        first.release(); #expect(try await input.wait(context: .background).status == "done")
        #expect(try await allEntries(chat.root).map(\.kind) == ["pi.user", "pi.assistant", "pi.reset"])
        #expect(try await chat.root.context(context: .background).entries.map(\.kind) == ["pi.reset"])
        try await chat.harness.close(context: .background)
    }
    @Test func withdrawingQueuedInputKeepsWriteForFinalBoundary() async throws {
        let setup = HarnessChatSetup(); let first = HarnessGatedResponse(message: chatAssistant("answer"))
        setup.models.setResponses([first.step]); let chat = try await openChat(setup: setup)
        let input = try await chat.root.submit(.input(content: .text("a")), context: .background); await first.reached.wait()
        let write = try await chat.root.submit(.write(entry: EntryDraft(kind: "note")), context: .background)
        let withdrawn = try await chat.root.submit(.input(content: .text("follow")), context: .background)
        #expect(try await withdrawn.abort(context: .background) == .aborted)
        #expect(try await withdrawn.wait(context: .background).reason == "aborted")
        #expect(try await chat.harness.snapshot(InboxDoc, conversationId: chat.root.id, context: .background)?.items.map(\.id) == [write.id])
        first.release(); _ = try await input.wait(context: .background)
        #expect(try await write.wait(context: .background).status == "done")
        #expect(try await allEntries(chat.root).map(\.kind) == ["pi.user", "pi.assistant", "note"])
        try await chat.harness.close(context: .background)
    }
    @Test(arguments: [false, true])
    func failedRunRetainsQueuedItemsAndNextAdmissionAppliesBoundary(_ steer: Bool) async throws {
        let setup = HarnessChatSetup(settings: HarnessSettings(retry: .init(enabled: false)))
        let first = HarnessGatedResponse(message: chatAssistant("", reason: .error, error: "permanent failure"))
        setup.models.setResponses([first.step, .message(chatAssistant("second")), .message(chatAssistant("third"))])
        let chat = try await openChat(setup: setup)
        let input = try await chat.root.submit(.input(content: .text("a")), context: .background); await first.reached.wait()
        let f = try await chat.root.submit(.input(content: .text("f")), context: .background)
        first.release(); #expect(try await input.wait(context: .background).reason == "model_error")
        #expect(try await f.status(context: .background).status == "queued")
        let next = try await chat.root.submit(.input(content: .text("g"), whenBusy: steer ? .steer : .reject), context: .background)
        let receipt = try await next.wait(context: .background)
        #expect(receipt.status == "done"); #expect(try await f.wait(context: .background).status == "done")
        if steer { #expect(try await f.wait(context: .background).answer == receipt.answer) }
        let users = try await allEntries(chat.root).filter { $0.kind == "pi.user" }.flatMap { try $0.messages() ?? [] }.map { textOf($0) }
        #expect(users == ["a", "f", "g"])
        try await chat.harness.close(context: .background)
    }
    @Test func queuedStaleWriteBehindFailedRunStartsWaitingFollowUp() async throws {
        let setup = HarnessChatSetup(settings: HarnessSettings(retry: .init(enabled: false)))
        let first = HarnessGatedResponse(message: chatAssistant("", reason: .error, error: "permanent failure"))
        setup.models.setResponses([first.step, .message(chatAssistant("second"))])
        let chat = try await openChat(setup: setup)
        let old = try await chat.root.commit({ tx in try await tx.appendEntry(chat.root.id, value: EntryDraft(kind: "note")) }, context: .background)
        try await chat.root.reset(context: .background)
        let input = try await chat.root.submit(.input(content: .text("a")), context: .background); await first.reached.wait()
        let f = try await chat.root.submit(.input(content: .text("f")), context: .background)
        first.release(); _ = try await input.wait(context: .background)
        let stale = try await chat.root.submit(.write(entry: EntryDraft(kind: "summary", head: .entry(old.id))), context: .background)
        #expect(try await stale.wait(context: .background).reason == "stale")
        #expect(try await f.wait(context: .background).status == "done")
        try await chat.harness.close(context: .background)
    }
    @Test(arguments: ["write", "reset", "followUp"])
    func onYieldContinuationSurvivesPlainWriteAndEndsForResetOrFollowUp(_ boundary: String) async throws {
        let setup = HarnessChatSetup(); let first = HarnessGatedResponse(message: chatAssistant("first"))
        setup.models.setResponses([first.step, .message(chatAssistant("second"))])
        try setup.registry.install(Extension(name: "continuation", hooks: [hook(generationTask, handlers: GenerationHooks(onYield: { message, _, _ in
            message.content.contains { if case .text(let text) = $0 { return text.text == "first" }; return false } ? GenerationYield(continue: .text("continue")) : nil
        }))]))
        let chat = try await openChat(setup: setup)
        let input = try await chat.root.submit(.input(content: .text("a")), context: .background); await first.reached.wait()
        var followUp: Submission?
        switch boundary {
        case "write": _ = try await chat.root.submit(.write(entry: EntryDraft(kind: "note")), context: .background)
        case "reset": try await chat.root.reset(context: .background)
        default: followUp = try await chat.root.submit(.input(content: .text("follow")), context: .background)
        }
        first.release(); let settled = try await input.wait(context: .background)
        if let followUp { _ = try await followUp.wait(context: .background) }
        let entries = try await allEntries(chat.root)
        let assistant = try entries.first { $0.id == settled.answer }?.messages()?.first
        #expect(textOf(assistant) == (boundary == "write" ? "second" : "first"))
        let texts = try entries.filter { $0.kind == "pi.user" }.flatMap { try $0.messages() ?? [] }.map { textOf($0) }
        #expect(texts == (boundary == "write" ? ["a", "continue"] : boundary == "reset" ? ["a"] : ["a", "follow"]))
        try await chat.harness.close(context: .background)
    }
    @Test func abortingRunTaskLeavesQueuedInputs() async throws {
        let setup = HarnessChatSetup(); let held = HarnessUnanswered(); setup.models.setResponses([held.step])
        let chat = try await openChat(setup: setup)
        let input = try await chat.root.submit(.input(content: .text("a")), context: .background); await held.reached.wait()
        let f = try await chat.root.submit(.input(content: .text("f")), context: .background)
        let run = try #require(try await chat.harness.snapshot(LiveDoc, conversationId: chat.root.id, context: .background)?.run)
        _ = try await chat.harness.abortTask(id: run.taskId, context: .background)
        #expect(try await input.wait(context: .background).reason == "aborted")
        #expect(try await f.status(context: .background).status == "queued")
        #expect(try await chat.harness.snapshot(InboxDoc, conversationId: chat.root.id, context: .background)?.items.map(\.id) == [f.id])
        try await chat.harness.close(context: .background)
    }
    @Test func queuedSubmissionsSurviveSQLiteReopen() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let setup = HarnessChatSetup(); let held = HarnessUnanswered(); setup.models.setResponses([held.step])
        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        _ = try await first.root.submit(.input(content: .text("a")), context: .background); await held.reached.wait()
        let f = try await first.root.submit(.input(content: .text("f")), context: .background)
        try await first.harness.close(context: .background)
        setup.models.setResponses([.message(chatAssistant("first")), .message(chatAssistant("second"))])
        let reopened = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        let handle = try #require(try await reopened.harness.submission(id: f.id, context: .background))
        #expect(try await handle.wait(context: .background).status == "done")
        #expect(try await reopened.harness.snapshot(InboxDoc, conversationId: reopened.root.id, context: .background)?.items.isEmpty == true)
        try await reopened.harness.close(context: .background)
    }
}
