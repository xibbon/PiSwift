import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

// Upstream v1.4.0 types.ts:78 requires an explicit checkpoint policy in each definition.

private struct D3Opened: Sendable {
    let harness: Harness
    let storage: D3TestStorage
    let wakes: SessionTestLog<HarnessWake>
    let reports: SessionTestLog<String>
}
private func d3Open(_ base: any DurableStorage, registry: Registry,
                    settings: HarnessSettingsProvider? = nil,
                    events: SessionTestLog<String> = SessionTestLog()) async throws -> D3Opened {
    let storage = D3TestStorage(base, events: events)
    let wakes = SessionTestLog<HarnessWake>(), reports = SessionTestLog<String>()
    let harness = try await Harness.open(storage: storage, options: .init(models: FakeDurableModels(),
        registry: registry, settings: settings, onWake: { wakes.append($0) }, onReport: {
            reports.append(String(describing: $0)); events.append("report")
        }), context: .background)
    return D3Opened(harness: harness, storage: storage, wakes: wakes, reports: reports)
}
private func d3Registry(_ definition: HarnessTestTask) throws -> Registry {
    let registry = Registry()
    try registry.install(Extension(name: "loop", tasks: [AnyTaskDefinition(definition)]))
    return registry
}
private func d3Stop(_ runtime: TaskRuntime) async {
    let gate = SessionTestGate()
    let registration = runtime.signal.addAbortListener { _ in gate.release() }
    if runtime.signal.aborted { gate.release() }
    await gate.wait()
    runtime.signal.removeAbortListener(registration)
}
private func d3Crash(_ opened: D3Opened) async throws {
    opened.storage.crash()
    try await opened.harness.close(context: .background)
}
private func d3Record(_ id: TaskID, kind: String = "test.loop", state: TaskState? = nil,
                      restarts: Double? = nil, abortRequested: Bool = false,
                      abandonOnRestart: Bool? = nil) throws -> TaskRecord {
    TaskRecord(id: id, conversationId: rootConversationID, kind: kind, version: 1,
        input: .number(0), state: try state ?? .running(checkpoint: JSONValue(encoding: HarnessTaskCheckpoint())),
        abortRequested: abortRequested, abandonOnRestart: abandonOnRestart, restarts: restarts)
}
private func d3Seed(_ storage: any DurableStorage, _ record: TaskRecord) async throws {
    _ = try await storage.commit([.conversation(value: ConversationRecord(id: rootConversationID)),
                                .task(value: record)], context: .background)
}
private func d3ExpectBlocked(_ harness: Harness, _ id: TaskID, reason: TaskBlockedReason) async throws {
    let inspection = try await harness.inspect(context: .background)
    let item = try #require(inspection.tasks.first { $0.record.id == id })
    guard case .blocked(let actual, _) = item.state else { Issue.record("Expected blocked task"); return }
    #expect(actual == reason)
}

private func d3WaitForParkedPass(_ harness: Harness) async throws {
    try await harnessEventually { !harness.wake().active && !harness.tasks.state.withLock { $0.pumping } }
}

@Suite struct D3HarnessBlockedTests {
    // upstream v1.4.0 harness-blocked.test.ts:82.
    @Test func recoveryFailureKeepsHostWakeActive() async throws {
        let base = MemoryStorage(), id = try TaskID(20), events = SessionTestLog<String>()
        try await d3Seed(base, d3Record(id, state: .completing(outcome: .completed(result: .null))))
        let storage = D3TestStorage(base, events: events)
        storage.failNext("terminal")
        let wakes = SessionTestLog<HarnessWake>()
        let harness = try await Harness.open(storage: storage, options: .init(models: FakeDurableModels(), registry: Registry(),
            onWake: { wakes.append($0) }), context: .background)
        guard case .failed = await harness.closed else { Issue.record("Recovery failure did not fail Session"); return }
        #expect(wakes.values == [HarnessWake(active: true)])
        #expect(try await base.task(id, context: .background)?.state.status == "completing")
        try await harness.close(context: .background)
        try await base.close(context: .background)
    }

    // upstream v1.4.0 harness-blocked.test.ts:135.
    @Test func parksAfterThreeCrashesAndRetryRunsTask() async throws {
        let base = MemoryStorage(), crashing = Mutex(true), runs = SessionTestLog<Int>()
        let definition = harnessOneStep("test.loop") { _, runtime, context in
            runs.append(1)
            if crashing.withLock({ $0 }) { await d3Stop(runtime) }
            else { try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context) }
        }
        let registry = try d3Registry(definition), settings = HarnessSettingsProvider { .init(restartLimit: 3) }
        var opened = try await d3Open(base, registry: registry, settings: settings)
        let root = try await opened.harness.root(context: .background), id = try await harnessStart(root, definition)
        for count in 1...3 {
            try opened.harness.resume()
            try await harnessEventually { runs.count == count }
            try await d3Crash(opened)
            opened = try await d3Open(base, registry: registry, settings: settings)
        }
        let harness = opened.harness
        #expect(try await harness.getTask(id: id, context: .background)?.storedRestarts == 3)
        try await d3ExpectBlocked(harness, id, reason: .restartLimit)
        let graph = try await harness.taskGraph(context: .background)
        #expect(graph.value.tasks[String(id.rawValue)]?.blocked == .restartLimit)
        #expect(opened.reports.values == ["Task \(id.rawValue) (test.loop) was cut off 3 times without progress; it is parked until retryTask()"])
        try await harnessEventually { !harness.wake().active }
        #expect(harness.wake() == HarnessWake(active: false))
        try harness.resume(); try await d3WaitForParkedPass(harness)
        #expect(runs.count == 3)
        crashing.withLock { $0 = false }
        try await harness.retryTask(id: id, context: .background)
        let receipt = try await harness.waitForTask(id: id, context: .background)
        #expect(receipt.outcome.status == "completed" && receipt.record.storedRestarts == nil)
        #expect(runs.count == 4)
        graph.dispose(); try await harness.close(context: .background); try await base.close(context: .background)
    }

    // upstream v1.4.0 harness-blocked.test.ts:179.
    @Test func closeDoesNotAddRestart() async throws {
        let base = MemoryStorage(), crashing = Mutex(true), runs = SessionTestLog<Int>()
        let definition = harnessOneStep("test.loop") { _, runtime, context in
            runs.append(1)
            if crashing.withLock({ $0 }) { await d3Stop(runtime) }
            else { try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context) }
        }
        let registry = try d3Registry(definition), settings = HarnessSettingsProvider { .init(restartLimit: 1) }
        let first = try await d3Open(base, registry: registry, settings: settings)
        let id = try await harnessStart(first.harness.root(context: .background), definition)
        try first.harness.resume(); try await harnessEventually { runs.count == 1 }
        try await first.harness.close(context: .background)
        let opened = try await d3Open(base, registry: registry, settings: settings)
        let record = try #require(await opened.harness.getTask(id: id, context: .background))
        #expect(record.state.status == "pending" && record.storedRestarts == nil)
        crashing.withLock { $0 = false }
        #expect(try await opened.harness.waitForTask(id: id, context: .background).outcome.status == "completed")
        try await opened.harness.close(context: .background); try await base.close(context: .background)
    }

    // upstream v1.4.0 harness-blocked.test.ts:201.
    @Test func closeKeepsAbortMarkAdmittedOnLine() async throws {
        let storage = ControlledStorage(), started = SessionTestGate()
        let definition = harnessOneStep("test.abort-mark-close") { _, runtime, _ in started.release(); await d3Stop(runtime) }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], storage: storage)
        let root = try await harness.root(context: .background), id = try await harnessStart(root, definition)
        try harness.resume(); await started.wait()
        let held = await storage.holdCommits()
        let holding = Task { try await root.commit({ tx in try await tx.appendEntry(root.id, value: .init(kind: "hold")) }, context: .background) }
        await held.waitUntilEntered()
        let aborting = Task { try await harness.abortTask(id: id, context: .background) }
        try await harnessEventually { harness.session.line.queuedCount > 0 }
        let closing = Task { try await harness.close(context: .background) }
        try await harnessEventually { harness.tasks.closing }
        await held.release(); _ = try await holding.value
        #expect(try await aborting.value == .marked)
        try await closing.value
        let saved = await storage.commits.flatMap { $0 }.compactMap { write -> TaskRecord? in
            if case .task(let task, _) = write, task.id == id { return task }; return nil
        }.last
        #expect(saved?.abortRequested == true && saved?.state.status == "pending")
    }

    // upstream v1.4.0 harness-blocked.test.ts:228.
    @Test func abortCutoffFaultsAtLimitAndRemovesCount() async throws {
        let base = MemoryStorage(), aborts = SessionTestLog<TaskID>(), events = SessionTestLog<String>()
        let definition = harnessOneStep("test.loop", run: { _, runtime, _ in await d3Stop(runtime) }, abort: { task, runtime, _ in
            aborts.append(task.id); await d3Stop(runtime)
        })
        let registry = try d3Registry(definition), settings = HarnessSettingsProvider { .init(restartLimit: 1) }
        let first = try await d3Open(base, registry: registry, settings: settings)
        let id = try await harnessStart(first.harness.root(context: .background), definition)
        try first.harness.resume(); _ = try await first.harness.abortTask(id: id, context: .background)
        try await harnessEventually { aborts.count == 1 }; try await d3Crash(first)
        let opened = try await d3Open(base, registry: registry, settings: settings, events: events)
        let receipt = try await opened.harness.waitForTask(id: id, context: .background)
        guard case .faulted(let error, _) = receipt.outcome else { Issue.record("Expected restart fault"); return }
        #expect(error.detail == .object(["reason": .string("restart_limit")]))
        #expect(receipt.record.storedRestarts == nil && aborts.values == [id])
        try await harnessEventually { opened.reports.count == 1 }
        #expect(opened.reports.values == ["Abort handler of task \(id.rawValue) (test.loop) was cut off 1 times"])
        let saved = try #require(events.values.firstIndex(of: "saved terminal")), reported = try #require(events.values.firstIndex(of: "report"))
        #expect(saved < reported)
        try await opened.harness.close(context: .background); try await base.close(context: .background)
    }

    // upstream v1.4.0 harness-blocked.test.ts:269.
    @Test func raisedLiveLimitRunsParkedTask() async throws {
        let base = MemoryStorage(), runs = SessionTestLog<Int>(), limit = Mutex(1.0), id = try TaskID(20)
        let definition = harnessOneStep("test.loop") { _, runtime, context in
            runs.append(1); try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }
        try await d3Seed(base, d3Record(id))
        let opened = try await d3Open(base, registry: d3Registry(definition), settings: HarnessSettingsProvider { .init(restartLimit: limit.withLock { $0 }) })
        let graph = try await opened.harness.taskGraph(context: .background)
        try opened.harness.resume(); try await d3WaitForParkedPass(opened.harness)
        #expect(graph.value.tasks[String(id.rawValue)]?.blocked == .restartLimit && runs.count == 0)
        limit.withLock { $0 = .infinity }; try opened.harness.resume()
        #expect(try await opened.harness.waitForTask(id: id, context: .background).outcome.status == "completed")
        #expect(runs.count == 1)
        graph.dispose(); try await opened.harness.close(context: .background); try await base.close(context: .background)
    }

    // upstream v1.4.0 harness-blocked.test.ts:300.
    @Test func parkedTaskCanRunAbortHandler() async throws {
        let base = MemoryStorage(), runs = SessionTestLog<Int>(), aborts = SessionTestLog<TaskID>(), id = try TaskID(20)
        let definition = harnessOneStep("test.loop", run: { _, _, _ in runs.append(1) }, abort: { task, runtime, context in
            aborts.append(task.id); try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
        })
        try await d3Seed(base, d3Record(id))
        let opened = try await d3Open(base, registry: d3Registry(definition), settings: HarnessSettingsProvider { .init(restartLimit: 1) })
        _ = try await opened.harness.abortTask(id: id, context: .background)
        #expect(try await opened.harness.waitForTask(id: id, context: .background).outcome.status == "aborted")
        #expect(aborts.values == [id] && runs.count == 0)
        try await opened.harness.close(context: .background); try await base.close(context: .background)
    }

    // upstream v1.4.0 harness-blocked.test.ts:329.
    @Test func equalCheckpointDoesNotResetCount() async throws {
        let base = MemoryStorage(), runs = SessionTestLog<Int>()
        let definition = harnessOneStep("test.loop") { task, runtime, context in
            try await runtime.commit({ _, _ in .running(checkpoint: try JSONValue(encoding: task.checkpoint)) }, context: context)
            runs.append(1); await d3Stop(runtime)
        }
        let registry = try d3Registry(definition), settings = HarnessSettingsProvider { .init(restartLimit: 2) }
        var opened = try await d3Open(base, registry: registry, settings: settings)
        let id = try await harnessStart(opened.harness.root(context: .background), definition)
        for count in 1...2 {
            try opened.harness.resume(); try await harnessEventually { runs.count == count }
            try await d3Crash(opened); opened = try await d3Open(base, registry: registry, settings: settings)
        }
        #expect(try await opened.harness.getTask(id: id, context: .background)?.storedRestarts == 2)
        try await d3ExpectBlocked(opened.harness, id, reason: .restartLimit)
        try await opened.harness.close(context: .background); try await base.close(context: .background)
    }

    // upstream v1.4.0 harness-blocked.test.ts:368.
    @Test func changedCheckpointResetsCount() async throws {
        let base = MemoryStorage(), started = SessionTestGate(), id = try TaskID(20)
        try await d3Seed(base, d3Record(id))
        let definition = harnessOneStep("test.loop") { task, runtime, context in
            if task.checkpoint.phase == .run {
                try await runtime.commit({ _, _ in .running(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined))) }, context: context)
            } else { started.release(); await d3Stop(runtime) }
        }
        let opened = try await d3Open(base, registry: d3Registry(definition), settings: HarnessSettingsProvider { .init(restartLimit: 2) })
        #expect(try await opened.harness.getTask(id: id, context: .background)?.storedRestarts == 1)
        try opened.harness.resume(); await started.wait()
        #expect(try await opened.harness.getTask(id: id, context: .background)?.storedRestarts == nil)
        try await opened.harness.close(context: .background); try await base.close(context: .background)
    }

    // upstream v1.4.0 harness-blocked.test.ts:410.
    @Test func migrationFailureBlocksGraphAndEndsWake() async throws {
        let base = MemoryStorage(), id = try TaskID(20)
        try await d3Seed(base, d3Record(id, state: .pending(checkpoint: JSONValue(encoding: HarnessTaskCheckpoint()))))
        let definition = HarnessTestTask(name: "test.loop", version: 2, initial: { _ in HarnessTaskCheckpoint() },
            phase: { _, _, _ in Issue.record("Failed migration ran") }, abort: { _, _, _ in },
            migrate: { _, _, _ in throw TaskDefinitionError("cannot migrate") })
        let opened = try await d3Open(base, registry: d3Registry(definition))
        let graph = try await opened.harness.taskGraph(context: .background)
        try opened.harness.resume()
        try await harnessEventually { graph.value.tasks[String(id.rawValue)]?.blocked == .migrationFailed }
        try await harnessEventually { !opened.harness.wake().active && opened.wakes.values.last?.active == false }
        #expect(opened.harness.wake() == HarnessWake(active: false))
        graph.dispose(); try await opened.harness.close(context: .background); try await base.close(context: .background)
    }

    // upstream v1.4.0 harness-blocked.test.ts:450.
    @Test func abandonedTaskWaitsForMissingDefinition() async throws {
        let base = MemoryStorage(), id = try TaskID(20)
        try await d3Seed(base, d3Record(id, state: .pending(checkpoint: JSONValue(encoding: HarnessTaskCheckpoint())), abandonOnRestart: true))
        let opened = try await d3Open(base, registry: Registry()), graph = try await opened.harness.taskGraph(context: .background)
        try opened.harness.resume()
        try await harnessEventually { try await opened.harness.getTask(id: id, context: .background)?.abortReason == .restart }
        try await harnessEventually { graph.value.tasks[String(id.rawValue)]?.blocked == .missingTask }
        graph.dispose(); try await opened.harness.close(context: .background); try await base.close(context: .background)
    }

    // upstream v1.4.0 harness-blocked.test.ts:477.
    @Test func definitionInstallUnblocksGraphAndWakesHost() async throws {
        let base = MemoryStorage(), registry = Registry(), id = try TaskID(20)
        try await d3Seed(base, d3Record(id, state: .pending(checkpoint: JSONValue(encoding: HarnessTaskCheckpoint()))))
        let opened = try await d3Open(base, registry: registry), graph = try await opened.harness.taskGraph(context: .background)
        try opened.harness.resume()
        try await harnessEventually { graph.value.tasks[String(id.rawValue)]?.blocked == .missingTask && !opened.harness.wake().active && opened.wakes.values.last?.active == false }
        let wakeCount = opened.wakes.count, entered = SessionTestGate(), release = SessionTestGate()
        defer { release.release() }
        let definition = harnessOneStep("test.loop") { _, runtime, context in
            entered.release(); await release.wait()
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }
        try registry.install(Extension(name: "late", tasks: [AnyTaskDefinition(definition)]))
        await entered.wait()
        try await harnessEventually { graph.value.tasks[String(id.rawValue)]?.blocked == nil && opened.wakes.values.dropFirst(wakeCount).contains { $0.active } }
        #expect(opened.wakes.values.dropFirst(wakeCount).filter { $0.active }.count == 1)
        #expect(try await opened.harness.getTask(id: id, context: .background)?.state.status == "running")
        release.release()
        #expect(try await opened.harness.waitForTask(id: id, context: .background).outcome.status == "completed")
        graph.dispose(); try await opened.harness.close(context: .background); try await base.close(context: .background)
    }
}

@Suite struct D3HarnessRestartTests {
    // upstream v1.4.0 src/harness/agent.ts:56-61,83.
    @Test(arguments: [0.0, Double.nan, -Double.infinity, -2.0, 0.5, 0.999])
    func invalidLimitsUseDefault(limit: Double) {
        #expect(resolveSettings(.init(restartLimit: limit)).restartLimit == 5)
    }

    // upstream v1.4.0 src/harness/agent.ts:59-61.
    @Test(arguments: [1.0, 1.99, 2.75, 5.999, Double.infinity])
    func validLimitsRoundDown(limit: Double) {
        #expect(resolveSettings(.init(restartLimit: limit)).restartLimit == limit.rounded(.down))
    }

    // Upstream stores a parked task as pending with a restart count.
    // Decoding must not require a Swift-only parked state.
    @Test func typeScriptPendingRecordAtLimitDoesNotRun() async throws {
        let base = MemoryStorage(), id = try TaskID(20), runs = SessionTestLog<Int>()
        let raw: JSONValue = .object([
            "id": .number(Double(id.rawValue)), "conversationId": .number(Double(rootConversationID.rawValue)),
            "kind": "test.loop", "version": 1, "input": 0,
            "state": ["status": "pending", "checkpoint": ["phase": "run", "count": 0, "ids": []]],
            "background": false, "abortRequested": false, "restarts": 5,
        ])
        let record = try raw.decode(TaskRecord.self)
        try await d3Seed(base, record)
        let definition = harnessOneStep("test.loop") { _, _, _ in runs.append(1) }
        let opened = try await d3Open(base, registry: d3Registry(definition))
        let graph = try await opened.harness.taskGraph(context: .background)
        try opened.harness.resume(); try await d3WaitForParkedPass(opened.harness)
        #expect(runs.count == 0)
        #expect(try await opened.harness.getTask(id: id, context: .background) == record)
        try await d3ExpectBlocked(opened.harness, id, reason: .restartLimit)
        #expect(graph.value.tasks[String(id.rawValue)]?.blocked == .restartLimit)
        #expect(opened.harness.wake() == HarnessWake(active: false))
        graph.dispose(); try await opened.harness.close(context: .background); try await base.close(context: .background)
    }

    @Test(arguments: [false, true])
    func faultReportFollowsDecisionCommit(writeFails: Bool) async throws {
        let base = MemoryStorage(), events = SessionTestLog<String>()
        let entered = SessionTestGate(), release = SessionTestGate()
        let definition = harnessOneStep("test.phase-fault") { _, _, _ in
            entered.release(); await release.wait(); throw TaskDefinitionError("D3 phase fault")
        }
        let opened = try await d3Open(base, registry: d3Registry(definition), events: events)
        let id = try await harnessStart(opened.harness.root(context: .background), definition)
        try opened.harness.resume(); await entered.wait()
        if writeFails { opened.storage.failNext("terminal") }
        release.release()
        if writeFails {
            guard case .failed = await opened.harness.closed else { Issue.record("Failed decision did not fail Session"); return }
            #expect(try await base.task(id, context: .background)?.state.status == "running")
            #expect(opened.reports.values == ["D3 write failed"])
            #expect(!events.values.contains("saved terminal"))
        } else {
            #expect(try await opened.harness.waitForTask(id: id, context: .background).outcome == .faulted(error: .init(message: "D3 phase fault")))
            try await harnessEventually { opened.reports.count == 1 }
            #expect(opened.reports.values == ["D3 phase fault"])
            let saved = try #require(events.values.firstIndex(of: "saved terminal")), report = try #require(events.values.firstIndex(of: "report"))
            #expect(saved < report)
        }
        try await opened.harness.close(context: .background); try await base.close(context: .background)
    }

    @Test func failedAbortCutoffDecisionDoesNotReportFault() async throws {
        let base = MemoryStorage(), id = try TaskID(20), events = SessionTestLog<String>()
        try await d3Seed(base, d3Record(id, abortRequested: true))
        let definition = harnessOneStep("test.loop", run: { _, _, _ in Issue.record("Cutoff task ran") },
            abort: { _, _, _ in Issue.record("Cutoff abort handler ran") })
        let opened = try await d3Open(base, registry: d3Registry(definition), settings: HarnessSettingsProvider { .init(restartLimit: 1) }, events: events)
        opened.storage.failNext("terminal"); try opened.harness.resume()
        guard case .failed = await opened.harness.closed else { Issue.record("Failed cutoff decision did not fail Session"); return }
        #expect(opened.reports.values == ["D3 write failed"])
        #expect(!events.values.contains("saved terminal"))
        let record = try #require(await base.task(id, context: .background))
        #expect(record.state.status == "pending" && record.abortRequested && record.storedRestarts == 1)
        try await opened.harness.close(context: .background); try await base.close(context: .background)
    }

    @Test func failedCloseWriteRetainsRunningRecordAndFailsSession() async throws {
        let base = MemoryStorage(), started = SessionTestGate()
        let definition = harnessOneStep("test.close-failure") { _, runtime, _ in started.release(); await d3Stop(runtime) }
        let opened = try await d3Open(base, registry: d3Registry(definition))
        let id = try await harnessStart(opened.harness.root(context: .background), definition)
        try opened.harness.resume(); await started.wait()
        let running = try #require(await base.task(id, context: .background))
        opened.storage.failNext("pending")
        try await opened.harness.close(context: .background)
        guard case .failed = await opened.harness.closed else { Issue.record("Failed close write did not fail Session"); return }
        #expect(try await base.task(id, context: .background) == running)
        #expect(opened.reports.values == ["D3 write failed"])
        try await base.close(context: .background)
    }

    @Test func recordCopiesKeepCarriersAndUnknownFieldsUntilTerminal() async throws {
        let base = MemoryStorage(), id = try TaskID(20), saved = SessionTestGate(), complete = Mutex(false)
        let checkpoint = try JSONValue(encoding: HarnessTaskCheckpoint())
        let trace: JSONValue = ["traceparent": "parent", "e\u{301}": "first", "é": "second"]
        let links: JSONValue = .array([["traceparent": "linked"]])
        let opaque: JSONValue = ["nested": [1, ["unchanged": true]]]
        var raw = try JSONValue(encoding: d3Record(id, restarts: 1))
        guard case .object(var fields) = raw else { Issue.record("Expected record object"); return }
        fields["trace"] = trace; fields["links"] = links; fields["future"] = opaque
        raw = .object(fields)
        try await d3Seed(base, raw.decode(TaskRecord.self))
        let output = try TaskDocToken<JSONObject>(kind: "test.d3-output", version: 1, initial: { ["text": ""] }, checkpointWhen: { _, _, _ in false })
        let definition = harnessOneStep("test.loop") { task, runtime, context in
            if complete.withLock({ $0 }) {
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
                return
            }
            _ = try await runtime.memo("effect", value: .string("done"), context: context)
            try await runtime.commit({ tx, _ in
                try await tx.doc(output, taskId: task.id).set("text", .string("output"))
                _ = try await tx.appendEntry(task.record.conversationId, value: .init(kind: "test.output", data: .string("output")))
                return .running(checkpoint: checkpoint)
            }, context: context)
            saved.release(); await d3Stop(runtime)
        }
        let registry = try d3Registry(definition)
        let opened = try await d3Open(base, registry: registry)
        let recovered = try #require(await opened.harness.getTask(id: id, context: .background))
        #expect(recovered.storedRestarts == 2)
        try opened.harness.resume(); await saved.wait()
        let running = try #require(await opened.harness.getTask(id: id, context: .background))
        #expect(running.storedRestarts == 2 && running.memos == ["effect": "done"])
        #expect(try await opened.harness.snapshot(output, taskId: id, context: .background) == ["text": "output"])
        try await opened.harness.close(context: .background)
        let pending = try #require(await base.task(id, context: .background))
        #expect(pending.state.status == "pending" && pending.storedRestarts == 2)
        for record in [recovered, running, pending] {
            guard case .object(let copied) = try JSONValue(encoding: record) else { Issue.record("Expected record copy"); return }
            #expect(copied["trace"] == trace && copied["links"] == links && copied["future"] == opaque)
        }
        complete.withLock { $0 = true }
        let reopened = try await d3Open(base, registry: registry)
        let receipt = try await reopened.harness.waitForTask(id: id, context: .background)
        #expect(receipt.record.storedRestarts == nil && receipt.record.memos == nil)
        guard case .object(let terminal) = try JSONValue(encoding: receipt.record) else { Issue.record("Expected terminal object"); return }
        #expect(terminal["restarts"] == nil && terminal["memos"] == nil)
        #expect(terminal["trace"] == trace && terminal["links"] == links && terminal["future"] == opaque)
        try await reopened.harness.close(context: .background); try await base.close(context: .background)
    }
}
