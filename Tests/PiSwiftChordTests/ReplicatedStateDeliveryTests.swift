import Synchronization
import Testing
@testable import PiSwiftChord

private final class DeliveryTestValue: Sendable {
    let value: Int
    init(_ value: Int) { self.value = value }
}

private struct DeliveryTestError: Error, Sendable, Equatable {
    let message: String
}

private actor DeliveryTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private final class DeliveryTestLog<Element: Sendable>: Sendable {
    private struct Storage {
        var elements: [Element] = []
        var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    }
    private let storage = Mutex(Storage())

    var elements: [Element] { storage.withLock { $0.elements } }

    func append(_ element: Element) {
        let ready = storage.withLock { state in
            state.elements.append(element)
            let ready = state.waiters.filter { $0.0 <= state.elements.count }
            state.waiters.removeAll { $0.0 <= state.elements.count }
            return ready.map { $0.1 }
        }
        for waiter in ready { waiter.resume() }
    }

    func waitForCount(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let isReady = storage.withLock { state in
                if state.elements.count >= count { return true }
                state.waiters.append((count, continuation))
                return false
            }
            if isReady { continuation.resume() }
        }
    }
}

private final class DeliveryTestAttachment: ReplicatedStateSourceAttachment, Sendable {
    typealias Value = DeliveryTestValue
    let snapshot = ReplicatedStateSourceSnapshot(value: DeliveryTestValue(0), cursor: 0)
    private let listener = Mutex<(@Sendable (ReplicatedStateSourceFrame<Value>) -> Void)?>(nil)

    func activate(_ listener: @escaping @Sendable (ReplicatedStateSourceFrame<Value>) -> Void) throws {
        self.listener.withLock { $0 = listener }
    }

    func dispose() { listener.withLock { $0 = nil } }

    func publish(_ value: Value, context: ChordContext) {
        let receive = listener.withLock { $0 }
        receive?(.init(cursor: value.value, value: value,
                       ops: [.set(["value"], .number(Double(value.value)))], context: context))
    }
}

private final class DeliveryTestSource: ReplicatedStateSource, Sendable {
    typealias Value = DeliveryTestValue
    let attachment = DeliveryTestAttachment()
    func attach() throws -> any ReplicatedStateSourceAttachment<Value> { attachment }
    func publish(_ value: Int, context: ChordContext = .background) {
        attachment.publish(DeliveryTestValue(value), context: context)
    }
}

private struct DeliveryTestEvent: Sendable {
    let value: DeliveryTestValue
    let context: ChordContext
    let delivery: ReplicatedStateDelivery
}

// Port only the attached rows from chord v1.1.0 state-delivery.test.ts.
// Mutable state and replica rows need the state types outside work order CH6.
// A Swift async listener starts in a task. Readiness gates replace immediate
// JavaScript callback assertions and timer-based vi.waitFor calls.
@Suite("ReplicatedState attached public delivery")
struct ReplicatedStateDeliveryTests {
    @Test("Awaits hydration and each update independently of other subscribers and exact listeners")
    func independentSubscribers() async throws {
        let source = DeliveryTestSource()
        let state = try replicatedState(source)
        defer { state.dispose() }
        let hydration = DeliveryTestGate()
        let update = DeliveryTestGate()
        let events = DeliveryTestLog<String>()
        let exact = DeliveryTestLog<Int>()
        let fast = DeliveryTestLog<Int>()
        state.subscribeOperations { _, sequence, _ in exact.append(sequence) }
        state.subscribe { value, _, _ in
            events.append("start:\(value.value)")
            if value.value == 0 { await hydration.wait() }
            if value.value == 1 { await update.wait() }
            events.append("end:\(value.value)")
        }
        state.subscribe { value, _, _ in fast.append(value.value) }
        await events.waitForCount(1)
        source.publish(1)
        source.publish(2)
        await fast.waitForCount(3)
        #expect(events.elements == ["start:0"])
        #expect(fast.elements == [0, 1, 2])
        #expect(state.value.value == 2)
        #expect(exact.elements == [1, 2])
        await hydration.open()
        await events.waitForCount(3)
        #expect(events.elements == ["start:0", "end:0", "start:1"])
        await update.open()
        await state.waitUntilIdle()
        #expect(events.elements == ["start:0", "end:0", "start:1", "end:1", "start:2", "end:2"])
    }

    @Test("Bounds pending deliveries without changing exact publication", arguments: [100, 101, 102, 201, 202])
    func boundedDeliveries(count: Int) async throws {
        let source = DeliveryTestSource()
        let state = try replicatedState(source)
        defer { state.dispose() }
        let hydration = DeliveryTestGate()
        let received = DeliveryTestLog<Int>()
        let exact = DeliveryTestLog<Int>()
        state.subscribeOperations { _, sequence, _ in exact.append(sequence) }
        state.subscribe { value, _, _ in
            received.append(value.value)
            if value.value == 0 { await hydration.wait() }
        }
        await received.waitForCount(1)
        for value in 1...count { source.publish(value) }
        #expect(received.elements == [0])
        #expect(exact.elements == Array(1...count))
        await hydration.open()
        await state.waitUntilIdle()
        let first = ((count - 1) / 100) * 100 + 1
        #expect(received.elements == [0] + Array(first...count))
    }

    @Test("Excludes a running update from overflow and retains exact value, context, and delivery")
    func overflowExcludesRunningUpdate() async throws {
        let source = DeliveryTestSource()
        let state = try replicatedState(source)
        defer { state.dispose() }
        let gate = DeliveryTestGate()
        let context = ChordContext.background.withCancel().context
        let marker = ChordContextKey<String>("delivery-test-context")
        let markedContext = context.withValue("newest", for: marker)
        let received = DeliveryTestLog<DeliveryTestEvent>()
        state.subscribe { value, context, delivery in
            received.append(.init(value: value, context: context, delivery: delivery))
            if value.value == 1 { await gate.wait() }
        }
        await state.waitUntilIdle()
        source.publish(1)
        await received.waitForCount(2)
        for value in 2..<102 { source.publish(value) }
        let newest = DeliveryTestValue(102)
        source.attachment.publish(newest, context: markedContext)
        let adopted = state.value
        source.publish(103)
        #expect(received.elements.map { $0.value.value } == [0, 1])
        await gate.open()
        await state.waitUntilIdle()
        let events = received.elements
        #expect(events.map { $0.value.value } == [0, 1, 102, 103])
        let event = try #require(events.dropFirst(2).first)
        #expect(event.value === adopted)
        #expect(event.value === newest)
        #expect(event.context.value(marker) == "newest")
        #expect(event.context.abortSignal === markedContext.abortSignal)
        #expect(event.delivery == .update(sequence: 102))
    }

    @Test("Serializes reentrant hydration and update callbacks")
    func reentrantCallbacks() async throws {
        let source = DeliveryTestSource()
        let state = try replicatedState(source)
        defer { state.dispose() }
        let events = DeliveryTestLog<String>()
        state.subscribe { value, _, _ in
            events.append("start:\(value.value)")
            if value.value < 2 { source.publish(value.value + 1) }
            events.append("end:\(value.value)")
        }
        await state.waitUntilIdle()
        #expect(events.elements == ["start:0", "end:0", "start:1", "end:1", "start:2", "end:2"])
    }

    @Test("Treats two subscriptions of the same callback independently")
    func independentIdenticalCallbacks() async throws {
        let source = DeliveryTestSource()
        let state = try replicatedState(source)
        defer { state.dispose() }
        let gate = DeliveryTestGate()
        let received = DeliveryTestLog<Int>()
        let listener: @Sendable (DeliveryTestValue, ChordContext, ReplicatedStateDelivery) async throws -> Void = {
            value, _, _ in
            received.append(value.value)
            if value.value == 0 { await gate.wait() }
        }
        let stopFirst = state.subscribe(listener)
        let stopSecond = state.subscribe(listener)
        await received.waitForCount(2)
        source.publish(1)
        stopFirst.cancel()
        stopFirst.cancel()
        await gate.open()
        await state.waitUntilIdle()
        #expect(received.elements == [0, 0, 1])
        stopSecond.cancel()
    }

    @Test("Unsubscribe drops queued callbacks without joining or aborting the running callback")
    func unsubscribeDuringCallback() async throws {
        let source = DeliveryTestSource()
        let state = try replicatedState(source)
        defer { state.dispose() }
        let gate = DeliveryTestGate()
        let context = ChordContext.background.withCancel().context
        let received = DeliveryTestLog<Int>()
        let completed = DeliveryTestLog<Bool>()
        let stop = state.subscribe { value, _, _ in
            received.append(value.value)
            if value.value == 1 {
                await gate.wait()
                completed.append(!Task.isCancelled)
            }
        }
        await state.waitUntilIdle()
        source.publish(1, context: context)
        await received.waitForCount(2)
        source.publish(2, context: context)
        stop.cancel()
        source.publish(3, context: context)
        #expect(context.abortSignal?.aborted == false)
        #expect(completed.elements.isEmpty)
        await gate.open()
        await state.waitUntilIdle()
        #expect(completed.elements == [true])
        #expect(received.elements == [0, 1])
    }
}

@Suite("ReplicatedState attached listener errors")
struct ReplicatedStateListenerErrorTests {
    @Test("Isolates an immediate hydration failure without removing the subscription")
    func hydrationFailure() async throws {
        let source = DeliveryTestSource()
        let errors = DeliveryTestLog<DeliveryTestError>()
        let state = try replicatedState(source, onError: { error in
            if let error = error as? DeliveryTestError { errors.append(error) }
            else { Issue.record("Unexpected error: \(error)") }
        })
        defer { state.dispose() }
        let received = DeliveryTestLog<Int>()
        let failure = DeliveryTestError(message: "sync hydration")
        state.subscribe { value, _, _ in
            received.append(value.value)
            if value.value == 0 { throw failure }
        }
        await state.waitUntilIdle()
        source.publish(1)
        await state.waitUntilIdle()
        #expect(errors.elements == [failure])
        #expect(received.elements == [0, 1])
    }

    @Test("Observes hydration rejection, immediate throw, and update rejection while continuing delivery")
    func continuingAfterFailures() async throws {
        let source = DeliveryTestSource()
        let errors = DeliveryTestLog<DeliveryTestError>()
        let state = try replicatedState(source, onError: { error in
            if let error = error as? DeliveryTestError { errors.append(error) }
            else { Issue.record("Unexpected error: \(error)") }
        })
        defer { state.dispose() }
        let gate = DeliveryTestGate()
        let updateGate = DeliveryTestGate()
        let received = DeliveryTestLog<Int>()
        let fast = DeliveryTestLog<Int>()
        state.subscribe { value, _, _ in
            received.append(value.value)
            if value.value == 0 {
                await gate.wait()
                throw DeliveryTestError(message: "async hydration")
            }
            if value.value == 1 { throw DeliveryTestError(message: "sync update") }
            if value.value == 2 {
                await updateGate.wait()
                throw DeliveryTestError(message: "async update")
            }
        }
        state.subscribe { value, _, _ in fast.append(value.value) }
        await received.waitForCount(1)
        for value in 1...3 { source.publish(value) }
        await fast.waitForCount(4)
        #expect(fast.elements == [0, 1, 2, 3])
        await gate.open()
        await received.waitForCount(3)
        #expect(received.elements == [0, 1, 2])
        #expect(errors.elements.map(\.message) == ["async hydration", "sync update"])
        await updateGate.open()
        await state.waitUntilIdle()
        #expect(received.elements == [0, 1, 2, 3])
        #expect(errors.elements.map(\.message) == ["async hydration", "sync update", "async update"])
        #expect(fast.elements == [0, 1, 2, 3])
    }

    @Test("Still observes a callback rejection after unsubscribe")
    func failureAfterUnsubscribe() async throws {
        let source = DeliveryTestSource()
        let errors = DeliveryTestLog<DeliveryTestError>()
        let state = try replicatedState(source, onError: { error in
            if let error = error as? DeliveryTestError { errors.append(error) }
            else { Issue.record("Unexpected error: \(error)") }
        })
        defer { state.dispose() }
        let gate = DeliveryTestGate()
        let received = DeliveryTestLog<Int>()
        let failure = DeliveryTestError(message: "stopped callback")
        let stop = state.subscribe { value, _, _ in
            received.append(value.value)
            await gate.wait()
            throw failure
        }
        await received.waitForCount(1)
        source.publish(1)
        stop.cancel()
        await gate.open()
        await state.waitUntilIdle()
        #expect(errors.elements == [failure])
        #expect(received.elements == [0])
    }
}
