import Synchronization
import Testing
@testable import PiSwiftChord

private actor CapturedWatchGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true; let pending = waiters; waiters = []
        for waiter in pending { waiter.resume() }
    }
}

// v1.5.2 CH3: upstream chord/watch.ts:364–381 uses the selected value itself as JSON.
// A Swift Codable source has a separate JSON snapshot. Its live tree can advance before
// the replacement closure runs, so the selected value must carry its own snapshot.
@Suite(.timeLimit(.minutes(1))) struct WatchCapturedReplacementTests {
    @Test("overflow uses the selected frame's JSON after the source advances")
    func capturedOverflow() async throws {
        let delivery = CapturedWatchGate(); let source = Mutex<JSONValue>(.string("first"))
        let calls = Mutex<[WatchCall<Int>]>([]); let replacements = Mutex(0)
        let watch = Watch<Int>(value: 0, replacement: { _ in
            replacements.withLock { $0 += 1 }; return source.withLock { $0 }
        }, detach: {}, report: { _ in }, deliveryReady: { await delivery.wait() })
        // A single batch passes through unchanged. The bound applies to folded batches.
        for range in [0..<5_001, 5_001..<10_001] {
            let ops = range.map { Delta.Op.set([.key("k\($0)")], .number(Double($0))) }
            watch.advance(.value(value: 1, ops: ops, retired: false), replacement: .string("first"), context: .background)
        }
        try watch.start { call, _ in calls.withLock { $0.append(call) } }
        // Force the race: the source tree now belongs to another revision, before delivery can start.
        source.withLock { $0 = .string("later") }
        await delivery.release(); await watch.waitUntilIdle()
        #expect(calls.withLock { $0.count } == 1)
        guard case .value(let value, let ops, let retired) = calls.withLock({ $0.first }) else {
            Issue.record("Expected one value call"); return
        }
        #expect(value == 1); #expect(!retired); #expect(ops.count == 1)
        #expect(ops.first == .replace(.string("first")))
        #expect(replacements.withLock { $0 } == 0)
        _ = await watch.stop()
    }

    @Test("a recovery replacement uses the newest supplied snapshot and normal advance clears it")
    func recoveryAndReset() async throws {
        let calls = Mutex<[WatchCall<Int>]>([])
        let watch = Watch<Int>(value: 0, replacement: { .number(Double($0)) }, detach: {})
        watch.fail(.message("unavailable"), context: .background)
        watch.advance(.value(value: 1, ops: [], retired: false), replacement: .string("one"), context: .background)
        watch.advance(.value(value: 2, ops: [], retired: false), replacement: .string("two"), context: .background)
        try watch.start { call, _ in calls.withLock { $0.append(call) } }
        await watch.waitUntilIdle()
        #expect(calls.withLock { $0 } == [.value(value: 2, ops: [.replace(.string("two"))], retired: false)])
        watch.fail(.message("again"), context: .background)
        await watch.waitUntilIdle()
        watch.advance(.value(value: 3, ops: [], retired: false), context: .background)
        await watch.waitUntilIdle()
        #expect(calls.withLock { $0.last } == .value(value: 3, ops: [.replace(3)], retired: false))
        _ = await watch.stop()
    }
}
