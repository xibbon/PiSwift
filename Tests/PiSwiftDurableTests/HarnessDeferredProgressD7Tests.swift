import Testing
import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite("PiSwiftDurableTests.HarnessDeferredProgressD7", .timeLimit(.minutes(1)))
struct HarnessDeferredProgressD7Tests {
    @Test func generationPartialsStayInMemoryUntilPersistWithinMs() async throws {
        let clock = TestClock(now: 1_000)
        let setup = HarnessChatSetup(settings: .init(progress: .init(persistWithinMs: 400)), clock: clock)
        let models = HarnessManualModels(base: setup.models)
        let storage = ControlledStorage()
        let opened = try await openChat(storage: storage, setup: setup, models: models)
        let memory = SessionTestLog<String>()
        let own = try opened.harness.session.observeCommits { publication, _ in
            guard case .memory(let documents) = publication else { return }
            for document in documents where document.record.kind == "pi.live" {
                if let text = document.value?["generation"]?["message"]?["content"]?[0]?["text"]?.stringValue {
                    memory.append(text)
                }
            }
        }
        let input = try await generationSubmit(opened)
        try await eventually { models.seen.withLock { !$0.isEmpty } }
        let before = await storage.commits.count
        generationPartial(models, text: "word")
        try await eventually { clock.pendingSleeperCount >= 2 }
        clock.advance(by: 100)
        try await eventually { memory.values.contains("word") }
        #expect(await storage.commits.count == before)
        clock.advance(by: 300)
        try await eventually { await storage.commits.count > before }
        generationFinal(models, text: "word")
        _ = try await input.wait(context: .background)
        own.cancel(); try await opened.harness.close(context: .background)
    }

    @Test func cleanCloseStoresHeldGenerationPartial() async throws {
        let clock = TestClock(now: 1_000)
        let setup = HarnessChatSetup(settings: .init(progress: .init(persistWithinMs: .infinity)), clock: clock)
        let models = HarnessManualModels(base: setup.models)
        let storage = ControlledStorage()
        let opened = try await openChat(storage: storage, setup: setup, models: models)
        _ = try await generationSubmit(opened)
        try await eventually { models.seen.withLock { !$0.isEmpty } }
        generationPartial(models, text: "held")
        try await eventually { clock.pendingSleeperCount == 1 }
        clock.advance(by: 100)
        try await eventually { try await generationLive(opened)?.generation?.message?["content"]?[0]?["text"] == .string("held") }
        let before = await storage.commits.count
        try await opened.harness.close(context: .background)
        #expect(await storage.commits.count > before)
    }

    @Test(.timeLimit(.minutes(1))) func crashBeforeFirstStoreLeavesNoAbortedEntry() async throws {
        // v1.5.2 D7 harness-deferred-progress.test.ts:158-175.
        let clock = TestClock(now: 1_000)
        let setup = HarnessChatSetup(settings: .init(progress: .init(persistWithinMs: .infinity)), clock: clock)
        let manual = HarnessManualModels(base: setup.models)
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("crash-before-first.sqlite").path
        let storage = ControlledStorage(try await SqliteStorage.open(path: path))
        let first = try await openChat(storage: storage, setup: setup, models: manual)
        let input = try await generationSubmit(first)
        try await eventually { manual.seen.withLock { !$0.isEmpty } }
        let before = await storage.commits.count
        generationPartial(manual, text: "held")
        try await eventually { clock.pendingSleeperCount == 1 }
        clock.advance(by: 100)
        try await eventually { try await generationLive(first)?.generation?.message != nil }
        #expect(await storage.commits.count == before)
        first.harness.session.fail(D7HarnessCrash())
        _ = await first.harness.closed
        setup.models.setResponses([.message(chatAssistant("answer"))])
        let reopened = ControlledStorage(try await SqliteStorage.open(path: path))
        let second = try await openChat(storage: reopened, setup: setup)
        try second.harness.resume()
        // v1.5.2 D7 generation.ts:508-551: a crashed request charges an attempt and sleeps for retry.
        try await eventually { try await generationLive(second)?.generation?.retry != nil && clock.pendingSleeperCount > 0 }
        clock.advance(by: 2_000)
        #expect(try await second.harness.submission(id: input.id, context: .background)?.wait(context: .background).status == "done")
        let answers = try await allEntries(second.root).filter { $0.kind == "pi.assistant" }
        #expect(answers.count == 1)
        #expect(textOf(try answers.first?.messages()?.first) == "answer")
        try await second.harness.close(context: .background)
    }

    @Test(.timeLimit(.minutes(1))) func crashAfterStoreConvertsPartialAndRetriesChargedAttempt() async throws {
        // v1.5.2 D7 harness-deferred-progress.test.ts:116-156.
        let clock = TestClock(now: 1_000)
        let setup = HarnessChatSetup(settings: .init(progress: .init(persistWithinMs: 150)), clock: clock)
        setup.updateSettings { $0.retry = .init(enabled: true, maxRetries: 5, baseDelayMs: 1) }
        let manual = HarnessManualModels(base: setup.models)
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("crash-after-first.sqlite").path
        let storage = ControlledStorage(try await SqliteStorage.open(path: path))
        let first = try await openChat(storage: storage, setup: setup, models: manual)
        let input = try await generationSubmit(first)
        try await eventually { manual.seen.withLock { !$0.isEmpty } }
        generationPartial(manual, text: "stored partial")
        try await eventually { clock.pendingSleeperCount >= 2 }
        clock.advance(by: 100)
        try await eventually { try await generationLive(first)?.generation?.message != nil }
        let before = await storage.commits.count
        clock.advance(by: 150)
        try await eventually { await storage.commits.count > before }
        first.harness.session.fail(D7HarnessCrash())
        _ = await first.harness.closed
        setup.models.setResponses([.message(chatAssistant("answer"))])
        let second = try await openChat(storage: ControlledStorage(try await SqliteStorage.open(path: path)), setup: setup)
        try second.harness.resume()
        try await eventually { try await generationLive(second)?.generation?.retry != nil && clock.pendingSleeperCount > 0 }
        clock.advance(by: 1)
        #expect(try await second.harness.submission(id: input.id, context: .background)?.wait(context: .background).status == "done")
        let answers = try await allEntries(second.root).filter { $0.kind == "pi.assistant" }
        #expect(answers.count == 2)
        #expect(textOf(try answers.first?.messages()?.first) == "stored partial")
        #expect(textOf(try answers.last?.messages()?.first) == "answer")
        try await second.harness.close(context: .background)
    }

    @Test(.timeLimit(.minutes(1))) func deferredResponsePollResumesAfterCrash() async throws {
        // v1.5.2 D7 harness-deferred-progress.test.ts:228-247.
        let clock = TestClock(now: 1_000)
        let setup = HarnessChatSetup(options: .init(deferred: .init(pollAfterMs: 60_000)), clock: clock)
        setup.updateSettings { $0.stream = .init(deferred: .init()) }
        setup.models.setResponses([.message(chatAssistant("deferred answer"))])
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("deferred-poll.sqlite").path
        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        let input = try await generationSubmit(first)
        try await eventually { try await generationLive(first)?.generation?.deferred != nil }
        first.harness.session.fail(D7HarnessCrash())
        _ = await first.harness.closed
        let second = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        clock.advance(by: 60_000)
        try second.harness.resume()
        let receipt = try #require(try await second.harness.submission(id: input.id, context: .background)?.wait(context: .background))
        #expect(receipt.status == "done")
        let answerId = try #require(receipt.answer)
        let answer = try await second.root.commit({ tx in try await tx.entry(answerId) }, context: .background)
        #expect(textOf(try answer?.messages()?.first) == "deferred answer")
        try await second.harness.close(context: .background)
    }

    @Test(.timeLimit(.minutes(1))) func storedPartialConvertsOnceThroughRepeatedCrashes() async throws {
        // v1.5.2 D7 harness-deferred-progress.test.ts:177-208.
        let clock = TestClock(now: 1_000)
        let setup = HarnessChatSetup(settings: .init(progress: .init(persistWithinMs: 150)), clock: clock)
        setup.updateSettings { $0.retry = .init(enabled: true, maxRetries: 5, baseDelayMs: 1) }
        let firstManual = HarnessManualModels(base: setup.models)
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("repeated-crash.sqlite").path
        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: setup, models: firstManual)
        let input = try await generationSubmit(first)
        try await eventually { firstManual.seen.withLock { !$0.isEmpty } }
        generationPartial(firstManual, text: "stored partial")
        try await eventually { clock.pendingSleeperCount >= 2 }
        clock.advance(by: 100)
        try await eventually { try await generationLive(first)?.generation?.message != nil }
        clock.advance(by: 150)
        try await eventually {
            guard let record = try await first.harness.session.storage.findDocument(
                .init(kind: "pi.live", scope: .conversation(conversationId: first.root.id)),
                at: .current, context: .background) else { return false }
            let stored = try await first.harness.session.storage.document(record.id, at: .current, context: .background)
            return stored?.value["generation"]?["message"]?["content"]?[0]?["text"] == .string("stored partial")
        }
        first.harness.session.fail(D7HarnessCrash()); _ = await first.harness.closed

        let unopened = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        #expect(try await generationLive(unopened)?.generation?.message?["content"]?[0]?["text"] == .string("stored partial"))
        unopened.harness.session.fail(D7HarnessCrash()); _ = await unopened.harness.closed

        setup.updateSettings { $0.progress = .init(persistWithinMs: .infinity) }
        let thirdManual = HarnessManualModels(base: setup.models)
        let third = try await openChat(storage: SqliteStorage.open(path: path), setup: setup, models: thirdManual)
        try third.harness.resume()
        try await eventually { try await generationLive(third)?.generation?.retry != nil && clock.pendingSleeperCount > 0 }
        clock.advance(by: 1)
        try await eventually { thirdManual.seen.withLock { !$0.isEmpty } }
        generationPartial(thirdManual, text: "lost partial")
        try await eventually { clock.pendingSleeperCount == 1 }
        clock.advance(by: 100)
        try await eventually { try await generationLive(third)?.generation?.message?["content"]?[0]?["text"] == .string("lost partial") }
        third.harness.session.fail(D7HarnessCrash()); _ = await third.harness.closed

        setup.models.setResponses([.message(chatAssistant("answer"))])
        let fourth = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        try fourth.harness.resume()
        try await eventually { try await generationLive(fourth)?.generation?.retry != nil && clock.pendingSleeperCount > 0 }
        // v1.5.2 D7 generation.ts:508-551: the next charged attempt uses the next retry backoff.
        clock.advance(by: 1_000)
        #expect(try await fourth.harness.submission(id: input.id, context: .background)?.wait(context: .background).status == "done")
        let answers = try await allEntries(fourth.root).filter { $0.kind == "pi.assistant" }
        #expect(answers.count == 2)
        #expect(textOf(try answers.first?.messages()?.first) == "stored partial")
        #expect(textOf(try answers.last?.messages()?.first) == "answer")
        try await fourth.harness.close(context: .background)
    }

    @Test(.timeLimit(.minutes(1))) func thirdPartyTaskStoresTheHeldPartialItRead() async throws {
        // v1.5.2 D7 harness-deferred-progress.test.ts:430-444.
        let clock = TestClock(now: 1_000)
        let setup = HarnessChatSetup(settings: .init(progress: .init(persistWithinMs: .infinity)), clock: clock)
        let audit = harnessOneStep("test.d7.audit") { _, runtime, context in
            try await runtime.commit({ tx, _ in
                let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
                let text = try live.child("generation")?.child("message")?.child("content")?.child(0)?.get("text")?.stringValue ?? ""
                _ = try await tx.appendEntry(runtime.conversationId, value: EntryDraft(kind: "test.d7.audit", data: .string(text)))
                return .terminal(outcome: .completed(result: .null))
            }, context: context)
        }
        try setup.registry.install(Extension(name: "D7-audit", tasks: [AnyTaskDefinition(audit)]))
        let manual = HarnessManualModels(base: setup.models)
        let storage = ControlledStorage()
        let opened = try await openChat(storage: storage, setup: setup, models: manual)
        let stored = SessionTestLog<CommitPublication>()
        let subscription = try opened.harness.observeCommits(.init(advance: { publication, _ in stored.append(publication) }, end: { _ in }))
        let input = try await generationSubmit(opened)
        try await eventually { manual.seen.withLock { !$0.isEmpty } }
        generationPartial(manual, text: "partial for audit")
        try await eventually { clock.pendingSleeperCount == 1 }
        clock.advance(by: 100)
        try await eventually { try await generationLive(opened)?.generation?.message != nil }
        let task = try await harnessStart(opened.root, audit)
        #expect(try await opened.harness.waitForTask(id: task, context: .background).outcome.status == "completed")
        try await eventually {
            stored.values.contains { publication in
                publication.changes.contains { if case .entry(let entry) = $0 { entry.kind == "test.d7.audit" } else { false } }
            }
        }
        let publication = try #require(stored.values.first { publication in
            publication.changes.contains { if case .entry(let entry) = $0 { entry.kind == "test.d7.audit" } else { false } }
        })
        #expect(publication.changes.contains { if case .document(let doc) = $0 { doc.record.kind == "pi.live" } else { false } })
        let auditEntry = try #require(try await allEntries(opened.root).first { $0.kind == "test.d7.audit" })
        #expect(auditEntry.data == .string("partial for audit"))
        generationFinal(manual)
        _ = try await input.wait(context: .background)
        subscription.detach(); try await opened.harness.close(context: .background)
    }
}

private struct D7HarnessCrash: Error {}
