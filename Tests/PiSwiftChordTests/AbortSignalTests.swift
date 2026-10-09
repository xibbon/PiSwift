import Foundation
import Synchronization
import Testing
@testable import PiSwiftChord

@Suite("AbortSignal")
struct AbortSignalTests {
    @Test("Callbacks run synchronously on the thread that calls abort")
    func callingThread() {
        let controller = AbortController()
        let callingThread = ObjectIdentifier(Thread.current)
        let called = Mutex(false)
        controller.signal.addAbortListener { _ in
            #expect(ObjectIdentifier(Thread.current) == callingThread)
            called.withLock { $0 = true }
        }
        controller.abort()
        #expect(called.withLock { $0 })
    }

    @Test("The first reason wins and listeners run in order")
    func firstReasonAndOrder() throws {
        let controller = AbortController()
        let signal = controller.signal
        let calls = Mutex<[Int]>([])
        let first = ContextTestError(text: "first")
        #expect(!signal.aborted)
        #expect(signal.reason == nil)
        try signal.throwIfAborted()
        for index in 0..<3 {
            signal.addAbortListener { reason in
                #expect(signal.aborted)
                #expect(signal.reason as? ContextTestError == first)
                #expect(reason as? ContextTestError == first)
                calls.withLock { $0.append(index) }
            }
        }
        controller.abort(first)
        #expect(calls.withLock { $0 } == [0, 1, 2])
        controller.abort(ContextTestError(text: "second"))
        controller.abort()
        #expect(signal.reason as? ContextTestError == first)
        #expect(calls.withLock { $0 } == [0, 1, 2])
        #expect(signal.listenerCount == 0)
        do { try signal.throwIfAborted(); Issue.record("The signal must throw.") }
        catch { #expect(error as? ContextTestError == first) }
    }

    @Test("The default reason has the required text")
    func defaultReason() {
        let controller = AbortController()
        controller.abort()
        #expect(controller.signal.reason as? AbortError == AbortError())
        #expect(String(describing: controller.signal.reason!) == "The operation was aborted")
        do { try controller.signal.throwIfAborted(); Issue.record("The signal must throw.") }
        catch { #expect(error as? AbortError == AbortError()) }
    }

    @Test("Listeners added after abort are never called")
    func addedAfterAbort() {
        let controller = AbortController()
        let calls = Mutex(0)
        controller.abort()
        controller.signal.addAbortListener { _ in calls.withLock { $0 += 1 } }
        controller.abort()
        #expect(calls.withLock { $0 } == 0)
        #expect(controller.signal.listenerCount == 0)
    }

    @Test("Removal uses the registration identity")
    func removedListeners() {
        let controller = AbortController()
        let other = AbortController()
        let calls = Mutex<[Int]>([])
        let removed = controller.signal.addAbortListener { _ in calls.withLock { $0.append(1) } }
        controller.signal.addAbortListener { _ in calls.withLock { $0.append(2) } }
        let unrelated = other.signal.addAbortListener { _ in calls.withLock { $0.append(3) } }
        controller.signal.removeAbortListener(unrelated)
        #expect(controller.signal.listenerCount == 2)
        controller.signal.removeAbortListener(removed)
        controller.signal.removeAbortListener(removed)
        controller.abort()
        #expect(calls.withLock { $0 } == [2])
        #expect(other.signal.listenerCount == 1)
    }

    @Test("A listener can abort and change listeners without a deadlock")
    func reentrantListeners() {
        let first = AbortController()
        let other = AbortController()
        let calls = Mutex<[Int]>([])
        let removed = Mutex<AbortListenerRegistration?>(nil)
        other.signal.addAbortListener { _ in calls.withLock { $0.append(2) } }
        first.signal.addAbortListener { _ in
            calls.withLock { $0.append(1) }
            first.abort(ContextTestError(text: "later"))
            other.abort()
            first.signal.addAbortListener { _ in calls.withLock { $0.append(99) } }
            if let registration = removed.withLock({ $0 }) {
                first.signal.removeAbortListener(registration)
            }
        }
        let registration = first.signal.addAbortListener { _ in calls.withLock { $0.append(98) } }
        removed.withLock { $0 = registration }
        first.signal.addAbortListener { _ in calls.withLock { $0.append(3) } }
        let reason = ContextTestError(text: "first")
        first.abort(reason)
        #expect(calls.withLock { $0 } == [1, 2, 3])
        #expect(first.signal.reason as? ContextTestError == reason)
        #expect(first.signal.listenerCount == 0)
    }

    @Test("One hundred concurrent abort calls deliver each listener once")
    func concurrentAbort() async {
        let controller = AbortController()
        let calls = Mutex(Array(repeating: 0, count: 10))
        for index in 0..<10 {
            controller.signal.addAbortListener { reason in
                #expect(controller.signal.aborted)
                #expect(controller.signal.reason as? ContextTestError == reason as? ContextTestError)
                calls.withLock { $0[index] += 1 }
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask { controller.abort(ContextTestError(text: String(index))) }
            }
        }
        #expect(calls.withLock { $0 } == Array(repeating: 1, count: 10))
        #expect(controller.signal.reason is ContextTestError)
        #expect(controller.signal.listenerCount == 0)
    }

    @Test("Each source can abort a combined signal", arguments: 0..<3)
    func eachSource(index: Int) {
        let controllers = (0..<3).map { _ in AbortController() }
        let combined = AbortSignal.any(controllers.map(\.signal))
        let calls = Mutex(0)
        combined.addAbortListener { _ in calls.withLock { $0 += 1 } }
        #expect(!combined.aborted)
        for controller in controllers { #expect(controller.signal.listenerCount == 1) }
        let reason = ContextTestError(text: "source \(index)")
        controllers[index].abort(reason)
        #expect(combined.aborted)
        #expect(combined.reason as? ContextTestError == reason)
        #expect(calls.withLock { $0 } == 1)
        for controller in controllers {
            #expect(controller.signal.listenerCount == 0)
            controller.abort(ContextTestError(text: "later"))
        }
        #expect(combined.reason as? ContextTestError == reason)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test("Sources already aborted use array order")
    func preAbortedArrayOrder() {
        let active = AbortController()
        let first = AbortController()
        let second = AbortController()
        let firstReason = ContextTestError(text: "first")
        let secondReason = ContextTestError(text: "second")
        second.abort(secondReason)
        first.abort(firstReason)
        let combined = AbortSignal.any([active.signal, first.signal, second.signal])
        #expect(combined.aborted)
        #expect(combined.reason as? ContextTestError == firstReason)
        let reversed = AbortSignal.any([second.signal, first.signal])
        #expect(reversed.reason as? ContextTestError == secondReason)
        #expect(active.signal.listenerCount == 0)
        #expect(first.signal.listenerCount == 0)
        #expect(second.signal.listenerCount == 0)
    }

    @Test("An empty source array does not abort")
    func emptyArray() throws {
        let signal = AbortSignal.any([])
        #expect(!signal.aborted)
        #expect(signal.reason == nil)
        try signal.throwIfAborted()
    }

    @Test("Combined signal deinit removes source listeners")
    func releasesSources() {
        let first = AbortController()
        let second = AbortController()
        var combined: AbortSignal? = AbortSignal.any([first.signal, second.signal])
        weak var reference = combined
        #expect(reference != nil)
        #expect(first.signal.listenerCount == 1)
        #expect(second.signal.listenerCount == 1)
        combined = nil
        #expect(reference == nil)
        #expect(first.signal.listenerCount == 0)
        #expect(second.signal.listenerCount == 0)
        first.abort()
        second.abort()
    }

    @Test("Source listeners see combined state before derived callbacks run")
    func combinedStateAndOrder() {
        let source = AbortController()
        let derived = Mutex<AbortSignal?>(nil)
        let calls = Mutex<[String]>([])
        let reason = ContextTestError(text: "source")
        source.signal.addAbortListener { _ in
            #expect(derived.withLock { $0?.aborted } == true)
            #expect(derived.withLock { $0?.reason as? ContextTestError } == reason)
            calls.withLock { $0.append("before") }
        }
        let combined = AbortSignal.any([source.signal])
        derived.withLock { $0 = combined }
        source.signal.addAbortListener { _ in calls.withLock { $0.append("after") } }
        combined.addAbortListener { _ in calls.withLock { $0.append("derived") } }
        source.abort(reason)
        #expect(calls.withLock { $0 } == ["before", "after", "derived"])
    }

    @Test("A source listener that aborts another source preserves the first reason")
    func reentrantSource() {
        let first = AbortController()
        let second = AbortController()
        let firstReason = ContextTestError(text: "first")
        let secondReason = ContextTestError(text: "second")
        first.signal.addAbortListener { _ in second.abort(secondReason) }
        let combined = AbortSignal.any([first.signal, second.signal])
        let reasons = Mutex<[ContextTestError]>([])
        combined.addAbortListener { reason in
            if let reason = reason as? ContextTestError { reasons.withLock { $0.append(reason) } }
        }
        first.abort(firstReason)
        #expect(second.signal.reason as? ContextTestError == secondReason)
        #expect(combined.reason as? ContextTestError == firstReason)
        #expect(reasons.withLock { $0 } == [firstReason])
    }

    @Test("Nested combined signals set all states before source callbacks")
    func nestedCombined() {
        let source = AbortController()
        let signals = Mutex<[AbortSignal]>([])
        let calls = Mutex<[String]>([])
        let reason = ContextTestError(text: "nested")
        source.signal.addAbortListener { _ in
            for signal in signals.withLock({ $0 }) {
                #expect(signal.aborted)
                #expect(signal.reason as? ContextTestError == reason)
            }
            calls.withLock { $0.append("source") }
        }
        let first = AbortSignal.any([source.signal])
        let second = AbortSignal.any([first])
        signals.withLock { $0 = [first, second] }
        first.addAbortListener { _ in calls.withLock { $0.append("first") } }
        second.addAbortListener { _ in calls.withLock { $0.append("second") } }
        source.abort(reason)
        #expect(calls.withLock { $0 } == ["source", "first", "second"])
        #expect(first.listenerCount == 0)
        #expect(second.listenerCount == 0)
        #expect(source.signal.listenerCount == 0)
    }

    @Test("A mixed graph delivers callbacks in signal creation order", arguments: [false, true])
    func mixedGraph(siblingBeforeOuter: Bool) {
        let source = AbortController()
        let inner = AbortSignal.any([source.signal])
        let outer: AbortSignal
        let sibling: AbortSignal
        if siblingBeforeOuter {
            sibling = AbortSignal.any([source.signal])
            outer = AbortSignal.any([inner])
        } else {
            outer = AbortSignal.any([inner])
            sibling = AbortSignal.any([source.signal])
        }
        let calls = Mutex<[String]>([])
        // Register in reverse order to check signal order independently.
        sibling.addAbortListener { _ in calls.withLock { $0.append("sibling") } }
        outer.addAbortListener { _ in calls.withLock { $0.append("outer") } }
        inner.addAbortListener { _ in calls.withLock { $0.append("inner") } }
        let reason = ContextTestError(text: "mixed graph")
        source.abort(reason)
        let expected = siblingBeforeOuter ? ["inner", "sibling", "outer"] : ["inner", "outer", "sibling"]
        #expect(calls.withLock { $0 } == expected)
        for signal in [inner, outer, sibling] {
            #expect(signal.aborted)
            #expect(signal.reason as? ContextTestError == reason)
            #expect(signal.listenerCount == 0)
        }
        #expect(source.signal.listenerCount == 0)
    }
}
