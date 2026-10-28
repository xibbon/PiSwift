import PiSwiftChord
import PiSwiftDurableTesting
import Synchronization
import Testing
@testable import PiSwiftDurable

private final class WakeRaceTimers: Sendable {
    private let delays = Mutex<[Double]>([])
    private let cancellations = Mutex(0)
    var armedDelays: [Double] { delays.withLock { $0 } }
    var disarmedCount: Int { cancellations.withLock { $0 } }
    var setTimer: HarnessSetTimer {
        { [self] _, delay, options in
            if options.background { return nil }
            delays.withLock { $0.append(delay) }
            // Hold every callback, as if a native timer fired but its delivery is queued.
            return { [self] in cancellations.withLock { $0 += 1 } }
        }
    }
}

@Test(arguments: [false, true])
func wakeDeliveryReplacesDueTimerWithoutLosingWork(laterSleep: Bool) async throws {
    let clock = TestClock(), timers = WakeRaceTimers(), runs = SessionTestLog<Int>()
    let definition = harnessOneStep("d2.wake-race") { task, runtime, context in
        if task.checkpoint.phase == .run {
            try await runtime.sleepUntil(Double(task.input),
                checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined)), context: context)
            return
        }
        runs.append(task.input)
        try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(Double(task.input)))) }, context: context)
    }
    let registry = Registry()
    try registry.install(Extension(name: "race", tasks: [AnyTaskDefinition(definition)]))
    let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: FakeDurableModels(),
        registry: registry, clock: clock, setTimer: timers.setTimer), context: .background)
    let root = try await harness.root(context: .background)
    let due = try await harnessStart(root, definition, input: 10)
    let later = laterSleep ? try await harnessStart(root, definition, input: 20) : nil
    try harness.resume()
    try await harnessEventually {
        let sleeping = try await harness.getTask(id: due, context: .background)?.state.status == "sleeping"
        let quiet = harness.tasks.state.withLock { !$0.pumping && !$0.wakeScheduled && !$0.reconcileScheduled && $0.reconcilingWork == 0 && $0.invocations.isEmpty }
        var laterReady = true
        if let later { laterReady = try await harness.getTask(id: later, context: .background)?.state.status == "sleeping" }
        return sleeping && laterReady && quiet && timers.armedDelays.contains(10)
    }
    let previousDisarms = timers.disarmedCount
    clock.advance(by: 11)
    // Reproduce a queued wake offer that sees a due sleep before its timer callback.
    harness.tasks.scheduleWake()
    try await harnessEventually { timers.disarmedCount == previousDisarms + 1 }
    print("D2 RACE: old timer disarmed at \(clock.now()), laterSleep=\(laterSleep)")
    try await harnessEventually { try await harness.getTask(id: due, context: .background)?.state.status == "terminal" }
    #expect(runs.values == [10])
    if let later {
        #expect(try await harness.getTask(id: later, context: .background)?.state.status == "sleeping")
        #expect(harness.wake().at == 20)
    }
    try await harness.close(context: .background)
}
