import PiSwiftChord
import PiSwiftDurableTesting
import Synchronization
import Testing
@testable import PiSwiftDurable

/// Advances after returning the time used to calculate a relative delay.
private final class AdvanceOnReadClock: DurableClock {
    let base = TestClock()
    private let advance = Mutex<Int64?>(100)
    func now() -> Int64 {
        let time = base.now()
        if let amount = advance.withLock({ let amount = $0; $0 = nil; return amount }) {
            base.advance(by: amount)
        }
        return time
    }
    func sleep(until deadline: Int64) async throws { try await base.sleep(until: deadline) }
}

@Test func defaultDeadlineTimerDoesNotAddAnOldDelayToANewTime() async throws {
    let clock = AdvanceOnReadClock(), timers = HarnessTimers(clock: clock)
    let wait = settled { try await timers.sleep(until: 100) }
    do {
        try await harnessEventually { wait.isSettled }
        #expect(clock.base.now() == 100 && clock.base.pendingSleeperCount == 0)
        try #require(wait.result).get()
    } catch {
        let detail = "deadline wait expired: now=\(clock.base.now()) sleepers=\(clock.base.pendingSleeperCount)"
        // Release a wrongly shifted timer before reporting the regression.
        clock.base.advance(by: 100)
        throw TaskDefinitionError("\(detail); \(error)")
    }
}

@Test(arguments: [false, true])
func sleepDeadlineCrossedBeforeFirstTimerRunsWithoutAnotherAdvance(advanceInsideArm: Bool) async throws {
    let clock = TestClock(), calls = SessionTestLog<Int>(), arms = SessionTestLog<Double>()
    let definition = harnessOneStep("d2.sleep-admission") { _, runtime, context in
        calls.append(1)
        try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
    }
    let registry = Registry()
    try registry.install(Extension(name: "race", tasks: [AnyTaskDefinition(definition)]))
    let host: HarnessSetTimer = { _, delay, options in
        if options.background { return nil }
        arms.append(delay); clock.advance(by: 11)
        // Hold delivery to expose an overdue timer without incidental callbacks.
        return {}
    }
    let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: FakeDurableModels(),
        registry: registry, clock: clock, setTimer: advanceInsideArm ? host : nil), context: .background)
    let root = try await harness.root(context: .background)
    let id = try await harnessStart(root, definition)
    try await root.commit({ tx in
        let record = try #require(await tx.task(id))
        try tx.setTask(record.replacing(state: .sleeping(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint()), until: 10)))
    }, context: .background)
    try await harnessEventually {
        harness.tasks.state.withLock { !$0.pumping && !$0.wakeScheduled && !$0.reconcileScheduled && $0.reconciles.isEmpty }
    }
    // Hold the wake offer while a real reservation pass skips the future sleep.
    // Release it only after the pass ends, so no incidental work can hide a lost wake.
    harness.tasks.state.withLock { $0.wakeScheduled = true }
    try harness.resume()
    try await harnessEventually {
        harness.tasks.state.withLock {
            !$0.pumping && !$0.dirty && $0.runnable.isEmpty && $0.invocations.isEmpty &&
                !$0.reconcileScheduled && $0.reconciles.isEmpty
        }
    }
    #expect(clock.now() == 0 && calls.values.isEmpty)
    #expect(harness.tasks.state.withLock { $0.sleepAt == nil })
    if !advanceInsideArm { clock.advance(by: 11) }
    harness.tasks.state.withLock { $0.wakeScheduled = false }
    harness.tasks.scheduleWake()
    do {
        try await harnessEventually { try await harness.getTask(id: id, context: .background)?.state.status == "terminal" }
    } catch {
        let detail = harness.tasks.state.withLock { state in
            "sleepAt=\(String(describing: state.sleepAt)) runnable=\(state.runnable.map(\.rawValue)) " +
            "pumping=\(state.pumping) wakeScheduled=\(state.wakeScheduled)"
        }
        try await harness.close(context: .background)
        throw TaskDefinitionError("terminal wait expired: advanceInsideArm=\(advanceInsideArm) now=\(clock.now()) \(detail); \(error)")
    }
    #expect(calls.values == [1])
    #expect(clock.now() == 11)
    #expect(arms.values == (advanceInsideArm ? [10] : []))
    try await harness.close(context: .background)
}

@Test(arguments: [false, true])
func deadlineTimerKeepsItsTargetWhenAnAdvancePassesMultipleChunks(overrideNow: Bool) async throws {
    let clock = TestClock(), deadline: Int64 = 4_294_967_300
    let offset: Int64 = overrideNow ? 1_000 : 0
    let now: @Sendable () -> Int64 = { clock.now() + offset }
    let timers = HarnessTimers(clock: clock, now: overrideNow ? now : nil)
    let work = Task { try await timers.sleep(until: deadline + offset) }
    defer { work.cancel() }
    try await harnessEventually { clock.pendingSleeperCount == 1 }
    clock.advance(by: deadline)
    let result = settled { try await work.value }
    try await harnessEventually { result.isSettled }
    try #require(result.result).get()
    #expect(clock.pendingSleeperCount == 0)
}

@Test func deadlineClockWaitRechecksAnEarlyHostCallback() async throws {
    let clock = TestClock(), callbacks = SessionTestLog<@Sendable () -> Void>(), delays = SessionTestLog<Double>()
    let timers = HarnessTimers(clock: clock, setTimer: { callback, delay, _ in
        delays.append(delay); callbacks.append(callback); return {}
    })
    let work = Task { try await timers.sleep(until: 100) }
    defer { work.cancel() }
    try await harnessEventually { callbacks.values.count == 1 }
    callbacks.values[0]()
    try await harnessEventually { callbacks.values.count == 2 }
    #expect(delays.values == [100, 100])
    let result = settled { try await work.value }
    #expect(!result.isSettled)
    clock.advance(by: 100); callbacks.values[1]()
    try await harnessEventually { result.isSettled }
    try #require(result.result).get()
}
