import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
import Synchronization
import Testing
@testable import PiSwiftDurable

private struct ParkedToolRun: Sendable, Equatable {
    let wake: WakeReason?
    let checkpoint: JSONValue?

    init(_ api: ToolExecutionApi) {
        self.init(wake: api.wake, checkpoint: api.checkpoint)
    }

    init(wake: WakeReason? = nil, checkpoint: JSONValue? = nil) {
        self.wake = wake
        self.checkpoint = checkpoint
    }
}

// Ports the remaining cases in v1.6.0 harness-tool-parks.test.ts.
@Suite(.timeLimit(.minutes(1)))
struct HarnessToolParkTests {
    // Lines 248–289.
    @Test func waitsForAnOwnedChildAndWakesWithItsID() async throws {
        let setup = HarnessChatSetup()
        let done = try doneSignal()
        let ready = try done.key("child")
        let child = harnessOneStep("test.park-child") { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                try await runtime.sleep(signals: [ready],
                    checkpoint: JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined)), context: context)
            case .joined:
                try await runtime.commit({ _, _ in try completed(1) }, context: context)
            }
        }
        try setup.registry.install(Extension(name: "park-child", tasks: [AnyTaskDefinition(child)]))
        let children = SessionTestLog<TaskID>()
        let wakes = SessionTestLog<WakeReason?>()
        let spawn = try tool("spawn", replay: .safe) { _, api, context in
            wakes.append(api.wake)
            if api.wake != nil { return .result(.init(output: [.text(.init(text: "joined"))])) }
            let childID = try await api.createTask(child, input: 0,
                options: .init(ownership: .task(taskId: api.taskId)), context: context)
            children.append(childID)
            return .park(.wait(on: [childID], policy: .any))
        }
        try installHarnessTool(spawn, setup: setup)
        let opened = try await startChat(setup, calls: [("spawn", [:], "c1")])
        let submission = try await generationSubmit(opened, "go")
        _ = try await parkedTask(opened, status: .waiting)
        #expect(try await generationLive(opened)?.tools?.first?.status == .waiting)
        let childID = try #require(children.values.first)
        #expect(try await opened.harness.signal(taskId: childID, token: done, key: "child",
            value: ["text": "go"], context: .background) == .delivered)
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(wakes.values == [nil, .tasks(ended: [childID])])
        try await opened.harness.close(context: .background)
    }

    // Lines 293–316. The Swift enums exclude a mixed sleep and wait or a mixed park and result.
    @Test func invalidParksGoThroughAfterToolAndFailTheirTask() async throws {
        let parks: [(String, ToolPark)] = [
            ("empty", .sleep()),
            ("unowned", .wait(on: [try TaskID(1)], policy: .any)),
        ]
        for (name, park) in parks {
            let setup = HarnessChatSetup()
            let calls = SessionTestLog<TaskID>()
            let diagnosticCodes = SessionTestLog<String>()
            let registration = try tool(name) { _, api, _ in
                calls.append(api.taskId)
                return .park(park)
            }
            try installHarnessTool(registration, setup: setup)
            try setup.registry.install(Extension(name: "audit", hooks: [hook(ToolHooks(afterTool: { call, result, _, _ in
                #expect(call.name == name)
                #expect(result.isError == true)
                for diagnostic in result.diagnostics ?? [] {
                    if let code = diagnostic.code { diagnosticCodes.append(code) }
                }
                return nil
            }))]))
            let opened = try await startChat(setup, calls: [(name, [:], "c1")])
            let submission = try await generationSubmit(opened, "go")
            #expect(try await submission.wait(context: .background).status == "done")
            let result = try await firstResult(opened)
            #expect(result.isError)
            #expect(harnessToolText(result).contains("Tool \(name) returned an invalid park"))
            #expect(diagnosticCodes.values == ["invalid_park"])
            let id = try #require(calls.values.first)
            #expect(try await opened.harness.waitForTask(id: id, context: .background).outcome.status == "failed")
            #expect(try await generationLive(opened)?.tools?.first?.taskId == nil)
            try await opened.harness.close(context: .background)
        }
    }

    // Lines 321–341.
    @Test func rejectsASecondSleepOnTheSignalThatAlreadyWokeTheCall() async throws {
        let setup = HarnessChatSetup()
        let done = try doneSignal()
        let key = try done.key("k")
        let runs = SessionTestLog<ParkedToolRun>()
        let again = try tool("again") { _, api, _ in
            runs.append(.init(api))
            return .park(.sleep(signals: [key]))
        }
        try installHarnessTool(again, setup: setup)
        let opened = try await startChat(setup, calls: [("again", [:], "c1")])
        let submission = try await generationSubmit(opened, "go")
        let id = try await parkedTask(opened)
        #expect(try await opened.harness.signal(taskId: id, token: done, key: "k",
            value: ["text": "x"], context: .background) == .delivered)
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(runs.values == [.init(), .init(wake: .signal(signal: done.name, key: "k"))])
        #expect(harnessToolText(try await firstResult(opened)).contains("it already woke a wait"))
        #expect(try await opened.harness.waitForTask(id: id, context: .background).outcome.status == "failed")
        try await opened.harness.close(context: .background)
    }

    @Test func signalDeliveredBeforeParkCommitWakesTheTool() async throws {
        let setup = HarnessChatSetup()
        let done = try doneSignal()
        let key = try done.key("done")
        let entered = HarnessChatSignal()
        let release = HarnessChatSignal()
        defer { release.signal() }
        let runs = SessionTestLog<ParkedToolRun>()
        let registration = try tool("ci") { _, api, context in
            runs.append(.init(api))
            if api.wake == nil {
                #expect(try await api.readSignal(done, key: "done", context: context) == nil)
                entered.signal()
                await release.wait()
                return .park(.sleep(signals: [key], checkpoint: "started"))
            }
            guard case .value(let value) = try await api.readSignal(done, key: "done", context: context),
                  let message = value["text"]?.stringValue else {
                throw TaskDefinitionError("Expected the signal value")
            }
            return .result(.init(output: [.text(.init(text: message))]))
        }
        try installHarnessTool(registration, setup: setup)
        let opened = try await startChat(setup)
        let submission = try await generationSubmit(opened, "go")
        try await eventually { entered.isSignalled }
        let id = try #require(try await generationLive(opened)?.tools?.first?.taskId)
        #expect(try await opened.harness.getTask(id: id, context: .background)?.state.status == "running")
        #expect(try await opened.harness.signal(taskId: id, token: done, key: "done",
            value: ["text": "arrived early"], context: .background) == .delivered)
        release.signal()
        let waiter = settled { try await submission.wait(context: .background) }
        do { try await eventually { waiter.isSettled } }
        catch {
            try await opened.harness.close(context: .background)
            throw error
        }
        #expect(try waiter.result?.get().status == "done")
        #expect(runs.values == [.init(), .init(wake: .signal(signal: done.name, key: "done"), checkpoint: "started")])
        #expect(harnessToolText(try await firstResult(opened)) == "arrived early")
        try await opened.harness.close(context: .background)
    }

    // Lines 345–370.
    @Test func abortingAParkedCallPassesItsCheckpointAndEnvironmentToCancel() async throws {
        let setup = HarnessChatSetup()
        let cancels = SessionTestLog<ParkedToolRun>()
        let environments = SessionTestLog<String?>()
        let done = try doneSignal()
        let registration = try signalTool(done) { _, api, _ in
            cancels.append(.init(api))
            environments.append(api.env?.cwd)
        }
        try installHarnessTool(registration, setup: setup)
        let opened = try await startChat(setup, env: { _, _ in HarnessToolEnvironment(cwd: "/work") })
        let submission = try await generationSubmit(opened, "go")
        let id = try await parkedTask(opened)
        try await opened.root.abort(context: .background)
        #expect(try await submission.wait(context: .background).status == "unanswered")
        #expect(cancels.values == [.init(checkpoint: ["build": 1])])
        #expect(environments.values == ["/work"])
        #expect(harnessToolText(try await firstResult(opened)).contains("Tool ci was aborted"))
        #expect(try await opened.harness.waitForTask(id: id, context: .background).outcome.status == "aborted")
        try await opened.harness.close(context: .background)
    }

    // Lines 372–395.
    @Test func reportsCancelFailureAtRestartLimitOneAndStillAborts() async throws {
        let setup = HarnessChatSetup(settings: .init(restartLimit: 1))
        let cancels = SessionTestLog<ParkedToolRun>()
        let registration = try signalTool(doneSignal()) { _, api, _ in
            cancels.append(.init(api))
            throw TaskDefinitionError("cancel failed")
        }
        try installHarnessTool(registration, setup: setup)
        let opened = try await startChat(setup)
        let submission = try await generationSubmit(opened, "go")
        let id = try await parkedTask(opened)
        try await opened.root.abort(context: .background)
        #expect(try await submission.wait(context: .background).status == "unanswered")
        #expect(cancels.values == [.init(checkpoint: ["build": 1])])
        #expect(try await opened.harness.waitForTask(id: id, context: .background).outcome.status == "aborted")
        #expect(setup.reports.values.map { String(describing: $0) }.contains("cancel failed"))
        try await opened.harness.close(context: .background)
    }

    // Lines 397–429.
    @Test func abortCancelsAfterTheWokenInvocationCleansUp() async throws {
        let setup = HarnessChatSetup()
        let done = try doneSignal()
        let park = ToolPark.sleep(signals: [try done.key("done")], checkpoint: "first")
        let started = HarnessChatSignal()
        let cleanup = SessionTestLog<String>()
        let cancels = SessionTestLog<ParkedToolRun>()
        let registration = try tool("ci", cancel: { _, api, _ in
            cleanup.append("cancel")
            cancels.append(.init(api))
        }) { _, api, context in
            if api.wake == nil { return .park(park) }
            started.signal()
            do { try await harnessToolAwaitAbort(context) }
            catch {
                cleanup.append("execute")
                throw error
            }
            return .result(.init())
        }
        try installHarnessTool(registration, setup: setup)
        let opened = try await startChat(setup)
        let submission = try await generationSubmit(opened, "go")
        let id = try await parkedTask(opened)
        #expect(try await opened.harness.signal(taskId: id, token: done, key: "done",
            value: ["text": "x"], context: .background) == .delivered)
        try await eventually { started.isSignalled }
        try await opened.root.abort(context: .background)
        #expect(try await submission.wait(context: .background).status == "unanswered")
        #expect(cleanup.values == ["execute", "cancel"])
        #expect(cancels.values == [.init(checkpoint: "first")])
        try await opened.harness.close(context: .background)
    }

    // Lines 431–450.
    @Test func reportsAbortWhenTheParkedToolIsNoLongerInstalled() async throws {
        let setup = HarnessChatSetup()
        let cancels = SessionTestLog<ParkedToolRun>()
        let registration = try signalTool(doneSignal()) { _, api, _ in cancels.append(.init(api)) }
        let installed = Extension(name: "ci", tools: [registration])
        try setup.registry.install(installed)
        let opened = try await startChat(setup)
        let submission = try await generationSubmit(opened, "go")
        _ = try await parkedTask(opened)
        setup.registry.uninstall(installed)
        try await opened.root.abort(context: .background)
        #expect(try await submission.wait(context: .background).status == "unanswered")
        #expect(cancels.values.isEmpty)
        #expect(setup.reports.values.map { String(describing: $0) }
            .contains("Tool ci is not available: its parked call c1 was not cancelled"))
        try await opened.harness.close(context: .background)
    }

    // Lines 452–490.
    @Test func cancelsWithTheNewCheckpointWhenAbortWinsTheParkCommit() async throws {
        let setup = HarnessChatSetup()
        let done = try doneSignal()
        let park = ToolPark.sleep(signals: [try done.key("k")], checkpoint: "started")
        let entered = HarnessChatSignal()
        let release = HarnessChatSignal()
        defer { release.signal() }
        let cancels = SessionTestLog<ParkedToolRun>()
        let registration = try tool("race", cancel: { _, api, context in
            cancels.append(.init(api))
            #expect(context.abortSignal?.aborted != true)
        }) { _, _, _ in
            entered.signal()
            await release.wait()
            return .park(park)
        }
        try installHarnessTool(registration, setup: setup)
        let opened = try await startChat(setup, calls: [("race", [:], "c1")])
        let submission = try await generationSubmit(opened, "go")
        try await eventually { entered.isSignalled }
        let id = try #require(try await generationLive(opened)?.tools?.first?.taskId)
        let aborting = Task { try await opened.harness.abortTask(id: id, context: .background) }
        try await eventually {
            try await opened.harness.getTask(id: id, context: .background)?.abortRequested == true
        }
        release.signal()
        _ = try await aborting.value
        #expect(try await opened.harness.waitForTask(id: id, context: .background).outcome.status == "aborted")
        #expect(cancels.values == [.init(checkpoint: "started")])
        try await opened.root.abort(context: .background)
        _ = try await submission.wait(context: .background)
        try await opened.harness.close(context: .background)
    }

    // Lines 494–517.
    @Test func wakingAnUninstalledToolFailsAndPreservesItsDetailsAndDiagnostics() async throws {
        let setup = HarnessChatSetup()
        let done = try doneSignal()
        let runs = SessionTestLog<ParkedToolRun>()
        let installed = try Extension(name: "ci", tools: [signalTool(done, runs: runs)])
        try setup.registry.install(installed)
        let opened = try await startChat(setup)
        let submission = try await generationSubmit(opened, "go")
        let id = try await parkedTask(opened)
        setup.registry.uninstall(installed)
        #expect(try await opened.harness.signal(taskId: id, token: done, key: "done",
            value: ["text": "late"], context: .background) == .delivered)
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(try await opened.harness.waitForTask(id: id, context: .background).outcome.status == "failed")
        let result = try await firstResult(opened)
        #expect(result.isError)
        #expect(harnessToolDetails(result) == ["build": 1])
        #expect(harnessToolText(result).contains("[info] run 1"))
        #expect(harnessToolText(result).contains("Tool ci is not available"))
        #expect(setup.reports.values.map { String(describing: $0) }
            .contains("Tool ci is not available: its parked call c1 cannot run again"))
        #expect(runs.values == [.init()])
        try await opened.harness.close(context: .background)
    }

    // Lines 519–556.
    @Test func reopensAnInterruptedUnsafeWakeByCancellingItWithoutReplay() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("unsafe-park.sqlite").path
        let setup = HarnessChatSetup()
        let done = try doneSignal()
        let park = ToolPark.sleep(signals: [try done.key("done")], checkpoint: "first")
        let started = HarnessChatSignal()
        let runs = SessionTestLog<ParkedToolRun>()
        let cancels = SessionTestLog<ParkedToolRun>()
        let registration = try tool("ci", cancel: { _, api, _ in cancels.append(.init(api)) }) { _, api, context in
            runs.append(.init(api))
            if api.wake == nil { return .park(park) }
            try api.output(.text("rerun\n"), nil)
            try await api.details(["woken": true], context)
            started.signal()
            try await harnessToolAwaitAbort(context)
            return .result(.init())
        }
        try installHarnessTool(registration, setup: setup)
        let first = try await startChat(setup, storage: SqliteStorage.open(path: path))
        let submission = try await generationSubmit(first, "go")
        let id = try await parkedTask(first)
        #expect(try await first.harness.signal(taskId: id, token: done, key: "done",
            value: ["text": "x"], context: .background) == .delivered)
        try await eventually { started.isSignalled }
        first.harness.session.fail(TaskDefinitionError("Simulated process failure"))
        _ = await first.harness.closed

        let reopened = try await reopen(setup, path: path)
        let resumed = try #require(try await reopened.harness.submission(id: submission.id, context: .background))
        #expect(try await resumed.wait(context: .background).status == "done")
        #expect(runs.values == [.init(), .init(wake: .signal(signal: done.name, key: "done"), checkpoint: "first")])
        #expect(cancels.values == [.init(checkpoint: "first")])
        let result = try await firstResult(reopened)
        #expect(result.isError)
        #expect(harnessToolText(result).contains("Tool ci was interrupted and may have partially run"))
        try await reopened.harness.close(context: .background)
    }

    // Lines 558–604.
    @Test func replaysAnInterruptedSafeWakeWithParkDetailsAndDiagnosticsAndClearsOutput() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("safe-park.sqlite").path
        let setup = HarnessChatSetup(settings: .init(progress: .init(outputIntervalMs: 1, persistWithinMs: 1)))
        let done = try doneSignal()
        let park = ToolPark.sleep(signals: [try done.key("done")], checkpoint: "first")
        let runs = Mutex<[ParkedToolRun]>([])
        let registration = try tool("ci", replay: .safe) { _, api, context in
            let attempt = runs.withLock { values in
                values.append(.init(api))
                return values.count
            }
            if api.wake == nil {
                try api.diagnostic(.init(severity: .info, message: "parked"))
                try await api.details(["build": 1], context)
                return .park(park)
            }
            if attempt == 2 {
                try api.output(.text("cut off\n"), nil)
                try await harnessToolAwaitAbort(context)
            }
            return .result(.init())
        }
        try installHarnessTool(registration, setup: setup)
        let first = try await startChat(setup, storage: SqliteStorage.open(path: path))
        let submission = try await generationSubmit(first, "go")
        let id = try await parkedTask(first)
        #expect(try await first.harness.signal(taskId: id, token: done, key: "done",
            value: ["text": "x"], context: .background) == .delivered)
        try await eventually {
            let storage = first.harness.session.storage
            let key = DocumentAddress(kind: LiveDoc.definition.kind, scope: .conversation(conversationId: first.root.id))
            guard let record = try await storage.findDocument(key, at: .current, context: .background) else { return false }
            let document = try await storage.document(record.id, at: .current, context: .background)
            return document?.value["tools"]?[0]?["output"] == "cut off\n"
        }
        first.harness.session.fail(TaskDefinitionError("Simulated process failure"))
        _ = await first.harness.closed

        let reopened = try await reopen(setup, path: path)
        let resumed = try #require(try await reopened.harness.submission(id: submission.id, context: .background))
        #expect(try await resumed.wait(context: .background).status == "done")
        let woke = ParkedToolRun(wake: .signal(signal: done.name, key: "done"), checkpoint: "first")
        #expect(runs.withLock { $0 } == [.init(), woke, woke])
        let result = try await firstResult(reopened)
        #expect(!result.isError)
        #expect(harnessToolDetails(result) == ["build": 1])
        #expect(harnessToolText(result) == "<harness>\n[info] parked\n</harness>")
        try await reopened.harness.close(context: .background)
    }

    // Lines 608–644.
    @Test(arguments: [false, true])
    func wrapperCanForwardButCannotRecreateItsBasesPark(recreatesPark: Bool) async throws {
        let setup = HarnessChatSetup()
        let done = try doneSignal()
        let runs = SessionTestLog<ParkedToolRun>()
        let base = try signalTool(done, runs: runs)
        try installHarnessTool(base, setup: setup)
        try setup.registry.install(Extension(name: "wrapper", wraps: [wrapTool(base) { inner in
            var wrapper = inner
            wrapper.executeOutcome = { arguments, api, context in
                let outcome = try await inner.executeOutcome(arguments, api, context)
                if recreatesPark, case .park(let park) = outcome, case .sleep(let until, let keys) = park.trigger {
                    return .park(.sleep(until: until, signals: keys, checkpoint: park.checkpoint))
                }
                return outcome
            }
            return wrapper
        }]))
        let opened = try await startChat(setup)
        let submission = try await generationSubmit(opened, "go")
        if !recreatesPark {
            let id = try await parkedTask(opened)
            #expect(try await opened.harness.signal(taskId: id, token: done, key: "done",
                value: ["text": "wrapped"], context: .background) == .delivered)
        }
        #expect(try await submission.wait(context: .background).status == "done")
        let result = try await firstResult(opened)
        if recreatesPark {
            #expect(result.isError)
            #expect(harnessToolText(result).contains("a wrapper returned a park its base did not return"))
        } else {
            #expect(!result.isError)
            #expect(runs.count == 2)
        }
        try await opened.harness.close(context: .background)
    }

    // Lines 645–671.
    @Test func wrapperCanForwardTheSameBaseParkForConcurrentCalls() async throws {
        let setup = HarnessChatSetup(settings: .init(toolExecution: .parallel))
        let done = try doneSignal()
        let shared = ToolPark.sleep(signals: [try done.key("done")])
        let base = try tool("ci") { _, api, context in
            if try await api.readSignal(done, key: "done", context: context) == nil { return .park(shared) }
            return .result(.init(output: [.text(.init(text: "ok"))]))
        }
        try installHarnessTool(base, setup: setup)
        try setup.registry.install(Extension(name: "wrapper", wraps: [wrapTool(base) { $0 }]))
        let opened = try await startChat(setup, calls: [("ci", [:], "a"), ("ci", [:], "b")])
        let submission = try await generationSubmit(opened, "go")
        try await eventually {
            try await generationLive(opened)?.tools?.filter { $0.status == .sleeping }.count == 2
        }
        let slots = try #require(try await generationLive(opened)?.tools)
        for slot in slots {
            let id = try #require(slot.taskId)
            #expect(try await opened.harness.signal(taskId: id, token: done, key: "done",
                value: ["text": "x"], context: .background) == .delivered)
        }
        #expect(try await submission.wait(context: .background).status == "done")
        let results = try harnessToolResults(await allEntries(opened.root))
        #expect(results.map(\.isError) == [false, false])
        try await opened.harness.close(context: .background)
    }

    // Lines 673–702.
    @Test func wrapperCannotReturnAParkFromAnEarlierInvocation() async throws {
        let setup = HarnessChatSetup()
        let done = try doneSignal()
        let base = try signalTool(done)
        let saved = Mutex<ToolPark?>(nil)
        try installHarnessTool(base, setup: setup)
        try setup.registry.install(Extension(name: "wrapper", wraps: [wrapTool(base) { inner in
            var wrapper = inner
            wrapper.executeOutcome = { arguments, api, context in
                if let earlier = saved.withLock({ $0 }) { return .park(earlier) }
                let outcome = try await inner.executeOutcome(arguments, api, context)
                if case .park(let park) = outcome { saved.withLock { $0 = park } }
                return outcome
            }
            return wrapper
        }]))
        let opened = try await startChat(setup)
        let submission = try await generationSubmit(opened, "go")
        let id = try await parkedTask(opened)
        #expect(try await opened.harness.signal(taskId: id, token: done, key: "done",
            value: ["text": "x"], context: .background) == .delivered)
        #expect(try await submission.wait(context: .background).status == "done")
        let result = try await firstResult(opened)
        #expect(result.isError)
        #expect(harnessToolText(result).contains("a wrapper returned a park its base did not return"))
        try await opened.harness.close(context: .background)
    }

    private func doneSignal() throws -> SignalToken<JSONValue> {
        try defineSignal(name: "test.done", version: 1, schema: [
            "type": "object", "properties": ["text": ["type": "string"]], "required": ["text"],
        ])
    }

    private func signalTool(_ done: SignalToken<JSONValue>, runs: SessionTestLog<ParkedToolRun> = .init(),
                            cancel: (@Sendable (JSONValue, ToolExecutionApi, ChordContext) async throws -> Void)? = nil
    ) throws -> ToolRegistration {
        let key = try done.key("done")
        return try tool("ci", cancel: cancel) { _, api, context in
            runs.append(.init(api))
            if case .value(let value) = try await api.readSignal(done, key: "done", context: context),
               let message = value["text"]?.stringValue {
                return .result(.init(output: [.text(.init(text: message))]))
            }
            let count = runs.count
            let checkpoint: JSONValue = ["build": .number(Double(count))]
            try api.output(.text("started\n"), nil)
            try api.diagnostic(.init(severity: .info, message: "run \(count)"))
            try await api.details(checkpoint, context)
            return .park(.sleep(signals: [key], checkpoint: checkpoint))
        }
    }

    private func tool(_ name: String, replay: ToolReplay? = nil,
                      cancel: (@Sendable (JSONValue, ToolExecutionApi, ChordContext) async throws -> Void)? = nil,
                      execute: @escaping @Sendable (JSONValue, ToolExecutionApi, ChordContext) async throws -> ToolExecutionOutcome
    ) throws -> ToolRegistration {
        try ToolRegistration(name: name, description: name, parameters: ["type": "object", "properties": [:]],
            replay: replay, cancel: cancel, execute: execute)
    }

    private func startChat(_ setup: HarnessChatSetup, calls: [(String, JSONObject, String)] = [("ci", [:], "c1")],
                           storage: any DurableStorage = MemoryStorage(), env: HarnessEnvFactory? = nil
    ) async throws -> OpenChatResult {
        setup.models.setResponses([.message(try toolCalls(calls)), .message(chatAssistant("done"))])
        guard let env else {
            let opened = try await openChat(storage: storage, setup: setup)
            try opened.harness.resume()
            return opened
        }
        let harness = try await Harness.open(storage: storage, options: .init(models: setup.models,
            registry: setup.registry, settings: setup.settingsProvider, env: env, clock: setup.clock,
            onReport: { setup.reports.appendReport($0) }), context: .background)
        let root = try await harness.root(options: .init(agent: AgentChange(
            model: .set(ModelRef(provider: "faux", modelId: "faux-1")))), context: .background)
        try harness.resume()
        return OpenChatResult(harness: harness, root: root)
    }

    private func reopen(_ setup: HarnessChatSetup, path: String) async throws -> OpenChatResult {
        let opened = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        try opened.harness.resume()
        return opened
    }

    private func parkedTask(_ opened: OpenChatResult, status: ToolSlot.Status = .sleeping) async throws -> TaskID {
        try await eventually {
            guard let slot = try await generationLive(opened)?.tools?.first,
                  slot.status == status, let id = slot.taskId else { return false }
            return try await opened.harness.getTask(id: id, context: .background)?.state.status == status.rawValue
        }
        return try #require(try await generationLive(opened)?.tools?.first?.taskId)
    }

    private func firstResult(_ opened: OpenChatResult) async throws -> ToolResultMessage {
        try #require(try harnessToolResults(await allEntries(opened.root)).first)
    }
}
