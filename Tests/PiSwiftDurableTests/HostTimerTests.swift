@testable import PiSwiftDurable
import PiSwiftDurableTesting
import Synchronization
import Testing

private struct TestHostTimerError: Error {}
private func hostTimerEventually(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<10000 { if predicate() { return true }; await Task.yield() }
    return predicate()
}

@Test func hostTimerDeclineFallsBackAndReportsOnlyOnce() async throws {
    let reports = Mutex<[String]>([])
    let fired = Mutex(0)
    // Upstream v1.4.0 ReportInfo adds the second report callback argument.
    let timers = HarnessTimers(setTimer: { _, _, options in
        #expect(!options.background); return nil
    }, report: { error, _ in reports.withLock { $0.append(String(describing: error)) } })
    let first = timers.setTimer({ fired.withLock { $0 += 1 } }, delay: 0)
    let second = timers.setTimer({ fired.withLock { $0 += 1 } }, delay: 0)
    #expect(first != nil && second != nil)
    #expect(await hostTimerEventually { fired.withLock { $0 == 2 } })
    #expect(reports.withLock { $0 } == ["HarnessOptions.setTimer declined a timer that paces work; using setTimeout"])
}

@Test func throwingHostTimerFallsBackButBackgroundIsDeclined() async {
    let reports = Mutex<[String]>([])
    let fired = Mutex(false)
    // Upstream v1.4.0 ReportInfo adds the second report callback argument.
    let timers = HarnessTimers(setTimer: { _, _, _ in throw TestHostTimerError() },
                               report: { error, _ in reports.withLock { $0.append(String(describing: error)) } })
    let background = timers.setTimer({ Issue.record("Declined background timer fired") }, delay: 0, options: .init(background: true))
    #expect(background == nil)
    let foreground = timers.setTimer({ fired.withLock { $0 = true } }, delay: 0)
    #expect(foreground != nil)
    #expect(await hostTimerEventually { fired.withLock { $0 } })
    #expect(reports.withLock { $0.count } == 2)
    // E1: upstream timers.ts:60-68 reports the original error when a foreground host timer throws.
    #expect(reports.withLock { $0.last } == String(describing: TestHostTimerError()))
}

@Test func declinedBackgroundTimerDoesNotReportOrUseFallback() {
    // Upstream v1.4.0 ReportInfo adds the second report callback argument.
    let timers = HarnessTimers(setTimer: { _, _, options in #expect(options.background); return nil },
                               report: { _, _ in Issue.record("Background refusal must not report") })
    #expect(timers.setTimer({ Issue.record("Declined timer fired") }, delay: 0, options: .init(background: true)) == nil)
}

@Test func hostTimerCancellationRejectsLateAndRepeatedCallbacks() async throws {
    let callback = Mutex<(@Sendable () -> Void)?>(nil)
    let cancellations = Mutex(0)
    let deliveries = Mutex(0)
    let timers = HarnessTimers(setTimer: { fire, _, _ in
        callback.withLock { $0 = fire }
        return { cancellations.withLock { $0 += 1 } }
    })
    let armed = timers.setTimer({ deliveries.withLock { $0 += 1 } }, delay: 12)
    let disarm = try #require(armed)
    disarm(); disarm()
    let fire = try #require(callback.withLock { $0 })
    fire(); fire()
    for _ in 0..<100 { await Task.yield() }
    #expect(cancellations.withLock { $0 } == 1)
    #expect(deliveries.withLock { $0 } == 0)
}

@Test func synchronousHostTimerDeliveryRunsOutsideTheArmingLock() async {
    let lock = Mutex(false)
    let delivered = Mutex(false)
    let timers = HarnessTimers(setTimer: { fire, _, _ in fire(); return {} })
    lock.withLock { value in
        value = true
        _ = timers.setTimer({ lock.withLock { #expect($0) }; delivered.withLock { $0 = true } }, delay: 0)
    }
    #expect(await hostTimerEventually { delivered.withLock { $0 } })
}

@Test func defaultTimersShareClockWhileKeepingDocumentWaitCountsSeparate() async throws {
    let clock = TestClock(now: 1_000), fired = Mutex(false)
    let timers = HarnessTimers(clock: clock)
    let disarm = timers.setTimer({ fired.withLock { $0 = true } }, delay: 25)
    let retention = Task { try await timers.sleep(until: 1_025, background: true, documentRetention: true) }
    try await eventually { clock.pendingSleeperCount == 1 && clock.pendingDocumentRetentionCount == 1 }
    #expect(!fired.withLock { $0 })
    clock.advance(by: 25)
    try await retention.value
    try await eventually { fired.withLock { $0 } }
    #expect(clock.pendingSleeperCount == 0 && clock.pendingDocumentRetentionCount == 0)
    disarm?()

    let cancelled = Task { try await timers.sleep(until: 1_050, background: true, documentRetention: true) }
    try await eventually { clock.pendingDocumentRetentionCount == 1 }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    try await eventually { clock.pendingDocumentRetentionCount == 0 }
}
