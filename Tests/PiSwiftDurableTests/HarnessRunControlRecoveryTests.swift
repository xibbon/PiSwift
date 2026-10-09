import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private func h6WaitForCancellation(_ token: CancellationToken) async throws -> AssistantMessage {
    let gate = SessionTestGate()
    let remove = token.onCancel { gate.release() }
    defer { remove() }
    await gate.wait()
    throw CancellationError()
}
private func h6WaitForAbort(_ signal: AbortSignal) async throws {
    let gate = SessionTestGate()
    let registration = signal.addAbortListener { _ in gate.release() }
    defer { signal.removeAbortListener(registration) }
    if signal.aborted { gate.release() }
    await gate.wait()
    try signal.throwIfAborted()
}
private func h6RecoveryPath() throws -> URL {
    let directory = try sqliteTestDirectory()
    return directory.appendingPathComponent("generation.sqlite")
}
private func h6RunTask(_ opened: OpenChatResult) async throws -> TaskID {
    let live = try #require(try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background))
    return try #require(live.run?.taskId)
}
private func h6Checkpoint(_ harness: Harness, _ id: TaskID) async throws -> GenerationCheckpoint {
    let record = try #require(try await harness.getTask(id: id, context: .background))
    let raw: JSONValue
    switch record.state {
    case .pending(let checkpoint, _), .running(let checkpoint, _), .waiting(let checkpoint, _, _, _): raw = checkpoint
    default: throw TaskDefinitionError("Expected a recoverable generation")
    }
    return try raw.decode(GenerationCheckpoint.self)
}
private func h6Reacquire(_ harness: Harness, _ id: SubmissionID) async throws -> Submission {
    try #require(try await harness.submission(id: id, context: .background))
}

@Suite struct HarnessRunControlRecoveryTests {
    // upstream harness-generation-recovery.test.ts:41.
    @Test func preparationInterruptedBeforeCommitRunsAgainOnReopen() async throws {
        let path = try h6RecoveryPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let setup = HarnessChatSetup(), reached = SessionTestGate(), first = Mutex(true)
        try setup.registry.install(Extension(name: "preamble", sections: [section("preamble") { _, context in
            let block = first.withLock { value in let old = value; value = false; return old }
            if block { reached.release(); try await h6WaitForAbort(try #require(context.abortSignal)) }
            return "p"
        }]))
        setup.models.setResponses([.message(chatAssistant("answer"))])
        var opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        let submitted = try await opened.root.submit(.input(content: .text("hi")), context: .background)
        await reached.wait()
        let taskId = try await h6RunTask(opened)
        try await opened.harness.close(context: .background)
        opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        let checkpoint = try await h6Checkpoint(opened.harness, taskId)
        #expect(checkpoint.phase == .prepare && checkpoint.attempt == 1)
        #expect(setup.models.calls().streamSimple == 0)
        let reacquired = try await h6Reacquire(opened.harness, submitted.id)
        #expect(try await reacquired.wait(context: .background).status == "done")
        #expect(try await allEntries(opened.root).map(\.kind) == ["pi.user", "pi.system", "pi.assistant"])
        try await opened.harness.close(context: .background)
    }

    // upstream harness-generation-recovery.test.ts:74.
    @Test func requestRecoveryKeepsPinnedOptionsAndCommittedMessages() async throws {
        let path = try h6RecoveryPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let setup = HarnessChatSetup(), reached = SessionTestGate(), timeouts = SessionTestLog<Int?>(), roles = SessionTestLog<[String]>()
        setup.updateSettings { $0.stream = .init(timeoutMs: 1234) }
        try setup.registry.install(Extension(name: "preamble", sections: [section("preamble", tag: false) { _, _ in "p" }]))
        setup.models.setResponses([
            .factory { _, options, _, _ in reached.release(); return try await h6WaitForCancellation(try #require(options?.signal)) },
            .factory { request, options, _, _ in
                roles.append(request.messages.map(\.role)); timeouts.append(options?.timeoutMs)
                return chatAssistant("answer")
            }
        ])
        var opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        let submitted = try await opened.root.submit(.input(content: .text("hi")), context: .background)
        await reached.wait()
        let taskId = try await h6RunTask(opened)
        try await opened.harness.close(context: .background)
        opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        let checkpoint = try await h6Checkpoint(opened.harness, taskId)
        #expect(checkpoint.phase == .request && checkpoint.attempt == 1 && checkpoint.thinkingLevel == .off)
        #expect(checkpoint.streamOptions?.timeoutMs == 1234)
        setup.updateSettings { $0.stream = .init(timeoutMs: 999) }
        #expect(try await h6Reacquire(opened.harness, submitted.id).wait(context: .background).status == "done")
        #expect(roles.values == [["system", "user"]] && timeouts.values == [1234])
        #expect(try await allEntries(opened.root).map(\.kind) == ["pi.user", "pi.system", "pi.assistant"])
        try await opened.harness.close(context: .background)
    }

    // upstream harness-generation-recovery.test.ts:124. The committed crash partial is an explicit fixture.
    @Test func recoveryConvertsCommittedPartialExactlyOnceAndKeepsOriginalRequest() async throws {
        let path = try h6RecoveryPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let setup = HarnessChatSetup(), reached = SessionTestGate(), roles = SessionTestLog<[String]>()
        setup.models.setResponses([
            .factory { _, options, _, _ in reached.release(); return try await h6WaitForCancellation(try #require(options?.signal)) },
            .factory { request, _, _, _ in roles.append(request.messages.map(\.role)); return chatAssistant("answer") }
        ])
        var opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        let submitted = try await opened.root.submit(.input(content: .text("hi")), context: .background)
        await reached.wait()
        var partialMessage = chatAssistant("durable partial")
        partialMessage.usage = Usage(input: 7, output: 11, cacheRead: 0, cacheWrite: 0, totalTokens: 18)
        let partial = try EntryRecord.encodeMessages([.assistant(partialMessage)])[0]
        let conversationId = opened.root.id
        try await opened.root.commit({ tx in
            let live = try await tx.doc(LiveDoc, conversationId: conversationId)
            try live.child("generation")!.set("message", partial)
        }, context: .background)
        try await opened.harness.close(context: .background)
        opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        #expect(try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background)?.generation?.message == partial.objectValue)
        #expect(try await h6Reacquire(opened.harness, submitted.id).wait(context: .background).status == "done")
        let entries = try await allEntries(opened.root)
        #expect(entries.map(\.kind) == ["pi.user", "pi.assistant", "pi.assistant"])
        let converted = try #require(entries[1].messages()?.first)
        if case .assistant(let message) = converted { #expect(message.stopReason == .aborted) } else { Issue.record("Expected assistant partial") }
        #expect(textOf(converted) == "durable partial" && roles.values == [["user"]])
        #expect(try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background) == LiveState())
        let assistantUsage = try entries.flatMap { try $0.messages() ?? [] }.compactMap { message -> Usage? in
            if case .assistant(let assistant) = message { return assistant.usage }; return nil
        }
        let usage = try #require(try await opened.harness.usage(context: .background).models["faux/faux-1"])
        #expect(usage.input == assistantUsage.reduce(0) { $0 + $1.input })
        #expect(usage.output == assistantUsage.reduce(0) { $0 + $1.output })
        #expect(usage.totalTokens == assistantUsage.reduce(0) { $0 + $1.totalTokens })
        try await opened.harness.close(context: .background)
        opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        #expect(try await allEntries(opened.root).count == 3)
        let reopenedUsage = try #require(try await opened.harness.usage(context: .background).models["faux/faux-1"])
        #expect(reopenedUsage.input == usage.input && reopenedUsage.output == usage.output && reopenedUsage.totalTokens == usage.totalTokens)
        try await opened.harness.close(context: .background)
    }

    // upstream harness-generation-recovery.test.ts:164.
    @Test func retryBackoffResumesAtStoredDeadline() async throws {
        let path = try h6RecoveryPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let clock = TestClock(now: 1000)
        let retained = HarnessChatSetup(clock: clock)
        retained.updateSettings { $0.retry = .init(enabled: true, maxRetries: 2, baseDelayMs: 60000) }
        retained.models.setResponses([.message(chatAssistant("", reason: .error, error: "503 Service Unavailable")), .message(chatAssistant("recovered"))])
        var opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: retained)
        let submitted = try await opened.root.submit(.input(content: .text("hi")), context: .background)
        let firstHarness = opened.harness, rootId = opened.root.id
        try await eventually { try await firstHarness.snapshot(LiveDoc, conversationId: rootId, context: .background)?.generation?.retry != nil }
        let taskId = try await h6RunTask(opened)
        try await opened.harness.close(context: .background)
        opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: retained)
        let checkpoint = try await h6Checkpoint(opened.harness, taskId)
        #expect(checkpoint.phase == .retry && checkpoint.until == 61000 && checkpoint.attempt == 1)
        clock.advance(by: 60000)
        #expect(try await h6Reacquire(opened.harness, submitted.id).wait(context: .background).status == "done")
        #expect(try await allEntries(opened.root).map(\.kind) == ["pi.user", "pi.assistant", "pi.assistant"])
        try await opened.harness.close(context: .background)
    }

    // upstream harness-generation-recovery.test.ts:201.
    @Test func deferredPollingResumesFromDurableHandle() async throws {
        let path = try h6RecoveryPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let clock = TestClock(now: 1000)
        let setup = HarnessChatSetup(options: .init(deferred: .init(pollAfterMs: 60000)), clock: clock)
        setup.updateSettings { $0.stream = .init(deferred: .init()) }
        setup.models.setResponses([.message(chatAssistant("deferred answer"))])
        var opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        let submitted = try await opened.root.submit(.input(content: .text("hi")), context: .background)
        let firstHarness = opened.harness, rootId = opened.root.id
        try await eventually { try await firstHarness.snapshot(LiveDoc, conversationId: rootId, context: .background)?.generation?.deferred != nil }
        let taskId = try await h6RunTask(opened)
        try await opened.harness.close(context: .background)
        opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        let checkpoint = try await h6Checkpoint(opened.harness, taskId)
        #expect(checkpoint.phase == .poll && checkpoint.pollAt == 61000 && checkpoint.attempt == 1)
        clock.advance(by: 60000)
        let receipt = try await h6Reacquire(opened.harness, submitted.id).wait(context: .background)
        #expect(receipt.status == "done")
        let answerId = try #require(receipt.answer), conversation = opened.root
        let answer = try await conversation.commit({ tx in try await tx.entry(answerId) }, context: .background)
        #expect(try textOf(answer?.messages()?.first) == "deferred answer")
        #expect(setup.models.calls().fetchDeferred == 1)
        try await opened.harness.close(context: .background)
    }

    // upstream harness-generation-recovery.test.ts:230.
    @Test(arguments: [false, true])
    func missingPinnedModelAfterReopenEndsRequestAndPoll(poll: Bool) async throws {
        let path = try h6RecoveryPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let clock = TestClock(now: 1000), reached = SessionTestGate()
        let setup = HarnessChatSetup(options: .init(deferred: .init(pollAfterMs: 60000)), clock: clock)
        if poll { setup.updateSettings { $0.stream = .init(deferred: .init()) }; setup.models.setResponses([.message(chatAssistant("deferred"))]) }
        else { setup.models.setResponses([.factory { _, options, _, _ in reached.release(); return try await h6WaitForCancellation(try #require(options?.signal)) }]) }
        var opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        let submitted = try await opened.root.submit(.input(content: .text("hi")), context: .background)
        if poll {
            let firstHarness = opened.harness, rootId = opened.root.id
            try await eventually { try await firstHarness.snapshot(LiveDoc, conversationId: rootId, context: .background)?.generation?.deferred != nil }
        } else { await reached.wait() }
        try await opened.harness.close(context: .background)
        let empty = FakeDurableModels(options: .init(provider: "empty"))
        opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup, models: empty)
        let receipt = try await h6Reacquire(opened.harness, submitted.id).wait(context: .background)
        #expect(receipt.status == "unanswered" && receipt.reason == "no_model")
        #expect(empty.calls().streamSimple == 0 && empty.calls().fetchDeferred == 0)
        try await opened.harness.close(context: .background)
    }

    // upstream harness-generation-recovery.test.ts:270.
    @Test func settledAnswerAndSubmissionRemainReadableAfterReopen() async throws {
        let path = try h6RecoveryPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let setup = HarnessChatSetup()
        try setup.registry.install(Extension(name: "preamble", sections: [section("preamble", tag: false) { _, _ in "You are terse." }]))
        setup.models.setResponses([.message(chatAssistant("42"))])
        var opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        let submitted = try await opened.root.submit(.input(content: .text("answer?")), context: .background)
        let receipt = try await submitted.wait(context: .background)
        #expect(receipt.status == "done")
        let answerId = try #require(receipt.answer), conversation = opened.root
        let answer = try await conversation.commit({ tx in try await tx.entry(answerId) }, context: .background)
        #expect(try textOf(answer?.messages()?.first) == "42")
        try await opened.harness.close(context: .background)
        opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        #expect(try await h6Reacquire(opened.harness, submitted.id).status(context: .background) == receipt.record)
        let reopenedRoot = opened.root
        #expect(try await reopenedRoot.commit({ tx in try await tx.entry(answerId) }, context: .background) == answer)
        #expect(setup.models.calls().streamSimple == 1)
        try await opened.harness.close(context: .background)
    }
}
