import PiSwiftChord
import Synchronization

/// A bounded window over the full transcript and the built-in documents.
public struct ConversationView: Sendable, Equatable, Codable {
    /// The conversation handle returned by the test setup.
    public let conversation: ConversationRecord
    /// Transcript entries in ID order, including summaries and resets.
    public let entries: [EntryRecord]
    /// The ID of the transcript entry immediately before this window.
    public let before: EntryID?
    /// The current built-in document objects indexed by document kind.
    public let docs: [String: JSONObject]
    // Only Watch values carry this cache. It belongs to the same immutable revision as the fields.
    internal var watchJSON: JSONValue?
    private enum CodingKeys: String, CodingKey { case conversation, entries, before, docs }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.conversation == rhs.conversation && lhs.entries == rhs.entries && lhs.before == rhs.before && lhs.docs == rhs.docs
    }
    /// Pairs conversation metadata with one window and its documents.
    public init(conversation: ConversationRecord, entries: [EntryRecord], before: EntryID? = nil, docs: [String: JSONObject]) {
        self.conversation = conversation; self.entries = entries; self.before = before; self.docs = docs
    }
}

/// Initial inclusive position and the bounds of a conversation view.
public struct ConversationWindow: Sendable, Equatable {
    public let from: EntryID?
    public let min: Int?
    public let max: Int?
    public init(from: EntryID? = nil, min: Int? = nil, max: Int? = nil) {
        self.from = from; self.min = min; self.max = max
    }
    internal func resolved() throws -> (from: EntryID?, min: Int, max: Int) {
        let lower = min ?? 50
        guard lower >= 1, lower <= Int(EntryID.maximumRawValue) else {
            throw SessionError.message("Window min must be an integer >= 1, got \(lower)")
        }
        let upper = max ?? 2 * lower
        guard upper >= lower, upper <= Int(EntryID.maximumRawValue) else {
            throw SessionError.message("Window max must be an integer >= min (\(lower)), got \(upper)")
        }
        return (from, lower, upper)
    }
}

/// A stream of committed conversation views. Call stop() to release its observer.
public typealias ConversationWatch = Watch<ConversationView>

/// Callbacks run on the Session line. They must not call Session operations.
internal final class ConversationViewObserver: Sendable {
    let advance: (@Sendable (ConversationView, [Delta.Op], ChordContext) -> Void)?
    let closeSession: @Sendable () -> Void
    init(advance: (@Sendable (ConversationView, [Delta.Op], ChordContext) -> Void)? = nil,
         closeSession: @escaping @Sendable () -> Void) {
        self.advance = advance; self.closeSession = closeSession
    }
}

private final class ConversationMount: Sendable {
    struct Incarnation: Sendable { let id: DocumentID; let version: Int }
    struct State {
        let conversation: ConversationRecord
        var docs: [String: JSONObject]
        var tree: JSONValue
        var incarnations: [String: Incarnation]
        var observers: [ObjectIdentifier: WindowedView] = [:]
    }
    let state: Mutex<State>
    init(conversation: ConversationRecord, docs: [String: JSONObject], incarnations: [String: Incarnation]) {
        let values = JSONObject(docs.map { ($0.key, JSONValue.object($0.value)) })
        state = Mutex(State(conversation: conversation, docs: docs, tree: ["docs": .object(values)], incarnations: incarnations))
    }
}

private final class WindowedView: Sendable {
    struct State { var value: ConversationView }
    let min: Int
    let max: Int
    let observer: ConversationViewObserver
    let state: Mutex<State>
    init(value: ConversationView, min: Int, max: Int, observer: ConversationViewObserver) {
        self.min = min; self.max = max; self.observer = observer; state = Mutex(State(value: value))
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
        let commits = try session.observeCommits { [weak self] publication, context in
            try self?.advance(publication, context: context)
        }
        do {
            let close = try session.subscribeClose { [weak self] in self?.close() }
            state.withLock { $0.subscriptions = [commits, close] }
        } catch { commits.cancel(); throw error }
    }

    deinit { for subscription in state.withLock({ $0.subscriptions }) { subscription.cancel() } }

    /// Hydrate and register atomically, so no committed revision can be missed.
    func attach(id: ConversationID, context: ChordContext, window: ConversationWindow? = nil,
                create: @Sendable (ConversationView, @escaping @Sendable () -> Void) async throws -> ConversationViewObserver
    ) async throws -> ConversationViewObserver {
        let bounds = try (window ?? ConversationWindow()).resolved()
        return try await session.readOnLine {
            try context.abortSignal?.throwIfAborted()
            let mount: ConversationMount
            if let existing = state.withLock({ $0.mounts[id] }) { mount = existing }
            else { mount = try await build(id: id, context: context) }
            let loaded = try await loadWindow(id: id, bounds: bounds, context: context)
            let value = mount.state.withLock {
                ConversationView(conversation: $0.conversation, entries: loaded.entries, before: loaded.before, docs: $0.docs)
            }
            let identity = ViewObserverIdentity()
            let release: @Sendable () -> Void = { [weak self] in self?.detach(id: id, mount: mount, identity: identity) }
            let observer = try await create(value, release)
            identity.value.withLock { $0 = ObjectIdentifier(observer) }
            do {
                try context.abortSignal?.throwIfAborted()
                try state.withLock { state in
                    guard !state.closed else { throw closedError() }
                    mount.state.withLock { $0.observers[ObjectIdentifier(observer)] = WindowedView(value: value, min: bounds.min, max: bounds.max, observer: observer) }
                    state.mounts[id] = mount
                }
                return observer
            } catch { observer.closeSession(); throw error }
        }
    }
    // v1.5.2 CH3: The context controls attachment only. Host callbacks run on the Session line.
    func observe(id: ConversationID, observer: Observer<ConversationView>, context: ChordContext, window: ConversationWindow? = nil) async throws -> Observation<ConversationView> {
        let result = Mutex<(ConversationView, GuardedObserver<WatchCall<ConversationView>>)?>(nil)
        _ = try await attach(id: id, context: context, window: window) { value, release in
            let guarded = GuardedObserver(advance: observer.advance, end: observer.end,
                detach: release, report: { self.session.report($0) })
            result.withLock { $0 = (value, guarded) }
            return ConversationViewObserver(advance: { value, ops, context in
                guarded.advance(.value(value: value, ops: ops, retired: false), context: context)
            }, closeSession: { guarded.end(self.session.observerCloseEnd) })
        }
        let (value, guarded) = result.withLock { $0! }
        do { try context.abortSignal?.throwIfAborted() }
        catch { guarded.detach(); throw error }
        return Observation(value: value, detach: { guarded.detach() })
    }
    func watch(id: ConversationID, context: ChordContext, window: ConversationWindow? = nil) async throws -> Watch<ConversationView> {
        let result = Mutex<Watch<ConversationView>?>(nil)
        _ = try await attach(id: id, context: context, window: window) { value, release in
            var initial = value
            initial.watchJSON = try JSONValue(encoding: value)
            let watch = Watch(value: initial, replacement: { $0.watchJSON! }, detach: release, report: { self.session.report($0) })
            result.withLock { $0 = watch }
            return ConversationViewObserver(advance: { value, ops, context in
                do {
                    var next = value
                    next.watchJSON = try JSONValue(encoding: value)
                    watch.advance(.value(value: next, ops: ops, retired: false), context: context)
                }
                catch { self.session.report(error); watch.end(.failed(.message(String(describing: error)))) }
            }, closeSession: { watch.end(self.session.watchCloseEnd) })
        }
        let watch = result.withLock { $0! }
        do {
            if let signal = context.abortSignal { try watch.observeAbort(signal) }
            try context.abortSignal?.throwIfAborted()
            return watch
        } catch { watch.abort(); throw error }
    }
    func attachedState(id: ConversationID, context: ChordContext, window: ConversationWindow? = nil) async throws -> AttachedReplicatedState<ConversationView> {
        let result = Mutex<CommittedStateSource<ConversationView>?>(nil)
        _ = try await attach(id: id, context: context, window: window) { value, release in
            let source = CommittedStateSource(value: value, release: release)
            result.withLock { $0 = source }
            return ConversationViewObserver(advance: { value, ops, context in source.advance(value: value, ops: ops, context: context) },
                closeSession: { source.closeSession() })
        }
        let source = result.withLock { $0! }
        do {
            let attached = try replicatedState(source, onError: { self.session.report($0) })
            do { try context.abortSignal?.throwIfAborted() }
            catch { attached.dispose(); throw error }
            return attached
        } catch { source.closeSession(); throw error }
    }
    private func build(id: ConversationID, context: ChordContext) async throws -> ConversationMount {
        guard let conversation = try await storage.conversation(id, context: context) else {
            throw SessionError.message("Conversation \(id.rawValue) does not exist")
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
        return ConversationMount(conversation: conversation, docs: docs, incarnations: incarnations)
    }

    private func loadWindow(
        id: ConversationID, bounds: (from: EntryID?, min: Int, max: Int), context: ChordContext
    ) async throws -> (entries: [EntryRecord], before: EntryID?) {
        if let from = bounds.from {
            let since = try await scanUpTo(.init(conversationId: id, minEntryId: from, order: .ascending),
                                           count: bounds.max + 1, context: context)
            if since.count <= bounds.max {
                let previous: EntryRecord?
                if from.rawValue > 1 {
                    previous = try await storage.scanEntries(
                        .init(conversationId: id, maxEntryId: try EntryID(from.rawValue - 1)),
                        limit: 1, cursor: nil, context: context).items.first
                } else {
                    previous = nil
                }
                return (since, previous?.id)
            }
        }
        var newest = try await scanUpTo(.init(conversationId: id), count: bounds.min + 1, context: context)
        let before = newest.count > bounds.min ? newest.removeLast().id : nil
        newest.reverse()
        return (newest, before)
    }

    private func scanUpTo(_ query: EntryQuery, count: Int, context: ChordContext) async throws -> [EntryRecord] {
        var entries: [EntryRecord] = []
        var cursor: Cursor?
        repeat {
            let page = try await storage.scanEntries(query, limit: Swift.min(256, count - entries.count),
                                                     cursor: cursor, context: context)
            entries += page.items
            cursor = page.next
        } while cursor != nil && entries.count < count
        return entries
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
            for observer in observers { observer.observer.closeSession() }
        }
    }
    private func advance(_ publication: ObservedCommit, context: ChordContext) throws {
        let mounts = state.withLock { Array($0.mounts) }
        for (id, mount) in mounts {
            let next = try mount.state.withLock { state -> ([EntryRecord], [Delta.Op], [String: JSONObject], [WindowedView]) in
                var appended: [EntryRecord] = []
                var docOps: [Delta.Op] = []
                for change in publication.changes {
                    if case .entry(let entry) = change, entry.conversationId == id {
                        appended.append(entry)
                        continue
                    }
                    guard case .document(let change) = change, change.source == nil,
                          change.conversationId == id, change.record.key == nil,
                          Self.mounted.contains(where: { $0.kind == change.record.kind }) else { continue }
                    let kind = change.record.kind
                    let path: Delta.Path = ["docs", .key(kind)]
                    let mounted = state.incarnations[kind]
                    if let value = change.value {
                        if mounted?.id == change.record.id, mounted?.version == change.version {
                            docOps += change.ops.map { prefixedViewOp($0, prefix: path) }
                        } else {
                            state.incarnations[kind] = .init(id: change.record.id, version: change.version!)
                            docOps.append(.set(path, .object(value)))
                        }
                    } else if mounted?.id == change.record.id {
                        state.incarnations.removeValue(forKey: kind)
                        docOps.append(.delete(path))
                    }
                }
                if !docOps.isEmpty {
                    state.tree = try Delta.applyImmutable(state.tree, docOps)!
                    let mountedDocs = state.tree.objectValue!["docs"]!.objectValue!
                    state.docs = Dictionary(uniqueKeysWithValues: mountedDocs.map { ($0.0, $0.1.objectValue!) })
                }
                return (appended, docOps, state.docs, Array(state.observers.values))
            }
            if next.0.isEmpty && next.1.isEmpty { continue }
            let inserted = try next.0.map { try JSONValue(encoding: $0) }
            let frameContext = context.withoutAbortSignal()
            for windowed in next.3 {
                let revision = windowed.state.withLock { state -> (ConversationView, [Delta.Op]) in
                    let previous = state.value
                    var entries = previous.entries
                    var before = previous.before
                    var ops = next.1
                    if !next.0.isEmpty {
                        ops.append(.splice(["entries"], index: entries.count, remove: 0, items: inserted))
                        entries += next.0
                        if entries.count > windowed.max {
                            let drop = entries.count - windowed.min
                            before = entries[drop - 1].id
                            entries.removeFirst(drop)
                            ops.append(.splice(["entries"], index: 0, remove: drop, items: []))
                            ops.append(.set(["before"], .number(Double(before!.rawValue))))
                        }
                    }
                    state.value = .init(conversation: previous.conversation, entries: entries, before: before, docs: next.2)
                    return (state.value, ops)
                }
                windowed.observer.advance?(revision.0, revision.1, frameContext)
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
    /// Attaches the conversation view to committed changes. Cancel it to release the observer.
    public func viewState(context: ChordContext, window: ConversationWindow? = nil) async throws -> AttachedReplicatedState<ConversationView> {
        try await withTaskCancellationContext(try bound(context)) { context in
            try harness.assertOpen(); return try await harness.views.attachedState(id: id, context: context, window: window)
        }
    }
    /// Attaches a stream of committed conversation views. Call stop() on the watch to release it.
    public func watch(context: ChordContext, window: ConversationWindow? = nil) async throws -> ConversationWatch {
        try await withTaskCancellationContext(try bound(context)) { context in
            try harness.assertOpen(); return try await harness.views.watch(id: id, context: context, window: window)
        }
    }
}

extension Harness {
    /// Observe each conversation change on the Session line. Detach to release the observer.
    public func observeConversation(_ id: ConversationID, observer: Observer<ConversationView>, context: ChordContext, window: ConversationWindow? = nil) async throws -> Observation<ConversationView> {
        try await withTaskCancellationContext(context) { context in
            try assertOpen()
            return try await views.observe(id: id, observer: observer, context: context, window: window)
        }
    }
}
