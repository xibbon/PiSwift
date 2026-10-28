import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite("PiSwiftDurableTests.E4CodemodePolicyClock")
struct E4CodemodePolicyClockTests {
    // Upstream session-definitions.test.ts:80. Omission fails at the initializer signature.
    @Test func explicitPoliciesWorkForSingletonsAndFamilies() async throws {
        let calls = SessionTestLog<Int>()
        let singleton = try SessionDocToken<JSONObject>(kind: "e4.singleton", version: 1, initial: { ["count": 0] },
            checkpointWhen: { _, _, info in calls.append(info.deltasSinceBase); return true })
        let family = try SessionDocFamilyToken<JSONObject, Int>(kind: "e4.family", version: 1, initial: { ["count": .number(Double($0))] },
            checkpointWhen: { _, _, info in calls.append(info.deltasSinceBase); return true })
        let opened = try await openTestSession()
        try await opened.session.commit({ tx in
            _ = try await tx.doc(singleton)
            _ = try await tx.doc(family, key: "a", seed: 2)
        }, context: .background)
        try await opened.session.commit({ tx in
            try await tx.doc(singleton).set("count", 1)
            try await tx.doc(family, key: "a", seed: 99).set("count", 3)
        }, context: .background)
        #expect(calls.values == [0, 0])
        #expect(try await opened.session.snapshot(singleton, context: .background)?["count"] == 1)
        #expect(try await opened.session.snapshot(family, key: "a", context: .background)?["count"] == 3)
        let writes = try #require(await opened.storage.commits.last)
        #expect(writes.filter { if case .documentChange(_, .base, _) = $0 { true } else { false } }.count == 2)
        try await opened.session.close(context: .background)
    }

    // Upstream codemode-checkpoints.test.ts:7. D4 covers the store boundary and historical reads.
    @Test func taskDocumentsKeepDeltasUntilRetirement() throws {
        let info = CheckpointInfo(deltasSinceBase: 1000)
        #expect(try !NestedCallDoc.definition.checkpointWhen([:], [], info))
        #expect(try !CodemodeRunDoc.definition.checkpointWhen([:], [], info))
        #expect(try !CodemodeJournalDoc.definition.checkpointWhen(["entries": []], [], info))
    }

    // Native proof of codemode.ts:403,456. Each open has a distinct clock in the same epoch.
    @Test(arguments: [false, true])
    func harnessStartAndStoredDeadlineSurviveReopen(_ expired: Bool) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("e4-clock.sqlite").path
        let epoch: Int64 = 1_700_123_000_000
        let firstClock = TestClock(now: epoch)
        let setup = HarnessChatSetup(clock: firstClock)
        let reached = HarnessChatSignal(), resumed = HarnessChatSignal()
        let sandbox = DeterministicCodemodeSandbox { state in
            state.seq == 0 ? .init(calls: [.init(target: .global, name: "hold")]) : .init(result: .init(value: 1))
        }
        let global = CodemodeGlobal(name: "hold") { _, _, context in
            if !resumed.isSignalled { reached.signal(); try await harnessToolAwaitAbort(context) }
            return 1
        }
        try setup.registry.install(createCodemodeExtension(options: .init(sandbox: sandbox, models: false, globals: [global])))
        // Use a long real watchdog interval. Only the Harness clock advances in this test.
        setup.models.setResponses([.message(e10Call("// @options: {\"timeout_ms\":60000}\nscript")), .message(chatAssistant("done"))])
        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        let submission = try await generationSubmit(first).id
        await reached.wait()
        let task = try await e4CodemodeTask(first)
        try await eventually {
            try await first.harness.snapshot(CodemodeJournalDoc, taskId: task, context: .background)?["firstIssued"] == 1
        }
        let start = try #require(try await first.harness.snapshot(CodemodeRunDoc, taskId: task, context: .background)?["start"])
        #expect(start["startedAt"] == .number(Double(epoch)))
        #expect(start["deadline"] == .number(Double(epoch + 60_000)))
        let firstOptions = try #require(await sandbox.starts.first).options
        #expect(firstOptions.startedAt == Double(epoch))
        #expect(firstOptions.timeoutMs == 60_000)
        try await first.harness.close(context: .background)

        let secondClock = TestClock(now: epoch + (expired ? 60_000 : 20_000))
        let secondSetup = HarnessChatSetup(registry: setup.registry, clock: secondClock)
        let second = try await openChat(storage: SqliteStorage.open(path: path), setup: secondSetup, models: setup.models)
        #expect(try await second.harness.snapshot(CodemodeRunDoc, taskId: task, context: .background)?["start"] == start)
        resumed.signal()
        try second.harness.resume()
        let pending = try #require(try await second.harness.submission(id: submission, context: .background))
        #expect(try await pending.wait(context: .background).status == "done")
        try await second.harness.waitForIdle(context: .background)
        let result = try #require(try harnessToolResults(await allEntries(second.root)).last)
        #expect(result.isError == expired)
        let starts = await sandbox.starts
        #expect(starts.count == (expired ? 1 : 2))
        if expired {
            #expect(result.content.contains { if case .text(let text) = $0 { text.text.contains("deadline passed while it was interrupted") } else { false } })
        } else {
            #expect(starts[1].options.startedAt == Double(epoch))
            #expect(starts[1].options.seed == firstOptions.seed)
            #expect(starts[1].options.timeoutMs == 40_000)
        }
        #expect(setup.reports.values.isEmpty)
        #expect(secondSetup.reports.values.isEmpty)
        try await second.harness.close(context: .background)
    }

    // Native proof of codemode.ts:554,809. Inspect the journal before task retirement.
    @Test func journalDeliveryAndWallTimeUseTheHarnessClock() async throws {
        let clock = TestClock(now: 1_700_123_000_000)
        let setup = HarnessChatSetup(clock: clock)
        let observed = SessionTestLog<JSONValue>()
        let sandbox = DeterministicCodemodeSandbox { state in
            if state.seq == 0 { return .init(calls: [.init(target: .global, name: "advance")]) }
            observed.append(.number(state.deliveries[0].now))
            return .init(result: .init(value: 1))
        }
        let global = CodemodeGlobal(name: "advance") { _, _, _ in clock.advance(by: 2250); return 1 }
        try setup.registry.install(createCodemodeExtension(options: .init(sandbox: sandbox, models: false, globals: [global])))
        try setup.registry.install(Extension(name: "e4-journal", hooks: [hook(ToolHooks(afterTool: { call, _, api, context in
            if call.name == "codemode" {
                if let journal = try await api.read.snapshot(CodemodeJournalDoc, taskId: api.taskId, context: context) {
                    observed.append(.object(journal))
                }
            }
            return nil
        }))]))
        setup.models.setResponses([.message(e10Call()), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup)
        try await e10Submit(opened)
        try await opened.harness.waitForIdle(context: .background)
        let message = try await e10Message(opened.root)
        #expect(e10Text(message).contains("Wall time 2.3 seconds"))
        #expect(observed.values.first == .number(Double(clock.now())))
        #expect(observed.values.last?["entries"]?[0]?["at"] == .number(Double(clock.now())))
        #expect(setup.reports.values.isEmpty)
        try await opened.harness.close(context: .background)
    }

    // Upstream codemode.test.ts:671. Await the late launch itself; no elapsed-time wait is needed.
    @Test(arguments: [false, true])
    func dropsGlobalResultAfterScriptFinishedBeforeReadingEndedClock(_ callFinished: Bool) async throws {
        let reached = HarnessChatSignal(), release = HarnessChatSignal()
        let reads = SessionTestLog<Int>()
        var api = try toolTestApi()
        api.now = { reads.append(1); throw TaskDefinitionError("The invocation has ended") }
        let sandbox = DeterministicCodemodeSandbox { state in
            state.seq == 0
                ? .init(calls: [.init(target: .global, name: "slowly"), .init(target: .global, name: "quickly")])
                : .init(result: .init(value: 1))
        }
        let run = try await sandbox.start(source: "script", name: "late", options: .init(startedAt: 1000, seed: 1,
            globals: [.init(name: "slowly"), .init(name: "quickly")]))
        let call = DurableCodemodeCall(options: .init(sandbox: sandbox, models: false, globals: [
            .init(name: "slowly", execute: { _, _, _ in reached.signal(); await release.wait(); return "late" })
        ]), api: api, context: .background)
        await call.e4Bind(run)
        let pending = Task { await call.launch(.init(id: 1, target: .global, name: "slowly")) }
        await reached.wait()
        try await run.deliver(seq: 1, now: 1000, id: 2, outcome: .success(nil))
        #expect(await run.result.value == 1)
        if callFinished { await call.e4Finish() }
        release.signal()
        await pending.value
        #expect(reads.values.isEmpty)
        #expect(await call.queue.isEmpty)
        #expect(await call.failure == nil)
    }
}

private func e4CodemodeTask(_ opened: OpenChatResult) async throws -> TaskID {
    let tasks = try await opened.harness.commit({ tx in try await tx.scanTasks(.init(kind: "pi.tool"), limit: 100).items }, context: .background)
    return try #require(tasks.first { $0.input["kind"] == "model" }).id
}

private extension DurableCodemodeCall {
    func e4Bind(_ run: any CodemodeRun) { self.run = run }
    func e4Finish() { finished = true }
}
