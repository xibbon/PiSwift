import PiSwiftChord
import Synchronization

/// v1.5.2 session/session.ts:1588–1653 `#enqueue` outcome fence.
/// A job enters this fence at the same instant it reserves the Session line.
internal final class SessionOutcomeLine: Sendable {
    internal struct Ticket: Sendable {
        let owner: SessionOutcomeLine
        let index: Int
        func tryDeliver() -> Bool { owner.tryDeliver(index) }
        func deliver() async { await owner.deliver(index) }
        func waitDelivered() async { await owner.waitUntil(index) }
    }
    private struct State {
        var nextIndex = 0
        var delivered = -1
        var deliveryWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
        var outstanding = 0
        var room: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())
    var outstandingCount: Int { state.withLock { $0.outstanding } }
    func reserve() -> Ticket {
        state.withLock { state in
            let index = state.nextIndex
            state.nextIndex += 1
            return Ticket(owner: self, index: index)
        }
    }
    private func waitUntil(_ index: Int) async {
        if state.withLock({ $0.delivered >= index }) { return }
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if state.delivered >= index { return true }
                state.deliveryWaiters[index, default: []].append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
    func tryClaimRoom() -> Bool {
        state.withLock { state in
            if state.outstanding < 256 { state.outstanding += 1; return true }
            return false
        }
    }
    func waitForRoom() async {
        if tryClaimRoom() { return }
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if state.outstanding < 256 { state.outstanding += 1; return true }
                state.room.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
    private func tryDeliver(_ index: Int) -> Bool {
        let result = state.withLock { state -> (Bool, [CheckedContinuation<Void, Never>], CheckedContinuation<Void, Never>?) in
            guard state.delivered >= index - 1 else { return (false, [], nil) }
            guard state.delivered < index else { return (true, [], nil) }
            state.delivered = index
            let delivery = state.deliveryWaiters.removeValue(forKey: index) ?? []
            if let next = state.room.first {
                state.room.removeFirst()
                return (true, delivery, next)
            }
            state.outstanding -= 1
            return (true, delivery, nil)
        }
        for waiter in result.1 { waiter.resume() }
        result.2?.resume()
        return result.0
    }
    private func deliver(_ index: Int) async {
        while !tryDeliver(index) { await waitUntil(index - 1) }
    }
}

/// v1.5.2 session/writer.ts `PublishFailure`.
internal enum WriterPublishFailure: Sendable {
    case adoption(any Error)
    case listener(any Error)
    case external(any Error)
}

/// v1.5.2 session/writer.ts `PartSpec` and `Part`.
internal final class SessionWriterPart: Sendable {
    let writes: [StorageWrite]
    let keys: [String]
    let touchesDocument: Bool
    let context: ChordContext
    let delivered: SessionOutcomeLine.Ticket?
    let publish: @Sendable (Seq) -> WriterPublishFailure?
    let discard: @Sendable () -> Void
    private struct State {
        var outcome: Result<Void, any Error>?
        var outcomeWaiters: [CheckedContinuation<Result<Void, any Error>, Never>] = []
        var gateOpen = false
        var gateWaiters: [CheckedContinuation<Void, Never>] = []
        var publicationFault: WriterPublishFailure?
        var publicationInvoked = false
        var publicationDone = false
        var publicationWaiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())
    init(writes: [StorageWrite], keys: [String], context: ChordContext,
         delivered: SessionOutcomeLine.Ticket? = nil,
         publish: @escaping @Sendable (Seq) -> WriterPublishFailure?,
         discard: @escaping @Sendable () -> Void) {
        self.writes = writes; self.keys = keys; self.touchesDocument = keys.contains { $0.hasPrefix("doc:") }
        self.context = context; self.delivered = delivered
        self.publish = publish; self.discard = discard
    }
    func wait() async throws {
        if let outcome = state.withLock({ $0.outcome }) { return try outcome.get() }
        let outcome: Result<Void, any Error> = await withCheckedContinuation { continuation in
            let current = state.withLock { state -> Result<Void, any Error>? in
                if let outcome = state.outcome { return outcome }
                state.outcomeWaiters.append(continuation)
                return nil
            }
            if let current { continuation.resume(returning: current) }
        }
        try outcome.get()
    }
    var settledOutcome: Result<Void, any Error>? { state.withLock { $0.outcome } }
    func waitGate() async {
        if state.withLock({ $0.gateOpen }) { return }
        await withCheckedContinuation { continuation in
            let open = state.withLock { state in
                if state.gateOpen { return true }
                state.gateWaiters.append(continuation)
                return false
            }
            if open { continuation.resume() }
        }
    }
    fileprivate func runPublication(_ body: () -> WriterPublishFailure?) {
        let first = state.withLock { state in
            if state.publicationInvoked { return false }
            state.publicationInvoked = true
            return true
        }
        guard first else { return }
        let fault = body()
        let waiters = state.withLock { state in
            state.publicationFault = fault
            state.publicationDone = true
            let waiters = state.publicationWaiters
            state.publicationWaiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
    fileprivate func publicationResult() async -> WriterPublishFailure? {
        let current = state.withLock { state -> (Bool, WriterPublishFailure?) in
            (state.publicationDone, state.publicationFault)
        }
        if current.0 { return current.1 }
        await withCheckedContinuation { continuation in
            let done = state.withLock { state in
                if state.publicationDone { return true }
                state.publicationWaiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
        return state.withLock { $0.publicationFault }
    }
    fileprivate func settleAndOpen(_ result: Result<Void, any Error>) {
        let waiters = state.withLock { state -> ([CheckedContinuation<Result<Void, any Error>, Never>], [CheckedContinuation<Void, Never>]) in
            guard state.outcome == nil else { return ([], []) }
            state.outcome = result
            state.gateOpen = true
            let waiters = (state.outcomeWaiters, state.gateWaiters)
            state.outcomeWaiters.removeAll()
            state.gateWaiters.removeAll()
            return waiters
        }
        for waiter in waiters.0 { waiter.resume(returning: result) }
        for waiter in waiters.1 { waiter.resume() }
    }
}

/// Commits prepared parts off the Session line. The writer's single worker
/// serializes storage calls and publication; its mutex owns admission and gates.
/// v1.5.2 session/writer.ts `Writer`.
internal final class SessionWriter: Sendable {
    private enum Receipts {
        case single(Seq?)
        case grouped([Int: Seq])
        mutating func receive(_ index: Int, _ seq: Seq) {
            switch self {
            case .single where index == 0: self = .single(seq)
            case .single: break
            case .grouped(var values): values[index] = seq; self = .grouped(values)
            }
        }
        func sequence(at index: Int) -> Seq? {
            switch self {
            case .single(let seq): index == 0 ? seq : nil
            case .grouped(let values): values[index]
            }
        }
    }
    private struct State {
        var queue: [SessionWriterPart] = []
        var flight = false
        var unpublished: [String: SessionWriterPart] = [:]
        var newest: SessionWriterPart?
        var pendingParts = 0
    }
    private let state = Mutex(State())
    private let storage: GuardedStorage
    private let latch: SessionFailureLatch
    private let failSession: @Sendable (any Error) -> Void
    private let report: @Sendable (any Error) -> Void

    init(storage: GuardedStorage, latch: SessionFailureLatch,
         fail: @escaping @Sendable (any Error) -> Void,
         report: @escaping @Sendable (any Error) -> Void) {
        self.storage = storage; self.latch = latch; failSession = fail; self.report = report
    }

    /// v1.5.2 writer.ts `admit`, `#pump`: all state changes precede line release.
    /// The first caller runs its own storage call after releasing the line;
    /// only a waiting group needs a new task.
    func admit(_ part: SessionWriterPart) -> Bool {
        state.withLock { state in
            state.pendingParts += 1
            for key in part.keys { state.unpublished[key] = part }
            state.newest = part
            if state.flight { state.queue.append(part); return false }
            state.flight = true
            return true
        }
    }

    func runFirst(_ part: SessionWriterPart) async {
        await send([part])
        let next = takeNext()
        if let next { Task { await flush(next) } }
    }

    /// v1.5.2 writer.ts `gate` and `drained`.
    func pendingGate(_ key: String) -> SessionWriterPart? {
        state.withLock { state in
            key == SessionKeys.allKeys ? state.newest : state.unpublished[key]
        }
    }
    func gate(_ key: String) async {
        if let pending = pendingGate(key) { await pending.waitGate() }
    }
    func drained() async { await gate(SessionKeys.allKeys) }
    var unpublished: Int { state.withLock { $0.unpublished.count } }
    var pendingParts: Int { state.withLock { $0.pendingParts } }
    func hasGate(_ key: String) -> Bool { state.withLock { $0.unpublished[key] != nil } }

    /// v1.5.2 writer.ts `#flush` and `#pump`.
    private func flush(_ first: [SessionWriterPart]) async {
        var parts = first
        while true {
            await send(parts)
            guard let next = takeNext() else { return }
            parts = next
        }
    }
    private func takeNext() -> [SessionWriterPart]? {
        state.withLock { state in
            if state.queue.isEmpty { state.flight = false; return nil }
            let parts = state.queue
            state.queue.removeAll(keepingCapacity: true)
            return parts
        }
    }

    /// v1.5.2 writer.ts `#send`.
    private func send(_ parts: [SessionWriterPart]) async {
        if let cause = latch.failure {
            for part in parts { unpublish(part, SessionFailed(cause)) }
            return
        }
        let received = Mutex<Receipts>(parts.count == 1 ? .single(nil) : .grouped([:]))
        var result: CommitResult?
        var rejected: (any Error)?
        do {
            result = try await storage.commit(parts.map(\.writes), receive: { index, seq in
                received.withLock { $0.receive(index, seq) }
            }, context: parts[0].context.withoutAbortSignal())
        } catch { rejected = error }
        if let cause = latch.failure {
            for part in parts { unpublish(part, SessionFailed(cause)) }
            return
        }
        await publish(parts, seqs: received.withLock { $0 }, result: result, rejected: rejected)
    }

    /// v1.5.2 writer.ts `#publish`. Refusal stops the group and fails the
    /// Session after all earlier receipts have been published.
    private func publish(_ parts: [SessionWriterPart], seqs: Receipts,
                         result: CommitResult?, rejected: (any Error)?) async {
        var stop: (any Error)?
        var externalStop = false
        var pending: [(SessionWriterPart, any Error, Bool)] = []
        for (index, part) in parts.enumerated() {
            if let stop {
                let error: any Error = externalStop ? SessionFailed(stop) : (rejected ?? SessionFailed(stop))
                pending.append((part, error, false))
                continue
            }
            guard let seq = seqs.sequence(at: index) else {
                let error: any Error = rejected ?? result?.refused ?? StorageRequestError("Storage committed without adopting the batch")
                stop = error
                pending.append((part, error, false))
                continue
            }
            let publication: @Sendable () -> Void = {
                part.runPublication {
                    if let cause = self.latch.failure { return .external(cause) }
                    return part.publish(seq)
                }
            }
            if storage.publishesImmediately { publication() }
            else {
                do { try await storage.publishing(publication, context: part.context) }
                catch {
                    // v1.5.2 session.ts:1693–1720: a stored part must still
                    // publish if its optional storage scope throws.
                    report(error)
                    publication()
                }
            }
            let publicationFault = await part.publicationResult()
            if let fault = publicationFault {
                switch fault {
                case .external(let error):
                    stop = error
                    externalStop = true
                    pending.append((part, SessionFailed(error), false))
                case .adoption(let error):
                    stop = error
                    pending.append((part, error, true))
                case .listener(let error):
                    if let rejected {
                        report(error)
                        pending.append((part, rejected, true))
                    } else {
                        // The stored part succeeds; subsequent parts fail.
                        stop = error
                        finish(part, .success(()))
                    }
                }
            } else if let rejected {
                pending.append((part, rejected, true))
            } else if let cause = latch.failure {
                // v1.5.2 writer.ts:279–283: a host callback can fail the
                // Session while this already stored part is publishing.
                finish(part, .failure(SessionFailed(cause)))
            } else {
                finish(part, .success(()))
            }
            // v1.5.2 writer.ts:239–240 `hop`: the caller's continuation runs
            // before the next part is published. Swift uses an explicit ack.
            if index + 1 < parts.count {
                if let delivered = part.delivered, stop == nil, rejected == nil { await delivered.waitDelivered() }
                await Task.yield()
            }
        }
        if let error = rejected ?? stop {
            failSession(error)
            for (part, error, published) in pending {
                if published { finish(part, .failure(error)) }
                else { unpublish(part, error) }
            }
        }
    }

    /// v1.5.2 writer.ts `#unpublish`, `#unregister`, and `#open`.
    private func unpublish(_ part: SessionWriterPart, _ error: any Error) {
        part.discard()
        finish(part, .failure(error))
    }
    private func finish(_ part: SessionWriterPart, _ result: Result<Void, any Error>) {
        state.withLock { state in
            state.pendingParts -= 1
            for key in part.keys where state.unpublished[key] === part { state.unpublished.removeValue(forKey: key) }
            if state.newest === part { state.newest = nil }
        }
        part.settleAndOpen(result)
    }
}
