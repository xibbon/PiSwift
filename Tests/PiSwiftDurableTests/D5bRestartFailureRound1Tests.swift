import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private final class D5bResumedPollModels: DurableModels {
    let base: FakeDurableModels
    private let fetched = Mutex<[String]>([])
    init(_ base: FakeDurableModels) { self.base = base }
    var handles: [String] { fetched.withLock { $0 } }
    func getModel(provider: String, modelId: String) -> Model? { base.getModel(provider: provider, modelId: modelId) }
    func streamSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) -> AssistantMessageEventStream {
        base.streamSimple(model: model, context: context, options: options)
    }
    func fetchDeferred(model: Model, handle: DeferredHandle, options: DeferredFetchOptions) async -> AssistantMessage {
        fetched.withLock { $0.append(handle.id) }
        return chatAssistant("deferred answer")
    }
    func cancelDeferred(model: Model, handle: DeferredHandle, options: DeferredCancelOptions) async throws {
        try await base.cancelDeferred(model: model, handle: handle, options: options)
    }
}

@Suite("PiSwiftDurableTests.D5bRestartFailureRound1", .serialized)
struct D5bRestartFailureRound1Tests {
    private struct Seed: Sendable { let submission: SubmissionID; let task: TaskID; let user: EntryID }

    private func seed(_ path: URL, setup: HarnessChatSetup, checkpoint: @escaping @Sendable (EntryID) -> GenerationCheckpoint,
                      partial: String? = nil, earlierPartial: String? = nil,
                      previousRestarts: Int = 0) async throws -> Seed {
        let opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        let ids = try await opened.root.commit({ tx in
            let user = try await tx.appendEntry(opened.root.id, value: EntryDraft(kind: userEntry.kind,
                model: EntryRecord.encodeMessages([.user(.init(content: .text("hi"), timestamp: 1))])))
            if let earlierPartial {
                let message = chatAssistant(earlierPartial, reason: .aborted)
                _ = try await tx.appendEntry(opened.root.id, value: EntryDraft(kind: assistantEntry.kind,
                    model: EntryRecord.encodeMessages([.assistant(message)])))
            }
            let input = try await tx.createSubmission(.input(conversationId: opened.root.id, state: .placed(entry: user.id)))
            let task = try await createGeneration(tx: tx, conversationId: opened.root.id)
            let live = try await tx.doc(LiveDoc, conversationId: opened.root.id)
            try live.set("run", JSONValue(encoding: LiveRun(taskId: task, inputs: [input.id], first: user.id)))
            let message = try partial.flatMap { try EntryRecord.encodeMessages([.assistant(chatAssistant($0))]).first?.objectValue }
            try live.set("generation", JSONValue(encoding: LiveGeneration(attempt: checkpoint(user.id).attempt ?? 1, message: message)))
            return Seed(submission: input.id, task: task, user: user.id)
        }, context: .background)
        try await opened.harness.close(context: .background)
        let storage = try await SqliteStorage.open(path: path.path)
        let record = try #require(await storage.task(ids.task, context: .background))
        let state = TaskState.running(checkpoint: try JSONValue(encoding: checkpoint(ids.user)))
        let replacement = previousRestarts == 0 ? record.replacing(state: state) :
            record.replacing(state: state, restarts: .some(Double(previousRestarts)))
        _ = try await storage.commit([.task(value: replacement)], context: .background)
        try await storage.close(context: .background)
        return ids
    }

    private func request(_ user: EntryID, attempt: Int = 1) -> GenerationCheckpoint {
        .init(phase: .request, attempt: attempt, model: .init(provider: "faux", modelId: "faux-1"),
              thinkingLevel: .off, streamOptions: .init(), cutoff: user)
    }

    private func poll(_ user: EntryID, at: Int64 = 10_000, attempt: Int = 1) -> GenerationCheckpoint {
        .init(phase: .poll, attempt: attempt, model: .init(provider: "faux", modelId: "faux-1"),
              thinkingLevel: .off, cutoff: user,
              handle: .init(.init(provider: "faux", modelId: "faux-1", api: "fixture-faux", id: "deferred:d5b")),
              pollAt: at)
    }

    @Test("charges the attempt: keeps the partial, waits for the retry backoff, and answers on the next attempt", .timeLimit(.minutes(1)))
    func chargedPartialBackoffAndAnswer() async throws {
        // v1.5.2 D5b harness-restart-failure.test.ts:141–178.
        let directory = try sqliteTestDirectory(), path = directory.appendingPathComponent("partial-retry.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(now: 1_000)
        let setup = HarnessChatSetup(settings: .init(retry: .init(enabled: true, maxRetries: 2, baseDelayMs: 60_000)), clock: clock)
        let ids = try await seed(path, setup: setup, checkpoint: { request($0) }, partial: "partial")
        setup.models.setResponses([.factory { request, _, _, _ in
            #expect(request.messages.map(\.role) == ["user"])
            return chatAssistant("answer")
        }])
        let opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        try opened.harness.resume()
        try await eventually { try await opened.harness.getTask(id: ids.task, context: .background)?.state.status == "sleeping" }
        let live = try #require(await generationLive(opened))
        #expect(live.generation?.retry?.error == "The host stopped while the model was answering, on attempt 1")
        #expect(live.generation?.retry?.at == 61_000)
        let before = try await allEntries(opened.root)
        #expect(before.map(\.kind) == ["pi.user", "pi.assistant"])
        guard case .assistant(let converted) = try before[1].messages()?.first else {
            Issue.record("Expected converted assistant partial"); return
        }
        #expect(converted.stopReason == .aborted)
        #expect(textOf(.assistant(converted)) == "partial")
        clock.advance(by: 60_000)
        let submission = try #require(try await opened.harness.submission(id: ids.submission, context: .background))
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(try await allEntries(opened.root).map(\.kind) == ["pi.user", "pi.assistant", "pi.assistant"])
        #expect(setup.models.calls().streamSimple == 1)
        try await opened.harness.close(context: .background)
    }

    @Test("sleeps the backoff of settings.retry before the next attempt", .timeLimit(.minutes(1)))
    func settingsBackoffSurvivesRequestDeath() async throws {
        // v1.5.2 D5b harness-restart-failure.test.ts:180–202.
        let directory = try sqliteTestDirectory(), path = directory.appendingPathComponent("backoff.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(now: 1_000_000)
        let setup = HarnessChatSetup(settings: .init(retry: .init(enabled: true, maxRetries: 2, baseDelayMs: 60_000)), clock: clock)
        let ids = try await seed(path, setup: setup, checkpoint: { request($0) }, partial: "partial")
        let opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        try opened.harness.resume()
        try await eventually { try await opened.harness.getTask(id: ids.task, context: .background)?.state.status == "sleeping" }
        let record = try #require(await opened.harness.getTask(id: ids.task, context: .background))
        guard case .sleeping(let checkpoint, let until, _) = record.state else { Issue.record("Expected retry sleep"); return }
        #expect(checkpoint["phase"] == "retry" && until == 1_060_000)
        #expect(record.storedRestarts == nil)
        #expect(try await generationLive(opened)?.generation?.retry?.at == 1_060_000)
        try await opened.harness.close(context: .background)
    }

    @Test("ends the run interrupted once no retry is left, keeping every partial", .timeLimit(.minutes(1)))
    func exhaustedRetryConvertsEveryPartial() async throws {
        // v1.5.2 D5b harness-restart-failure.test.ts:204–240.
        let directory = try sqliteTestDirectory(), path = directory.appendingPathComponent("exhausted.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = HarnessChatSetup(settings: .init(retry: .init(enabled: true, maxRetries: 1, baseDelayMs: 1)))
        let ids = try await seed(path, setup: setup, checkpoint: { request($0, attempt: 2) },
                                 partial: "second partial", earlierPartial: "first partial")
        let opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        try opened.harness.resume()
        let submission = try #require(try await opened.harness.submission(id: ids.submission, context: .background))
        let settled = try await submission.wait(context: .background)
        #expect(settled.reason == "interrupted")
        #expect(try JSONValue(encoding: settled.record)["detail"] == "The host stopped while the model was answering, on attempt 2")
        let entries = try await allEntries(opened.root)
        #expect(entries.map(\.kind) == ["pi.user", "pi.assistant", "pi.assistant"])
        for (entry, text) in zip(entries.dropFirst(), ["first partial", "second partial"]) {
            guard case .assistant(let message) = try entry.messages()?.first else { Issue.record("Expected partial assistant"); return }
            #expect(message.stopReason == .aborted && textOf(.assistant(message)) == text)
        }
        #expect(setup.models.calls().streamSimple == 0)
        try await opened.harness.close(context: .background)
    }

    @Test("ends a run whose generation is cut off restartLimit times outside a request", .timeLimit(.minutes(1)))
    func prepareCutOffEndsRestartLimit() async throws {
        // v1.5.2 D5b harness-restart-failure.test.ts:330–362.
        let directory = try sqliteTestDirectory(), path = directory.appendingPathComponent("prepare-limit.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = HarnessChatSetup(settings: .init(restartLimit: 1))
        let ids = try await seed(path, setup: setup, checkpoint: { _ in .init(phase: .prepare, attempt: 1) })
        let opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        try opened.harness.resume()
        let submission = try #require(try await opened.harness.submission(id: ids.submission, context: .background))
        let settled = try await submission.wait(context: .background)
        #expect(settled.reason == "restart_limit")
        #expect(try JSONValue(encoding: settled.record)["detail"] == "The generation was interrupted once in its prepare phase")
        #expect(try await generationLive(opened)?.runFailure?.reason == .restartLimit)
        try await eventually { setup.reports.infos.contains { $0.kind == "task_interrupted" } }
        try await opened.harness.close(context: .background)
    }

    @Test("cancels the deferred response when a crash during its poll ends the run", .timeLimit(.minutes(1)))
    func exhaustedPollCancelsHandle() async throws {
        // v1.5.2 D5b harness-restart-failure.test.ts:554–572.
        let directory = try sqliteTestDirectory(), path = directory.appendingPathComponent("poll-cancel.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = HarnessChatSetup(settings: .init(retry: .init(enabled: false)))
        let ids = try await seed(path, setup: setup, checkpoint: { poll($0) })
        let opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        try opened.harness.resume()
        let submission = try #require(try await opened.harness.submission(id: ids.submission, context: .background))
        #expect(try await submission.wait(context: .background).reason == "interrupted")
        #expect(setup.models.state().cancelledDeferred.map(\.id) == ["deferred:d5b"])
        #expect(setup.models.calls().fetchDeferred == 0)
        try await opened.harness.close(context: .background)
    }

    @Test("charges a crash during a poll's fetch, then polls the same deferred response again", .timeLimit(.minutes(1)))
    func chargedPollRetriesSavedHandle() async throws {
        // v1.5.2 D5b harness-restart-failure.test.ts:523–552. The pre-event
        // running poll is seeded; this model records the resumed fetch.
        let directory = try sqliteTestDirectory(), path = directory.appendingPathComponent("poll-retry.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(now: 1_000)
        let setup = HarnessChatSetup(settings: .init(retry: .init(enabled: true, maxRetries: 2, baseDelayMs: 1)), clock: clock)
        let ids = try await seed(path, setup: setup, checkpoint: { poll($0, at: 1_000) })
        let model = D5bResumedPollModels(setup.models)
        let opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup, models: model)
        try opened.harness.resume()
        try await eventually { try await opened.harness.getTask(id: ids.task, context: .background)?.state.status == "sleeping" }
        let record = try #require(await opened.harness.getTask(id: ids.task, context: .background))
        guard case .sleeping(let checkpoint, _, _) = record.state else { Issue.record("Expected poll retry"); return }
        #expect(checkpoint["phase"] == "retry" && checkpoint["poll"]?["handle"]?["id"] == "deferred:d5b")
        #expect(try await generationLive(opened)?.generation?.retry?.error == "The host stopped while the deferred answer was fetched, on attempt 1")
        clock.advance(by: 1)
        let submission = try #require(try await opened.harness.submission(id: ids.submission, context: .background))
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(model.handles == ["deferred:d5b"])
        #expect(setup.models.calls().streamSimple == 0)
        #expect(setup.models.state().cancelledDeferred.isEmpty)
        let answer = try #require(await allEntries(opened.root).last)
        #expect(try textOf(answer.messages()?.first) == "deferred answer")
        try await opened.harness.close(context: .background)
    }

    @Test("charges an interrupted poll even when the clock moved backwards", .timeLimit(.minutes(1)))
    func reversedClockStillChargesPoll() async throws {
        // v1.5.2 D5b harness-restart-failure.test.ts:574–594.
        let directory = try sqliteTestDirectory(), path = directory.appendingPathComponent("poll-reversed.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = HarnessChatSetup(settings: .init(retry: .init(enabled: false)), clock: TestClock(now: 1_010))
        let ids = try await seed(path, setup: first, checkpoint: { poll($0, at: 1_010) })
        let setup = HarnessChatSetup(settings: .init(retry: .init(enabled: false)), clock: TestClock(now: 1_000))
        let opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        try opened.harness.resume()
        let submission = try #require(try await opened.harness.submission(id: ids.submission, context: .background))
        #expect(try await submission.wait(context: .background).reason == "interrupted")
        #expect(setup.models.calls().fetchDeferred == 0)
        try await opened.harness.close(context: .background)
    }

    @Test("drops the partial past the limit, where converting it may be what keeps failing", .timeLimit(.minutes(1)))
    func beyondRestartLimitDropsPartial() async throws {
        // v1.5.2 D5b harness-restart-failure.test.ts:648–669.
        let directory = try sqliteTestDirectory(), path = directory.appendingPathComponent("drop-partial.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = HarnessChatSetup(settings: .init(restartLimit: 2))
        let ids = try await seed(path, setup: setup, checkpoint: { request($0) },
                                 partial: "will drop", previousRestarts: 2)
        let opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        try opened.harness.resume()
        let submission = try #require(try await opened.harness.submission(id: ids.submission, context: .background))
        #expect(try await submission.wait(context: .background).reason == "restart_limit")
        #expect(try await allEntries(opened.root).map(\.kind) == ["pi.user"])
        #expect(try await generationLive(opened)?.generation == nil)
        try await opened.harness.close(context: .background)
    }

    @Test("charges a request once when a crash is followed by a clean close before the charge", .timeLimit(.minutes(1)))
    func crashThenCleanCloseChargesOnce() async throws {
        // v1.5.2 D5b harness-restart-failure.test.ts:596–619.
        let directory = try sqliteTestDirectory(), path = directory.appendingPathComponent("crash-close.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(now: 1_000)
        let setup = HarnessChatSetup(settings: .init(retry: .init(enabled: true, maxRetries: 3, baseDelayMs: 1)), clock: clock)
        let ids = try await seed(path, setup: setup, checkpoint: { request($0) }, partial: "partial")
        let paused = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        #expect(try await paused.harness.getTask(id: ids.task, context: .background)?.storedRestarts == 1)
        try await paused.harness.close(context: .background)
        setup.models.setResponses([.message(chatAssistant("answer"))])
        let resumed = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        #expect(try await resumed.harness.getTask(id: ids.task, context: .background)?.storedRestarts == 1)
        try resumed.harness.resume()
        try await eventually { try await resumed.harness.getTask(id: ids.task, context: .background)?.state.status == "sleeping" }
        #expect(try await generationLive(resumed)?.generation?.retry?.error == "The host stopped while the model was answering, on attempt 1")
        clock.advance(by: 1)
        let submission = try #require(try await resumed.harness.submission(id: ids.submission, context: .background))
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(setup.models.calls().streamSimple == 1)
        try await resumed.harness.close(context: .background)
    }

    @Test("ends a run restart_limit when charging the interrupted request keeps being cut off", .timeLimit(.minutes(1)))
    func repeatedChargeAtLimitKeepsPartial() async throws {
        // v1.5.2 D5b harness-restart-failure.test.ts:621–646.
        let directory = try sqliteTestDirectory(), path = directory.appendingPathComponent("charge-limit.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = HarnessChatSetup(settings: .init(restartLimit: 1))
        let ids = try await seed(path, setup: setup, checkpoint: { request($0) }, partial: "partial")
        let opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        try opened.harness.resume()
        let submission = try #require(try await opened.harness.submission(id: ids.submission, context: .background))
        #expect(try await submission.wait(context: .background).reason == "restart_limit")
        #expect(try JSONValue(encoding: await submission.status(context: .background))["detail"] == "The generation was interrupted once in its request phase")
        let entries = try await allEntries(opened.root)
        #expect(entries.map(\.kind) == ["pi.user", "pi.assistant"])
        guard case .assistant(let message) = try entries[1].messages()?.first else { Issue.record("Expected converted partial"); return }
        #expect(message.stopReason == .aborted && textOf(.assistant(message)) == "partial")
        #expect(setup.models.calls().streamSimple == 0)
        try await opened.harness.close(context: .background)
    }

    @Test("ends a run someone aborted as aborted when its abort handler is cut off restartLimit times", .timeLimit(.minutes(1)))
    func abortHandlerCutOffKeepsAbortedReason() async throws {
        // v1.5.2 D5b harness-restart-failure.test.ts:671–710.
        let directory = try sqliteTestDirectory(), path = directory.appendingPathComponent("abort-cutoff.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = HarnessChatSetup(settings: .init(restartLimit: 2))
        let ids = try await seed(path, setup: setup, checkpoint: { poll($0) })
        let storage = try await SqliteStorage.open(path: path.path)
        let record = try #require(await storage.task(ids.task, context: .background))
        _ = try await storage.commit([.task(value: record.replacing(abortRequested: true, restarts: .some(1)))], context: .background)
        try await storage.close(context: .background)
        let opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        #expect(try await opened.harness.getTask(id: ids.task, context: .background)?.storedRestarts == 2)
        try opened.harness.resume()
        let submission = try #require(try await opened.harness.submission(id: ids.submission, context: .background))
        let settled = try await submission.wait(context: .background)
        let detail = "Abort handler of task \(ids.task.rawValue) (pi.generation) was cut off 2 times"
        #expect(settled.reason == "aborted")
        #expect(try JSONValue(encoding: settled.record)["detail"] == .string(detail))
        #expect(try await generationLive(opened)?.runFailure?.reason == .aborted)
        #expect(try await generationLive(opened)?.runFailure?.detail == detail)
        let task = try #require(await opened.harness.getTask(id: ids.task, context: .background))
        #expect(task.state.outcome?.status == "faulted")
        try await eventually { setup.reports.infos.contains { $0.kind == "task_faulted" } }
        try await opened.harness.close(context: .background)
    }

    @Test("resolves the settings no more often than before: only a task that was cut off reads the limit", .timeLimit(.minutes(1)))
    func normalRoundsDoNotResolveRestartLimitPerTask() async throws {
        // v1.5.2 D5b harness-restart-failure.test.ts:737–777.
        let setup = HarnessChatSetup(), resolutions = Mutex(0)
        try installHarnessTool(harnessTestTool("echo"), setup: setup)
        var responses: [FakeDurableResponseStep] = []
        for index in 0...5 {
            responses.append(.message(try toolCalls([("echo", [:], "c\(index)")])))
            responses.append(.message(chatAssistant("done")))
        }
        setup.models.setResponses(responses)
        let provider = HarnessSettingsProvider { resolutions.withLock { $0 += 1 }; return setup.settings }
        let harness = try await Harness.open(storage: MemoryStorage(),
            options: .init(models: setup.models, registry: setup.registry, settings: provider), context: .background)
        let root = try await harness.root(options: .init(agent: .init(model: .set(.init(provider: "faux", modelId: "faux-1")))), context: .background)
        #expect(try await root.submit(.input(content: .text("warm up")), context: .background).wait(context: .background).status == "done")
        resolutions.withLock { $0 = 0 }
        for index in 0..<5 {
            #expect(try await root.submit(.input(content: .text("round \(index)")), context: .background).wait(context: .background).status == "done")
        }
        // The tag's Proxy counts only `extensions` reads (<=49 per run).
        // Swift's provider callback counts *all* settings reads. The same
        // script at 1de58fd called it 841 times; this run must not add reads.
        #expect(resolutions.withLock { $0 } <= 841)
        try await harness.close(context: .background)
    }
}
