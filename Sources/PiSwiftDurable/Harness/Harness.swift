import PiSwiftChord
import Synchronization

private struct WeakHarness: Sendable { weak var value: Harness? }

private final class HarnessSessionHooks: SessionHooks {
    let scheduler = Mutex<TaskScheduler?>(nil)
    let app: (@Sendable (Transaction, ConversationRecord) async throws -> Void)?
    init(app: (@Sendable (Transaction, ConversationRecord) async throws -> Void)?) { self.app = app }
    func conversationCreated(_ tx: Transaction, record: ConversationRecord) async throws {
        _ = try await tx.doc(LiveDoc, conversationId: record.id)
        _ = try await tx.doc(InboxDoc, conversationId: record.id)
        _ = try await tx.doc(UsageDoc, conversationId: record.id)
        _ = try await tx.doc(ProviderDoc, conversationId: record.id)
        try await createAgent(tx: tx, conversation: record)
        try await app?(tx, record)
    }
    func beforeClose() async {
        let tasks = scheduler.withLock { state in let tasks = state; state = nil; return tasks }
        await tasks?.join()
    }
}

/// Durable task service over one Session. Reads do not start task scheduling.
public final class Harness: Sendable {
    internal let session: Session
    internal let storage: any DurableStorage
    internal let options: HarnessOptions
    internal let tasks: TaskScheduler
    internal let submissions: Submissions
    internal let views: ConversationViews
    internal let graph: TaskGraphView
    private let closed = Mutex(false)
    private init(session: Session, storage: any DurableStorage, options: HarnessOptions,
                 tasks: TaskScheduler, submissions: Submissions) throws {
        self.session = session; self.storage = storage; self.options = options; self.tasks = tasks; self.submissions = submissions
        self.views = try ConversationViews(session: session, storage: storage)
        self.graph = try TaskGraphView(session: session, storage: storage)
    }
    public static func open(storage: any DurableStorage, options: HarnessOptions,
                            context: ChordContext) async throws -> Harness {
        try await withTaskCancellationContext(context) { context in
            try context.abortSignal?.throwIfAborted()
            let snapshot = options.registry.snapshot()
            let missing = ["pi.generation", "pi.tool", "pi.compaction"].filter { snapshot.task(name: $0) == nil }
            if !missing.isEmpty { throw HarnessOpenError.missingBuiltins(missing) }
            let hooks = HarnessSessionHooks(app: options.conversationCreated)
            let now = options.now ?? { options.clock.now() }
            let session = try await Session.open(storage: storage, now: now, hooks: hooks, context: context)
            let report: @Sendable (any Error) -> Void = options.onReport ?? { _ in }
            let settings: @Sendable () -> Settings = { options.settings?.resolve() ?? resolveSettings() }
            let reference = Mutex(WeakHarness())
            let scheduler = TaskScheduler(session: session, registry: options.registry, models: options.models,
                clock: options.clock, now: now, settings: settings,
                agent: { id, snapshot, callContext in
                    let state = try await session.snapshot(AgentDoc, conversationId: id, context: callContext)
                    return resolveAgent(state: state, snapshot: snapshot, settings: settings(), report: report)
                }, env: { id, callContext in
                    guard let build = options.env else { return nil }
                    let cwd = try await session.snapshot(AgentDoc, conversationId: id, context: callContext)?.cwd
                    return try await build(EnvTarget(conversationId: id, cwd: cwd, read: documentReader(session: session, storage: storage)), callContext)
                }, conversation: { id, binding, callContext in
                    let found = try await session.readOnLine { try await storage.conversation(id, context: callContext) }
                    guard found != nil else { return nil }
                    guard let harness = reference.withLock({ $0.value }) else { throw closedError() }
                    return ConversationHandle(Conversation(id: id, harness: harness, binding: binding))
                }, report: report, context: context.withoutAbortSignal(),
                settleOutcome: { tx, record, outcome in try await settleSchedulerOutcome(tx: tx, record: record, outcome: outcome) },
                withdrawInputs: { tx, id in try await withdrawQueuedInputs(tx: tx, conversationId: id) })
            hooks.scheduler.withLock { $0 = scheduler }
            let submissions = try Submissions(session: session, storage: storage, now: now, settings: settings, resume: { scheduler.resume() })
            let harness = try Harness(session: session, storage: storage, options: options, tasks: scheduler, submissions: submissions)
            reference.withLock { $0.value = harness }
            do { try await scheduler.open(context: context) }
            catch {
                do { try await harness.close(context: context.withoutAbortSignal()) } catch { report(error) }
                throw error
            }
            return harness
        }
    }
    internal func assertOpen() throws { if closed.withLock({ $0 }) { throw closedError() } }
    public func resume() throws { try assertOpen(); tasks.resume() }
    public func close(context: ChordContext) async throws {
        closed.withLock { $0 = true }
        try await withTaskCancellationContext(context) { try await session.close(context: $0) }
    }
    public func commit<T>(_ change: (Transaction) async throws -> T, context: ChordContext) async throws -> T {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); return try await session.commit(change, context: context)
        }
    }
    public func subscribeCommits(_ listener: @escaping @Sendable (CommitPublication, ChordContext) -> Void) throws -> SessionSubscription {
        try assertOpen(); return try session.subscribeCommits(listener)
    }
    public func subscribeClose(_ listener: @escaping @Sendable () -> Void) throws -> SessionSubscription {
        try assertOpen(); return try session.subscribeClose(listener)
    }
    public func root(options: ConversationRootOptions = .init(), context: ChordContext) async throws -> Conversation {
        try await create(.root, agent: options.agent, initialize: options.initialize, context: context)
    }
    public func createConversation(options: ConversationCreateOptions, context: ChordContext) async throws -> Conversation {
        try await create(.independent(options.ownership), agent: options.agent, initialize: options.initialize, context: context)
    }
    public func conversation(id: ConversationID, context: ChordContext) async throws -> Conversation? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted()
            let record = try await session.readOnLine { try await storage.conversation(id, context: context) }
            return record.map { Conversation(id: $0.id, harness: self) }
        }
    }
    internal enum CreateTarget { case root, independent(ConversationOwnership), fork(ConversationID, EntryID, ConversationOwnership) }
    internal func create(_ target: CreateTarget, agent: AgentChange?, initialize: ConversationInit?, context: ChordContext) async throws -> Conversation {
        try await withTaskCancellationContext(context) { context in
            try assertOpen()
            let id = try await session.commit({ tx in
                if case .root = target, try await tx.conversation(rootConversationID) != nil { return rootConversationID }
                let record: ConversationRecord
                switch target {
                case .root: record = try await tx.createRootConversation()
                case .independent(let ownership): record = try await tx.createConversation(ownership: ownership)
                case let .fork(parent, at, ownership): record = try await tx.forkConversation(parent, at: at, ownership: ownership)
                }
                if let agent { try await configure(tx: tx, conversationId: record.id, change: agent) }
                try await initialize?(tx, record.id)
                return record.id
            }, context: context)
            return Conversation(id: id, harness: self)
        }
    }
    public func getTask(id: TaskID, context: ChordContext) async throws -> TaskRecord? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted()
            return try await session.readOnLine { try await storage.task(id, context: context) }
        }
    }
    public func inspect(context: ChordContext) async throws -> HarnessInspection {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted()
            return try await session.readOnLine {
                let inspection = try await tasks.inspect(snapshot: options.registry.snapshot())
                var records: [SubmissionRecord] = []
                for status in [SubmissionStatus.queued, .placed] {
                    records += try await scanAll { try await storage.scanSubmissions(.init(status: status), limit: 256, cursor: $0, context: context) }
                }
                return HarnessInspection(scheduling: inspection.scheduling, tasks: inspection.tasks, submissions: records.sorted { $0.id < $1.id })
            }
        }
    }
    public func abortTask(id: TaskID, context: ChordContext) async throws -> TaskAbortResult {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); return try await tasks.abort(id: id, context: context)
        }
    }
    public func waitForTask(id: TaskID, context: ChordContext) async throws -> SettledTask {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); tasks.resume(); return try await tasks.waitForTask(id: id, context: context)
        }
    }
    public func waitForIdle(context: ChordContext) async throws {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); tasks.resume(); try await tasks.waitForIdle(conversationId: nil, context: context)
        }
    }
    public func usage(context: ChordContext) async throws -> UsageState {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted()
            let conversations = try await session.readOnLine {
                try await scanAll { try await storage.scanConversations(.init(), limit: 256, cursor: $0, context: context) }
            }
            let reader = documentReader(session: session, storage: storage)
            var total = UsageState()
            for conversation in conversations {
                if let raw = try await reader.snapshot("pi.usage", conversation.id, context) {
                    let value = try JSONValue.object(raw).decode(UsageState.self)
                    addUsageState(sum: &total, state: value)
                }
            }
            return total
        }
    }
    internal func resolveConversationAgent(id: ConversationID, context: ChordContext) async throws -> Agent {
        try assertOpen(); try context.abortSignal?.throwIfAborted()
        let value = try await session.snapshot(AgentDoc, conversationId: id, context: context)
        return resolveAgent(state: value, snapshot: options.registry.snapshot(), settings: options.settings?.resolve() ?? resolveSettings(), report: options.onReport ?? { _ in })
    }
}
public enum HarnessOpenError: Error, Sendable, CustomStringConvertible {
    case missingBuiltins([String])
    public var description: String {
        switch self { case .missingBuiltins(let names): "Registry lacks built-in tasks \(names.joined(separator: ", ")); create it with createRegistry()" }
    }
}

internal func documentReader(session: Session, storage: any DurableStorage) -> HarnessDocumentReader {
    HarnessDocumentReader(snapshot: { kind, id, context in
        try await session.readOnLine {
            let scope: DocumentScope = id.map { .conversation(conversationId: $0) } ?? .session()
            guard let record = try await storage.findDocument(DocumentAddress(kind: kind, scope: scope), at: .current, context: context) else { return nil }
            return try await storage.document(record.id, at: .current, context: context)?.value
        }
    }, snapshotAsOf: { kind, id, at, context in
        try await session.readOnLine {
            guard let entry = try await storage.entry(id, id: at, context: context) else {
                throw SessionError.message("Entry \(at.rawValue) is not visible from conversation \(id.rawValue)")
            }
            let address = DocumentAddress(kind: kind, scope: .conversation(conversationId: entry.entry.conversationId))
            guard let record = try await storage.findDocument(address, at: .sequence(entry.commitSeq), context: context) else { return nil }
            return try await storage.document(record.id, at: .sequence(entry.commitSeq), context: context)?.value
        }
    }, typedRead: { definition, address, context in
        try await session.currentSnapshot(definition, address: address, context: context)
    }, typedHistoricalRead: { definition, address, at, context in
        try await session.historicalSnapshot(definition, address: address, at: at, context: context)
    })
}
