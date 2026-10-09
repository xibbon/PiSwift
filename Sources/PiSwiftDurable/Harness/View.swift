import PiSwiftChord
import Synchronization

/// The active entries and the built-in documents of one conversation.
public struct ConversationView: Sendable, Equatable, Codable {
    public let conversation: ConversationRecord
    public let entries: [EntryRecord]
    public let docs: [String: JSONObject]
    public init(conversation: ConversationRecord, entries: [EntryRecord], docs: [String: JSONObject]) {
        self.conversation = conversation; self.entries = entries; self.docs = docs
    }
}

public typealias ConversationWatch = CommittedWatch<ConversationView>

/// Callbacks run on the Session line. They must not call Session operations.
internal final class ConversationViewObserver: Sendable {
    let advance: (@Sendable (ConversationView, [Delta.Op], ChordContext) -> Void)?
    let publication: (@Sendable (ConversationView, ConversationView, [Delta.Op], CommitPublication, ChordContext) -> Void)?
    let closeSession: @Sendable () -> Void
    init(advance: (@Sendable (ConversationView, [Delta.Op], ChordContext) -> Void)? = nil,
         publication: (@Sendable (ConversationView, ConversationView, [Delta.Op], CommitPublication, ChordContext) -> Void)? = nil,
         closeSession: @escaping @Sendable () -> Void) {
        self.advance = advance; self.publication = publication; self.closeSession = closeSession
    }
}

private final class ConversationMount: Sendable {
    struct Incarnation: Sendable { let id: DocumentID; let version: Int }
    struct State {
        var value: ConversationView
        var tree: JSONValue
        var docs: [String: Incarnation]
        var observers: [ObjectIdentifier: ConversationViewObserver] = [:]
    }
    let state: Mutex<State>
    init(value: ConversationView, docs: [String: Incarnation]) throws {
        state = Mutex(State(value: value, tree: try JSONValue(encoding: value), docs: docs))
    }
}

/// One shared mount for each observed conversation. The last release removes it.
internal final class ConversationViews: Sendable {
    private struct State {
        var closed = false
        var mounts: [ConversationID: ConversationMount] = [:]
        var subscriptions: [SessionSubscription] = []
    }
    private let state = Mutex(State())
    private let session: Session
    private let storage: any DurableStorage
    private static var mounted: [DocumentDefinition] {
        [AgentDoc.definition, LiveDoc.definition, InboxDoc.definition, ProviderDoc.definition, UsageDoc.definition]
    }
    init(session: Session, storage: any DurableStorage) throws {
        self.session = session; self.storage = storage
        let commits = try session.subscribeCommits { [weak self] publication, context in
            self?.advance(publication, context: context)
        }
        do {
            let close = try session.subscribeClose { [weak self] in self?.close() }
            state.withLock { $0.subscriptions = [commits, close] }
        } catch { commits.cancel(); throw error }
    }

    deinit { for subscription in state.withLock({ $0.subscriptions }) { subscription.cancel() } }

    /// Hydrate and register atomically, so no committed revision can be missed.
    func attach(id: ConversationID, context: ChordContext,
                create: @Sendable (ConversationView, @escaping @Sendable () -> Void, any DurableStorage) async throws -> ConversationViewObserver
    ) async throws -> ConversationViewObserver {
        try await session.readOnLine {
            try context.abortSignal?.throwIfAborted()
            let mount: ConversationMount
            if let existing = state.withLock({ $0.mounts[id] }) { mount = existing }
            else { mount = try await build(id: id, context: context) }
            let identity = ViewObserverIdentity()
            let release: @Sendable () -> Void = { [weak self] in self?.detach(id: id, mount: mount, identity: identity) }
            let observer = try await create(mount.state.withLock { $0.value }, release, storage)
            identity.value.withLock { $0 = ObjectIdentifier(observer) }
            do {
                try context.abortSignal?.throwIfAborted()
                try state.withLock { state in
                    guard !state.closed else { throw closedError() }
                    mount.state.withLock { $0.observers[ObjectIdentifier(observer)] = observer }
                    state.mounts[id] = mount
                }
                return observer
            } catch { observer.closeSession(); throw error }
        }
    }
    func watch(id: ConversationID, context: ChordContext) async throws -> CommittedWatch<ConversationView> {
        let result = Mutex<CommittedWatch<ConversationView>?>(nil)
        _ = try await attach(id: id, context: context) { value, release, _ in
            let tree = Mutex(try JSONValue(encoding: value))
            let watch = CommittedWatch(value: value, replacement: { _ in tree.withLock { $0 } }, detach: release)
            result.withLock { $0 = watch }
            return ConversationViewObserver(advance: { value, ops, context in
                do { let next = try JSONValue(encoding: value); tree.withLock { $0 = next }; watch.advance(value: value, ops: ops, context: context) }
                catch { watch.fail(error) }
            }, closeSession: { watch.closeSession() })
        }
        let watch = result.withLock { $0! }
        do {
            if let signal = context.abortSignal { try watch.observeCancellation(signal) }
            try context.abortSignal?.throwIfAborted()
            return watch
        } catch { watch.cancel(); throw error }
    }
    func attachedState(id: ConversationID, context: ChordContext) async throws -> AttachedReplicatedState<ConversationView> {
        let result = Mutex<CommittedStateSource<ConversationView>?>(nil)
        _ = try await attach(id: id, context: context) { value, release, _ in
            let source = CommittedStateSource(value: value, release: release)
            result.withLock { $0 = source }
            return ConversationViewObserver(advance: { value, ops, context in source.advance(value: value, ops: ops, context: context) },
                closeSession: { source.closeSession() })
        }
        let source = result.withLock { $0! }
        do {
            let attached = try replicatedState(source)
            do { try context.abortSignal?.throwIfAborted() }
            catch { attached.dispose(); throw error }
            return attached
        } catch { source.closeSession(); throw error }
    }
    private func build(id: ConversationID, context: ChordContext) async throws -> ConversationMount {
        guard let conversation = try await storage.conversation(id, context: context) else {
            throw SessionError.message("Conversation \(id.rawValue) does not exist")
        }
        // This structural read does not decode model messages.
        let tail = try await storage.scanEntries(.init(conversationId: id), limit: 1, cursor: nil, context: context).items.first?.id
        var entries: [EntryRecord] = []
        if let tail {
            let head = try await storage.findLatestHeadMarker(id, atOrBeforeEntryId: tail, context: context)
            let range = try await scanAll { try await storage.scanEntries(.init(conversationId: id, minEntryId: head?.head, maxEntryId: tail, order: .ascending), limit: 256, cursor: $0, context: context) }
            entries = head.map { [$0] + range.filter { $0.head == nil } } ?? range
        }
        var docs: [String: JSONObject] = [:]
        var incarnations: [String: ConversationMount.Incarnation] = [:]
        for definition in Self.mounted {
            guard let loaded = try await session.loadDocument(definition, address: .init(kind: definition.kind, scope: .conversation(conversationId: id)), context: context) else { continue }
            try definition.check(loaded.record)
            try definition.checkVersion(loaded.storedVersion, record: loaded.record)
            docs[definition.kind] = loaded.tracker.value.objectValue!
            incarnations[definition.kind] = .init(id: loaded.record.id, version: loaded.valueVersion)
        }
        return try ConversationMount(value: .init(conversation: conversation, entries: entries, docs: docs), docs: incarnations)
    }
    private func detach(id: ConversationID, mount: ConversationMount, identity: ViewObserverIdentity) {
        guard let identity = identity.value.withLock({ $0 }) else { return }
        state.withLock { state in
            let empty = mount.state.withLock { state in state.observers.removeValue(forKey: identity); return state.observers.isEmpty }
            if empty, state.mounts[id] === mount { state.mounts.removeValue(forKey: id) }
        }
    }
    private func close() {
        let mounts = state.withLock { state -> [ConversationMount] in
            state.closed = true; let mounts = Array(state.mounts.values); state.mounts.removeAll(); return mounts
        }
        for mount in mounts {
            let observers = mount.state.withLock { Array($0.observers.values) }
            for observer in observers { observer.closeSession() }
        }
    }
    private func advance(_ publication: CommitPublication, context: ChordContext) {
        let mounts = state.withLock { Array($0.mounts) }
        for (id, mount) in mounts {
            do {
                let next = try mount.state.withLock { state -> (ConversationView, ConversationView, [Delta.Op], [ConversationViewObserver]) in
                    let before = state.value
                    var entries = before.entries
                    var docOps: [Delta.Op] = []; var entryOps: [Delta.Op] = []
                    for change in publication.changes {
                        if case .entry(let entry) = change, entry.conversationId == id {
                            let value = try JSONValue(encoding: entry)
                            if let target = entry.head {
                                let kept = entries.firstIndex { $0.head == nil && $0.id >= target } ?? entries.count
                                entryOps.append(.splice(["entries"], index: 0, remove: kept, items: [value]))
                                entries = [entry] + Array(entries[kept...])
                            } else {
                                entryOps.append(.splice(["entries"], index: entries.count, remove: 0, items: [value])); entries.append(entry)
                            }
                            continue
                        }
                        guard case .document(let change) = change, change.source == nil,
                              change.conversationId == id, change.record.key == nil,
                              Self.mounted.contains(where: { $0.kind == change.record.kind }) else { continue }
                        let kind = change.record.kind; let path: Delta.Path = ["docs", .key(kind)]
                        let mounted = state.docs[kind]
                        if let value = change.value {
                            if mounted?.id == change.record.id, mounted?.version == change.version {
                                docOps += change.ops.map { prefixedViewOp($0, prefix: path) }
                            } else {
                                state.docs[kind] = .init(id: change.record.id, version: change.version!)
                                docOps.append(.set(path, .object(value)))
                            }
                        } else if mounted?.id == change.record.id {
                            state.docs.removeValue(forKey: kind); docOps.append(.delete(path))
                        }
                    }
                    let ops = docOps + entryOps
                    if !ops.isEmpty {
                        state.tree = try Delta.applyImmutable(state.tree, ops)!
                        var docs = before.docs
                        if !docOps.isEmpty {
                            let mountedDocs = state.tree.objectValue!["docs"]!.objectValue!
                            for definition in Self.mounted {
                                let value = mountedDocs[definition.kind]?.objectValue
                                if docs[definition.kind] != value { docs[definition.kind] = value }
                            }
                        }
                        state.value = .init(conversation: before.conversation, entries: entries, docs: docs)
                    }
                    return (before, state.value, ops, Array(state.observers.values))
                }
                let frameContext = context.withoutAbortSignal()
                if !next.2.isEmpty { for observer in next.3 { observer.advance?(next.1, next.2, frameContext) } }
                for observer in next.3 { observer.publication?(next.0, next.1, next.2, publication, frameContext) }
            } catch {
                let observers = mount.state.withLock { Array($0.observers.values) }
                for observer in observers { observer.closeSession() }
            }
        }
    }
}

private final class ViewObserverIdentity: Sendable { let value = Mutex<ObjectIdentifier?>(nil) }

internal func prefixedViewOp(_ op: Delta.Op, prefix: Delta.Path) -> Delta.Op {
    switch op {
    case .replace(let value): .set(prefix, value)
    case .set(let path, let value): .set(prefix + path, value)
    case .delete(let path): .delete(prefix + path)
    case .append(let path, let text): .append(prefix + path, text)
    case .trim(let path, let count): .trim(prefix + path, count)
    case .splice(let path, let index, let remove, let items): .splice(prefix + path, index: index, remove: remove, items: items)
    case .move(let path, let permutation): .move(prefix + path, permutation: permutation)
    }
}

extension Conversation {
    public func viewState(context: ChordContext) async throws -> AttachedReplicatedState<ConversationView> {
        try await withTaskCancellationContext(try bound(context)) { context in
            try harness.assertOpen(); return try await harness.views.attachedState(id: id, context: context)
        }
    }
    public func watch(context: ChordContext) async throws -> ConversationWatch {
        try await withTaskCancellationContext(try bound(context)) { context in
            try harness.assertOpen(); return try await harness.views.watch(id: id, context: context)
        }
    }
}
