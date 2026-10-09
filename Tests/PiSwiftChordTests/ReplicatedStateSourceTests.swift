import Synchronization
import Testing
@testable import PiSwiftChord

private final class SourceTestValue: Sendable {
    let value: Int
    init(_ value: Int) { self.value = value }
}

private struct SourceTestError: Error, Sendable, Equatable { let message: String }

private final class SourceTestAttachment<Value: Sendable>: ReplicatedStateSourceAttachment {
    let snapshot: ReplicatedStateSourceSnapshot<Value>
    private struct State {
        var buffer: [ReplicatedStateSourceFrame<Value>] = []
        var listener: (@Sendable (ReplicatedStateSourceFrame<Value>) -> Void)?
        var savedListener: (@Sendable (ReplicatedStateSourceFrame<Value>) -> Void)?
        var activated = false
        var disposed = false
        var disposalCalls = 0
    }
    private let storage = Mutex(State())
    let activationError: SourceTestError?
    init(snapshot: ReplicatedStateSourceSnapshot<Value>, activationError: SourceTestError? = nil) {
        self.snapshot = snapshot
        self.activationError = activationError
    }
    var disposed: Bool { storage.withLock { $0.disposed } }
    var disposalCalls: Int { storage.withLock { $0.disposalCalls } }
    func activate(_ listener: @escaping @Sendable (ReplicatedStateSourceFrame<Value>) -> Void) throws {
        if let activationError { throw activationError }
        let frames = try storage.withLock { state in
            guard !state.activated else { throw SourceTestError(message: "already active") }
            guard !state.disposed else { throw SourceTestError(message: "disposed") }
            state.activated = true
            state.listener = listener
            state.savedListener = listener
            let frames = state.buffer
            state.buffer = []
            return frames
        }
        for frame in frames { listener(frame) }
    }
    // Match upstream's direct TestSourceAttachment.publish. This permits nested
    // frame calls to exercise the publisher's own reentrant publication buffer.
    func publish(_ frame: ReplicatedStateSourceFrame<Value>) {
        let listener = storage.withLock { state in
            guard !state.disposed else { return Optional<@Sendable (ReplicatedStateSourceFrame<Value>) -> Void>.none }
            guard let listener = state.listener else {
                state.buffer.append(frame)
                return nil
            }
            return listener
        }
        listener?(frame)
    }
    func publishAfterDisposal(_ frame: ReplicatedStateSourceFrame<Value>) {
        storage.withLock { $0.savedListener }?(frame)
    }
    func dispose() {
        storage.withLock { state in
            state.disposalCalls += 1
            guard !state.disposed else { return }
            state.disposed = true
            state.buffer = []
            state.listener = nil
        }
    }
}

private final class SourceTestSource<Value: Sendable>: ReplicatedStateSource {
    private struct State {
        var value: Value
        var cursor: Int
        var attachments: [SourceTestAttachment<Value>] = []
        var onAttach: (@Sendable () -> Void)?
    }
    private let storage: Mutex<State>
    let activationError: SourceTestError?
    init(_ value: Value, cursor: Int = 0, activationError: SourceTestError? = nil) {
        storage = Mutex(State(value: value, cursor: cursor))
        self.activationError = activationError
    }
    var attachments: [SourceTestAttachment<Value>] { storage.withLock { $0.attachments } }
    var activeCount: Int { attachments.filter { !$0.disposed }.count }
    func onAttach(_ action: @escaping @Sendable () -> Void) { storage.withLock { $0.onAttach = action } }
    func attach() throws -> any ReplicatedStateSourceAttachment<Value> {
        let (attachment, onAttach) = storage.withLock { state in
            let attachment = SourceTestAttachment(snapshot: .init(value: state.value, cursor: state.cursor),
                                                  activationError: activationError)
            state.attachments.append(attachment)
            return (attachment, state.onAttach)
        }
        onAttach?()
        return attachment
    }
    func commit(_ value: Value, ops: [Delta.Op] = [], context: Context = .background, cursor: Int? = nil) {
        let (frame, attachments) = storage.withLock { state in
            state.value = value
            state.cursor = cursor ?? state.cursor + 1
            return (ReplicatedStateSourceFrame(cursor: state.cursor, value: value, ops: ops, context: context),
                    state.attachments)
        }
        for attachment in attachments { attachment.publish(frame) }
    }
}

private struct SourceTestDelivery: Sendable, Equatable {
    let value: Int
    let delivery: ReplicatedStateDelivery
}

@Suite("ReplicatedState authoritative sources")
struct ReplicatedStateSourceTests {
    @Test("Captures before activation and drains queued commits in order")
    func bufferedActivation() async throws {
        let second = SourceTestValue(2)
        let source = SourceTestSource(SourceTestValue(0), cursor: 10)
        source.onAttach {
            source.commit(SourceTestValue(1), ops: [.set(["value"], 1)])
            source.commit(second, ops: [.set(["value"], 2)])
        }
        let state = try replicatedState(source)
        defer { state.dispose() }
        let deliveries = Mutex<[SourceTestDelivery]>([])
        state.subscribe { value, _, delivery in deliveries.withLock { $0.append(.init(value: value.value, delivery: delivery)) } }
        await state.waitUntilIdle()
        #expect(state.value === second)
        #expect(deliveries.withLock { $0 } == [.init(value: 2, delivery: .hydrate(sequence: 2))])
    }

    @Test("Hydrates at sequence zero after existing source commits")
    func lateAttachment() async throws {
        let current = SourceTestValue(1)
        let source = SourceTestSource(SourceTestValue(0), cursor: 40)
        source.commit(current, ops: [.set(["value"], 1)])
        let state = try replicatedState(source)
        defer { state.dispose() }
        let deliveries = Mutex<[ReplicatedStateDelivery]>([])
        state.subscribe { _, context, delivery in
            #expect(context.description == Context.background.description)
            deliveries.withLock { $0.append(delivery) }
        }
        await state.waitUntilIdle()
        #expect(state.value === current)
        #expect(deliveries.withLock { $0 } == [.hydrate(sequence: 0)])
    }

    @Test("Publishes exact values and operation batches without applying or re-diffing")
    func exactPublications() async throws {
        let source = SourceTestSource(SourceTestValue(0))
        let state = try replicatedState(source)
        defer { state.dispose() }
        let next = SourceTestValue(1)
        // Deliberately unrelated to the value. Applying or re-diffing changes this batch.
        let ops: [Delta.Op] = [.delete(["absent"]), .set(["value"], 99), .set(["value"], 99)]
        let marker = ContextKey<String>("commit")
        let context = Context.todo.withValue("exact", for: marker)
        let receivedOps = Mutex<[[Delta.Op]]>([])
        let receivedValues = Mutex<[SourceTestValue]>([])
        state.subscribeOperations { batch, sequence, receivedContext in
            #expect(sequence == 1)
            #expect(receivedContext.value(marker) == "exact")
            receivedOps.withLock { $0.append(batch) }
        }
        state.subscribe { value, receivedContext, delivery in
            if delivery.kind == .update {
                #expect(receivedContext.value(marker) == "exact")
                receivedValues.withLock { $0.append(value) }
            }
        }
        source.commit(next, ops: ops, context: context)
        await state.waitUntilIdle()
        #expect(state.value === next)
        #expect(receivedValues.withLock { $0.first } === next)
        #expect(receivedOps.withLock { $0 } == [ops])
    }

    @Test("Buffers reentrant frames and skips updates covered by late hydration")
    func lateHydrationDuringOperations() async throws {
        let source = SourceTestSource(SourceTestValue(0))
        let state = try replicatedState(source)
        defer { state.dispose() }
        let received = Mutex<[Int]>([])
        let late = Mutex<[SourceTestDelivery]>([])
        state.subscribeOperations { _, sequence, _ in
            if sequence != 1 { return }
            source.commit(SourceTestValue(2), ops: [.set(["value"], 2)])
            state.subscribe { value, _, delivery in late.withLock { $0.append(.init(value: value.value, delivery: delivery)) } }
        }
        state.subscribe { value, _, delivery in
            if delivery.kind == .update { received.withLock { $0.append(value.value) } }
        }
        source.commit(SourceTestValue(1), ops: [.set(["value"], 1)])
        await state.waitUntilIdle()
        #expect(received.withLock { $0 } == [1, 2])
        #expect(late.withLock { $0 } == [.init(value: 2, delivery: .hydrate(sequence: 2))])
    }

    @Test("Reports listener failures without throwing them into the source")
    func isolatedFailures() async throws {
        let source = SourceTestSource(SourceTestValue(0))
        let errors = Mutex<[SourceTestError]>([])
        let state = try replicatedState(source, onError: { error in
            if let error = error as? SourceTestError { errors.withLock { $0.append(error) } }
        })
        defer { state.dispose() }
        let received = Mutex<[Int]>([])
        state.subscribe { _, _, delivery in
            if delivery.kind == .update { throw SourceTestError(message: "listener failed") }
        }
        state.subscribe { value, _, delivery in
            if delivery.kind == .update { received.withLock { $0.append(value.value) } }
        }
        source.commit(SourceTestValue(1))
        source.commit(SourceTestValue(2))
        await state.waitUntilIdle()
        #expect(received.withLock { $0 } == [1, 2])
        #expect(errors.withLock { $0.map(\.message) } == ["listener failed", "listener failed"])
    }

    @Test("Reports cursor gaps, disposes the attachment, and ignores later frames")
    func cursorGap() throws {
        let initial = SourceTestValue(0)
        let source = SourceTestSource(initial, cursor: 5)
        let errors = Mutex<[ReplicatedStateSourceError]>([])
        let state = try replicatedState(source, onError: { error in
            if let error = error as? ReplicatedStateSourceError { errors.withLock { $0.append(error) } }
        })
        source.commit(SourceTestValue(2), cursor: 7)
        #expect(errors.withLock { $0 } == [.cursorGap(expected: 6, received: 7)])
        #expect(source.activeCount == 0)
        #expect(state.value === initial)
        // Call the receiver directly through a misbehaving source after disposal.
        source.attachments.first?.publishAfterDisposal(.init(cursor: 8, value: SourceTestValue(3), ops: [], context: .background))
        #expect(state.value === initial)
        #expect(errors.withLock { $0.count } == 1)
        state.dispose()
        #expect(source.attachments.first?.disposalCalls == 1)
    }

    @Test("Keeps attachments independent and disposes each idempotently")
    func independentAttachments() async throws {
        let source = SourceTestSource(SourceTestValue(0))
        let first = try replicatedState(source)
        let second = try replicatedState(source)
        #expect(source.activeCount == 2)
        source.commit(SourceTestValue(1))
        #expect(first.value.value == 1)
        #expect(second.value.value == 1)
        first.dispose()
        first.dispose()
        #expect(source.activeCount == 1)
        source.commit(SourceTestValue(2))
        #expect(first.value.value == 1)
        #expect(second.value.value == 2)
        let received = Mutex<[SourceTestDelivery]>([])
        first.subscribe { value, _, delivery in received.withLock { $0.append(.init(value: value.value, delivery: delivery)) } }
        await first.waitUntilIdle()
        #expect(received.withLock { $0 } == [.init(value: 1, delivery: .hydrate(sequence: 1))])
        second.dispose()
        #expect(source.activeCount == 0)
        #expect(source.attachments.map(\.disposalCalls) == [1, 1])
    }

    @Test("Rejects unsafe snapshot cursors and disposes setup", arguments: [Int.min, -9_007_199_254_740_992, 9_007_199_254_740_992, Int.max])
    func unsafeSnapshot(cursor: Int) throws {
        let source = SourceTestSource(0, cursor: cursor)
        #expect(throws: ReplicatedStateSourceError.invalidSnapshotCursor(cursor)) { try replicatedState(source) }
        #expect(source.activeCount == 0)
        #expect(source.attachments.first?.disposalCalls == 1)
    }

    @Test("Rejects unsafe frame cursors and ignores later receiver calls", arguments: [Int.min, 9_007_199_254_740_992, Int.max])
    func unsafeFrame(cursor: Int) throws {
        let errors = Mutex<[ReplicatedStateSourceError]>([])
        let source = SourceTestSource(0)
        let state = try replicatedState(source, onError: { error in
            if let error = error as? ReplicatedStateSourceError { errors.withLock { $0.append(error) } }
        })
        source.commit(1, cursor: cursor)
        #expect(state.value == 0)
        #expect(errors.withLock { $0 } == [.invalidFrameCursor(cursor)])
        #expect(source.activeCount == 0)
        source.attachments.first?.publishAfterDisposal(.init(cursor: 1, value: 2, ops: [], context: .background))
        #expect(state.value == 0)
        #expect(errors.withLock { $0.count } == 1)
    }

    @Test("Accepts negative safe cursors and both safe boundaries", arguments: [-9_007_199_254_740_991, -2, 9_007_199_254_740_990])
    func safeCursor(cursor: Int) throws {
        let source = SourceTestSource(0, cursor: cursor)
        let state = try replicatedState(source)
        defer { state.dispose() }
        source.commit(1)
        #expect(state.value == 1)
    }

    @Test("Disposes once and rethrows an activation failure")
    func activationFailure() throws {
        let failure = SourceTestError(message: "activation failed")
        let source = SourceTestSource(0, activationError: failure)
        #expect(throws: failure) { try replicatedState(source) }
        #expect(source.activeCount == 0)
        #expect(source.attachments.first?.disposalCalls == 1)
    }

    @Test("Default and throwing error handlers allow continued delivery")
    func errorHandlers() async throws {
        let source = SourceTestSource(0)
        let state = try replicatedState(source)
        defer { state.dispose() }
        let received = Mutex<[Int]>([])
        state.subscribe { value, _, _ in
            received.withLock { $0.append(value) }
            throw SourceTestError(message: "ignored")
        }
        source.commit(1)
        await state.waitUntilIdle()
        #expect(received.withLock { $0 } == [0, 1])
        let secondSource = SourceTestSource(0)
        let calls = Mutex(0)
        let second = try replicatedState(secondSource, onError: { _ in
            calls.withLock { $0 += 1 }
            throw SourceTestError(message: "handler failure")
        })
        defer { second.dispose() }
        second.subscribe { _, _, _ in throw SourceTestError(message: "listener failure") }
        secondSource.commit(1)
        await second.waitUntilIdle()
        #expect(calls.withLock { $0 } == 2)
        #expect(second.value == 1)
    }

    @Test("Collects operations failures across reentrant publications")
    func collectedOperationsFailures() throws {
        let source = SourceTestSource(0)
        let reports = Mutex<[any Error]>([])
        let state = try replicatedState(source, onError: { error in reports.withLock { $0.append(error) } })
        defer { state.dispose() }
        state.subscribeOperations { _, sequence, _ in
            if sequence == 1 { source.commit(2) }
            throw SourceTestError(message: "first")
        }
        state.subscribeOperations { _, _, _ in throw SourceTestError(message: "second") }
        source.commit(1)
        let errors = reports.withLock { $0 }
        #expect(errors.count == 1)
        let aggregate = try #require(errors.first as? ReplicatedStateOperationsErrors)
        #expect(aggregate.errors.compactMap { ($0 as? SourceTestError)?.message } == ["first", "second", "first", "second"])
        #expect(state.value == 2)
    }

    @Test("Cancels the operations hook and reports its failures")
    func operationsCancellation() throws {
        let source = SourceTestSource(0)
        let errors = Mutex<[SourceTestError]>([])
        let state = try replicatedState(source, onError: { error in
            if let error = error as? SourceTestError { errors.withLock { $0.append(error) } }
        })
        defer { state.dispose() }
        let received = Mutex<[[Delta.Op]]>([])
        let subscription = state.subscribeOperations { ops, _, _ in
            received.withLock { $0.append(ops) }
            throw SourceTestError(message: "hook failure")
        }
        source.commit(1, ops: [])
        subscription.cancel()
        subscription.cancel()
        source.commit(2, ops: [.replace(2)])
        #expect(state.value == 2)
        #expect(received.withLock { $0 } == [[]])
        #expect(errors.withLock { $0.map(\.message) } == ["hook failure"])
    }
}
