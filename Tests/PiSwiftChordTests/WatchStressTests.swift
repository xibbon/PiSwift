import Darwin
import Dispatch
import Foundation
@testable import PiSwiftChord
import Synchronization
import Testing

private final class StressObservation: Sendable {
    private struct State {
        var active = 0
        var maximumActive = 0
        var calls = 0
        var mismatch = 0
        var replica: JSONValue = ["n": 0]
        var firstCall: CheckedContinuation<Void, Never>?
        var firstSeen = false
    }
    private let state = Mutex(State())

    func begin() {
        let first = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.active += 1
            state.maximumActive = max(state.maximumActive, state.active)
            state.calls += 1
            state.firstSeen = true
            let first = state.firstCall
            state.firstCall = nil
            return first
        }
        first?.resume()
    }
    func waitForFirstCall() async {
        await withCheckedContinuation { continuation in
            let seen = state.withLock { state in
                if state.firstSeen { return true }
                state.firstCall = continuation
                return false
            }
            if seen { continuation.resume() }
        }
    }
    func receive(_ call: WatchCall<JSONValue>) {
        state.withLock { state in
            switch call {
            case .value(let value, let ops, _):
                do {
                    let applied = try Delta.applyImmutable(state.replica, ops)
                    if applied != value { state.mismatch += 1 }
                    state.replica = value
                } catch { state.mismatch += 1 }
            case .failed: state.mismatch += 1
            }
        }
    }
    func finish() { state.withLock { $0.active -= 1 } }
    var result: (calls: Int, maximumActive: Int, mismatch: Int, replica: JSONValue) {
        state.withLock { ($0.calls, $0.maximumActive, $0.mismatch, $0.replica) }
    }
}

private actor StressGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        let ready = waiters
        waiters = []
        for waiter in ready { waiter.resume() }
    }
}

private final class BlockingReplacement: Sendable {
    let entered = DispatchSemaphore(value: 0)
    let released = DispatchSemaphore(value: 0)
    func value() -> Int {
        entered.signal()
        released.wait()
        return -1
    }
}

@Suite("Watch stress") struct WatchStressTests {
    private func peakRSS() -> Int64 {
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        return Int64(usage.ru_maxrss)
    }

    @Test(.timeLimit(.minutes(1))) func jsonEndAfterEmptyTakeClosesWhenWorkerExits() async throws {
        let empty = StressGate(), release = StressGate()
        let detached = Mutex(0)
        let watch = Watch<JSONValue>(value: 0, replacement: { $0 },
            detach: { detached.withLock { $0 += 1 } }, report: { _ in },
            deliveryReady: {}, workerEmpty: { await empty.release(); await release.wait() })
        try watch.start { _, _ in }
        watch.advance(.value(value: 1, ops: [.replace(1)], retired: false), context: .background)
        await empty.wait()
        watch.endAfterDelivery()
        #expect(detached.withLock { $0 } == 0)
        await release.release()
        #expect(await watch.closed == .ended)
        #expect(detached.withLock { $0 } == 1)
    }

    @Test(.timeLimit(.minutes(1))) func nativeEndAfterEmptyTakeClosesWhenWorkerExits() async throws {
        let empty = StressGate(), release = StressGate()
        let detached = Mutex(0)
        let watch = NativeWatch<Int>(value: 0,
            detach: { detached.withLock { $0 += 1 } }, report: { _ in },
            deliveryReady: {}, workerEmpty: { await empty.release(); await release.wait() })
        try watch.start { _, _ in }
        watch.advance(1, context: .background)
        await empty.wait()
        watch.endAfterDelivery()
        #expect(detached.withLock { $0 } == 0)
        await release.release()
        #expect(await watch.closed == .ended)
        #expect(detached.withLock { $0 } == 1)
    }

    @Test(.timeLimit(.minutes(1))) func nativeEndingWaitsForUnresolvedOverflowReplacement() async throws {
        let blocker = BlockingReplacement()
        let firstCall = StressGate(), releaseFirst = StressGate()
        let detached = Mutex(0), first = Mutex(true), values = Mutex<[Int]>([])
        let watch = NativeWatch<Int>(value: 0,
            detach: { detached.withLock { $0 += 1 } }, report: { _ in }, replace: { blocker.value() })
        try watch.start { call, _ in
            if case .value(let value) = call { values.withLock { $0.append(value) } }
            let pause = first.withLock { first in let wasFirst = first; first = false; return wasFirst }
            if pause { await firstCall.release(); await releaseFirst.wait() }
        }
        watch.advance(0, context: .background)
        await firstCall.wait()
        for value in 1...100 { watch.advance(value, context: .background) }
        let overflow = Task.detached { watch.advance(101, context: .background) }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                blocker.entered.wait()
                continuation.resume()
            }
        }
        watch.endAfterDelivery()
        await releaseFirst.release()
        await watch.waitUntilIdle()
        #expect(detached.withLock { $0 } == 0)
        blocker.released.signal()
        await overflow.value
        #expect(await watch.closed == .ended)
        #expect(values.withLock { $0 } == [0, -1])
    }

    @Test(.timeLimit(.minutes(1))) func oneOversizedBatchUsesCH1RootReplacement() async throws {
        let calls = Mutex<[WatchCall<JSONValue>]>([])
        let watch = Watch<JSONValue>(value: ["n": 0], detach: {})
        try watch.start { call, _ in calls.withLock { $0.append(call) } }
        let operations = Array(repeating: Delta.Op.set(["n"], 1), count: maxPendingReceivedOps + 1)
        watch.advance(.value(value: ["n": 1], ops: operations, retired: false), context: .background)
        watch.endAfterDelivery()
        #expect(await watch.closed == .ended)
        #expect(calls.withLock { $0 } == [.value(value: ["n": 1], ops: [.replace(["n": 1])], retired: false)])
    }

    @Test(.timeLimit(.minutes(1))) func hundredThousandSeededFramesFromFourTasksStayBoundedAndSerial() async throws {
        let source = Mutex(0)
        let observation = StressObservation()
        let releaseFirst = StressGate()
        let watch = Watch<JSONValue>(value: ["n": 0], detach: {})
        try watch.start { call, _ in
            observation.begin()
            defer { observation.finish() }
            observation.receive(call)
            // Hold the first delivery until all producers finish. The pending
            // frames must then coalesce into exactly one later delivery.
            if observation.result.calls == 1 { await releaseFirst.wait() }
        }
        // Ensure the listener has actually entered before concurrent producers begin.
        watch.advance(.value(value: ["n": 1], ops: [.set(["n"], 1)], retired: false), context: .background)
        await observation.waitForFirstCall()
        let initialRSS = peakRSS()
        let maximumPending = Mutex(0)
        await withTaskGroup(of: Void.self) { group in
            for taskIndex in 0..<4 {
                group.addTask {
                    var seed = UInt32(0x7a15_c032) &+ UInt32(taskIndex)
                    for frame in 0..<25_000 {
                        seed ^= seed << 13
                        seed ^= seed >> 17
                        seed ^= seed << 5
                        let increment = 1 + Int(seed % 3)
                        source.withLock { number in
                            number += increment
                            let value: JSONValue = ["n": .number(Double(number))]
                            watch.advance(.value(value: value, ops: [.set(["n"], .number(Double(number)))],
                                retired: seed % 8_191 == 0), context: .background)
                        }
                        if frame % 250 == 0 {
                            let count = watch.pendingOperationCount
                            maximumPending.withLock { $0 = max($0, count) }
                        }
                    }
                }
            }
        }
        let lateRSS = peakRSS()
        watch.endAfterDelivery()
        await releaseFirst.release()
        #expect(await watch.closed == .ended)
        await watch.waitUntilIdle()
        let result = observation.result
        let finalValue: JSONValue = ["n": .number(Double(source.withLock { $0 }))]
        #expect(result.replica == finalValue)
        #expect(watch.value == finalValue)
        #expect(result.maximumActive == 1)
        #expect(result.mismatch == 0)
        #expect(result.calls == 2)
        #expect(maximumPending.withLock { $0 } <= maxPendingOps)
        #expect(watch.pendingOperationCount == 0)
        print("CH2 stress frames=100000 calls=\(result.calls) maxActive=\(result.maximumActive) maxPendingOps=\(maximumPending.withLock { $0 }) peakRSSStart=\(initialRSS) peakRSSLate=\(lateRSS)")
    }
}
