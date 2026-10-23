import Synchronization
import Testing
@testable import PiSwiftChord

private final class PublicationValue: Sendable {
    let number: Int
    init(_ number: Int) { self.number = number }
}

private final class PublicationSource: ReplicatedStateSource, ReplicatedStateSourceAttachment {
    typealias Value = PublicationValue
    let snapshot = ReplicatedStateSourceSnapshot(value: PublicationValue(0), cursor: 0)
    private let listener = Mutex<(@Sendable (ReplicatedStateSourceFrame<Value>) -> Void)?>(nil)
    func attach() throws -> any ReplicatedStateSourceAttachment<Value> { self }
    func activate(_ listener: @escaping @Sendable (ReplicatedStateSourceFrame<Value>) -> Void) throws {
        self.listener.withLock { $0 = listener }
    }
    func dispose() { listener.withLock { $0 = nil } }
    func publish(_ value: Value, context: ChordContext = .background) {
        // The operations deliberately disagree with the source value.
        listener.withLock { $0 }?(.init(cursor: value.number, value: value, ops: [.set(["value"], 99)], context: context))
    }
}

private actor PublicationGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        let ready = waiters
        waiters.removeAll()
        for waiter in ready { waiter.resume() }
    }
}

private struct PublicationEvent: Sendable, Equatable {
    let value: Int
    let delivery: ReplicatedStateDelivery
}
private struct PublicationFailure: Error {}

@Suite struct StatePublicationV130Tests {
    // Public async variants of replicated-state.test.ts:77 and :280.
    @Test func publicCallbackPublishesAgainAndLateSubscriberHydratesOnce() async throws {
        let source = PublicationSource()
        let state = try replicatedState(source)
        defer { state.dispose() }
        let received = Mutex<[PublicationEvent]>([])
        let late = Mutex<[PublicationEvent]>([])
        let exact = Mutex<[Int]>([])
        let next = PublicationValue(2)
        let marker = ChordContextKey<String>("D1 publication")
        let context = ChordContext.background.withValue("nested", for: marker)
        state.subscribeOperations { _, sequence, _ in exact.withLock { $0.append(sequence) } }
        state.subscribe { _, _, delivery in
            guard delivery == .update(sequence: 1) else { return }
            source.publish(next, context: context)
            state.subscribe { value, _, delivery in
                late.withLock { $0.append(.init(value: value.number, delivery: delivery)) }
            }
        }
        state.subscribe { value, receivedContext, delivery in
            received.withLock { $0.append(.init(value: value.number, delivery: delivery)) }
            if delivery == .update(sequence: 2) {
                #expect(value === next)
                #expect(receivedContext.value(marker) == "nested")
            }
        }
        await state.waitUntilIdle()
        source.publish(PublicationValue(1))
        await state.waitUntilIdle()
        #expect(received.withLock { $0 } == [.init(value: 0, delivery: .hydrate(sequence: 0)),
                                            .init(value: 1, delivery: .update(sequence: 1)),
                                            .init(value: 2, delivery: .update(sequence: 2))])
        #expect(late.withLock { $0 } == [.init(value: 2, delivery: .hydrate(sequence: 2))])
        #expect(exact.withLock { $0 } == [1, 2])
        #expect(state.value === next)
    }

    // A public listener can hold an update while another listener publishes.
    @Test func publicReentrantDeliveryDoesNotWaitForHeldSubscriber() async throws {
        let source = PublicationSource()
        let state = try replicatedState(source)
        defer { state.dispose() }
        let held = PublicationGate(), started = PublicationGate(), fastFinished = PublicationGate()
        let slow = Mutex<[Int]>([]), fast = Mutex<[Int]>([])
        state.subscribe { value, _, delivery in
            slow.withLock { $0.append(value.number) }
            if delivery == .update(sequence: 1) {
                await started.release()
                await held.wait()
            }
        }
        state.subscribe { value, _, delivery in
            fast.withLock { $0.append(value.number) }
            if delivery == .update(sequence: 1) {
                await started.wait()
                source.publish(PublicationValue(2))
            }
            if delivery == .update(sequence: 2) { await fastFinished.release() }
        }
        await state.waitUntilIdle()
        source.publish(PublicationValue(1))
        await fastFinished.wait()
        #expect(slow.withLock { $0 } == [0, 1])
        #expect(fast.withLock { $0 } == [0, 1, 2])
        #expect(state.value.number == 2)
        await held.release()
        await state.waitUntilIdle()
        #expect(slow.withLock { $0 } == [0, 1, 2])
    }

    @Test func publicListenerFailureReportsOnceAfterPublicationAndDeliveryContinues() async throws {
        let source = PublicationSource()
        let errors = Mutex(0)
        let state = try replicatedState(source, onError: { _ in errors.withLock { $0 += 1 } })
        defer { state.dispose() }
        let received = Mutex<[Int]>([])
        state.subscribe { _, _, delivery in
            if delivery == .update(sequence: 1) {
                #expect(state.value.number == 1)
                throw PublicationFailure()
            }
        }
        state.subscribe { value, _, _ in received.withLock { $0.append(value.number) } }
        await state.waitUntilIdle()
        source.publish(PublicationValue(1))
        await state.waitUntilIdle()
        #expect(errors.withLock { $0 } == 1)
        #expect(received.withLock { $0 } == [0, 1])
        source.publish(PublicationValue(2))
        await state.waitUntilIdle()
        #expect(received.withLock { $0 } == [0, 1, 2])
        #expect(errors.withLock { $0 } == 1)
    }
}
