import Foundation
import PiSwiftChord
import Synchronization

/// Hooks for the harness. Conversation creation runs inside its transaction.
public protocol SessionHooks: Sendable {
    func conversationCreated(_ tx: Transaction, record: ConversationRecord) async throws
    func beforeClose() async
}
public extension SessionHooks {
    func conversationCreated(_ tx: Transaction, record: ConversationRecord) async throws {}
    func beforeClose() async {}
}
public struct DefaultSessionHooks: SessionHooks { public init() {} }

/// One mutation line over one storage backend.
public final class Session: Sendable {
    internal let storage: any DurableStorage
    internal let now: @Sendable () -> Int64
    internal let hooks: any SessionHooks
    internal let line = SessionLine()
    private struct CommitListener: Sendable {
        let id: Int
        let call: @Sendable (CommitPublication, PiSwiftChord.Context) -> Void
    }
    private struct CloseListener: Sendable {
        let id: Int
        let call: @Sendable () -> Void
    }
    private struct State: Sendable {
        var poison: (any Error)?
        var closing: Task<Void, any Error>?
        var nextListener = 0
        var commits: [CommitListener] = []
        var closes: [CloseListener] = []
        var documents: [[UInt8]: LoadedDocument] = [:]
    }
    private let state = Mutex(State())
    // Capture cached revisions atomically with all adoption, eviction, and installation.
    private let committedRead = Mutex(())
    private init(storage: any DurableStorage, now: @escaping @Sendable () -> Int64, hooks: any SessionHooks) {
        self.storage = storage; self.now = now; self.hooks = hooks
    }
    public static func open(storage: any DurableStorage,
                            now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                            hooks: any SessionHooks = DefaultSessionHooks(),
                            context: PiSwiftChord.Context) async throws -> Session {
        Session(storage: storage, now: now, hooks: hooks)
    }
    private func admit() throws -> SessionLine.Ticket {
        try state.withLock {
            if $0.closing != nil { throw SessionError.closed }
            if $0.poison != nil { throw SessionError.poisoned }
            return line.reserve()
        }
    }
    internal func assertHealthy() throws {
        try state.withLock { if $0.poison != nil { throw SessionError.poisoned } }
    }
    public func commit<T>(_ change: (Transaction) async throws -> T,
                          context: PiSwiftChord.Context) async throws -> T {
        try await commitWith(change, context: context, scope: TransactionScope())
    }
    internal func commitWith<T>(_ change: (Transaction) async throws -> T,
                                context: PiSwiftChord.Context,
                                scope: TransactionScope = TransactionScope()) async throws -> T {
        let ticket = try admit()
        await ticket.wait()
        defer { line.release() }
        try assertHealthy()
        try context.abortSignal?.throwIfAborted()
        let tx = Transaction(session: self, context: context, scope: scope)
        let result: T
        do { result = try await change(tx) }
        catch { await tx.settleFailure(); throw error }
        let writes = try await tx.settleSuccess()
        if writes.isEmpty { tx.discard(); return result }
        let seq: Seq
        do { seq = try await storage.commit(writes, context: context.withoutAbortSignal()) }
        catch {
            tx.discard()
            if !(error is StorageRejected) { state.withLock { $0.poison = error } }
            throw error
        }
        let documents: [DocumentCommitChange]
        do { documents = try committedRead.withLock { _ in try tx.adopt(seq) } }
        catch { state.withLock { $0.poison = error }; throw error }
        var changes: [CommitChange] = []
        for write in writes {
            switch write {
            case .conversation(let value, _): changes.append(.conversation(value))
            case .entry(let value, _): changes.append(.entry(value))
            case .task(let value, _): changes.append(.task(value))
            case .submission(let value, _): changes.append(.submission(value))
            default: break
            }
        }
        changes.append(contentsOf: documents.map(CommitChange.document))
        let publication = CommitPublication(seq: seq, changes: changes)
        let listeners = state.withLock { $0.commits }
        for listener in listeners { listener.call(publication, context) }
        return result
    }
    internal func readOnLine<T>(_ job: () async throws -> T) async throws -> T {
        let ticket = try admit()
        await ticket.wait()
        defer { line.release() }
        try assertHealthy()
        return try await job()
    }
    internal func unloadDocuments() async throws {
        // This internal operation also works during harness cleanup.
        let ticket = line.reserve()
        await ticket.wait()
        defer { line.release() }
        state.withLock { $0.documents.removeAll() }
    }
    /// The listener runs on the line after adoption. It must not block or call Session operations.
    public func subscribeCommits(_ listener: @escaping @Sendable (CommitPublication, PiSwiftChord.Context) -> Void) throws -> SessionSubscription {
        let id = try state.withLock { state in
            if state.closing != nil { throw SessionError.closed }
            if state.poison != nil { throw SessionError.poisoned }
            state.nextListener += 1
            let id = state.nextListener
            state.commits.append(CommitListener(id: id, call: listener)); return id
        }
        return SessionSubscription { [weak self] in self?.state.withLock { $0.commits.removeAll { $0.id == id } } }
    }
    /// The listener runs when close seals admission. It must not block or call Session operations.
    public func subscribeClose(_ listener: @escaping @Sendable () -> Void) throws -> SessionSubscription {
        let id = try state.withLock { state in
            if state.closing != nil { throw SessionError.closed }
            if state.poison != nil { throw SessionError.poisoned }
            state.nextListener += 1
            let id = state.nextListener
            state.closes.append(CloseListener(id: id, call: listener)); return id
        }
        return SessionSubscription { [weak self] in self?.state.withLock { $0.closes.removeAll { $0.id == id } } }
    }
    public func close(context: PiSwiftChord.Context) async throws {
        let begin = SessionLine.Ticket()
        let (task, listeners) = state.withLock { state -> (Task<Void, any Error>, [CloseListener]) in
            if let closing = state.closing { return (closing, []) }
            let cleanup = context.withoutAbortSignal()
            let task = Task {
                await begin.wait()
                await self.hooks.beforeClose()
                let ticket = self.line.reserve()
                await ticket.wait()
                defer { self.line.release() }
                self.state.withLock { $0.commits.removeAll(); $0.documents.removeAll() }
                try await self.storage.close(context: cleanup)
            }
            state.closing = task
            let listeners = state.closes; state.closes.removeAll()
            return (task, listeners)
        }
        for listener in listeners { listener.call() }
        begin.grant()
        try await awaitWithContext(task, context)
    }
    internal func loadDocument(_ definition: DocumentDefinition, address: DocumentAddress,
                               context: PiSwiftChord.Context) async throws -> LoadedDocument? {
        if let cached = cachedDocument(address) {
            if cached.valueVersion == definition.version { return cached }
            evictDocument(address, recordID: cached.record.id)
        }
        guard let record = try await storage.findDocument(address, at: .current, context: context) else { return nil }
        guard let stored = try await storage.document(record.id, at: .current, context: context) else {
            throw SessionError.message("Current document \(record.id.rawValue) (\(record.kind)) cannot be read")
        }
        let value = try definition.materialize(stored)
        let loaded = LoadedDocument(address: address, record: stored.record, storedVersion: stored.version,
                                    valueVersion: definition.version, deltasSinceBase: stored.deltasSinceBase,
                                    tracker: try Delta.track(.object(value)))
        installDocument(loaded)
        return loaded
    }
    internal func currentSnapshot<Value: Decodable & Sendable>(_ definition: DocumentDefinition,
                        address: DocumentAddress, context: PiSwiftChord.Context) async throws -> Value? {
        let captured = try committedRead.withLock { _ -> (LoadedDocument, Int, JSONValue)? in
            let cached = try state.withLock { state -> LoadedDocument? in
                if state.closing != nil { throw SessionError.closed }
                if state.poison != nil { throw SessionError.poisoned }
                return state.documents[Array(documentAddressID(address).utf8)]
            }
            guard let cached, cached.valueVersion == definition.version else { return nil }
            try definition.check(cached.record)
            try definition.checkVersion(cached.storedVersion, record: cached.record)
            return (cached, cached.tracker.revision, cached.tracker.value)
        }
        if let (loaded, revision, tree) = captured {
            return try loaded.snapshot(Value.self, revision: revision, tree: tree)
        }
        return try await readOnLine {
            guard let loaded = try await loadDocument(definition, address: address, context: context) else { return nil }
            try definition.check(loaded.record)
            try definition.checkVersion(loaded.storedVersion, record: loaded.record)
            return try loaded.snapshot(Value.self)
        }
    }
    internal func historicalSnapshot<Value: Decodable & Sendable>(_ definition: DocumentDefinition,
                        address: DocumentAddress, at: EntryID, context: PiSwiftChord.Context) async throws -> Value? {
        try await readOnLine {
            guard case .conversation(let conversationID, _) = address.scope else {
                throw SessionError.message("Session.snapshotAsOf() requires a conversation document")
            }
            guard let entry = try await storage.entry(conversationID, id: at, context: context) else {
                throw SessionError.message("Entry \(at.rawValue) is not visible from conversation \(conversationID.rawValue)")
            }
            let source = DocumentAddress(kind: address.kind, scope: .conversation(conversationId: entry.entry.conversationId), key: address.key)
            guard let record = try await storage.findDocument(source, at: .sequence(entry.commitSeq), context: context) else { return nil }
            guard let stored = try await storage.document(record.id, at: .sequence(entry.commitSeq), context: context) else {
                throw SessionError.message("Historical document \(record.id.rawValue) (\(record.kind)) cannot be read")
            }
            return try JSONValue.object(definition.materialize(stored)).decode(Value.self)
        }
    }
    internal func conversationDocumentOnLine<Value: Codable & Sendable>(_ token: ConversationDocToken<Value>, conversationId: ConversationID,
                        context: PiSwiftChord.Context) async throws -> (record: DocumentRecord, version: Int, value: JSONObject)? {
        try await conversationDocumentOnLine(token.definition, conversationId: conversationId, context: context)
    }
    internal func conversationDocumentOnLine<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID,
                        context: PiSwiftChord.Context) async throws -> (record: DocumentRecord, version: Int, value: JSONObject)? {
        try await conversationDocumentOnLine(token.definition, conversationId: conversationId, context: context)
    }
    private func conversationDocumentOnLine(_ definition: DocumentDefinition, conversationId: ConversationID,
                        context: PiSwiftChord.Context) async throws -> (record: DocumentRecord, version: Int, value: JSONObject)? {
        let address = DocumentAddress(kind: definition.kind, scope: .conversation(conversationId: conversationId))
        guard let loaded = try await loadDocument(definition, address: address, context: context) else { return nil }
        try definition.check(loaded.record)
        try definition.checkVersion(loaded.storedVersion, record: loaded.record)
        return (loaded.record, loaded.valueVersion, loaded.tracker.value.objectValue!)
    }
    internal func cachedDocument(_ address: DocumentAddress) -> LoadedDocument? {
        state.withLock { $0.documents[Array(documentAddressID(address).utf8)] }
    }
    internal func installDocument(_ document: LoadedDocument) {
        state.withLock { $0.documents[Array(documentAddressID(document.address).utf8)] = document }
    }
    internal func evictDocument(_ address: DocumentAddress, recordID: DocumentID) {
        state.withLock {
            let key = Array(documentAddressID(address).utf8)
            if $0.documents[key]?.record.id == recordID { $0.documents.removeValue(forKey: key) }
        }
    }
}
