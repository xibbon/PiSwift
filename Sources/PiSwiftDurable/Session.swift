import Foundation
import PiSwiftChord
import Synchronization

/// Hooks for the harness. Conversation creation runs inside its transaction.
public protocol SessionHooks: Sendable {
    /// Initializes application state inside the new conversation transaction.
    func conversationCreated(_ tx: Transaction, record: ConversationRecord) async throws
    /// Runs before the session releases its storage.
    func beforeClose() async
}
public extension SessionHooks {
    /// Performs no initialization unless the application supplies an override.
    func conversationCreated(_ tx: Transaction, record: ConversationRecord) async throws {}
    /// Performs no action unless the application supplies an override.
    func beforeClose() async {}
}
/// Session hooks that perform no application initialization.
public struct DefaultSessionHooks: SessionHooks {
    /// Creates hooks with no application callbacks.
    public init() {}
}

/// One mutation line over one storage backend.
public final class Session: Sendable {
    internal struct CacheBounds: Sendable {
        let conversations: Int
        let tasks: Int
        let submissions: Int
        init(conversations: Int = 4096, tasks: Int = 256, submissions: Int = 256) {
            self.conversations = conversations; self.tasks = tasks; self.submissions = submissions
        }
    }
    internal let storage: any DurableStorage
    private let cached: SessionCachedStorage
    private let tails = SessionConversationTails()
    private let failureLatch: SessionFailureLatch
    internal let onReport: @Sendable (any Error, ReportInfo) -> Void
    internal func report(_ error: any Error, _ info: ReportInfo = .listenerError) { onReport(error, info) }
    internal let now: @Sendable () -> Int64
    internal let hooks: any SessionHooks
    private let documentRetentionMs: @Sendable () throws -> Double?
    private let cacheNow: @Sendable () throws -> Int64
    private let documentTimer: SessionDocumentTimer
    // This build flag is used only for the full-suite retention checks.
    #if DEBUG && PI_DURABLE_ZERO_DOCUMENT_RETENTION
    internal static let defaultDocumentRetentionMs: Double = 0
    #else
    internal static let defaultDocumentRetentionMs: Double = 600_000
    #endif
    internal static func documentRetention(_ value: Double?) -> Double {
        guard let value, value >= 0 else { return defaultDocumentRetentionMs }
        return value
    }
    private struct DocumentSweep: Sendable {
        let id: Int
        let at: Double
        var queued = false
        var timer: Task<Void, Never>?
    }
    internal let line = SessionLine()
    private let outcomes = SessionOutcomeLine()
    internal var outstandingJobs: Int { outcomes.outstandingCount }
    private let writer: SessionWriter
    internal var writerUnpublished: Int { writer.unpublished }
    internal var writerPendingParts: Int { writer.pendingParts }
    private struct CommitListener: Sendable {
        let id: Int
        let call: @Sendable (CommitPublication, ChordContext) -> Void
        var end: (@Sendable (WatchEnd) -> Void)? = nil
    }
    private struct InternalListener: Sendable {
        let id: Int
        let call: @Sendable (CommitPublication, ChordContext) throws -> Void
    }
    private struct CloseListener: Sendable {
        let id: Int
        let call: @Sendable () -> Void
    }
    private struct State: Sendable {
        var closing: Task<Void, any Error>?
        var terminal: SessionCloseResult?
        var terminalWaiters: [CheckedContinuation<SessionCloseResult, Never>] = []
        var internals: [InternalListener] = []
        var nextListener = 0
        var commits: [CommitListener] = []
        var closes: [CloseListener] = []
        var documents: [[UInt8]: LoadedDocument] = [:]
        var idleDocuments = SessionDocumentIdleMap()
        var attachedDocuments: [DocumentID: Int] = [:]
        var documentSweep: DocumentSweep?
        var nextDocumentSweep = 0
        var sweepJobs = 0
        var documentTimersUnavailable = false
    }
    private let state = Mutex(State())
    // Capture cached revisions atomically with all adoption, eviction, and installation.
    private let committedRead = Mutex(())
    #if DEBUG
    // v1.5.2 session-adoption.test.ts:115–125 fault injection. This seam is
    // internal to the debug build and consumed once by Transaction.adopt.
    private let adoptionFailure = Mutex<(any Error)?>(nil)
    private let cachePublicationFailure = Mutex<(any Error)?>(nil)
    internal func failNextCachePublication(_ error: any Error) { cachePublicationFailure.withLock { $0 = error } }
    internal func failNextAdoption(_ error: any Error) { adoptionFailure.withLock { $0 = error } }
    internal func checkAdoptionFault() throws {
        let error = adoptionFailure.withLock { failure -> (any Error)? in
            let error = failure; failure = nil; return error
        }
        if let error { throw error }
    }
    #endif
    deinit { state.withLock { $0.documentSweep?.timer?.cancel() } }
    private init(storage: any DurableStorage, now: @escaping @Sendable () -> Int64,
                 documentRetentionMs: @escaping @Sendable () throws -> Double?, documentTimer: SessionDocumentTimer,
                 cacheNow: (@Sendable () throws -> Int64)?, cacheBounds: CacheBounds,
                 hooks: any SessionHooks, report: @escaping @Sendable (any Error, ReportInfo) -> Void) {
        let latch = SessionFailureLatch()
        self.failureLatch = latch
        self.documentRetentionMs = documentRetentionMs; self.documentTimer = documentTimer
        self.cacheNow = cacheNow ?? now
        let cached = SessionCachedStorage(storage, conversationCapacity: cacheBounds.conversations,
                                          taskCapacity: cacheBounds.tasks, submissionCapacity: cacheBounds.submissions)
        let guarded = GuardedStorage(cached, latch: latch)
        let writer = SessionWriter(storage: guarded, latch: latch,
            fail: { [weak guarded] error in
                if error as? SessionError == .closed, guarded?.closing == true { return }
                latch.fail(error)
            }, report: { error in report(error, .listenerError) })
        guarded.installWriter(writer)
        self.storage = guarded; self.cached = cached; self.writer = writer
        self.now = now; self.hooks = hooks; self.onReport = report
    }
    /// Creates a session over the supplied storage without reading persisted records.
    /// Unobserved documents leave the cache after ten minutes by default.
    /// A retention of zero releases them after use; positive infinity keeps them.
    /// Negative values and NaN use the default. Retention timers use the host time source.
    public static func open(storage: any DurableStorage,
                            now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                            documentRetentionMs: Double? = nil,
                            setTimer: HarnessSetTimer? = nil,
                            hooks: any SessionHooks = DefaultSessionHooks(),
                            onReport: @escaping @Sendable (any Error, ReportInfo) -> Void = { _, _ in },
                            context: ChordContext) async throws -> Session {
        try await openWithDocumentRetention(storage: storage, now: now, documentRetentionMs: { documentRetentionMs },
            documentTimer: .host(HarnessTimers(now: now, setTimer: setTimer, report: onReport)), hooks: hooks, onReport: onReport, context: context)
    }
    /// Adapts a callback that receives only the original error.
    public static func open(storage: any DurableStorage,
                            now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                            documentRetentionMs: Double? = nil, setTimer: HarnessSetTimer? = nil,
                            hooks: any SessionHooks = DefaultSessionHooks(),
                            onReport: @escaping @Sendable (any Error) -> Void,
                            context: ChordContext) async throws -> Session {
        try await open(storage: storage, now: now, documentRetentionMs: documentRetentionMs,
                       setTimer: setTimer, hooks: hooks, onReport: { error, _ in onReport(error) }, context: context)
    }
    /// Opens a Session with an internal timer hook for retention tests.
    internal static func open(storage: any DurableStorage,
                            now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                            documentRetentionMs: Double?,
                            documentTimer: SessionDocumentTimer,
                            hooks: any SessionHooks = DefaultSessionHooks(),
                            onReport: @escaping @Sendable (any Error, ReportInfo) -> Void = { _, _ in },
                            context: ChordContext) async throws -> Session {
        try await openWithDocumentRetention(storage: storage, now: now, documentRetentionMs: { documentRetentionMs },
            documentTimer: documentTimer, hooks: hooks, onReport: onReport, context: context)
    }
    internal static func openWithDocumentRetention(storage: any DurableStorage,
                            now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                            documentRetentionMs: @escaping @Sendable () throws -> Double?,
                            documentTimer: SessionDocumentTimer? = nil,
                            cacheNow: (@Sendable () throws -> Int64)? = nil,
                            cacheBounds: CacheBounds = CacheBounds(),
                            hooks: any SessionHooks = DefaultSessionHooks(),
                            onReport: @escaping @Sendable (any Error, ReportInfo) -> Void = { _, _ in },
                            context: ChordContext) async throws -> Session {
        let session = Session(storage: storage, now: now, documentRetentionMs: documentRetentionMs,
            documentTimer: documentTimer ?? .host(HarnessTimers(now: now, report: onReport)), cacheNow: cacheNow,
            cacheBounds: cacheBounds, hooks: hooks, report: onReport)
        session.failureLatch.install { [weak session] error in
            guard let session else { return }
            _ = session.beginClose(context: .background)
            session.report(error, .sessionFailed)
        }
        return session
    }
    private func admit() throws -> (SessionLine.Ticket, SessionOutcomeLine.Ticket) {
        try state.withLock {
            try failureLatch.check()
            if $0.closing != nil { throw SessionError.closed }
            return (line.reserve(), outcomes.reserve())
        }
    }
    internal func assertHealthy() throws {
        try failureLatch.check()
    }
    /// v1.5.2 session.ts `touch`: a memory decision waits for the latest
    /// unpublished writer of the key, then rechecks Session health.
    internal func touch(_ key: String) async throws {
        await writer.gate(key)
        try assertHealthy()
    }
    /// The newest visible entry, updated when this Session publishes an append.
    internal func latestEntryId(_ id: ConversationID, context: ChordContext) async throws -> EntryID? {
        try await touch(SessionKeys.conversationKey(id))
        try await touch(SessionKeys.appendKey(id))
        return try await tails.latest(id) {
            try await storage.scanEntries(.init(conversationId: id, order: .descending),
                                          limit: 1, cursor: nil, context: context).items.first?.id
        }
    }
    internal func latestHeadMarker(_ id: ConversationID, atOrBefore cutoff: EntryID?,
                                   context: ChordContext) async throws -> EntryRecord? {
        try await touch(SessionKeys.conversationKey(id))
        try await touch(SessionKeys.appendKey(id))
        return try await tails.marker(id, atOrBefore: cutoff) {
            try await storage.findLatestHeadMarker(id, atOrBeforeEntryId: cutoff, context: context)
        }
    }
    internal var recordCacheSizes: SessionCachedStorage.Sizes { cached.sizes }
    internal func evictCachedConversation(_ id: ConversationID) { cached.evictConversation(id) }
    internal func evictCachedSubmission(_ id: SubmissionID) { cached.evictSubmission(id) }
    internal var tailCacheSizes: (latest: Int, markers: Int) { (tails.size, tails.markers) }
    /// Commits the supplied changes atomically and publishes them after storage succeeds.
    public func commit<T>(_ change: (Transaction) async throws -> T,
                          context: ChordContext) async throws -> T {
        try await commitWith(change, context: context, scope: TransactionScope())
    }
    internal func commitWith<T>(_ change: (Transaction) async throws -> T,
                                context: ChordContext,
                                scope: TransactionScope = TransactionScope()) async throws -> T {
        let (ticket, delivery) = try admit()
        await ticket.wait()
        let prepared: (T, SessionWriterPart?, Bool)
        do {
            if !outcomes.tryClaimRoom() { await outcomes.waitForRoom() }
            prepared = try await commitOnLine(change, context: context, scope: scope, delivered: delivery)
            line.release()
        } catch {
            sweepDocuments()
            line.release()
            if !delivery.tryDeliver() { await delivery.deliver() }
            throw error
        }
        if prepared.2, let part = prepared.1 { await writer.runFirst(part) }
        let outcome: Result<Void, any Error>
        if let part = prepared.1 {
            if let settled = part.settledOutcome { outcome = settled }
            else {
                do { try await part.wait(); outcome = .success(()) }
                catch { outcome = .failure(error) }
            }
        } else { outcome = .success(()) }
        if prepared.1?.touchesDocument == true { sweepDocuments() }
        if !delivery.tryDeliver() { await delivery.deliver() }
        try outcome.get()
        if prepared.1 == nil { try assertHealthy() }
        return prepared.0
    }
    /// Cleanup reserves after admitted operations and can write after admission closes.
    internal func writeAtClose(_ change: (Transaction) async throws -> Void, context: ChordContext) async throws {
        let ticket = line.reserve()
        await ticket.wait()
        let part: SessionWriterPart?
        let startsWriter: Bool
        do {
            let prepared = try await commitOnLine(change, context: context.withoutAbortSignal(), scope: TransactionScope())
            part = prepared.1
            startsWriter = prepared.2
        } catch {
            line.release()
            fail(error)
            throw error
        }
        line.release()
        if startsWriter, let part { await writer.runFirst(part) }
        do { try await part?.wait() }
        catch { fail(error); throw error }
    }
    private func commitOnLine<T>(_ change: (Transaction) async throws -> T,
                                context: ChordContext, scope: TransactionScope,
                                delivered: SessionOutcomeLine.Ticket? = nil) async throws -> (T, SessionWriterPart?, Bool) {
        try assertHealthy()
        try context.abortSignal?.throwIfAborted()
        let tx = Transaction(session: self, context: context, scope: scope)
        let result: T
        do { result = try await change(tx); try assertHealthy() }
        catch { await tx.settleFailure(); throw error }
        let writes = try await tx.settleSuccess()
        if writes.isEmpty { tx.discard(); sweepDocuments(); return (result, nil, false) }
        let part = SessionWriterPart(writes: writes, keys: tx.writeKeys(writes), context: context,
            delivered: delivered,
            publish: { [weak self] seq in
                guard let self else { return .adoption(SessionError.closed) }
                return self.publishCommit(tx, writes: writes, seq: seq, context: context)
            }, discard: { tx.discard() })
        let first = writer.admit(part)
        return (result, part, first)
    }

    /// v1.5.2 session/session.ts `#adopt` and `#publish`.
    private func publishCommit(_ tx: Transaction, writes: [StorageWrite], seq: Seq,
                               context: ChordContext) -> WriterPublishFailure? {
        // v1.5.2 writer.ts:252–260: write-through precedes adoption.
        #if DEBUG
        let cacheError = cachePublicationFailure.withLock { failure -> (any Error)? in
            let error = failure; failure = nil; return error
        }
        if let cacheError { return .adoption(cacheError) }
        #endif
        if writes.count == 1, case .entry(let entry, _) = writes[0] {
            // Single-entry appends are the common publication path. They
            // cannot change a cached record, only this conversation's tail.
            tails.publishedEntry(entry)
        } else {
            cached.published(writes)
            tails.apply(writes)
        }
        let documents: [DocumentCommitChange]
        do { documents = try committedRead.withLock { _ in try tx.adopt(seq) } }
        catch { return .adoption(error) }
        for document in documents {
            touchDocument(DocumentAddress(kind: document.record.kind, scope: document.record.scope, key: document.record.key))
        }
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
        // v1.5.2 session.ts:1364–1385 queues host dispatch only if a
        // host was attached when this publication began. The dispatch uses
        // the listeners still attached after the own observers run.
        let hadHostListener = state.withLock { !$0.commits.isEmpty }
        let internalListeners = state.withLock { $0.internals }
        var ownFailure: (any Error)?
        for listener in internalListeners {
            do { try listener.call(publication, context) } catch { if ownFailure == nil { ownFailure = error } }
        }
        if hadHostListener {
            let listeners = state.withLock { $0.commits }
            for listener in listeners { listener.call(publication, context) }
        }
        sweepDocuments()
        return ownFailure.map { .listener($0) }
    }
    internal func readOnLine<T>(_ job: () async throws -> T) async throws -> T {
        let (ticket, delivery) = try admit()
        await ticket.wait()
        if !outcomes.tryClaimRoom() { await outcomes.waitForRoom() }
        let result: Result<T, any Error>
        do { try assertHealthy(); result = .success(try await job()) }
        catch { result = .failure(error) }
        line.release()
        if !delivery.tryDeliver() { await delivery.deliver() }
        switch result {
        case .success(let value): try assertHealthy(); return value
        case .failure(let error): throw error
        }
    }
    internal func unloadDocuments() async throws {
        // This internal operation also works during harness cleanup.
        let ticket = line.reserve()
        await ticket.wait()
        defer { line.release() }
        state.withLock { clearDocumentCache(&$0) }
    }
    /// The listener runs on the line after adoption. It must not block or call Session operations.
    public func subscribeCommits(_ listener: @escaping @Sendable (CommitPublication, ChordContext) -> Void) throws -> SessionSubscription {
        let id = try state.withLock { state in
            try failureLatch.check()
            if state.closing != nil { throw SessionError.closed }
            state.nextListener += 1
            let id = state.nextListener
            state.commits.append(CommitListener(id: id, call: listener)); return id
        }
        return SessionSubscription { [weak self] in self?.state.withLock { $0.commits.removeAll { $0.id == id } } }
    }
    /// The listener runs when close seals admission. It must not block or call Session operations.
    public func subscribeClose(_ listener: @escaping @Sendable () -> Void) throws -> SessionSubscription {
        let id = try state.withLock { state in
            try failureLatch.check()
            if state.closing != nil { throw SessionError.closed }
            state.nextListener += 1
            let id = state.nextListener
            state.closes.append(CloseListener(id: id, call: listener)); return id
        }
        return SessionSubscription { [weak self] in self?.state.withLock { $0.closes.removeAll { $0.id == id } } }
    }
    /// The first cause of Session failure.
    public var failure: (any Error)? { failureLatch.failure }

    // v1.5.2 CH3 session/session.ts:1839–1853 closeEnds.
    internal var watchCloseEnd: WatchEnd {
        failure.map { .failed(.message(String(describing: $0))) } ?? .ended
    }
    internal var observerCloseEnd: WatchEnd {
        failure.map { .failed(.message(String(describing: $0))) } ?? .failed(.message("session closed"))
    }

    /// Attach a synchronous commit observer. A listener error does not reject a stored commit.
    public func observeCommits(_ observer: CommitObserver) throws -> CommitObservation {
        let subscriptions = ObserverSubscriptions()
        let guarded = GuardedObserver(advance: observer.advance, end: observer.end,
            detach: { subscriptions.detach() }, report: { [weak self] in self?.report($0) })
        let id = try state.withLock { state in
            try failureLatch.check()
            if state.closing != nil { throw SessionError.closed }
            state.nextListener += 1
            let id = state.nextListener
            state.commits.append(CommitListener(id: id,
                call: { guarded.advance($0, context: $1) }, end: { guarded.end($0) }))
            return id
        }
        subscriptions.add(SessionSubscription { [weak self] in self?.state.withLock { $0.commits.removeAll { $0.id == id } } })
        return CommitObservation { guarded.detach() }
    }

    /// Resolves after backend close has finished, including a failed close.
    public var closed: SessionCloseResult {
        get async {
            await withCheckedContinuation { continuation in
                let result = state.withLock { state -> SessionCloseResult? in
                    if let terminal = state.terminal { return terminal }
                    state.terminalWaiters.append(continuation)
                    return nil
                }
                if let result { continuation.resume(returning: result) }
            }
        }
    }
    internal func fail(_ error: any Error) {
        // Close seals admission before its listeners seal the scheduler. Work
        // already queued by the scheduler can get the expected closed result
        // in that gap. It must not turn a healthy close into a Session failure.
        if error as? SessionError == .closed, state.withLock({ $0.closing != nil }) { return }
        failureLatch.fail(error)
    }
    internal func awaitHealthy<Value: Sendable>(_ work: Task<Value, any Error>, context: ChordContext) async throws -> Value {
        try await failureLatch.awaitHealthy(work, context: context)
    }
    internal func assertUsable() throws {
        try state.withLock { state in
            try failureLatch.check()
            if state.closing != nil { throw SessionError.closed }
        }
    }
    internal func observeCommits(_ listener: @escaping @Sendable (CommitPublication, ChordContext) throws -> Void) throws -> SessionSubscription {
        let id = try state.withLock { state in
            try failureLatch.check()
            if state.closing != nil { throw SessionError.closed }
            state.nextListener += 1
            let id = state.nextListener
            state.internals.append(InternalListener(id: id, call: listener)); return id
        }
        return SessionSubscription { [weak self] in self?.state.withLock { $0.internals.removeAll { $0.id == id } } }
    }
    /// Releases resources. Repeated calls wait for the same backend close.
    public func close(context: ChordContext) async throws {
        try await awaitWithContext(beginClose(context: context), context)
    }
    private func beginClose(context: ChordContext) -> Task<Void, any Error> {
        let begin = SessionLine.Ticket()
        let (task, listeners) = state.withLock { state -> (Task<Void, any Error>, [CloseListener]) in
            if let closing = state.closing { return (closing, []) }
            let cleanup = context.withoutAbortSignal()
            let task = Task {
                await begin.wait()
                await self.hooks.beforeClose()
                let ticket = self.line.reserve()
                await ticket.wait()
                defer { self.line.release(); self.finishClose() }
                await self.writer.drained()
                // v1.5.2 CH3 session/session.ts:797–802: end after the last publication.
                let observers = self.state.withLock { $0.commits }
                for observer in observers { observer.end?(self.observerCloseEnd) }
                self.state.withLock { $0.commits.removeAll(); $0.internals.removeAll(); self.clearDocumentCache(&$0); $0.attachedDocuments.removeAll() }
                do { try await self.storage.close(context: cleanup) }
                catch { self.fail(error); throw error }
            }
            state.closing = task
            state.documentSweep?.timer?.cancel()
            state.documentSweep = nil
            let listeners = state.closes; state.closes.removeAll()
            return (task, listeners)
        }
        for listener in listeners { listener.call() }
        begin.grant()
        return task
    }
    private func finishClose() {
        let result: SessionCloseResult = failure.map { .failed($0) } ?? .closed
        let waiters = state.withLock { state in
            state.terminal = result
            let waiters = state.terminalWaiters; state.terminalWaiters.removeAll(); return waiters
        }
        for waiter in waiters { waiter.resume(returning: result) }
    }
    internal func loadDocument(_ definition: DocumentDefinition, address: DocumentAddress,
                               context: ChordContext) async throws -> LoadedDocument? {
        try await waitForDocument(address)
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
    internal func waitForDocument(_ address: DocumentAddress) async throws {
        await writer.gate(SessionKeys.documentKey(address))
        try assertHealthy()
    }
    internal func currentSnapshot<Value: Decodable & Sendable>(_ definition: DocumentDefinition,
                        address: DocumentAddress, context: ChordContext) async throws -> Value? {
        // v1.5.2 D3a session.ts:595–612: a cached snapshot may return the
        // previous published revision while the next change is in storage.
        // A cache miss enters loadDocument, which waits at the address gate.
        let captured = try committedRead.withLock { _ -> (LoadedDocument, Int, JSONValue)? in
            let cached = try state.withLock { state -> LoadedDocument? in
                try failureLatch.check()
                if state.closing != nil { throw SessionError.closed }
                return state.documents[Array(documentAddressID(address).utf8)]
            }
            guard let cached, cached.valueVersion == definition.version else { return nil }
            try definition.check(cached.record)
            try definition.checkVersion(cached.storedVersion, record: cached.record)
            return (cached, cached.tracker.revision, cached.tracker.value)
        }
        if let (loaded, revision, tree) = captured {
            touchDocument(address)
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
                        address: DocumentAddress, at: EntryID, context: ChordContext) async throws -> Value? {
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
                        context: ChordContext) async throws -> (record: DocumentRecord, version: Int, value: JSONObject)? {
        try await conversationDocumentOnLine(token.definition, conversationId: conversationId, context: context)
    }
    internal func conversationDocumentOnLine<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID,
                        context: ChordContext) async throws -> (record: DocumentRecord, version: Int, value: JSONObject)? {
        try await conversationDocumentOnLine(token.definition, conversationId: conversationId, context: context)
    }
    private func conversationDocumentOnLine(_ definition: DocumentDefinition, conversationId: ConversationID,
                        context: ChordContext) async throws -> (record: DocumentRecord, version: Int, value: JSONObject)? {
        let address = DocumentAddress(kind: definition.kind, scope: .conversation(conversationId: conversationId))
        guard let loaded = try await loadDocument(definition, address: address, context: context) else { return nil }
        try definition.check(loaded.record)
        try definition.checkVersion(loaded.storedVersion, record: loaded.record)
        return (loaded.record, loaded.valueVersion, loaded.tracker.value.objectValue!)
    }
    internal func cachedDocument(_ address: DocumentAddress) -> LoadedDocument? {
        let loaded = state.withLock { $0.documents[Array(documentAddressID(address).utf8)] }
        if loaded != nil { touchDocument(address) }
        return loaded
    }
    internal func installDocument(_ document: LoadedDocument) {
        state.withLock { $0.documents[Array(documentAddressID(document.address).utf8)] = document }
        touchDocument(document.address)
    }
    internal func evictDocument(_ address: DocumentAddress, recordID: DocumentID) {
        state.withLock {
            let key = Array(documentAddressID(address).utf8)
            if $0.documents[key]?.record.id == recordID {
                $0.documents.removeValue(forKey: key); $0.idleDocuments.remove(key)
                if $0.idleDocuments.count == 0 { cancelDocumentTimer(&$0) }
            }
        }
    }

    /// Cache counts for retention tests. Observers are counted by record ID.
    internal var documentCacheSizes: (cached: Int, idle: Int, attached: Int, sweeps: Int) {
        state.withLock { ($0.documents.count, $0.idleDocuments.count, $0.attachedDocuments.count, $0.sweepJobs) }
    }
    private func retentionParameters() -> (now: Double, retention: Double, sleepNow: Int64) {
        // Take the sleep clock first. A concurrent advance must not move a deadline later.
        let sleepNow = documentTimer.now()
        let time: Int64
        do { time = try cacheNow() } catch { time = now() }
        let retention: Double
        do { retention = Self.documentRetention(try documentRetentionMs()) }
        catch { retention = Self.defaultDocumentRetentionMs }
        return (Double(time), retention, sleepNow)
    }
    private func touchDocument(_ address: DocumentAddress, recordID: DocumentID? = nil) {
        let (now, retention, sleepNow) = retentionParameters()
        state.withLock { state in
            let key = Array(documentAddressID(address).utf8)
            guard state.closing == nil, let cached = state.documents[key],
                  recordID == nil || cached.record.id == recordID,
                  state.attachedDocuments[cached.record.id] == nil else { return }
            if let since = state.idleDocuments.since(key), now - since < min(1000, retention / 10) { return }
            state.idleDocuments.touch(key, at: now)
            if state.documentSweep == nil || state.documentSweep!.at > now + retention {
                scheduleDocumentSweep(&state, now: now, retention: retention, sleepNow: sleepNow)
            }
        }
    }
    private func cancelDocumentTimer(_ state: inout State) {
        state.documentSweep?.timer?.cancel()
        // A queued job keeps its place until it runs. A later touch reuses it.
        if state.documentSweep?.queued != true { state.documentSweep = nil }
    }
    private func clearDocumentCache(_ state: inout State) {
        state.documents.removeAll(); state.idleDocuments.removeAll()
        cancelDocumentTimer(&state)
    }
    /// Called with the state lock. A timer or a queued line job is the only pending sweep.
    private func scheduleDocumentSweep(_ state: inout State, now: Double, retention: Double, sleepNow: Int64) {
        guard state.closing == nil else { return }
        guard let oldest = state.idleDocuments.first(where: {
            !writer.hasGate(SessionKeys.documentKey(String(decoding: $0, as: UTF8.self)))
        }), retention.isFinite else {
            cancelDocumentTimer(&state)
            return
        }
        let at = oldest.since + retention
        if let sweep = state.documentSweep, sweep.queued || sweep.at <= at { return }
        state.documentSweep?.timer?.cancel()
        state.nextDocumentSweep += 1
        let id = state.nextDocumentSweep
        state.documentSweep = DocumentSweep(id: id, at: at)
        let delay = at - now
        if delay <= 0 {
            queueDocumentSweep(&state, id: id)
            return
        }
        if state.documentTimersUnavailable { state.documentSweep = nil; return }
        // Bound each sleep and check the live setting again when it ends.
        let milliseconds = Int64(min(delay.rounded(.up), 2_147_483_647))
        let timer = documentTimer
        let sum = sleepNow.addingReportingOverflow(milliseconds)
        let deadline = sum.overflow ? Int64.max : sum.partialValue
        state.documentSweep?.timer = Task { [weak self] in
            do { try await timer.sleep(deadline) }
            catch {
                if !Task.isCancelled { self?.documentTimerFailed(id: id) }
                return
            }
            guard !Task.isCancelled else { return }
            self?.documentTimerFired(id: id)
        }
    }
    private func documentTimerFailed(id: Int) {
        state.withLock { state in
            guard state.documentSweep?.id == id else { return }
            state.documentTimersUnavailable = true
            state.documentSweep = nil
        }
    }
    private func documentTimerFired(id: Int) {
        state.withLock { state in
            guard state.closing == nil, state.documentSweep?.id == id else { return }
            queueDocumentSweep(&state, id: id)
        }
    }
    private func queueDocumentSweep(_ state: inout State, id: Int) {
        guard state.documentSweep?.queued == false else { return }
        state.documentSweep?.queued = true
        state.documentSweep?.timer = nil
        state.sweepJobs += 1
        let line = self.line
        let ticket = line.reserve()
        Task { [weak self] in
            await ticket.wait()
            defer { line.release() }
            guard let self else { return }
            self.state.withLock { state in
                if state.documentSweep?.id == id { state.documentSweep = nil }
            }
            self.sweepDocuments()
        }
    }
    /// Runs on the Session line, after settlement and publication have finished.
    private func sweepDocuments() {
        let (now, retention, sleepNow) = retentionParameters()
        state.withLock { state in
            guard state.closing == nil else { return }
            let expired = now - retention
            for key in state.idleDocuments.expired(before: expired) {
                if writer.hasGate(SessionKeys.documentKey(String(decoding: key, as: UTF8.self))) { continue }
                state.documents.removeValue(forKey: key)
                state.idleDocuments.remove(key)
            }
            scheduleDocumentSweep(&state, now: now, retention: retention, sleepNow: sleepNow)
        }
    }
    internal func pinDocument(_ address: DocumentAddress, recordID: DocumentID) throws -> SessionSubscription {
        try state.withLock { state in
            try failureLatch.check()
            if state.closing != nil { throw SessionError.closed }
            state.attachedDocuments[recordID, default: 0] += 1
            state.idleDocuments.remove(Array(documentAddressID(address).utf8))
            if state.idleDocuments.count == 0 { cancelDocumentTimer(&state) }
        }
        let released = Mutex(false)
        return SessionSubscription { [weak self] in
            let first = released.withLock { released in
                if released { return false }
                released = true; return true
            }
            guard first, let self else { return }
            let last = self.state.withLock { state in
                guard let count = state.attachedDocuments[recordID] else { return false }
                if count > 1 { state.attachedDocuments[recordID] = count - 1; return false }
                state.attachedDocuments.removeValue(forKey: recordID)
                return true
            }
            if last { self.touchDocument(address, recordID: recordID) }
        }
    }
}
