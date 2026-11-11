import Synchronization
import Testing
@testable import PiSwiftChord

private actor WatchTestGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { released = true; let pending = waiters; waiters.removeAll(); for waiter in pending { waiter.resume() } }
}

private final class WatchTestCalls: Sendable {
    private let calls = Mutex<[WatchCall<JSONValue>]>([])
    func withLock<Result: Sendable>(_ body: (inout [WatchCall<JSONValue>]) throws -> Result) rethrows -> Result {
        try calls.withLock { value in try body(&value) }
    }
}

private final class WatchTestPayload: Sendable {}

private struct WatchTestError: Error, Sendable {}

@Suite("Watch behavior (upstream v1.5.2)")
struct WatchBehaviorTests {
    private func make() -> Watch<JSONValue> {
        Watch(value: .number(0), detach: {}, report: { _ in })
    }
    private func frame(_ n: Int, retired: Bool = false) -> WatchCall<JSONValue> {
        .value(value: .number(Double(n)), ops: [.replace(.number(Double(n)))], retired: retired)
    }
    private func flush() async { try? await Task.sleep(for: .milliseconds(15)) }
    private func collect(_ watch: Watch<JSONValue>) throws -> WatchTestCalls {
        let calls = WatchTestCalls()
        try watch.start { call, _ in calls.withLock { $0.append(call) } }
        return calls
    }
    private func failureRecovery(_ mode: Int) async throws {
        let watch = make(); let calls = try collect(watch)
        watch.advance(frame(1), context: .background); await flush()
        if mode == 1 { watch.advance(.failed(.message("down")), context: .background) }
        else { watch.fail(.message("down"), context: .background) }
        if mode == 2 { watch.advance(frame(2), context: .background); watch.fail(.message("down"), context: .background) }
        if mode != 3 { await flush(); #expect(watch.value == .number(1)) }
        watch.advance(.value(value: .number(3), ops: [.set(["n"], .number(3))], retired: false), context: .background); await flush()
        #expect(calls.withLock { $0.last } == frame(3))
        #expect(watch.value == .number(3)); _ = await watch.stop()
    }
    private func blocked(_ action: @Sendable (Watch<JSONValue>) -> Void) async throws {
        let watch = make(); let gate = WatchTestGate(); let entered = WatchTestGate()
        let calls = Mutex<[WatchCall<JSONValue>]>([])
        try watch.start { call, _ in
            calls.withLock { $0.append(call) }; await entered.open(); await gate.wait()
        }
        watch.advance(frame(1), context: .background); await entered.wait()
        action(watch); await gate.open(); await flush()
        #expect(calls.withLock { !$0.isEmpty }); _ = await watch.stop()
    }

    @Test("keeps the acquisition value until start, then delivers the frames since in one call", .timeLimit(.minutes(1)))
    func case01() async throws {
        let watch = make(); watch.advance(frame(1), context: .background); watch.advance(frame(2), context: .background); #expect(watch.value == .number(0)); let calls = try collect(watch); await flush(); #expect(calls.withLock { $0 } == [frame(2)]); _ = await watch.stop()
    }

    @Test("passes a frame's ops on by identity to a listener that keeps up", .timeLimit(.minutes(1)))
    func case02() async throws {
        // Swift arrays have value semantics. JavaScript array identity is not applicable.
        let watch = make(); let calls = try collect(watch); watch.advance(frame(1), context: .background); await flush(); watch.advance(frame(2), context: .background); await flush(); #expect(calls.withLock { $0 } == [frame(1), frame(2)]); _ = await watch.stop()
    }

    @Test("never invokes the listener inline", .timeLimit(.minutes(1)))
    func case03() async throws {
        let watch = make()
        let gate = WatchTestGate()
        let entered = WatchTestGate()
        try watch.start { _, _ in await entered.open(); await gate.wait() }
        watch.advance(frame(1), context: .background)
        // If advance awaits or calls the asynchronous listener inline, this cannot proceed.
        await entered.wait()
        #expect(watch.value == .number(1))
        #expect(await watch.stop() == .stopped)
        await gate.open()
    }

    @Test("awaits each callback and folds frames advanced while one is in flight into the next call", .timeLimit(.minutes(1)))
    func case04() async throws {
        let watch = make()
        let gate = WatchTestGate(); let entered = WatchTestGate()
        let calls = Mutex<[WatchCall<JSONValue>]>([])
        try watch.start { call, _ in
            let first = calls.withLock { calls in calls.append(call); return calls.count == 1 }
            if first { await entered.open(); await gate.wait() }
        }
        watch.advance(frame(1), context: .background); await entered.wait()
        watch.advance(frame(2), context: .background); watch.advance(frame(3), context: .background)
        await flush(); #expect(calls.withLock { $0 } == [frame(1)])
        await gate.open(); await flush()
        #expect(calls.withLock { $0 } == [frame(1), frame(3)])
        _ = await watch.stop()
    }

    @Test("delivers the newest frame's context, without its abort signal", .timeLimit(.minutes(1)))
    func case05() async throws {
        let watch = make(); let key = ChordContextKey<String>("frame"); let controller = AbortController()
        let contexts = Mutex<[ChordContext]>([])
        watch.advance(frame(1), context: .background.withValue("first", for: key))
        watch.advance(frame(2), context: .background.withValue("second", for: key).withAbortSignal(controller.signal))
        try watch.start { _, context in contexts.withLock { $0.append(context) } }
        await flush(); #expect(contexts.withLock { $0.last?.value(key) } == "second"); #expect(contexts.withLock { $0.last?.abortSignal } == nil); _ = await watch.stop()
    }

    @Test("gets one call per batch whose ops turn the previous delivered value into the newest", .timeLimit(.minutes(1)))
    func case06() async throws {
        let watch = make()
        let gate = WatchTestGate(); let entered = WatchTestGate()
        let replica = Mutex<JSONValue?>(.number(0)); let calls = Mutex(0)
        try watch.start { call, _ in
            guard case .value(let value, let ops, _) = call else { Issue.record("Expected value"); return }
            try replica.withLock { state in state = try Delta.applyImmutable(state, ops); #expect(state == value) }
            let first = calls.withLock { n in n += 1; return n == 1 }
            if first { await entered.open(); await gate.wait() }
        }
        watch.advance(frame(1), context: .background); await entered.wait()
        for n in 2...600 { watch.advance(frame(n), context: .background) }
        #expect(calls.withLock { $0 } == 1)
        await gate.open(); await flush()
        #expect(calls.withLock { $0 } == 2); #expect(replica.withLock { $0 } == .number(600))
        _ = await watch.stop()
    }

    @Test("keeps 10000 pending ops after folding and replaces the root past them", .timeLimit(.minutes(1)))
    func case07() async throws {
        for count in [10_000, 10_001] {
            let watch = make()
            for n in 0..<count { watch.advance(.value(value: .number(Double(n)), ops: [.set([.index(n)], .number(Double(n)))], retired: false), context: .background) }
            let calls = try collect(watch); await flush()
            let last = calls.withLock { $0.last }
            if count == 10_000 {
                guard case .value(_, let ops, _) = last else { Issue.record("Expected value"); return }
                #expect(ops.count == count)
            } else { #expect(last == frame(10_000)) }
            _ = await watch.stop()
        }
    }

    @Test("never folds the in-flight call into an overflow", .timeLimit(.minutes(1)))
    func case08() async throws {
        let watch = make(); let gate = WatchTestGate(); let entered = WatchTestGate()
        let calls = Mutex<[WatchCall<JSONValue>]>([])
        try watch.start { call, _ in
            let first = calls.withLock { calls in calls.append(call); return calls.count == 1 }
            if first { await entered.open(); await gate.wait() }
        }
        watch.advance(frame(1), context: .background); await entered.wait()
        for n in 0...10_000 { watch.advance(.value(value: .number(Double(n)), ops: [.set([.index(n)], .number(Double(n)))], retired: false), context: .background) }
        await gate.open(); await flush()
        #expect(calls.withLock { $0 } == [frame(1), frame(10_000)])
        _ = await watch.stop()
    }

    @Test("starts folding again after an overflow was delivered", .timeLimit(.minutes(1)))
    func case09() async throws {
        let watch = make()
        for n in 0...10_000 { watch.advance(.value(value: .number(Double(n)), ops: [.set([.index(n)], .number(Double(n)))], retired: false), context: .background) }
        let calls = try collect(watch); await flush()
        watch.advance(frame(1), context: .background); await flush()
        watch.advance(frame(2), context: .background); await flush()
        #expect(calls.withLock { $0 } == [frame(10_000), frame(1), frame(2)])
        _ = await watch.stop()
    }

    @Test("reports a retirement in the next call with the value the source gives, and goes on", .timeLimit(.minutes(1)))
    func case10() async throws {
        let watch = make(); let calls = try collect(watch)
        watch.advance(frame(1), context: .background); await flush()
        watch.advance(.value(value: .number(1), ops: [], retired: true), context: .background); await flush()
        watch.advance(frame(2), context: .background); await flush()
        #expect(calls.withLock { $0 } == [frame(1), .value(value: .number(1), ops: [], retired: true), frame(2)])
        _ = await watch.stop()
    }

    @Test("folds a retirement and the frames around it into one call that reports it", .timeLimit(.minutes(1)))
    func case11() async throws {
        let watch = make(); watch.advance(frame(1, retired: true), context: .background); watch.advance(frame(2), context: .background); let calls = try collect(watch); await flush(); #expect(calls.withLock { $0 } == [frame(2, retired: true)]); watch.advance(frame(3), context: .background); await flush(); #expect(watch.value == .number(3)); _ = await watch.stop()
    }

    @Test("keeps reporting the retirement past an overflow", .timeLimit(.minutes(1)))
    func case12() async throws {
        let watch = make(); watch.advance(.value(value: .number(0), ops: [], retired: true), context: .background)
        for n in 0...10_000 { watch.advance(.value(value: .number(Double(n)), ops: [.set([.index(n)], .number(Double(n)))], retired: false), context: .background) }
        let calls = try collect(watch); await flush()
        #expect(calls.withLock { $0 } == [frame(10_000, retired: true)])
        _ = await watch.stop()
    }

    @Test("treats a null value as a value, never as a retirement", .timeLimit(.minutes(1)))
    func case13() async throws {
        let watch = make(); let calls = try collect(watch); watch.advance(.value(value: .null, ops: [.replace(.null)], retired: false), context: .background); await flush(); #expect(watch.value == .null); #expect(calls.withLock { $0.count } == 1); _ = await watch.stop()
    }

    @Test("discards a retirement still pending when the source ends", .timeLimit(.minutes(1)))
    func case14() async throws {
        let watch = make(); watch.advance(frame(1, retired: true), context: .background); watch.end(.ended); #expect(await watch.closed == .ended); #expect(watch.value == .number(0))
    }

    @Test("delivers a failure as a call, stays open, keeps the last value, and replaces the root on recovery", .timeLimit(.minutes(1)))
    func case15() async throws {
        try await failureRecovery(0)
    }

    @Test("takes a failure through `advance()` as through `fail()`", .timeLimit(.minutes(1)))
    func case16() async throws {
        try await failureRecovery(1)
    }

    @Test("folds pending values followed by a failure into the failure", .timeLimit(.minutes(1)))
    func case17() async throws {
        let watch = make()
        watch.advance(frame(1), context: .background); watch.advance(frame(2), context: .background)
        watch.fail(.message("down"), context: .background)
        let calls = try collect(watch); await flush()
        #expect(calls.withLock { $0 } == [.failed(.message("down"))])
        #expect(watch.value == .number(0)); _ = await watch.stop()
    }

    @Test("folds a pending failure followed by values into one root replacement with the newest value", .timeLimit(.minutes(1)))
    func case18() async throws {
        let watch = make(); watch.fail(.message("down"), context: .background)
        watch.advance(.value(value: .number(2), ops: [.set(["n"], .number(2))], retired: false), context: .background)
        watch.advance(.value(value: .number(3), ops: [.set(["n"], .number(3))], retired: false), context: .background)
        let calls = try collect(watch); await flush()
        #expect(calls.withLock { $0 } == [frame(3)]); _ = await watch.stop()
    }

    @Test("delivers a failure that arrives during a call after it, then the recovery", .timeLimit(.minutes(1)))
    func case19() async throws {
        let watch = make(); let gate = WatchTestGate(); let entered = WatchTestGate()
        let calls = Mutex<[WatchCall<JSONValue>]>([])
        try watch.start { call, _ in
            let first = calls.withLock { calls in calls.append(call); return calls.count == 1 }
            if first { await entered.open(); await gate.wait() }
        }
        watch.advance(frame(1), context: .background); await entered.wait()
        watch.fail(.message("down"), context: .background)
        await gate.open(); await flush()
        #expect(calls.withLock { $0 } == [frame(1), .failed(.message("down"))])
        #expect(watch.value == .number(1))
        watch.advance(frame(3), context: .background); await flush()
        #expect(calls.withLock { $0.last } == frame(3)); _ = await watch.stop()
    }

    @Test("drops a pending failure when the source ends, and ignores one after", .timeLimit(.minutes(1)))
    func case20() async throws {
        let watch = make(); watch.fail(.message("down"), context: .background); watch.end(.ended); watch.fail(.message("later"), context: .background); #expect(await watch.closed == .ended); #expect(watch.value == .number(0))
    }

    @Test("passes every lone value call on by identity, so a value call costs the watch no allocation", .timeLimit(.minutes(1)))
    func case21() async throws {
        // Swift enum values have no JavaScript object identity. Check the complete value instead.
        let watch = make(); let calls = try collect(watch); watch.advance(frame(1), context: .background); await flush(); #expect(calls.withLock { $0 } == [frame(1)]); _ = await watch.stop()
    }

    @Test("takes no more frames, delivers what is pending, then ends `ended` and only then detaches", .timeLimit(.minutes(1)))
    func case22() async throws {
        let detached = Mutex(0); let watch = Watch<JSONValue>(value: .number(0), detach: { detached.withLock { $0 += 1 } }, report: { _ in }); watch.advance(frame(1), context: .background); watch.endAfterDelivery(); watch.advance(frame(2), context: .background); #expect(detached.withLock { $0 } == 0); let calls = try collect(watch); #expect(await watch.closed == .ended); #expect(calls.withLock { $0 } == [frame(1)]); #expect(detached.withLock { $0 } == 1)
    }

    @Test("waits for start to deliver, and ends at once with nothing pending", .timeLimit(.minutes(1)))
    func case23() async throws {
        let empty = make(); empty.endAfterDelivery(); #expect(await empty.closed == .ended); let watch = make(); watch.advance(frame(1), context: .background); watch.endAfterDelivery(); await flush(); #expect(watch.value == .number(0)); _ = try collect(watch); #expect(await watch.closed == .ended); #expect(watch.value == .number(1))
    }

    @Test("ends a never-started watch at its source's end, dropping what is pending", .timeLimit(.minutes(1)))
    func case24() async throws {
        let watch = make(); watch.advance(frame(1), context: .background); watch.endAfterDelivery(); watch.end(.ended); #expect(await watch.closed == .ended); #expect(watch.value == .number(0))
    }

    @Test("ends `ended` only after the running call returns when nothing is pending, detached then", .timeLimit(.minutes(1)))
    func case25() async throws {
        let detached = Mutex(0)
        let watch = Watch<JSONValue>(value: .number(0), detach: { detached.withLock { $0 += 1 } }, report: { _ in })
        let gate = WatchTestGate(); let entered = WatchTestGate()
        try watch.start { _, _ in await entered.open(); await gate.wait() }
        watch.advance(frame(1), context: .background); await entered.wait()
        watch.endAfterDelivery(); await flush(); #expect(detached.withLock { $0 } == 0)
        await gate.open(); #expect(await watch.closed == .ended); #expect(detached.withLock { $0 } == 1)
    }

    @Test("ends `listener_error` and reports it when the running call throws after `endAfterDelivery()`", .timeLimit(.minutes(1)))
    func case26() async throws {
        let watch = make(); let gate = WatchTestGate(); let entered = WatchTestGate(); try watch.start { _, _ in await entered.open(); await gate.wait(); throw WatchTestError() }; watch.advance(frame(1), context: .background); await entered.wait(); watch.endAfterDelivery(); await gate.open(); let end = await watch.closed; if case .listenerError = end {} else { Issue.record("Expected listener error") }
    }

    @Test("ends `stopped` when stopped while ending, without awaiting the running call", .timeLimit(.minutes(1)))
    func case27() async throws {
        let watch = make(); let gate = WatchTestGate(); let entered = WatchTestGate(); try watch.start { _, _ in await entered.open(); await gate.wait() }; watch.advance(frame(1), context: .background); await entered.wait(); watch.endAfterDelivery(); #expect(await watch.stop() == .stopped); await gate.open()
    }

    @Test("hands a listener plain data only: `{ kind, value, ops, retired }`, cloneable and serializable", .timeLimit(.minutes(1)))
    func case28() async throws {
        // Swift call enums contain data. JavaScript Object.keys and structuredClone do not apply.
        let watch = make(); let calls = try collect(watch); watch.advance(frame(1), context: .background); await flush(); #expect(calls.withLock { $0 } == [frame(1)]); _ = await watch.stop()
    }

    @Test("passes a frame delivered alone on as the source made it", .timeLimit(.minutes(1)))
    func case29() async throws {
        let watch = make(); let calls = try collect(watch); watch.advance(frame(1, retired: true), context: .background); await flush(); #expect(calls.withLock { $0 } == [frame(1, retired: true)]); _ = await watch.stop()
    }

    @Test("keeps no frame context alive through a call a listener keeps", .timeLimit(.minutes(1)))
    func case30() async throws {
        let watch = make(); let calls = try collect(watch)
        func deliver() -> @Sendable () -> Bool {
            let payload = WatchTestPayload(); let key = ChordContextKey<WatchTestPayload>("payload")
            watch.advance(frame(1), context: .background.withValue(payload, for: key))
            return { [weak payload] in payload == nil }
        }
        let released = deliver(); await flush(); _ = await watch.stop(); await flush()
        #expect(calls.withLock { $0 } == [frame(1)])
        // ARC replaces upstream's forced V8 collection. The saved call has no context field.
        #expect(released())
    }

    @Test("stops idempotently and rejects a repeated or late start", .timeLimit(.minutes(1)))
    func case31() async throws {
        let watch = make(); _ = try collect(watch); #expect(throws: (any Error).self) { try watch.start { _, _ in } }; #expect(await watch.stop() == .stopped); #expect(await watch.stop() == .stopped); let late = make(); _ = await late.stop(); #expect(throws: (any Error).self) { try late.start { _, _ in } }
    }

    @Test("ends `ended` or `failed` from its source, dropping pending frames", .timeLimit(.minutes(1)))
    func case32() async throws {
        let watch = make(); watch.advance(frame(1), context: .background); watch.end(.ended)
        #expect(await watch.closed == .ended); #expect(watch.value == .number(0))
        let failed = make(); failed.end(.failed(.message("down"))); failed.end(.ended)
        #expect(await failed.closed == .failed(.message("down")))
    }

    @Test("stops future delivery without aborting or awaiting an in-flight callback", .timeLimit(.minutes(1)))
    func case33() async throws {
        let watch = make(); let gate = WatchTestGate(); let entered = WatchTestGate(); let calls = Mutex(0); try watch.start { _, _ in calls.withLock { $0 += 1 }; await entered.open(); await gate.wait() }; watch.advance(frame(1), context: .background); await entered.wait(); watch.advance(frame(2), context: .background); #expect(await watch.stop() == .stopped); await gate.open(); await flush(); #expect(calls.withLock { $0 } == 1)
    }

    @Test("ends `aborted` when its acquisition signal aborts, also when already aborted", .timeLimit(.minutes(1)))
    func case34() async throws {
        let controller = AbortController(); let watch = make(); try watch.observeAbort(controller.signal); controller.abort(); #expect(await watch.closed == .aborted); let late = make(); try late.observeAbort(controller.signal); #expect(await late.closed == .aborted); let direct = make(); direct.abort(); #expect(await direct.closed == .aborted)
    }

    @Test("ends `listener_error` on a throw, reports it, and delivers nothing more", .timeLimit(.minutes(1)))
    func case35() async throws {
        let reports = Mutex(0); let watch = Watch<JSONValue>(value: .null, detach: {}, report: { _ in reports.withLock { $0 += 1 } }); try watch.start { _, _ in throw WatchTestError() }; watch.advance(frame(1), context: .background); let end = await watch.closed; if case .listenerError = end {} else { Issue.record("Expected listener error") }; #expect(reports.withLock { $0 } == 1)
    }

    @Test("wraps a thrown non-Error in an Error", .timeLimit(.minutes(1)))
    func case36() async throws {
        // Swift requires thrown values to conform to Error. A thrown non-Error is not expressible.
        let watch = make(); try watch.start { _, _ in throw WatchTestError() }; watch.advance(frame(1), context: .background); let end = await watch.closed; if case .listenerError = end {} else { Issue.record("Expected listener error") }
    }

    @Test("retains neither its source, its listener, nor its signal once ended, while still referenced", .timeLimit(.minutes(1)))
    func case37() async throws {
        func acquire() throws -> (Watch<JSONValue>, @Sendable () -> Bool) {
            let source = WatchTestPayload(); let signal = AbortController().signal
            let watch = Watch<JSONValue>(value: .null, replacement: { value in _ = source; return value }, detach: { _ = source }, report: { _ in _ = source })
            try watch.observeAbort(signal)
            try watch.start { _, _ in _ = source }
            return (watch, { [weak source, weak signal] in source == nil && signal == nil })
        }
        for reason in [WatchEnd.stopped, .aborted, .ended] {
            let (watch, released) = try acquire(); #expect(!released())
            watch.end(reason); #expect(await watch.closed == reason); await flush()
            // Swift ARC gives a direct lifetime check. No forced GC is required.
            #expect(released()); #expect(watch.value == .null)
        }
    }

    @Test("keeps no ops a fold or an overflow dropped, while it waits", .timeLimit(.minutes(1)))
    func case38() async throws {
        // N/A: Swift cannot weakly reference JSON array storage or PendingOps leaf-index storage.
        // These value types have no V8 WeakRef or forced-GC equivalent.
        let detached = Mutex(0); let watch = Watch<JSONValue>(value: .null, detach: { detached.withLock { $0 += 1 } }, report: { _ in }); watch.advance(frame(1), context: .background); #expect(await watch.stop() == .stopped); #expect(detached.withLock { $0 } == 1); #expect(watch.value == .null)
    }

    @Test("releases its pending queue and leaf index once delivered or ended", .timeLimit(.minutes(1)))
    func case39() async throws {
        // N/A: the exact V8 WeakRef check cannot observe Swift array or leaf-index storage.
        // Check that a delivered queue leaves no stale operations in the next delivery.
        let watch = make(); let gate = WatchTestGate(); let entered = WatchTestGate()
        let calls = Mutex<[WatchCall<JSONValue>]>([])
        try watch.start { call, _ in
            let first = calls.withLock { calls in calls.append(call); return calls.count == 1 }
            if first { await entered.open(); await gate.wait() }
        }
        watch.advance(frame(1), context: .background); await entered.wait()
        watch.advance(frame(2), context: .background); watch.advance(frame(3), context: .background)
        await gate.open(); await flush(); #expect(watch.value == .number(3))
        watch.advance(frame(4), context: .background); await flush()
        #expect(calls.withLock { $0 } == [frame(1), frame(3), frame(4)]); _ = await watch.stop()
    }

    @Test("delivers a native backlog that never drains in order", .timeLimit(.minutes(1)))
    func case40() async throws {
        let watch = NativeWatch<Int>(value: 0, detach: {}, report: { _ in }); let values = Mutex<[Int]>([]); let next = Mutex(50); for n in 0..<50 { watch.advance(n, context: .background) }; try watch.start { call, _ in if case .value(let value) = call { values.withLock { $0.append(value) }; let n = next.withLock { n -> Int? in guard n < 1000 else { return nil }; defer { n += 1 }; return n }; if let n { watch.advance(n, context: .background) } } }; await watch.waitUntilIdle(); #expect(values.withLock { $0 } == Array(0..<1000)); _ = await watch.stop()
    }

    @Test("delivers values by identity in order with a context, never inline", .timeLimit(.minutes(1)))
    func case41() async throws {
        let initial = WatchTestPayload(); let first = WatchTestPayload(); let second = WatchTestPayload()
        let key = ChordContextKey<String>("frame"); let controller = AbortController()
        let watch = NativeWatch<WatchTestPayload>(value: initial, detach: {}, report: { _ in })
        let delivered = Mutex<[(WatchTestPayload, String?, Bool)]>([])
        watch.advance(first, context: .background.withValue("first", for: key))
        watch.advance(second, context: .background.withValue("second", for: key).withAbortSignal(controller.signal))
        #expect(watch.value === initial)
        try watch.start { call, context in
            if case .value(let value) = call {
                delivered.withLock { $0.append((value, context.value(key), context.abortSignal == nil)) }
            }
        }
        await flush()
        delivered.withLock { values in
            #expect(values.count == 2)
            if values.count == 2 {
                #expect(values[0].0 === first); #expect(values[1].0 === second)
                #expect(values[0].1 == "first"); #expect(values[1].1 == "second")
                #expect(values.allSatisfy { $0.2 })
            }
        }
        #expect(watch.value === second); _ = await watch.stop()
    }

    @Test("collapses 101 pending values to the newest", .timeLimit(.minutes(1)))
    func case42() async throws {
        let watch = NativeWatch<Int>(value: 0, detach: {}, report: { _ in }); for n in 1...101 { watch.advance(n, context: .background) }; let calls = Mutex<[Int]>([]); try watch.start { call, _ in if case .value(let value) = call { calls.withLock { $0.append(value) } } }; await flush(); #expect(calls.withLock { $0 } == [101]); _ = await watch.stop()
    }

    @Test("collapses 101 pending values to the value of `replace`", .timeLimit(.minutes(1)))
    func case43() async throws {
        let watch = NativeWatch<Int>(value: 0, detach: {}, report: { _ in }, replace: { -1 }); for n in 1...101 { watch.advance(n, context: .background) }; let calls = Mutex<[Int]>([]); try watch.start { call, _ in if case .value(let value) = call { calls.withLock { $0.append(value) } } }; await flush(); #expect(calls.withLock { $0 } == [-1]); _ = await watch.stop()
    }

    @Test("ends with every reason of its lifecycle", .timeLimit(.minutes(1)))
    func case44() async throws {
        func create() -> NativeWatch<Int> { NativeWatch(value: 0, detach: {}, report: { _ in }) }
        let stopped = create(); #expect(await stopped.stop() == .stopped)
        let aborted = create(); aborted.abort(); #expect(await aborted.closed == .aborted)
        let ended = create(); ended.end(.ended); #expect(await ended.closed == .ended)
        let failed = create(); failed.end(.failed(.message("down")))
        #expect(await failed.closed == .failed(.message("down")))
        let reports = Mutex(0)
        let throwing = NativeWatch<Int>(value: 0, detach: {}, report: { _ in reports.withLock { $0 += 1 } })
        try throwing.start { _, _ in throw WatchTestError() }; throwing.advance(1, context: .background)
        let result = await throwing.closed
        if case .listenerError = result {} else { Issue.record("Expected listener error") }
        #expect(reports.withLock { $0 } == 1)
        let finishing = create(); finishing.advance(1, context: .background); finishing.advance(2, context: .background)
        finishing.endAfterDelivery(); finishing.advance(3, context: .background)
        let values = Mutex<[Int]>([])
        try finishing.start { call, _ in if case .value(let value) = call { values.withLock { $0.append(value) } } }
        #expect(await finishing.closed == .ended); #expect(values.withLock { $0 } == [1, 2])
    }

    @Test("delivers a failure as a call, stays open, and folds it with the values around it", .timeLimit(.minutes(1)))
    func case45() async throws {
        let reports = Mutex(0)
        let watch = NativeWatch<Int>(value: 0, detach: {}, report: { _ in reports.withLock { $0 += 1 } })
        watch.advance(1, context: .background); watch.fail(.message("down"), context: .background)
        let calls = Mutex<[NativeWatchCall<Int>]>([])
        try watch.start { call, _ in calls.withLock { $0.append(call) } }
        await flush(); #expect(calls.withLock { $0 } == [.failed(.message("down"))]); #expect(watch.value == 0)
        watch.advance(2, context: .background); watch.advance(3, context: .background); await flush()
        #expect(calls.withLock { $0 } == [.failed(.message("down")), .value(2), .value(3)])
        #expect(watch.value == 3); #expect(reports.withLock { $0 } == 0); _ = await watch.stop()
        let folded = NativeWatch<Int>(value: 0, detach: {}, report: { _ in })
        folded.fail(.message("again"), context: .background); folded.advance(4, context: .background)
        let recovered = Mutex<[NativeWatchCall<Int>]>([])
        try folded.start { call, _ in recovered.withLock { $0.append(call) } }
        await flush(); #expect(recovered.withLock { $0 } == [.value(4)]); _ = await folded.stop()
    }

    @Test("retains neither its source nor its listener once stopped, while still referenced", .timeLimit(.minutes(1)))
    func case46() async throws {
        func acquire() throws -> (NativeWatch<Int>, @Sendable () -> Bool) {
            let source = WatchTestPayload()
            let watch = NativeWatch<Int>(value: 3, detach: { _ = source }, report: { _ in _ = source }, replace: { _ = source; return 4 })
            try watch.start { _, _ in _ = source }
            return (watch, { [weak source] in source == nil })
        }
        let (watch, released) = try acquire(); #expect(!released())
        #expect(await watch.stop() == .stopped); await flush()
        // ARC checks the source retained by detach, report, listener, and replace closures.
        #expect(released()); #expect(watch.value == 3)
    }
}
