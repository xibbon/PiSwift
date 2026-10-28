import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private struct SleepCheckpoint: TaskCheckpoint {
    enum Phase: String, Codable, Sendable { case start, after }
    var phase: Phase = .start
    var slept: Double? = nil
}
private typealias SleepTask = TaskDefinition<Int, SleepCheckpoint, Double, NoTaskHooks>

private func napTask(_ delay: Double, runs: SessionTestLog<Double> = .init()) -> SleepTask {
    SleepTask(name: "test.nap", version: 1, initial: { _ in SleepCheckpoint() }, phase: { task, runtime, context in
        switch task.checkpoint.phase {
        case .start:
            try await runtime.sleepUntil(Double(try runtime.now()) + delay,
                checkpoint: try JSONValue(encoding: SleepCheckpoint(phase: .after, slept: delay)), context: context)
        case .after:
            let resumed = Double(try runtime.now())
            runs.append(resumed)
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(resumed))) }, context: context)
        }
    }, abort: { _, runtime, context in
        try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "test")) }, context: context)
    })
}

private final class SleepTimer: Sendable {
    let delay: Double
    let callback: @Sendable () -> Void
    private let cancelled = Mutex(false)
    init(delay: Double, callback: @escaping @Sendable () -> Void) { self.delay = delay; self.callback = callback }
    var disarmed: Bool { cancelled.withLock { $0 } }
    func disarm() { cancelled.withLock { $0 = true } }
}
private final class SleepTimers: Sendable {
    private let timers = Mutex<[SleepTimer]>([])
    var armed: [SleepTimer] { timers.withLock { $0 } }
    var live: [SleepTimer] { armed.filter { !$0.disarmed } }
    var setTimer: HarnessSetTimer {
        { [self] callback, delay, options in
            if options.background { return nil }
            let timer = SleepTimer(delay: delay, callback: callback)
            timers.withLock { $0.append(timer) }
            return { timer.disarm() }
        }
    }
}
private func sleepOpen(_ tasks: [AnyTaskDefinition], storage: any DurableStorage = MemoryStorage(),
                       clock: any DurableClock = SystemDurableClock(), setTimer: HarnessSetTimer? = nil,
                       onWake: (@Sendable (HarnessWake) throws -> Void)? = nil) async throws -> (harness: Harness, registry: Registry, reports: HarnessReports) {
    let registry = Registry(), reports = HarnessReports()
    if !tasks.isEmpty { try registry.install(Extension(name: "tasks", tasks: tasks)) }
    let harness = try await Harness.open(storage: storage,
        options: .init(models: FakeDurableModels(), registry: registry, clock: clock,
            setTimer: setTimer, onWake: onWake, onReport: { reports.append($0) }), context: .background)
    return (harness: harness, registry: registry, reports: reports)
}
private func startNap(_ harness: Harness, _ task: SleepTask) async throws -> TaskID {
    let root = try await harness.root(context: .background)
    return try await root.commit({ tx in
        try await tx.createTask(task, input: 0, options: .init(ownership: .conversation()))
    }, context: .background)
}
private func sleepState(_ harness: Harness, _ id: TaskID) async throws -> TaskState? {
    try await harness.getTask(id: id, context: .background)?.state
}
// Match the upstream settle helper: allow queued work and host callbacks to finish.
private func settleSleep() async throws {
    for _ in 0..<10 { await Task.yield() }
    try await Task.sleep(for: .milliseconds(20))
    for _ in 0..<10 { await Task.yield() }
}

@Suite struct HarnessSleepTests {
    // upstream v1.4.0 harness-sleep.test.ts:88
    @Test func sleepHasNoInvocationAndResumesOnceAtCheckpoint() async throws {
        let clock = TestClock(now: 1_000), wakes = SessionTestLog<HarnessWake>(), runs = SessionTestLog<Double>()
        let nap = napTask(1_000, runs: runs)
        let opened = try await sleepOpen([AnyTaskDefinition(nap)], clock: clock, onWake: { wakes.append($0) })
        let harness = opened.harness
        let graph = try await harness.taskGraph(context: .background)
        let id = try await startNap(harness, nap)
        try harness.resume()
        try await harnessEventually { try await sleepState(harness, id)?.status == "sleeping" }
        #expect(try await sleepState(harness, id) == .sleeping(
            checkpoint: .object(["phase": .string("after"), "slept": .number(1_000)]), until: 2_000))
        let inspection = try await harness.inspect(context: .background)
        if case .sleeping(let until) = inspection.tasks.first(where: { $0.record.id == id })?.state {
            #expect(until == 2_000)
        } else { Issue.record("Expected sleeping inspection") }
        #expect(graph.value.tasks[String(id.rawValue)]?.state == .sleeping(phase: "after", until: 2_000))
        try await harnessEventually { !harness.wake().active }
        #expect(harness.tasks.state.withLock { $0.invocations[id] == nil })
        #expect(harness.wake() == HarnessWake(active: false, at: 2_000))
        try await harnessEventually { wakes.values.last == HarnessWake(active: false, at: 2_000) }

        clock.advance(by: 999)
        try harness.resume(); try harness.resume()
        try await settleSleep()
        #expect(runs.count == 0)
        #expect(try await sleepState(harness, id)?.status == "sleeping")
        clock.advance(by: 1)
        try harness.resume(); try harness.resume()
        #expect(try await harness.waitForTask(id: id, context: .background).outcome == .completed(result: .number(2_000)))
        #expect(runs.values == [2_000])
        try await harnessEventually { !harness.wake().active && wakes.values.last == HarnessWake(active: false) }
        #expect(harness.wake() == HarnessWake(active: false))
        let delivered = wakes.values
        for (previous, next) in zip(delivered, delivered.dropFirst()) { #expect(previous != next) }
        #expect(delivered.contains(HarnessWake(active: true)))
        #expect(delivered.contains(HarnessWake(active: false, at: 2_000)))
        graph.dispose()
        try await harness.close(context: .background)
    }

    // upstream v1.4.0 harness-sleep.test.ts:140
    @Test func sleepSurvivesSqliteReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("session.sqlite").path
        let clock = TestClock(now: 1_000), nap = napTask(60_000)
        let first = try await sleepOpen([AnyTaskDefinition(nap)], storage: SqliteStorage.open(path: path), clock: clock, onWake: { _ in })
        let id = try await startNap(first.harness, nap)
        try first.harness.resume()
        try await harnessEventually { try await sleepState(first.harness, id)?.status == "sleeping" }
        try await first.harness.close(context: .background)
        let second = try await sleepOpen([AnyTaskDefinition(nap)], storage: SqliteStorage.open(path: path), clock: clock, onWake: { _ in })
        try await harnessEventually { !second.harness.wake().active }
        #expect(second.harness.wake() == HarnessWake(active: false, at: 61_000))
        try second.harness.resume()
        try await settleSleep()
        #expect(try await sleepState(second.harness, id)?.status == "sleeping")
        try await second.harness.close(context: .background)
        clock.advance(by: 60_000)
        let third = try await sleepOpen([AnyTaskDefinition(nap)], storage: SqliteStorage.open(path: path), clock: clock, onWake: { _ in })
        #expect(third.harness.wake() == HarnessWake(active: true))
        try third.harness.resume()
        #expect(try await third.harness.waitForTask(id: id, context: .background).outcome == .completed(result: .number(61_000)))
        try await third.harness.close(context: .background)
    }

    // upstream v1.4.0 harness-sleep.test.ts:168; also check an early timer fire.
    @Test func hostTimerResumesSleepAndRechecksEarlyFire() async throws {
        let clock = TestClock(now: 1_000), timers = SleepTimers(), runs = SessionTestLog<Double>()
        let nap = napTask(500, runs: runs)
        let harness = try await sleepOpen([AnyTaskDefinition(nap)], clock: clock, setTimer: timers.setTimer).harness
        let id = try await startNap(harness, nap)
        try harness.resume()
        try await harnessEventually { timers.live.contains { $0.delay == 500 } }
        #expect(try await sleepState(harness, id)?.status == "sleeping")
        let early = try #require(timers.live.first { $0.delay == 500 })
        clock.advance(by: 200); early.callback()
        try await harnessEventually { timers.live.contains { $0.delay == 300 } }
        #expect(runs.count == 0)
        #expect(try await sleepState(harness, id)?.status == "sleeping")
        clock.advance(by: 300)
        try #require(timers.live.first { $0.delay == 300 }).callback()
        // Poll the record. waitForTask() itself resumes due sleeps.
        try await harnessEventually { try await sleepState(harness, id)?.status == "terminal" }
        #expect(try await sleepState(harness, id) == .terminal(outcome: .completed(result: .number(1_500))))
        try await harness.close(context: .background)
    }

    // upstream v1.4.0 harness-sleep.test.ts:188
    @Test func anyPassResumesDueSleepBeforeItsTimerFires() async throws {
        let clock = TestClock(now: 1_000), timers = SleepTimers(), nap = napTask(500)
        let opened = try await sleepOpen([AnyTaskDefinition(nap)], clock: clock, setTimer: timers.setTimer)
        let id = try await startNap(opened.harness, nap)
        try opened.harness.resume()
        try await harnessEventually { try await sleepState(opened.harness, id)?.status == "sleeping" }
        clock.advance(by: 500)
        try opened.registry.install(Extension(name: "unrelated"))
        try await harnessEventually { try await sleepState(opened.harness, id)?.status == "terminal" }
        #expect(try await sleepState(opened.harness, id) == .terminal(outcome: .completed(result: .number(1_500))))
        try await opened.harness.close(context: .background)
    }

    // upstream v1.4.0 harness-sleep.test.ts:208
    @Test func abortAndCloseDisarmSleepTimers() async throws {
        let timers = SleepTimers(), nap = napTask(500)
        let harness = try await sleepOpen([AnyTaskDefinition(nap)], clock: TestClock(now: 1_000), setTimer: timers.setTimer).harness
        let aborted = try await startNap(harness, nap)
        try harness.resume()
        try await harnessEventually { timers.live.contains { $0.delay == 500 } }
        _ = try await harness.abortTask(id: aborted, context: .background)
        _ = try await harness.waitForTask(id: aborted, context: .background)
        try await harnessEventually { timers.live.isEmpty }
        let kept = try await startNap(harness, nap)
        try await harnessEventually { try await sleepState(harness, kept)?.status == "sleeping" && timers.live.count == 1 }
        #expect(timers.live.map(\.delay) == [500])
        try await harness.close(context: .background)
        #expect(timers.live.isEmpty)
    }

    // upstream v1.4.0 harness-sleep.test.ts:229
    @Test func invocationEndDisarmsTimersAndIgnoresLateFire() async throws {
        let timers = SleepTimers(), fired = SessionTestLog<String>()
        let timed = harnessOneStep("test.timed") { _, runtime, context in
            _ = runtime.setTimer({ fired.append("late") }, delay: 60_000)
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }
        let harness = try await sleepOpen([AnyTaskDefinition(timed)], setTimer: timers.setTimer).harness
        let root = try await harness.root(context: .background)
        _ = try await harness.waitForTask(id: harnessStart(root, timed), context: .background)
        let timer = try #require(timers.armed.first { $0.delay == 60_000 })
        try await harnessEventually { timer.disarmed }
        timer.callback()
        #expect(fired.values.isEmpty)
        try await harness.close(context: .background)
    }

    // upstream v1.4.0 harness-sleep.test.ts:260
    @Test func onWakePreventsSleepTimer() async throws {
        let clock = TestClock(now: 1_000), timers = SleepTimers(), nap = napTask(500)
        let harness = try await sleepOpen([AnyTaskDefinition(nap)], clock: clock, setTimer: timers.setTimer, onWake: { _ in }).harness
        let id = try await startNap(harness, nap)
        try harness.resume()
        try await harnessEventually { try await sleepState(harness, id)?.status == "sleeping" }
        try await settleSleep()
        #expect(timers.armed.isEmpty)
        clock.advance(by: 500)
        #expect(harness.wake() == HarnessWake(active: true))
        try harness.resume()
        #expect(try await harness.waitForTask(id: id, context: .background).outcome.status == "completed")
        try await harness.close(context: .background)
    }

    // upstream v1.4.0 harness-sleep.test.ts:281
    @Test func declinedForegroundTimerUsesFallbackAndReportsOnce() async throws {
        let clock = TestClock(now: 1_000), nap = napTask(10)
        let opened = try await sleepOpen([AnyTaskDefinition(nap)], clock: clock, setTimer: { _, _, _ in nil })
        let first = try await startNap(opened.harness, nap), second = try await startNap(opened.harness, nap)
        try opened.harness.resume()
        // Keep host time fixed until a timer is required, even on a loaded test runner.
        try await harnessEventually {
            let firstState = try await sleepState(opened.harness, first)
            let secondState = try await sleepState(opened.harness, second)
            return firstState?.status == "sleeping" && secondState?.status == "sleeping" && opened.reports.count == 1
        }
        clock.advance(by: 10)
        // The native fallback must start the pass; a waitForTask call would also resume work.
        try await harnessEventually {
            let firstState = try await sleepState(opened.harness, first)
            let secondState = try await sleepState(opened.harness, second)
            return firstState?.status == "terminal" && secondState?.status == "terminal"
        }
        #expect(try await opened.harness.waitForTask(id: first, context: .background).outcome.status == "completed")
        #expect(try await opened.harness.waitForTask(id: second, context: .background).outcome.status == "completed")
        #expect(opened.reports.values.map { String(describing: $0) } == [
            "HarnessOptions.setTimer declined a timer that paces work; using setTimeout"
        ])
        try await opened.harness.close(context: .background)
    }

    // upstream v1.4.0 harness-sleep.test.ts:295
    @Test(arguments: [false, true]) func waitingAndHeldOutcomeOverSleepingChildAreInactive(hold: Bool) async throws {
        let child = napTask(500)
        let parent = harnessOneStep("test.parent") { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                try await runtime.commit({ tx, _ in
                    let childID = try await tx.createTask(child, input: 0, options: .init(ownership: .task(taskId: task.id)))
                    let checkpoint = try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined, ids: [childID]))
                    return hold ? .running(checkpoint: checkpoint) : .waiting(checkpoint: checkpoint, on: [childID], policy: .allSettled)
                }, context: context)
            case .joined:
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
            }
        }
        let harness = try await sleepOpen([AnyTaskDefinition(parent), AnyTaskDefinition(child)], clock: TestClock(now: 1_000), onWake: { _ in }).harness
        let root = try await harness.root(context: .background), id = try await harnessStart(root, parent)
        try harness.resume()
        try await harnessEventually { try await sleepState(harness, id)?.status == (hold ? "completing" : "waiting") }
        try await harnessEventually { harness.wake() == HarnessWake(active: false, at: 1_500) }
        #expect(harness.wake() == HarnessWake(active: false, at: 1_500))
        try await harness.close(context: .background)
    }

    // upstream v1.4.0 harness-sleep.test.ts:339
    @Test func sleepingTaskRunsAbortHandlerBeforeDeadline() async throws {
        let nap = napTask(60_000)
        let harness = try await sleepOpen([AnyTaskDefinition(nap)], clock: TestClock(now: 1_000), onWake: { _ in }).harness
        let id = try await startNap(harness, nap)
        try harness.resume()
        try await harnessEventually { try await sleepState(harness, id)?.status == "sleeping" }
        _ = try await harness.abortTask(id: id, context: .background)
        #expect(try await harness.waitForTask(id: id, context: .background).outcome == .aborted(reason: "test"))
        try await harness.close(context: .background)
    }

    // upstream v1.4.0 harness-sleep.test.ts:351
    @Test func invalidDeadlineAndSleepInAbortHandlerAreRejected() async throws {
        let errors = SessionTestLog<String>()
        let invalid = harnessOneStep("test.invalid-sleep") { _, runtime, context in
            for until in [Double.nan, -1, .infinity] {
                do {
                    try await runtime.sleepUntil(until, checkpoint: .object(["phase": .string("joined")]), context: context)
                    Issue.record("Invalid sleep returned")
                } catch { errors.append(String(describing: error)) }
            }
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }
        let aborting = harnessOneStep("test.sleep-in-abort", run: { _, runtime, _ in
            try await harnessEventually { runtime.signal.aborted }
        }, abort: { _, runtime, context in
            do {
                try await runtime.sleepUntil(Double(try runtime.now()) + 10, checkpoint: .object(["phase": .string("run")]), context: context)
                Issue.record("Abort sleep returned")
            } catch { errors.append(String(describing: error)) }
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "test")) }, context: context)
        })
        let harness = try await sleepOpen([AnyTaskDefinition(invalid), AnyTaskDefinition(aborting)]).harness
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, invalid), abortingID = try await harnessStart(root, aborting)
        try harness.resume()
        #expect(try await harness.waitForTask(id: id, context: .background).outcome.status == "completed")
        _ = try await harness.abortTask(id: abortingID, context: .background)
        #expect(try await harness.waitForTask(id: abortingID, context: .background).outcome.status == "aborted")
        #expect(errors.values == [
            "Task \(id.rawValue) cannot sleep until NaN: not a time in milliseconds",
            "Task \(id.rawValue) cannot sleep until -1: not a time in milliseconds",
            "Task \(id.rawValue) cannot sleep until Infinity: not a time in milliseconds",
            "Abort handler of task \(abortingID.rawValue) cannot sleep"
        ])
        try await harness.close(context: .background)
    }

    // upstream v1.4.0 harness-sleep.test.ts:405
    @Test func missingDefinitionDoesNotCountAsActive() async throws {
        let missing = napTask(10), harness = try await sleepOpen([]).harness
        _ = try await startNap(harness, missing)
        try await harnessEventually { !harness.wake().active }
        #expect(harness.wake() == HarnessWake(active: false))
        try harness.resume()
        try await settleSleep()
        try await harnessEventually { !harness.wake().active }
        #expect(harness.wake() == HarnessWake(active: false))
        try await harness.close(context: .background)
    }

    // upstream v1.4.0 harness-sleep.test.ts:420
    @Test func throwingOnWakeIsReportedAndOfferedAgain() async throws {
        let clock = TestClock(now: 1_000), wakes = SessionTestLog<HarnessWake>(), failing = Mutex(true), nap = napTask(1_000)
        let opened = try await sleepOpen([AnyTaskDefinition(nap)], clock: clock, onWake: { wake in
            wakes.append(wake)
            if failing.withLock({ $0 }) && wake.at != nil { throw TaskDefinitionError("alarm failed") }
        })
        let id = try await startNap(opened.harness, nap)
        try opened.harness.resume()
        try await harnessEventually { wakes.values.contains(HarnessWake(active: false, at: 2_000)) && opened.reports.count > 0 }
        #expect(opened.reports.values.contains { String(describing: $0) == "alarm failed" })
        failing.withLock { $0 = false }
        let offered = wakes.count
        try opened.registry.install(Extension(name: "unrelated"))
        try await harnessEventually { wakes.count > offered }
        #expect(wakes.values.last == HarnessWake(active: false, at: 2_000))
        clock.advance(by: 1_000)
        try opened.harness.resume()
        _ = try await opened.harness.waitForTask(id: id, context: .background)
        try await harnessEventually { wakes.values.last == HarnessWake(active: false) }
        try await opened.harness.close(context: .background)
    }
}
