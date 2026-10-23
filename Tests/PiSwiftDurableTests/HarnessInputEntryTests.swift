import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

// v1.3.0 harness-inbox.test.ts queuedNote. It must affect model context to queue.
func queuedInputNote(_ text: String) -> EntryDraft {
    EntryDraft(kind: "note", model: [["role": "user", "content": .string(text), "timestamp": 0]])
}
private func inputMention(_ text: String) -> InputEntry {
    InputEntry(kind: "chat.mention", data: ["author": "ann", "text": .string(text)])
}
private func inputTranscript(_ entries: [EntryRecord]) throws -> [[JSONValue]] {
    try entries.filter { $0.kind != "pi.system" }.map { entry in
        var row: [JSONValue] = [.string(entry.kind)]
        if let data = entry.data, !entry.kind.hasPrefix("pi.") { row.append(data) }
        let message = try entry.messages()?.first
        if message?.role != "toolResult", let text = textOf(message), !text.isEmpty { row.append(.string(text)) }
        return row
    }
}
private func inputInbox(_ opened: OpenChatResult) async throws -> [InboxItem] {
    try await opened.harness.snapshot(InboxDoc, conversationId: opened.root.id, context: .background)?.items ?? []
}
private func inputLog(_ requests: SessionTestLog<[String]>, _ reply: AssistantMessage) -> FakeDurableResponseStep {
    .factory { request, _, _, _ in
        requests.append(request.messages.map { "\($0.role):\(textOf($0) ?? "")" })
        return reply
    }
}
private func inputHold(_ setup: HarnessChatSetup, _ gate: HarnessChatSignal) throws -> AssistantMessage {
    try installHarnessTool(harnessTestTool("hold", execute: { _, _, _ in
        await gate.wait(); return .init(output: [.text(TextContent(text: "held"))])
    }), setup: setup)
    return try toolCalls([("hold", [:], "c1")])
}
private func inputToolRunning(_ opened: OpenChatResult) async throws {
    try await eventually { try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background)?.tools?.first?.status == .running }
}
private func inputPlaced(_ record: SubmissionRecord) -> EntryID? {
    switch record {
    case .input(_, _, _, .placed(let entry, _)), .input(_, _, _, .done(let entry, _, _)), .write(_, _, _, .done(let entry, _)): entry
    default: nil
    }
}

// All 11 cases from v1.3.0 harness-input-entries.test.ts.
@Suite struct HarnessInputEntryTests {
    @Test func idleInputUsesApplicationEntryAndUserMessage() async throws {
        let setup = HarnessChatSetup(clock: TestClock(now: 42)), requests = SessionTestLog<[String]>()
        setup.models.setResponses([inputLog(requests, chatAssistant("hi ann"))])
        let opened = try await openChat(setup: setup)
        let submission = try await opened.root.submit(.input(content: .text("ann: hi"), entry: inputMention("hi")), context: .background)
        let settled = try await submission.wait(context: .background), entries = try await allEntries(opened.root)
        #expect(try inputTranscript(entries) == [["chat.mention", ["author": "ann", "text": "hi"], "ann: hi"], ["pi.assistant", "hi ann"]])
        let placed = try #require(entries.first { $0.kind == "chat.mention" })
        #expect(placed.model == [["role": "user", "content": "ann: hi", "timestamp": 42]])
        #expect(settled.status == "done" && inputPlaced(settled.record) == placed.id && settled.answer == entries.last?.id)
        #expect(requests.values == [["user:ann: hi"]])
        let cut = try await opened.root.context(at: placed.id, context: .background)
        #expect(try EntryRecord.encodeMessages(cut.messages.filter { $0.role != "system" }) == placed.model)
        try await opened.harness.close(context: .background)
    }

    @Test func invalidKindWritesNothingAndWritesKeepBuiltInKinds() async throws {
        let opened = try await openChat(setup: HarnessChatSetup())
        let before = try await allEntries(opened.root).count
        for kind in ["", "pi.user", "pi.compaction"] {
            await #expect(throws: SessionError.self) { try await opened.root.submit(.input(content: .text("x"), entry: InputEntry(kind: kind)), context: .background) }
        }
        // A Swift String field rejects the upstream numeric kind before admission.
        #expect(throws: (any Error).self) { try JSONValue.object(["kind": 123]).decode(InputEntry.self) }
        #expect(try await allEntries(opened.root).count == before)
        #expect(try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background) == LiveState())
        try await opened.root.reset(context: .background)
        #expect(try await allEntries(opened.root).last?.kind == "pi.reset")
        try await opened.harness.close(context: .background)
    }

    @Test func decodedInputMetadataTakesOnlyKindAndData() async throws {
        let setup = HarnessChatSetup(), first = HarnessGatedResponse(message: chatAssistant("first"))
        setup.models.setResponses([.message(chatAssistant("idle")), first.step, .message(chatAssistant("queued"))])
        let opened = try await openChat(setup: setup)
        let entry = try JSONValue.object(["kind": "chat.mention", "model": [["role": "user", "content": "forged", "timestamp": 0]], "head": "self", "edits": [["target": 1, "action": "omit"]]]).decode(InputEntry.self)
        _ = try await opened.root.submit(.input(content: .text("idle"), entry: entry), context: .background).wait(context: .background)
        _ = try await opened.root.submit(.input(content: .text("a")), context: .background); await first.reached.wait()
        let queued = try await opened.root.submit(.input(content: .text("later"), entry: entry), context: .background)
        #expect(try JSONValue(encoding: await inputInbox(opened).last) == ["id": .number(Double(queued.id.rawValue)), "mode": "followUp", "content": "later", "entry": ["kind": "chat.mention"]])
        first.release(); _ = try await queued.wait(context: .background)
        let mentions = try await allEntries(opened.root).filter { $0.kind == "chat.mention" }
        #expect(mentions.count == 2)
        #expect(mentions.allSatisfy { $0.head == nil && $0.edits == nil && $0.model?.count == 1 })
        #expect(try mentions.map { textOf(try $0.messages()?.first) } == ["idle", "later"])
        try await opened.harness.close(context: .background)
    }

    @Test func busyInputsKeepMetadataAndPlaceAtTheirBoundaries() async throws {
        let setup = HarnessChatSetup(), gate = HarnessChatSignal()
        setup.models.setResponses([.message(try inputHold(setup, gate)), .message(chatAssistant("after tools")), .message(chatAssistant("follow-up"))])
        let opened = try await openChat(setup: setup), input = try await opened.root.submit(.input(content: .text("a")), context: .background)
        try await inputToolRunning(opened)
        let steer = try await opened.root.submit(.input(content: .text("s"), entry: inputMention("s"), whenBusy: .steer, requestId: "r-s"), context: .background)
        let follow = try await opened.root.submit(.input(content: .text("f"), entry: InputEntry(kind: "p2.input"), whenBusy: .followUp), context: .background)
        #expect(try await inputInbox(opened) == [InboxItem(id: steer.id, mode: .steer, content: "s", inputEntry: inputMention("s")), InboxItem(id: follow.id, mode: .followUp, content: "f", inputEntry: InputEntry(kind: "p2.input"))])
        #expect(try await opened.root.submit(.input(content: .text("other"), entry: inputMention("other"), whenBusy: .steer, requestId: "r-s"), context: .background).id == steer.id)
        await #expect(throws: ConversationBusy.self) { try await opened.root.submit(.input(content: .text("x"), entry: inputMention("x"), whenBusy: .reject), context: .background) }
        #expect(try await inputInbox(opened).count == 2)
        gate.signal(); _ = try await follow.wait(context: .background)
        let entries = try await allEntries(opened.root), answers = entries.filter { $0.kind == "pi.assistant" }
        #expect(try inputTranscript(entries) == [["pi.user", "a"], ["pi.assistant"], ["pi.tool-result"], ["chat.mention", ["author": "ann", "text": "s"], "s"], ["pi.assistant", "after tools"], ["p2.input", "f"], ["pi.assistant", "follow-up"]])
        #expect(try await input.wait(context: .background).answer == answers[1].id)
        #expect(try await steer.wait(context: .background).answer == answers[1].id)
        #expect(try inputPlaced(await steer.status(context: .background)) == entries.first { $0.kind == "chat.mention" }?.id)
        #expect(try await follow.wait(context: .background).answer == answers[2].id)
        #expect(try inputPlaced(await follow.status(context: .background)) == entries.first { $0.kind == "p2.input" }?.id)
        try await opened.harness.close(context: .background)
    }

    @Test func withdrawsCustomInputsIndividuallyAndOnAbort() async throws {
        let setup = HarnessChatSetup(), first = HarnessGatedResponse(message: chatAssistant("first"))
        setup.models.setResponses([first.step]); let opened = try await openChat(setup: setup)
        let input = try await opened.root.submit(.input(content: .text("a")), context: .background); await first.reached.wait()
        let withdrawn = try await opened.root.submit(.input(content: .text("w"), entry: inputMention("w")), context: .background)
        let aborted = try await opened.root.submit(.input(content: .text("x"), entry: inputMention("x")), context: .background)
        #expect(try await withdrawn.abort(context: .background) == .aborted)
        #expect(try await inputInbox(opened).map(\.id) == [aborted.id])
        try await opened.root.abort(context: .background)
        for submission in [withdrawn, aborted, input] { #expect(try await submission.wait(context: .background).reason == "aborted") }
        #expect(try await inputInbox(opened).isEmpty)
        #expect(try await allEntries(opened.root).allSatisfy { $0.kind != "chat.mention" })
        try await opened.harness.close(context: .background)
    }

    @Test func displayWriteDuringToolRunSettlesInTimeOrderAndDoesNotChangeRequests() async throws {
        let setup = HarnessChatSetup(), gate = HarnessChatSignal(), requests = SessionTestLog<[String]>()
        setup.models.setResponses([inputLog(requests, try inputHold(setup, gate)), inputLog(requests, chatAssistant("done"))])
        let opened = try await openChat(setup: setup), (stream, log) = try await eventListen(opened)
        let input = try await opened.root.submit(.input(content: .text("a")), context: .background)
        try await inputToolRunning(opened)
        let entry = EntryDraft(kind: "chat.message", data: ["author": "bob", "text": "lunch?"])
        let write = try await opened.root.submit(.write(entry: entry, requestId: "bob:1"), context: .background)
        let settled = try await write.status(context: .background)
        #expect(settled.status == "done"); #expect(try await inputInbox(opened).isEmpty)
        #expect(try inputTranscript(await allEntries(opened.root)) == [["pi.user", "a"], ["pi.assistant"], ["chat.message", ["author": "bob", "text": "lunch?"]]])
        try await eventually { log.events.contains { $0["type"] == "entry_appended" } }
        #expect(log.events.first { $0["type"] == "entry_appended" }?["entry"]?["id"] == .number(Double(try #require(inputPlaced(settled)).rawValue)))
        #expect(!log.types.contains("run_end"))
        #expect(try await opened.root.submit(.write(entry: entry, requestId: "bob:1"), context: .background).id == write.id)
        gate.signal(); _ = try await input.wait(context: .background)
        #expect(try inputTranscript(await allEntries(opened.root)) == [["pi.user", "a"], ["pi.assistant"], ["chat.message", ["author": "bob", "text": "lunch?"]], ["pi.tool-result"], ["pi.assistant", "done"]])
        #expect(requests.values == [["system:", "user:a"], ["system:", "user:a", "assistant:", "toolResult:held"]])
        _ = await stream.stop(); try await opened.harness.close(context: .background)
    }

    @Test func displayWriteWaitsBehindQueuedResetAndRemainsVisible() async throws {
        let setup = HarnessChatSetup(), first = HarnessGatedResponse(message: chatAssistant("first"))
        setup.models.setResponses([first.step]); let opened = try await openChat(setup: setup)
        let input = try await opened.root.submit(.input(content: .text("a")), context: .background); await first.reached.wait()
        try await opened.root.reset(context: .background)
        let chat = try await opened.root.submit(.write(entry: EntryDraft(kind: "chat.message", data: "hi")), context: .background)
        #expect(try await chat.status(context: .background).status == "queued")
        first.release(); _ = try await input.wait(context: .background)
        let settled = try await chat.wait(context: .background), entries = try await allEntries(opened.root)
        #expect(try #require(inputPlaced(settled.record)) > #require(entries.first { $0.kind == "pi.reset" }).id)
        #expect(try await opened.root.context(context: .background).entries.map(\.kind) == ["pi.reset", "chat.message"])
        let later = try await opened.root.submit(.write(entry: EntryDraft(kind: "chat.message", data: "again")), context: .background)
        #expect(try await later.status(context: .background).status == "done")
        try await opened.harness.close(context: .background)
    }

    @Test func displayWriteDuringPromptRenderDoesNotChangeRequest() async throws {
        let setup = HarnessChatSetup(), rendering = HarnessChatSignal(), render = HarnessChatSignal(), renders = Mutex(0), requests = SessionTestLog<[String]>()
        try setup.registry.install(Extension(name: "slow", sections: [section("slow") { _, _ in
            let count = renders.withLock { value in let count = value; value += 1; return count }
            if count == 1 { rendering.signal(); await render.wait() }
            return "SLOW"
        }]))
        setup.models.setResponses([inputLog(requests, chatAssistant("one")), inputLog(requests, chatAssistant("two"))])
        let opened = try await openChat(setup: setup)
        _ = try await opened.root.submit(.input(content: .text("a")), context: .background).wait(context: .background)
        let second = try await opened.root.submit(.input(content: .text("b")), context: .background); await rendering.wait()
        _ = try await opened.root.submit(.write(entry: EntryDraft(kind: "chat.message", data: "hi")), context: .background)
        render.signal(); _ = try await second.wait(context: .background)
        #expect(requests.values[1] == ["system:", "user:a", "assistant:one", "user:b"])
        #expect(try await allEntries(opened.root).map(\.kind) == ["pi.user", "pi.system", "pi.assistant", "pi.user", "chat.message", "pi.assistant"])
        try await opened.harness.close(context: .background)
    }

    @Test func displayWriteAfterFailureDoesNotPlaceQueuedInput() async throws {
        let setup = HarnessChatSetup(), first = HarnessGatedResponse(message: chatAssistant("", reason: .error, error: "invalid request"))
        setup.models.setResponses([first.step, .message(chatAssistant("for f"))]); let opened = try await openChat(setup: setup)
        let input = try await opened.root.submit(.input(content: .text("a")), context: .background); await first.reached.wait()
        let follow = try await opened.root.submit(.input(content: .text("f"), entry: inputMention("f")), context: .background)
        first.release(); #expect(try await input.wait(context: .background).reason == "model_error")
        try await opened.harness.waitForIdle(context: .background)
        let note = try await opened.root.submit(.write(entry: EntryDraft(kind: "note", data: "n")), context: .background)
        #expect(try await note.status(context: .background).status == "done")
        try await opened.harness.waitForIdle(context: .background)
        #expect(try await follow.status(context: .background).status == "queued")
        #expect(try await inputInbox(opened).map(\.id) == [follow.id])
        #expect(try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background) == LiveState())
        #expect(setup.models.state().callCount == 1)
        _ = try await opened.root.submit(.input(content: .text("g")), context: .background).wait(context: .background)
        #expect(try inputTranscript(await allEntries(opened.root)).filter { $0.first != "pi.assistant" } == [["pi.user", "a"], ["note", "n"], ["chat.mention", ["author": "ann", "text": "f"], "f"], ["pi.user", "g"]])
        try await opened.harness.close(context: .background)
    }

    @Test func queuedInputMetadataSurvivesSQLiteReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("D5-input-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("session.sqlite").path
        let setup = HarnessChatSetup(), first = HarnessGatedResponse(message: chatAssistant("first"))
        setup.models.setResponses([first.step, .message(chatAssistant("first again")), .message(chatAssistant("for f"))])
        let opened = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        _ = try await opened.root.submit(.input(content: .text("a")), context: .background); await first.reached.wait()
        let follow = try await opened.root.submit(.input(content: .text("f"), entry: inputMention("f")), context: .background)
        try await opened.harness.close(context: .background)
        let reopened = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        #expect(try await inputInbox(reopened).first { $0.id == follow.id }?.inputEntry == inputMention("f"))
        let handle = try #require(try await reopened.harness.submission(id: follow.id, context: .background))
        let settled = try await handle.wait(context: .background)
        let placed = try #require(try await allEntries(reopened.root).first { $0.kind == "chat.mention" })
        #expect(settled.status == "done" && inputPlaced(settled.record) == placed.id)
        #expect(placed.data == inputMention("f").data)
        #expect(placed.model?.first?["role"] == "user" && placed.model?.first?["content"] == "f")
        try await reopened.harness.close(context: .background)
        try FileManager.default.removeItem(at: directory)
    }

    @Test func displayWriteBypassesInboxButModelAndEditWritesQueue() async throws {
        let setup = HarnessChatSetup(), first = HarnessGatedResponse(message: chatAssistant("first"))
        setup.models.setResponses([first.step, .message(chatAssistant("second"))]); let opened = try await openChat(setup: setup)
        let input = try await opened.root.submit(.input(content: .text("a")), context: .background); await first.reached.wait()
        let follow = try await opened.root.submit(.input(content: .text("f")), context: .background)
        let model = try await opened.root.submit(.write(entry: queuedInputNote("m")), context: .background)
        let target = try #require(try await allEntries(opened.root).first { $0.kind == "pi.user" })
        let edit = try await opened.root.submit(.write(entry: EntryDraft(kind: "redact", edits: [.omit(target: target.id)])), context: .background)
        let note = try await opened.root.submit(.write(entry: EntryDraft(kind: "note", data: "n")), context: .background)
        #expect(try await note.status(context: .background).status == "done")
        #expect(try await inputInbox(opened).map(\.id) == [follow.id, model.id, edit.id])
        #expect(try await inputInbox(opened).map(\.mode) == [.followUp, .write, .write])
        first.release(); _ = try await follow.wait(context: .background)
        #expect(try inputTranscript(await allEntries(opened.root)) == [["pi.user", "a"], ["note", "n"], ["pi.assistant", "first"], ["note", "m"], ["redact"], ["pi.user", "f"], ["pi.assistant", "second"]])
        #expect(try await input.status(context: .background).status == "done")
        try await opened.harness.close(context: .background)
    }

    @Test func explicitEmptyModelOrEditsAreModelAffectingAndNullDataSurvivesCoding() throws {
        #expect(!isDisplayOnly(EntryDraft(kind: "note", model: [])))
        #expect(!isDisplayOnly(EntryDraft(kind: "note", edits: [])))
        let item = InboxItem(id: try SubmissionID(1), mode: .steer, content: "x", inputEntry: InputEntry(kind: "chat", data: .null))
        #expect(try JSONValue(encoding: item).decode(InboxItem.self) == item)
    }
}
