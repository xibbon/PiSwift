import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private struct HandoverCheckpoint: TaskCheckpoint {
    enum Phase: String, Codable, Sendable { case a, b, c }
    var phase: Phase
}
private typealias HandoverTask = TaskDefinition<Int, HandoverCheckpoint, Int, NoTaskHooks>
private func handoverDefinition(_ label: String, version: Double = 1, log: SessionTestLog<String>,
    gateA: SessionTestGate? = nil, gateB: SessionTestGate? = nil,
    afterProgress: (@Sendable () async throws -> Void)? = nil) -> HandoverTask {
    HandoverTask(name: "test.handover", version: version, initial: { _ in .init(phase: .a) }, phase: { task, runtime, context in
        switch task.checkpoint.phase {
        case .a, .b:
            log.append("\(label):\(task.checkpoint.phase.rawValue) start")
            if task.checkpoint.phase == .a { await gateA?.wait() } else { await gateB?.wait() }
            let next = HandoverCheckpoint(phase: task.checkpoint.phase == .a ? .b : .c)
            try await runtime.commit({ _, _ in .running(checkpoint: try JSONValue(encoding: next)) }, context: context)
            if task.checkpoint.phase == .a { try await afterProgress?() }
            log.append("\(label):\(task.checkpoint.phase.rawValue) end")
        case .c:
            log.append("\(label):c")
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }
    }, abort: { _, runtime, context in
        log.append("\(label):abort")
        try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: label)) }, context: context)
    })
}
private func startHandover(_ root: Conversation, _ definition: HandoverTask) async throws -> TaskID {
    try await root.commit({ tx in try await tx.createTask(definition, input: 0, options: .init(ownership: .conversation())) }, context: .background)
}

@Suite struct HarnessTaskHandoverTests {
    // upstream harness-tasks-recovery.test.ts:550
    @Test func vanishedActiveDefinitionOrphansAfterRunJoin() async throws {
        let entered = SessionTestGate(), abortRuns = SessionTestLog<Int>()
        let definition = harnessOneStep("test.vanishing", run: { _, runtime, context in
            entered.release()
            try await runtime.sleep(until: 60_000, context: context)
        }, abort: { _, _, _ in abortRuns.append(1); Issue.record("Missing definition's abort handler ran") })
        let clock = TestClock(now: 1000)
        let registry = Registry()
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], registry: registry, clock: clock)
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, definition)
        try harness.resume(); await entered.wait()
        registry.uninstall(name: "tasks")
        #expect(try await harness.abortTask(id: id, context: .background) == .marked)
        #expect(try await harness.waitForTask(id: id, context: .background).outcome == .orphaned(reason: "missing_task"))
        #expect(abortRuns.count == 0)
        try await harness.close(context: .background)
    }

    // upstream harness-tasks-recovery.test.ts:745
    @Test func oldDefinitionContinuesWhenReplacementMissingOrIncompatible() async throws {
        let log = SessionTestLog<String>(), gateA = SessionTestGate(), gateB = SessionTestGate()
        let old = handoverDefinition("old", log: log, gateA: gateA, gateB: gateB)
        let registry = Registry()
        let opened = try await openTasks(tasks: [AnyTaskDefinition(old)], registry: registry)
        let harness = opened.harness, root = try await harness.root(context: .background)
        let id = try await startHandover(root, old)
        try harness.resume(); try await harnessEventually { log.count == 1 }
        registry.uninstall(name: "tasks"); gateA.release()
        try await harnessEventually { log.values.contains("old:b start") }
        try registry.install(Extension(name: "tasks", tasks: [AnyTaskDefinition(handoverDefinition("incompatible", version: 2, log: log))]))
        gateB.release()
        _ = try await harness.waitForTask(id: id, context: .background)
        #expect(log.values == ["old:a start", "old:a end", "old:b start", "old:b end", "old:c"])
        #expect(opened.reports.count == 2)
        #expect(opened.reports.values.allSatisfy { String(describing: $0).contains("keeps running under its old") })
        #expect(opened.reports.values.compactMap { ($0 as? TaskHandoverError)?.cause.rawValue } == ["missing_task", "incompatible_task"])
        try await harness.close(context: .background)
    }

    // upstream harness-tasks-recovery.test.ts:762. The line queue fixes ordering without a timer.
    @Test func oldRuntimeCommitQueuedBehindHandoverRejects() async throws {
        let storage = ControlledStorage(), gate = SessionTestGate(), returning = SessionTestGate()
        let held = Mutex<ControlledStorage.Gate?>(nil), captured = Mutex<TaskRuntime?>(nil)
        let harnessRef = Mutex<Harness?>(nil), blocker = Mutex<Task<Void, any Error>?>(nil)
        let log = SessionTestLog<String>()
        let old = HandoverTask(name: "test.handover", version: 1, initial: { _ in .init(phase: .a) }, phase: { _, runtime, context in
            captured.withLock { $0 = runtime }; await gate.wait()
            try await runtime.commit({ _, _ in .running(checkpoint: try JSONValue(encoding: HandoverCheckpoint(phase: .b))) }, context: context)
            let hold = await storage.holdCommits(); held.withLock { $0 = hold }
            let harness = try #require(harnessRef.withLock { $0 })
            let work = Task {
                try await harness.commit({ tx in _ = try await tx.appendEntry(runtime.conversationId, value: .init(kind: "blocker")) }, context: .background)
            }
            blocker.withLock { $0 = work }
            await hold.waitUntilEntered(); returning.release()
        }, abort: { _, _, _ in })
        let registry = Registry()
        let harness = try await harnessOpen([AnyTaskDefinition(old)], storage: storage, registry: registry)
        harnessRef.withLock { $0 = harness }
        let root = try await harness.root(context: .background), id = try await startHandover(root, old)
        try harness.resume(); try await harnessEventually { captured.withLock { $0 != nil } }
        try registry.install(Extension(name: "tasks", tasks: [AnyTaskDefinition(handoverDefinition("new", log: log))]))
        gate.release(); await returning.wait()
        try await harnessEventually { harness.session.line.queuedCount >= 1 }
        let runtime = try #require(captured.withLock { $0 })
        let queued = harness.session.line.queuedCount
        let late = Task { try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(9))) }, context: .background) }
        try await harnessEventually { harness.session.line.queuedCount > queued }
        let hold = try #require(held.withLock { $0 }); await hold.release()
        do { try await late.value; Issue.record("Old invocation commit returned") }
        catch { #expect(String(describing: error).contains("invocation has ended")) }
        _ = try await harness.waitForTask(id: id, context: .background)
        if let work = blocker.withLock({ $0 }) { try await work.value }
        #expect(log.values == ["new:b start", "new:b end", "new:c"])
        try await harness.close(context: .background)
    }

    // upstream harness-tasks-recovery.test.ts:811. Swift can admit the new reservation before the abort call.
    @Test func abortMarkRacingHandoverIsPreservedForNewDefinition() async throws {
        let storage = ControlledStorage(), gate = SessionTestGate(), log = SessionTestLog<String>()
        let held = Mutex<ControlledStorage.Gate?>(nil)
        let old = handoverDefinition("old", log: log, gateA: gate, afterProgress: {
            let hold = await storage.holdCommits(); held.withLock { $0 = hold }
        })
        let registry = Registry()
        let harness = try await harnessOpen([AnyTaskDefinition(old)], storage: storage, registry: registry)
        let root = try await harness.root(context: .background), id = try await startHandover(root, old)
        try harness.resume(); try await harnessEventually { log.count == 1 }
        try registry.install(Extension(name: "tasks", tasks: [AnyTaskDefinition(handoverDefinition("new", log: log))]))
        gate.release(); try await harnessEventually { held.withLock { $0 != nil } }
        let hold = try #require(held.withLock { $0 }); await hold.waitUntilEntered()
        let queued = harness.session.line.queuedCount
        let aborting = Task { try await harness.abortTask(id: id, context: .background) }
        try await harnessEventually { harness.session.line.queuedCount > queued }
        await hold.release()
        #expect(try await aborting.value == .marked)
        #expect(try await harness.waitForTask(id: id, context: .background).outcome == .aborted(reason: "new"))
        let commits = await storage.commits
        let states = commits.flatMap { writes in writes.compactMap { write -> String? in
            guard case .task(let value, _) = write, value.id == id else { return nil }
            return value.state.status + (value.abortRequested ? "+mark" : "")
        } }
        #expect(Array(states.prefix(4)) == ["pending", "running", "running", "pending"])
        let firstMarked = try #require(states.firstIndex { $0.hasSuffix("+mark") })
        #expect(firstMarked >= 4)
        #expect(states[firstMarked] == "pending+mark" || states[firstMarked] == "running+mark")
        #expect(states[firstMarked...].allSatisfy { $0.hasSuffix("+mark") })
        #expect(states.last == "terminal+mark")
        #expect(log.values == ["old:a start", "old:a end", "new:abort"])
        try await harness.close(context: .background)
    }
    // upstream harness-tasks-recovery.test.ts:708,721
    @Test(arguments: ["success", "failure"])
    func newerDefinitionMigratesOnlyAfterOldPhaseCompletes(mode: String) async throws {
        let log = SessionTestLog<String>(), gate = SessionTestGate(), attempts = SessionTestLog<Int>()
        let old = handoverDefinition("old", log: log, gateA: gate)
        let registry = Registry()
        let opened = try await openTasks(tasks: [AnyTaskDefinition(old)], registry: registry)
        let harness = opened.harness, root = try await harness.root(context: .background)
        let id = try await startHandover(root, old)
        try harness.resume(); try await harnessEventually { log.count == 1 }
        let replacement = HandoverTask(name: old.name, version: 2, initial: { _ in .init(phase: .a) },
            phase: { task, runtime, context in
                #expect(task.checkpoint.phase == .c)
                #expect(task.record.version == 2)
                log.append("v2:c")
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(2))) }, context: context)
            }, abort: { _, _, _ in }, migrate: { input, checkpoint, fromVersion in
                attempts.append(1)
                #expect(fromVersion == 1)
                #expect(try checkpoint.decode(HandoverCheckpoint.self).phase == .b)
                if mode == "failure" { throw TaskDefinitionError("broken migration") }
                return (try input.decode(Int.self), HandoverCheckpoint(phase: .c))
            })
        try registry.install(Extension(name: "tasks", tasks: [AnyTaskDefinition(replacement)]))
        #expect(attempts.count == 0)
        gate.release()
        if mode == "success" {
            let receipt = try await harness.waitForTask(id: id, context: .background)
            #expect(receipt.record.version == 2)
            #expect(receipt.outcome == .completed(result: .number(2)))
            #expect(log.values == ["old:a start", "old:a end", "v2:c"])
            #expect(opened.reports.count == 0)
        } else {
            try await harnessEventually { opened.reports.count == 1 }
            let item = try #require(try await harness.inspect(context: .background).tasks.first)
            guard case .blocked(let reason, _) = item.state else {
                Issue.record("Failed handover migration was not blocked")
                try await harness.close(context: .background)
                return
            }
            #expect(reason == .migrationFailed)
            #expect(item.record.version == 1)
            #expect(item.record.state.status == "pending")
            #expect(try #require(item.record.state.checkpoint).decode(HandoverCheckpoint.self).phase == .b)
            #expect(log.values == ["old:a start", "old:a end"])
            #expect(String(describing: opened.reports.values[0]) == "broken migration")
        }
        #expect(attempts.count == 1)
        try await harness.close(context: .background)
    }

}
