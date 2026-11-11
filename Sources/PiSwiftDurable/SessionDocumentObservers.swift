import PiSwiftChord
import Synchronization

private final class DocumentWatchTree: Sendable {
    private let state: Mutex<JSONValue>
    init(_ value: JSONValue) { state = Mutex(value) }
    var value: JSONValue { state.withLock { $0 } }
    func replace(_ value: JSONValue) { state.withLock { $0 = value } }
}

// v1.5.2 CH3 session/session.ts:1457–1550 observeDocument.
private final class DocumentObservationRevision<Value: Codable & Sendable>: Sendable {
    private struct State {
        var attached = true
        var incarnation: DocumentID?
        var version: Int
        var value: Value?
        var pin: SessionSubscription?
    }
    private let state: Mutex<State>
    init(recordID: DocumentID, version: Int, value: Value, pin: SessionSubscription) {
        state = Mutex(State(incarnation: recordID, version: version, value: value, pin: pin))
    }
    func unpin() {
        let pin = state.withLock { state in let pin = state.pin; state.pin = nil; return pin }
        pin?.cancel()
    }
    func detach() {
        let pin = state.withLock { state in
            state.attached = false; state.value = nil
            let pin = state.pin; state.pin = nil; return pin
        }
        pin?.cancel()
    }
    func advance(_ change: DocumentCommitChange, pin: () throws -> SessionSubscription) throws -> WatchCall<Value>? {
        let current = state.withLock { $0 }
        guard current.attached else { return nil }
        if change.value == nil {
            guard current.incarnation == change.record.id, let last = current.value else { return nil }
            state.withLock { $0.incarnation = nil; $0.value = nil }
            unpin()
            return .value(value: last, ops: [], retired: true)
        }
        let replaced = current.incarnation != change.record.id || current.version != change.version
        if !replaced && change.ops.isEmpty { return nil }
        let value = try JSONValue.object(change.value!).decode(Value.self)
        if current.incarnation != change.record.id {
            unpin()
            let next = try pin()
            let keep = state.withLock { state in
                guard state.attached else { return false }
                state.pin = next; return true
            }
            if !keep { next.cancel(); return nil }
        }
        let attached = state.withLock { state in
            guard state.attached else { return false }
            state.incarnation = change.record.id; state.version = change.version!; state.value = value
            return true
        }
        guard attached else { return nil }
        return .value(value: value, ops: replaced ? [.replace(.object(change.value!))] : change.ops, retired: false)
    }
}

extension Session {
    internal func currentWatch<Value: Codable & Sendable>(
        _ definition: DocumentDefinition, address: DocumentAddress, context: ChordContext
    ) async throws -> Watch<Value>? {
        let watch: Watch<Value>? = try await attachDocument(definition, address: address, context: context) { (loaded: LoadedDocument, value: Value) in
            let subscriptions = ObserverSubscriptions()
            let tree = DocumentWatchTree(loaded.tracker.value)
            let watch = Watch<Value>(value: value, replacement: { _ in tree.value },
                detach: { subscriptions.detach() }, report: { self.report($0) })
            do {
                try self.observeDocument(loaded, value: value, address: address, subscriptions: subscriptions,
                    advance: { watch.advance($0, replacement: tree.value, context: $1) }, replace: { tree.replace($0) },
                    failed: { [weak self] error in self?.report(error); watch.end(.listenerError(String(describing: error))) },
                    foldPublication: true,
                    ownerEnded: { watch.endAfterDelivery() }, close: { [weak self] in watch.end(self?.watchCloseEnd ?? .ended) })
                if let signal = context.abortSignal { try watch.observeAbort(signal) }
                return watch
            } catch { watch.abort(); throw error }
        }
        do { try context.abortSignal?.throwIfAborted() }
        catch { watch?.abort(); throw error }
        return watch
    }

    internal func currentObservation<Value: Codable & Sendable>(
        _ definition: DocumentDefinition, address: DocumentAddress, observer: Observer<Value>, context: ChordContext
    ) async throws -> Observation<Value>? {
        let observation: Observation<Value>? = try await attachDocument(definition, address: address, context: context) { (loaded: LoadedDocument, value: Value) in
            let subscriptions = ObserverSubscriptions()
            let guarded = GuardedObserver(advance: observer.advance, end: observer.end,
                detach: { subscriptions.detach() }, report: { self.report($0) })
            do {
                try self.observeDocument(loaded, value: value, address: address, subscriptions: subscriptions,
                    advance: { guarded.advance($0, context: $1) },
                    failed: { [weak self] error in self?.report(error); guarded.end(.listenerError(String(describing: error))) },
                    ownerEnded: { guarded.end(.ended) },
                    close: { [weak self] in guarded.end(self?.observerCloseEnd ?? .failed(.message("session closed"))) })
                return Observation(value: value, detach: { guarded.detach() })
            } catch { guarded.detach(); throw error }
        }
        do { try context.abortSignal?.throwIfAborted() }
        catch { observation?.detach(); throw error }
        return observation
    }

    private func attachDocument<Value: Codable & Sendable, Attachment: Sendable>(
        _ definition: DocumentDefinition, address: DocumentAddress, context: ChordContext,
        attach: (LoadedDocument, Value) throws -> Attachment
    ) async throws -> Attachment? {
        try await readOnLine {
            try context.abortSignal?.throwIfAborted()
            let loaded = try await loadDocument(definition, address: address, context: context)
            try context.abortSignal?.throwIfAborted()
            guard let loaded else { return nil }
            try definition.check(loaded.record)
            try definition.checkVersion(loaded.storedVersion, record: loaded.record)
            return try attach(loaded, loaded.snapshot(Value.self))
        }
    }

    private func observeDocument<Value: Codable & Sendable>(
        _ loaded: LoadedDocument, value: Value, address: DocumentAddress, subscriptions: ObserverSubscriptions,
        advance: @escaping @Sendable (WatchCall<Value>, ChordContext) -> Void,
        replace: @escaping @Sendable (JSONValue) -> Void = { _ in },
        failed: @escaping @Sendable (any Error) -> Void,
        foldPublication: Bool = false,
        ownerEnded: @escaping @Sendable () -> Void, close: @escaping @Sendable () -> Void
    ) throws {
        let revision = DocumentObservationRevision(recordID: loaded.record.id, version: loaded.valueVersion,
            value: value, pin: try pinDocument(address, recordID: loaded.record.id))
        subscriptions.add(SessionSubscription { revision.detach() })
        let commits = ObserverSubscriptions()
        subscriptions.add(SessionSubscription { commits.detach() })
        commits.add(try observeCommits { [weak self] publication, context in
            guard subscriptions.attached, let self else { return }
            var ownerEnds = false
            var pending: WatchCall<Value>?
            for change in publication.changes {
                guard subscriptions.attached else { return }
                if case .task(let task) = change, case .task(let id, _) = address.scope,
                   task.id == id, task.state.status == "terminal" { ownerEnds = true }
                guard case .document(let document) = change, document.source == nil,
                      document.record.kind == address.kind, document.record.key == address.key,
                      documentAddressID(DocumentAddress(kind: document.record.kind, scope: document.record.scope, key: document.record.key)) == documentAddressID(address) else { continue }
                do {
                    if let call = try revision.advance(document, pin: { try self.pinDocument(address, recordID: document.record.id) }) {
                        if let value = document.value { replace(.object(value)) }
                        // JavaScript starts watch delivery after the synchronous publication.
                        // Keep that boundary when Swift's worker can start on another thread.
                        if foldPublication, case .value(let value, let ops, let retired) = call {
                            if case .value(_, let priorOps, let priorRetired) = pending {
                                pending = .value(value: value, ops: priorOps + ops, retired: priorRetired || retired)
                            } else { pending = call }
                        } else { advance(call, context) }
                    }
                } catch {
                    guard subscriptions.attached else { return }
                    subscriptions.detach(); failed(error); return
                }
            }
            if subscriptions.attached, let pending { advance(pending, context) }
            guard subscriptions.attached, ownerEnds else { return }
            commits.detach(); revision.unpin(); ownerEnded()
        })
        subscriptions.add(try subscribeClose {
            subscriptions.detach()
            close()
        })
    }
}
