import Foundation
import PiSwiftChord
import Synchronization

/// A parked or not-started tool keeps its restart-marked children.
private func keepsAbandonedChildren(_ owner: TaskRecord) -> Bool {
    guard owner.kind == "pi.tool", let checkpoint = owner.state.checkpoint?.objectValue,
          let phase = checkpoint["phase"]?.stringValue else { return false }
    return phase == "call" || phase == "parked"
}

internal struct InvocationBinding: Sendable {
    let invocation: TaskInvocation
    let signal: AbortSignal
    let check: @Sendable () throws -> Void
}
internal final class TaskInvocation: Sendable {
    let taskId: TaskID
    let conversationId: ConversationID
    let reportTask: ReportTask
    let abort: Bool
    let controller = AbortController()
    let context: ChordContext
    let done = HarnessPromise<Void>()
    struct State: Sendable {
        var ended = false
        var work: Task<Void, Never>?
        var watches: [UUID: @Sendable () -> Void] = [:]
        var timers: [UUID: HarnessDisarm] = [:]
    }
    let state = Mutex(State())
    init(_ record: TaskRecord, abort: Bool, context: ChordContext) {
        taskId = record.id; conversationId = record.conversationId; reportTask = ReportTask(record); self.abort = abort
        self.context = context.withoutAbortSignal().withAbortSignal(controller.signal)
    }
    func check() throws {
        if state.withLock({ $0.ended }) { throw SessionError.message("Task \(taskId.rawValue) invocation has ended") }
    }
}
internal final class RuntimePhase: Sendable {
    struct State: Sendable {
        var definition: AnyTaskDefinition
        var snapshot: RegistrySnapshot
        var agent: Task<Agent, any Error>?
        var reported: UUID?
        var reportedMissing = false
    }
    let state: Mutex<State>
    let installer: String?
    let registryEpoch: UInt64
    init(_ definition: AnyTaskDefinition, _ snapshot: RegistrySnapshot, registryEpoch: UInt64) {
        installer = snapshot.installer(of: definition)
        self.registryEpoch = registryEpoch
        state = Mutex(State(definition: definition, snapshot: snapshot))
    }
}

/// Every decision that changes a task runs in one callback on the Session line.
internal final class TaskScheduler: Sendable {
    internal let toolServices = ToolServices()
    let session: Session
    let storage: any DurableStorage
    let registry: any RegistryReader
    let models: HarnessModelsProvider
    let timers: HarnessTimers
    var clock: any DurableClock { timers.clock }
    let readOnly: Bool
    let onWake: (@Sendable (HarnessWake) throws -> Void)?
    let now: @Sendable () -> Int64
    let settings: @Sendable () -> Settings
    let resolveAgent: @Sendable (ConversationID, RegistrySnapshot, ChordContext) async throws -> Agent
    let env: @Sendable (ConversationID, ChordContext) async throws -> (any ExecutionEnv)?
    let conversation: @Sendable (ConversationID, InvocationBinding, ChordContext) async throws -> ConversationHandle?
    let report: @Sendable (any Error, ReportInfo) -> Void
    let context: ChordContext
    let settleOutcome: @Sendable (Transaction, TaskRecord, TaskOutcome) async throws -> Void
    let withdrawInputs: @Sendable (Transaction, ConversationID) async throws -> Void
    struct KeptContext: Sendable { let range: ContextRange; var idleSince: Int64?; var expiresAt: Int64? = nil }
    struct State: Sendable {
        var publicationVersion: UInt64 = 0
        var live: [TaskID: TaskRecord] = [:]
        var nodes: [TaskID: TaskNode] = [:]
        var liveOrder: [TaskID: UInt64] = [:]
        var nextOrder: UInt64 = 0
        var below: [OwnershipUp: Set<OwnershipUp>] = [:]
        var roots = Set<ConversationID>()
        var unloaded = Set<TaskID>()
        var dropQueue = Set<OwnershipUp>()
        var intent = Set<TaskID>()
        var runnable = Set<TaskID>()
        var sleeping = Set<TaskID>()
        var gatedWake = Set<TaskID>()
        var registryEpoch: UInt64 = 0
        var refreshBlocked: (@Sendable () -> Void)?
        var sleepDisarm: HarnessDisarm?
        var sleepAt: Double?
        var sleepID = UUID()
        var wakeScheduled = false
        var wakeDirty = false
        var lastWake: HarnessWake?
        var reconcilingWork = 0
        var finalizeChecks = Set<TaskID>()
        var waiters: [TaskID: Set<TaskID>] = [:]
        var failFastChecks = Set<TaskID>()
        var sweepScheduled = false
        var sweepWork: Task<Void, Never>?
        var candidateEntries = 0
        var directOwned: [TaskID: Set<TaskID>] = [:]
        var abandoned = Set<TaskID>()
        // An entry with nil owner is a loaded, ownerless conversation.
        var edges: [ConversationID: TaskOwnershipEdge] = [:]
        var invocations: [TaskID: TaskInvocation] = [:]
        var joining: [UUID: TaskInvocation] = [:]
        var stopped = Set<TaskID>()
        var failedMigrations: [TaskID: (UUID, any Error)] = [:]
        var unsupportedReported = Set<TaskID>()
        var enabled = false
        var closing = false
        var dirty = false
        var pumping = false
        var worker: Task<Void, Never>?
        var cascadePending = false
        var reconcileScheduled = false
        var reconciles: [UUID: Task<Void, Never>] = [:]
        var subscriptions: [SessionSubscription] = []
        var unsubscribe: (@Sendable () -> Void)?
        var contexts: [ConversationID: KeptContext] = [:]
        var idleOrder = ContextIdleIndex<ConversationID>()
        var unknownsChanged = false
        var expiry: HarnessDisarm?
        var expiryAt: Int64?
        var expiryID = UUID()
    }
    let state = Mutex(State())
    let taskWaiters = Waiters<TaskID, SettledTask>()
    let idleWaiters = Waiters<ConversationID?, Void>()
    init(session: Session, registry: any RegistryReader, models: @escaping HarnessModelsProvider,
         timers: HarnessTimers, now: @escaping @Sendable () -> Int64,
         readOnly: Bool = false,
         onWake: (@Sendable (HarnessWake) throws -> Void)? = nil,
         settings: @escaping @Sendable () -> Settings,
         agent: @escaping @Sendable (ConversationID, RegistrySnapshot, ChordContext) async throws -> Agent,
         env: @escaping @Sendable (ConversationID, ChordContext) async throws -> (any ExecutionEnv)?,
         conversation: @escaping @Sendable (ConversationID, InvocationBinding, ChordContext) async throws -> ConversationHandle?,
         report: @escaping @Sendable (any Error, ReportInfo) -> Void, context: ChordContext,
         settleOutcome: @escaping @Sendable (Transaction, TaskRecord, TaskOutcome) async throws -> Void = { _, _, _ in },
         withdrawInputs: @escaping @Sendable (Transaction, ConversationID) async throws -> Void = { _, _ in }) {
        self.session = session; storage = session.storage; self.registry = registry; self.models = models
        self.timers = timers; self.now = now; self.readOnly = readOnly; self.onWake = onWake; self.settings = settings; resolveAgent = agent; self.env = env
        self.conversation = conversation; self.report = report; self.context = context.withoutAbortSignal()
        self.settleOutcome = settleOutcome; self.withdrawInputs = withdrawInputs
    }
    var closing: Bool { state.withLock { $0.closing } }
    func records() -> [TaskRecord] {
        state.withLock { state in state.live.values.sorted { state.liveOrder[$0.id, default: 0] < state.liveOrder[$1.id, default: 0] } }
    }
    func current(_ id: TaskID) -> TaskRecord? { state.withLock { $0.live[id] } }
    var registryEpoch: UInt64 { state.withLock { $0.registryEpoch } }
    /// Recheck a gate when its registry snapshot changed while its hook ran.
    func wakeGatedCallIfRegistryChanged(_ id: TaskID, since epoch: UInt64) {
        let changed = state.withLock { state -> Bool in
            guard state.registryEpoch != epoch, let record = state.live[id], isGatedCall(record) else { return false }
            state.gatedWake.insert(id); state.runnable.insert(id)
            return true
        }
        if changed { kick() }
    }
    private func isGatedCall(_ record: TaskRecord) -> Bool {
        guard record.kind == "pi.tool", case .sleeping(let checkpoint, _, _) = record.state else { return false }
        return checkpoint["phase"]?.stringValue == "call"
    }
    func open(context: ChordContext) async throws {
        let commits = try session.observeCommits { [weak self] publication, _ in self?.observe(publication) }
        let close = try session.subscribeClose { [weak self] in self?.seal() }
        let unsubscribe = registry.subscribe { [weak self] in self?.registryChanged() }
        state.withLock { $0.subscriptions = [commits, close]; $0.unsubscribe = unsubscribe }
        try await session.commit({ tx in
            var found: [TaskRecord] = []
            for status in [TaskStatus.pending, .running, .waiting, .sleeping, .completing] {
                found += try await scanAll { cursor in try await tx.scanTasks(.init(status: status), limit: 256, cursor: cursor) }
            }
            state.withLock { state in
                for record in found {
                    state.track(record)
                    if readOnly { continue } // v1.5.2 scheduler.ts:470
                    if isGatedCall(record) { state.gatedWake.insert(record.id); state.runnable.insert(record.id) }
                    if case .waiting(_, _, .failFast, _) = record.state { state.failFastChecks.insert(record.id) }
                    if record.abandonOnRestart == true { state.abandoned.insert(record.id) }
                }
            }
            for record in found where !readOnly {
                if case .running(let checkpoint, let fields) = record.state {
                    let restarts = record.restarts + 1
                    try tx.setTask(record.replacing(state: .pending(checkpoint: checkpoint, extensions: fields), restarts: .some(restarts)))
                }
            }
        }, context: context)
        if readOnly { return }
        state.withLock { $0.cascadePending = true }
        scheduleReconcile()
        scheduleWake()
    }
    func resume() throws {
        if readOnly { throw ReadOnlySession("running tasks") }
        state.withLock { $0.enabled = true }; kick()
    }
    func join() async {
        if readOnly { return }
        let (admitted, worker, reconciles) = state.withLock { ($0.joining, $0.worker, Array($0.reconciles.values)) }
        // Session close listeners end watches before cleanup aborts task signals.
        for invocation in admitted.values { invocation.controller.abort() }
        await worker?.value
        // A reservation can suspend on a storage read before it registers its invocation.
        let invocations = state.withLock { Array(admitted.merging($0.joining) { first, _ in first }.values) }
        for invocation in invocations { invocation.controller.abort() }
        for invocation in invocations { _ = try? await invocation.done.value() }
        for work in reconciles { await work.value }
        // The callback reads after all admitted marks and reservations have settled.
        try? await session.writeAtClose({ tx in
            let stopped = state.withLock { $0.stopped }.union(invocations.map(\.taskId))
            var pending: [TaskRecord] = []
            for id in stopped.sorted() {
                // v1.5.2 scheduler.ts:592–599: take the record after all
                // admitted marks. Swift's close listener has detached the
                // scheduler observer, so its live map can lag publication.
                guard let record = try await tx.task(id), case .running(let checkpoint, let fields) = record.state else { continue }
                pending.append(record.replacing(state: .pending(checkpoint: checkpoint, extensions: fields)))
            }
            for record in pending { try tx.setTask(record) }
        }, context: context)
    }
    private func seal() {
        let (expiry, sleep, unsubscribe) = state.withLock { state in
            state.closing = true; state.contexts = [:]; state.idleOrder.clear()
            state.stopped.formUnion(state.invocations.keys)
            let expiry = state.expiry; state.expiry = nil; state.expiryAt = nil
            let sleep = state.sleepDisarm; state.sleepDisarm = nil; state.sleepAt = nil
            state.sleepID = UUID(); state.expiryID = UUID()
            let unsubscribe = state.unsubscribe; state.unsubscribe = nil
            return (expiry, sleep, unsubscribe)
        }
        unsubscribe?(); expiry?(); sleep?()
        let error: any Error = session.failure.map { SessionFailed($0) } ?? closedError()
        taskWaiters.rejectAll(error); idleWaiters.rejectAll(error)
    }
    private func observe(_ publication: ObservedCommit) {
        if case .memory = publication { return } // v1.5.2 D7 scheduler.ts:783-785
        var aborts: [TaskInvocation] = [], settled: [TaskRecord] = [], updated: [TaskRecord] = []
        var failed = Set<TaskID>(), repair = false, changed = false
        var idleChanges: [TaskRecord] = []
        // v1.5.2 context.ts:199–212; scheduler.ts publication handling:
        // extend retained current ranges from the committed entries in order.
        var appended: [ConversationID: [EntryRecord]] = [:]
        for change in publication.changes {
            if case .entry(let entry) = change { appended[entry.conversationId, default: []].append(entry) }
        }
        state.withLock { state in
            state.publicationVersion &+= 1
            for (id, entries) in appended {
                guard let kept = state.contexts[id] else { continue }
                // v1.5.2 D7 scheduler.ts:903-912: only a range in this commit's scope is checked.
                if let expiresAt = kept.expiresAt, expiresAt <= now() {
                    state.contexts.removeValue(forKey: id); state.idleOrder.remove(id)
                    continue
                }
                // If derivation fails, drop the cached range. The next read
                // reconstructs it from committed storage.
                do {
                    let advanced = try advanceContextRange(kept.range, appended: entries)
                    if let advanced { state.contexts[id] = KeptContext(range: advanced, idleSince: kept.idleSince, expiresAt: kept.expiresAt) }
                    else { state.contexts.removeValue(forKey: id); state.idleOrder.remove(id) }
                } catch { state.contexts.removeValue(forKey: id); state.idleOrder.remove(id) }
            }
            // Install conversation edges before the tasks that need them.
            for change in publication.changes {
                if case .conversation(let record) = change, state.edges[record.id] == nil { state.setEdge(record) }
            }
            for change in publication.changes {
                guard case .task(let record) = change else { continue }
                changed = true
                let previous = state.live[record.id]
                if previous == nil || record.state.status == "terminal" { idleChanges.append(record) }
                if record.failedOutcome && previous?.failedOutcome != true { failed.insert(record.id) }
                state.track(record)
                if !isGatedCall(record) { state.gatedWake.remove(record.id) }
                if record.state.status == "terminal" {
                    state.failedMigrations.removeValue(forKey: record.id); state.failFastChecks.remove(record.id)
                    settled.append(record); repair = true
                    continue
                }
                if previous == nil { updated.append(record) }
                if record.abortRequested && previous?.abortRequested != true {
                    state.cascadePending = true
                    if let invocation = state.invocations[record.id], !invocation.abort { aborts.append(invocation) }
                }
                if previous?.abortReason != nil && record.abortReason == nil { state.cascadePending = true }
                if record.state.status == "completing" && previous?.state.status != "completing" {
                    repair = true
                    if record.abortRequested || record.failedOutcome { state.cascadePending = true }
                }
                if case .waiting(_, _, .failFast, _) = record.state, previous?.state.status != "waiting" {
                    state.failFastChecks.insert(record.id); repair = true
                }
            }
            for id in failed {
                let waiters = state.waiters[id] ?? []
                state.candidateEntries += waiters.count
                for waiter in waiters {
                    if case .waiting(_, _, .failFast, _) = state.live[waiter]?.state {
                        state.failFastChecks.insert(waiter); repair = true
                    }
                }
            }
        }
        for record in updated {
            if state.withLock({ $0.unloaded.contains(record.id) }) { repair = true }
            else if !record.background && !record.abortRequested && belowCancelled(record.parent) {
                state.withLock { $0.cascadePending = true }
            }
        }
        if state.withLock({ !$0.intent.isEmpty }) {
            for change in publication.changes {
                if case .submission(let input) = change, input.type == "input", input.status == "queued" {
                    let up = OwnershipUp.conversation(input.conversationId)
                    if !state.withLock({ $0.known(up) }) || belowCancelled(up) { state.withLock { $0.cascadePending = true } }
                }
            }
        }
        for invocation in aborts { invocation.controller.abort() }
        if repair || state.withLock({ $0.cascadePending }) { scheduleReconcile() }
        for record in settled { taskWaiters.resolve(record.id, value: SettledTask(record: record)) }
        if changed {
            var scopes: Set<ConversationID>? = []
            for record in idleChanges {
                for step in above(record.parent) {
                    switch step {
                    case .conversation(let id): scopes?.insert(id)
                    case .unknown: scopes = nil
                    case .task: break
                    }
                    if scopes == nil { break }
                }
                if scopes == nil { break }
            }
            state.withLock { $0.sweep() }
            settleIdle(scopes: scopes); kick()
        } else {
            state.withLock { $0.sweep() }
        }
    }
    /// A Task is created under the lock. It cannot enter the pump until the lock is released.
    func kick(offerWake: Bool = true) {
        state.withLock { state in
            guard !state.closing else { return }
            state.dirty = true
            guard !state.pumping && state.enabled else { return }
            state.pumping = true
            state.worker = Task { [weak self] in await self?.pump() }
        }
        if offerWake { scheduleWake() }
    }
    private func pump() async {
        while state.withLock({ state in
            guard state.dirty && !state.closing else { state.pumping = false; return false }
            state.dirty = false; return true
        }) {
            do {
                if state.withLock({ $0.enabled && !$0.closing }) {
                    let reservations = try await reserve()
                    for reservation in reservations { start(reservation) }
                }
            } catch { if !closing { session.fail(error) } }
            settleIdle(scopes: [])
        }
    }
    /// Repair durable intent separately from handler scheduling, including while paused.
    func scheduleReconcile() {
        state.withLock { state in
            guard !readOnly, !state.closing, !state.reconcileScheduled else { return }
            state.reconcileScheduled = true
            let id = UUID()
            state.reconciles[id] = Task { [weak self] in
                guard let self else { return }
                self.state.withLock { $0.reconcileScheduled = false }
                do { try await self.reconcile() }
                catch { if !self.closing { self.session.fail(error) } }
                self.settleIdle(scopes: [])
                _ = self.state.withLock { $0.reconciles.removeValue(forKey: id) }
                self.scheduleWake()
            }
        }
    }
    private func reconcile() async throws {
        let work = state.withLock { state in
            let work = state.cascadePending || !state.finalizeChecks.isEmpty || !state.failFastChecks.isEmpty
            if work { state.reconcilingWork += 1 }; return work
        }
        defer { if work { state.withLock { $0.reconcilingWork -= 1 } }; scheduleWake() }
        let (cascade, checks) = state.withLock { state in
            let cascade = state.cascadePending, checks = Array(state.failFastChecks)
            state.candidateEntries += checks.count
            state.cascadePending = false; state.failFastChecks.removeAll()
            return (cascade, checks)
        }
        try await session.commit({ tx in
            guard !closing else { return }
            // v1.5.2 D3a scheduler.ts:1380–1412 `#region`: reconciliation
            // walks several task and ownership keys in memory. Drain earlier
            // publications before taking that graph snapshot on the line.
            try await session.touch(SessionKeys.allKeys)
            try await loadScopes()
            let queued = cascade ? try await loadQueuedScopes() : []
            var marks: [TaskID: (record: TaskRecord, reason: TaskAbortReason?)] = [:]
            func mark(_ record: TaskRecord, reason: TaskAbortReason?) {
                if let staged = marks[record.id], staged.reason == nil { return }
                if record.abortRequested && (record.abortReason == nil || reason != nil) { return }
                marks[record.id] = (record, reason)
            }
            let intents = state.withLock { state in state.candidateEntries += state.intent.count; return state.intent }
            for id in intents {
                guard let owner = current(id) else { continue }
                let restart = owner.abortReason == .restart && !owner.failedOutcome
                walkDown(.task(id), enter: { !intents.contains($0) }) { step in
                    if let live = step.live, !step.node.background { mark(live, reason: restart ? .restart : nil) }
                    return false
                }
            }
            for id in checks {
                guard let record = current(id), case .waiting(_, let on, _, _) = record.state else { continue }
                var failed = false
                for id in on {
                    let found: TaskRecord?
                    if let live = current(id) { found = live } else { found = try await storage.task(id, context: context) }
                    if found?.failedOutcome == true { failed = true; break }
                }
                if failed { for id in on { if let live = current(id), !live.failedOutcome { mark(live, reason: nil) } } }
            }
            for marked in marks.values { try tx.setTask(marked.record.withAbortMark(marked.reason)) }
            for id in queued where belowCancelled(.conversation(id)) { try await withdrawInputs(tx, id) }
            try await finalize(tx)
        }, context: context)
    }
    private func finalize(_ tx: Transaction) async throws {
        var round = state.withLock { state in
            let checks = Array(state.finalizeChecks); state.candidateEntries += checks.count
            state.finalizeChecks.removeAll(); return checks
        }
        var overlay = try TaskOverlay(tx), done = Set<TaskID>()
        // A chain may finalize one owner in each round. Keep the staged link
        // graph for the whole transaction; rebuild only after a publication.
        let staged = overlay
        let roundLinks = Mutex(links(staged))
        while !round.isEmpty {
            var next = Set<TaskID>()
            for id in round {
                // v1.5.2 D5a scheduler.ts:1163–1227: decide from a clean
                // ownership region before staging the terminal write.
                let ready = try await region({ () -> TaskRecord? in
                    guard let record = overlay.tasks[id] ?? current(id), record.state.status == "completing", !done.contains(id) else { return nil }
                    return ownedLive(id, overlay: overlay, links: roundLinks.withLock { $0 }, first: true, done: done).isEmpty ? record : nil
                }, refresh: {
                    try await self.loadScopes()
                    let fresh = self.links(staged)
                    roundLinks.withLock { $0 = fresh }
                })
                guard let record = ready else { continue }
                guard let outcome = record.state.outcome else { continue }
                let terminal = record.replacing(state: .terminal(outcome: outcome))
                try tx.setTask(terminal); overlay.tasks[id] = terminal; done.insert(id)
                if outcome.status == "faulted" || outcome.status == "orphaned" { try await settleOutcome(tx, record, outcome) }
                if let above = state.withLock({ $0.nearestLiveAbove(TaskNode(record), overlay: overlay) }), above.state.status == "completing" { next.insert(above.id) }
            }
            round = Array(next)
            state.withLock { $0.candidateEntries += next.count }
        }
    }
    func terminate(_ tx: Transaction, record: TaskRecord, outcome: TaskOutcome) async throws {
        try await loadScopes()
        let overlay = try TaskOverlay(tx)
        for record in overlay.tasks.values { try await loadChain(record.parent, overlay: overlay) }
        let held = try await region({
            !ownedLive(record.id, overlay: overlay, links: links(overlay), first: true).isEmpty
        }, refresh: { try await self.loadScopes() })
        try tx.setTask(record.replacing(state: held ? .completing(outcome: outcome) : .terminal(outcome: outcome)))
        if !held && (outcome.status == "faulted" || outcome.status == "orphaned") { try await settleOutcome(tx, record, outcome) }
    }
    func fit(_ record: TaskRecord, definition: AnyTaskDefinition?) -> (reason: String?, error: (any Error)?, migrates: Bool) {
        fit(TaskBlockedSubject(record: record), definition: definition)
    }
    func fit(_ record: TaskBlockedSubject, definition: AnyTaskDefinition?) -> (reason: String?, error: (any Error)?, migrates: Bool) {
        guard let definition else { return ("missing_task", nil, false) }
        if definition.version < record.version { return ("task_too_old", nil, false) }
        if let unsupported = unsupportedBuiltInPhase(record) {
            // The tagged scheduler blocks work it cannot migrate as migration_failed
            // (scheduler.ts:2178-2185). Keep unsupported v1.6.0 records unchanged.
            return ("migration_failed", TaskDefinitionError("Task \(record.kind) requires \(unsupported.order) for \(unsupported.shape)"), false)
        }
        if definition.version == record.version { return (nil, nil, false) }
        if let failed = state.withLock({ $0.failedMigrations[record.id] }), failed.0 == definition.identity { return ("migration_failed", failed.1, false) }
        return (nil, nil, true)
    }
    func unsupportedBuiltInPhase(_ record: TaskBlockedSubject) -> (shape: String, order: String)? {
        let phase = record.checkpoint?["phase"]?.stringValue
        if record.kind == "pi.generation" {
            if let phase, !["prepare", "request", "retry", "poll", "tools", "finish", "drain", "afterTools", "yield"].contains(phase) { return ("phase \(phase)", "D5b") }
        }
        if record.kind == "pi.tool" {
            if let phase, !["call", "execute", "parked"].contains(phase) { return ("phase \(phase)", "D6") }
        }
        return nil
    }
    func blockedReason(_ record: TaskBlockedSubject) -> TaskBlockedReason? {
        if ["completing", "terminal"].contains(record.status) { return nil }
        if unsupportedBuiltInPhase(record) != nil { return .migrationFailed }
        if record.abortRequested && record.abortReason == nil { return nil }
        let definition = registry.snapshot().task(name: record.kind), fit = fit(record, definition: definition)
        if let reason = fit.reason { return TaskBlockedReason(rawValue: reason) }
        return fit.migrates && definition?.migrate == nil ? .migrationFailed : nil
    }
    /// Registry notifications can arrive off the line. Graph frames use the Session order.
    private func registryChanged() {
        state.withLock { state in
            state.registryEpoch &+= 1
            for id in state.sleeping {
                guard let record = state.live[id], isGatedCall(record) else { continue }
                state.gatedWake.insert(id); state.runnable.insert(id)
            }
        }
        Task { [weak self] in
            guard let self else { return }
            do { try await self.session.readOnLine { self.refreshBlocked() } }
            catch { return }
            self.kick()
        }
    }
    func refreshBlocked() { state.withLock { $0.refreshBlocked }?() }
    struct Reservation: Sendable {
        let invocation: TaskInvocation
        let definition: AnyTaskDefinition
        let snapshot: RegistrySnapshot
        let registryEpoch: UInt64
        let joinID: UUID
    }
    private func reserve() async throws -> [Reservation] {
        // Read the epoch before any awaited work or registry snapshot. A later
        // publication must recheck a gate even if it arrived before the hook.
        let reservationEpoch = registryEpoch
        var reservations: [Reservation] = []
        var faulted: [(TaskRecord, String)] = []
        var abandoned: Set<TaskID> = []
        do {
            try await session.commit({ tx in
                guard !closing else { return }
                // v1.5.2 D3a scheduler.ts:1380–1412 `#region`: the
                // abandoned/ownership decisions below read multiple keys.
                try await session.touch(SessionKeys.allKeys)
                abandoned = state.withLock { state in state.candidateEntries += state.abandoned.count; return state.abandoned }
                // Commit all restart marks before a descendant can reserve a run invocation.
                if !abandoned.isEmpty {
                    for id in abandoned {
                        if let record = current(id), !record.abortRequested {
                            let owner = record.owner.flatMap { current($0) }
                            if owner.map(keepsAbandonedChildren) != true {
                                try tx.setTask(record.withAbortMark(.restart))
                            }
                        }
                    }
                    return
                }
                try await loadScopes()
                wakeDue()
                // v1.5.2 D3a scheduler.ts:2002–2023 `#planCandidates`.
                // Take candidates before any awaited planning step. A publication
                // can add a fresh notification while this pass is suspended.
                let candidates = state.withLock { state in
                    state.candidateEntries += state.runnable.count
                    let values = Array(state.runnable).sorted()
                    state.runnable.removeAll()
                    return values
                }
                var dropped = Set<TaskID>()
                defer {
                    state.withLock { state in
                        for id in candidates where !dropped.contains(id) {
                            if let live = state.live[id], live.state.status != "completing",
                               state.invocations[id] == nil { state.runnable.insert(id) }
                        }
                    }
                }
                var snapshot: RegistrySnapshot?
                for id in candidates {
                    // v1.5.2 D3a scheduler.ts:2033–2052 `#planReservation`:
                    // a runnable record read from memory must wait for its
                    // unpublished task write, then be read again.
                    try await session.touch(SessionKeys.taskKey(id))
                    guard let original = current(id), original.state.status != "completing", !state.withLock({ $0.invocations[id] != nil }) else {
                        dropped.insert(id); continue
                    }
                    if let unsupported = unsupportedBuiltInPhase(TaskBlockedSubject(record: original)) {
                        snapshot = snapshot ?? registry.snapshot()
                        if state.withLock({ $0.unsupportedReported.insert(original.id).inserted }) {
                            let error = TaskDefinitionError("Task \(original.kind) requires \(unsupported.order) for \(unsupported.shape)")
                            report(error, .migrationFailed(task: ReportTask(original), extension: snapshot!.installer(of: snapshot!.task(name: original.kind))))
                        }
                        dropped.insert(id)
                        continue
                    }
                    if !waitingOn(original, first: true).isEmpty { dropped.insert(id); continue }
                    if notDue(original) && !state.withLock({ $0.gatedWake.contains(id) }) { dropped.insert(id); continue }
                    if !original.abortRequested && !original.background && belowCancelled(original.parent) {
                        state.withLock { $0.cascadePending = true }; scheduleReconcile()
                        continue
                    }
                    var record = original
                    let cutOff = record.storedRestarts != nil && record.restarts >= settings().restartLimit
                    let limitsOwnRestarts = ["pi.generation", "pi.tool", "pi.compaction"].contains(record.kind)
                    if cutOff && (record.abortRequested || !limitsOwnRestarts) {
                        let message = record.abortRequested
                            ? "Abort handler of task \(id.rawValue) (\(record.kind)) was cut off \(restartCountText(record.restarts)) times"
                            : "Task \(id.rawValue) (\(record.kind)) was cut off \(restartCountText(record.restarts)) times without progress"
                        try await terminate(tx, record: record, outcome: .faulted(error: .init(message: message, detail: ["reason": "restart_limit"])))
                        faulted.append((record, message))
                        continue
                    }
                    snapshot = snapshot ?? registry.snapshot()
                    let definition = snapshot!.task(name: record.kind)
                    var resolution = fit(record, definition: definition)
                    if resolution.reason == nil, resolution.migrates, let definition {
                        do {
                            guard let migrate = definition.migrate else { throw SessionError.message("Task \(record.kind) version \(definition.version) has no migration from \(record.version)") }
                            let next = try migrate(record.input, record.state.checkpoint!, record.version)
                            let fields: JSONObject
                            switch record.state {
                            case .pending(_, let kept), .running(_, let kept): fields = kept
                            default: fields = [:]
                            }
                            record = record.replacing(input: next.input, version: definition.version,
                                                      state: .running(checkpoint: next.checkpoint, extensions: fields))
                        } catch {
                            state.withLock { $0.failedMigrations[record.id] = (definition.identity, error) }; report(error, .migrationFailed(task: ReportTask(record), extension: snapshot!.installer(of: definition)))
                            refreshBlocked()
                            scheduleWake()
                            resolution = ("migration_failed", error, false)
                        }
                    }
                    if let reason = resolution.reason {
                        let unsupportedShape = unsupportedBuiltInPhase(TaskBlockedSubject(record: record)) != nil
                        if reason == "migration_failed", unsupportedShape, let error = resolution.error,
                           state.withLock({ $0.unsupportedReported.insert(record.id).inserted }) {
                            report(error, .migrationFailed(task: ReportTask(record), extension: snapshot!.installer(of: definition!)))
                        }
                        if record.abortRequested && record.abortReason == nil { try await terminate(tx, record: record, outcome: .orphaned(reason: reason)) }
                        continue
                    }
                    guard let definition, let checkpoint = record.state.checkpoint else { continue }
                    if let (wake, memos) = try woke(original) {
                        record = signalWithMemos(record, memos)
                        record = record.replacing(state: .running(checkpoint: checkpoint,
                            extensions: ["wake": try JSONValue(encoding: wake)]))
                    }
                    if original.state.status != "running" || resolution.migrates {
                        if record.state.status != "running" {
                            let fields: JSONObject
                            if case .pending(_, let kept) = record.state { fields = kept } else { fields = [:] }
                            record = record.replacing(state: .running(checkpoint: checkpoint, extensions: fields))
                        }
                        try tx.setTask(record)
                    }
                    let invocation = TaskInvocation(record, abort: record.abortRequested, context: context), id = UUID()
                    state.withLock {
                        $0.gatedWake.remove(record.id)
                        $0.invocations[record.id] = invocation; $0.joining[id] = invocation
                        if $0.closing { $0.stopped.insert(record.id) }
                    }
                    dropped.insert(record.id)
                    reservations.append(Reservation(invocation: invocation, definition: definition,
                        snapshot: snapshot!, registryEpoch: reservationEpoch, joinID: id))
                }
            }, context: context)
            if !abandoned.isEmpty {
                state.withLock { $0.abandoned.subtract(abandoned); $0.dirty = true }
            }
            for (record, message) in faulted {
                let snapshot = registry.snapshot()
                report(SessionError.message(message), .taskFaulted(task: ReportTask(record), extension: snapshot.installer(of: snapshot.task(name: record.kind)), reason: .restartLimit))
            }
            return reservations
        } catch {
            for reservation in reservations { end(reservation.invocation); finish(reservation) }
            throw error
        }
    }

    /// Records why a reservation ends a wait or sleep.
    private func woke(_ record: TaskRecord) throws -> (WakeReason, JSONObject)? {
        guard !record.abortRequested else { return nil }
        if case .waiting(_, let on, let policy, _) = record.state {
            let ended = policy == .any ? state.withLock { state in on.filter { state.live[$0] == nil } } : on
            return (.tasks(ended: ended), [:])
        }
        guard case .sleeping = record.state else { return nil }
        return try sleepWake(record.state, memos: record.memos, now: Double(now()))
    }

    private func start(_ reservation: Reservation) {
        let work = Task {
            await run(reservation)
            end(reservation.invocation); finish(reservation); kick()
        }
        reservation.invocation.state.withLock { $0.work = work }
    }
    private func finish(_ reservation: Reservation) {
        reservation.invocation.done.finish(.success(()))
        _ = state.withLock { $0.joining.removeValue(forKey: reservation.joinID) }
    }
    func end(_ invocation: TaskInvocation) {
        let watches = invocation.state.withLock { state -> [@Sendable () -> Void]? in
            guard !state.ended else { return nil }; state.ended = true
            let stops = Array(state.watches.values) + Array(state.timers.values)
            state.watches = [:]; state.timers = [:]; return stops
        }
        guard let watches else { return }
        state.withLock {
            if $0.invocations[invocation.taskId] === invocation {
                $0.invocations.removeValue(forKey: invocation.taskId)
                if $0.live[invocation.taskId] != nil { $0.runnable.insert(invocation.taskId) }
            }
        }
        for stop in watches { stop() }
        invocation.controller.abort(SessionError.message("Task \(invocation.taskId.rawValue) invocation has ended"))
    }
    enum Decision { case proceed, end, fault(any Error) }
    private func step(_ invocation: TaskInvocation, phase: RuntimePhase, decide: (Transaction, TaskRecord) throws -> Decision) async -> TaskRecord? {
        var fault: (any Error)?
        do {
            let continued: TaskRecord? = try await session.commit({ tx in
                // v1.5.2 D3a scheduler.ts:1380–1412 `#region`: terminate
                // inspects ownership as well as this invocation's task.
                try await session.touch(SessionKeys.allKeys)
                // v1.5.2 D3a scheduler.ts:1380–1412 `#region`:
                // this decision reads task memory after a prior write settles.
                try await session.touch(SessionKeys.taskKey(invocation.taskId))
                guard let current = current(invocation.taskId), current.state.status == "running", !closing else { end(invocation); return nil }
                switch try decide(tx, current) {
                case .proceed: return current
                case .end: end(invocation); return nil
                case .fault(let error):
                    end(invocation)
                    fault = error
                    try await terminate(tx, record: current, outcome: .faulted(error: .init(message: String(describing: error))))
                    return nil
                }
            }, context: context)
            if let fault { report(fault, .taskFaulted(task: invocation.reportTask, extension: phase.installer, reason: .threw)) }
            return continued
        } catch { end(invocation); if !closing { session.fail(error) }; return nil }
    }
    private func run(_ reservation: Reservation) async {
        let invocation = reservation.invocation, phase = RuntimePhase(reservation.definition,
            reservation.snapshot, registryEpoch: reservation.registryEpoch)
        let runtime = TaskRuntime(scheduler: self, invocation: invocation, phase: phase)
        if invocation.abort {
            guard let current = current(invocation.taskId), !closing else { return }
            var failure: (any Error)?
            do { try await reservation.definition.abort(current, runtime, invocation.context) } catch { failure = error }
            _ = await step(invocation, phase: phase) { _, _ in .fault(failure ?? SessionError.message("Abort handler of task \(invocation.taskId.rawValue) returned without a terminal outcome")) }
            return
        }
        var previous: JSONValue?, failure: (any Error)?
        while true {
            let found = await step(invocation, phase: phase) { tx, current in
                if current.abortRequested { return .end }
                // The owner's mark can commit before this task's cascade mark.
                if !current.background && belowCancelled(current.parent) {
                    state.withLock { $0.cascadePending = true }; scheduleReconcile()
                    return .end
                }
                guard let previous else { return .proceed }
                if let failure { return .fault(failure) }
                if jsonStructurallyEqual(current.state.checkpoint!, previous) {
                    let name = previous.objectValue?["phase"]?.stringValue ?? "undefined"
                    return .fault(SessionError.message("Task \(current.kind) phase \(name) returned without durable progress"))
                }
                let snapshot = registry.snapshot(), next = snapshot.task(name: current.kind)
                let old = phase.state.withLock { $0.definition }
                phase.state.withLock { $0.snapshot = snapshot }
                if next?.identity != old.identity {
                    if let next, next.version == current.version || (next.version > current.version && next.migrate != nil) {
                        let fields: JSONObject
                        if case .running(_, let kept) = current.state { fields = kept } else { fields = [:] }
                        try tx.setTask(current.replacing(state: .pending(checkpoint: current.state.checkpoint!, extensions: fields))); return .end
                    }
                    let shouldReport = phase.state.withLock { state -> Bool in
                        if let next { if state.reported == next.identity && !state.reportedMissing { return false }; state.reported = next.identity; state.reportedMissing = false }
                        else { if state.reportedMissing { return false }; state.reported = nil; state.reportedMissing = true }
                        return true
                    }
                    if shouldReport {
                        let reason: ReportInfo.OutdatedReason = next == nil ? .missingTask :
                            next!.version < current.version ? .taskTooOld : .migrationFailed
                        report(SessionError.message("Task \(current.id.rawValue) keeps running under its old \(current.kind) definition"),
                               .taskOutdated(task: invocation.reportTask, extension: phase.installer, reason: reason))
                    }
                }
                return .proceed
            }
            guard let found, !closing else { return }
            previous = found.state.checkpoint; failure = nil
            phase.state.withLock { $0.agent = nil }
            do { try await phase.state.withLock({ $0.definition }).run(found, runtime, invocation.context) }
            catch { failure = error }
        }
    }
}

internal enum OwnershipUp: Hashable, Sendable { case task(TaskID), conversation(ConversationID) }
internal enum OwnershipStep: Sendable { case task(TaskNode), conversation(ConversationID), unknown }
internal struct TaskOverlay: Sendable {
    var tasks: [TaskID: TaskRecord]
    let conversations: [ConversationID: ConversationRecord]
    static let empty = TaskOverlay(tasks: [:], conversations: [:])
    init(tasks: [TaskID: TaskRecord], conversations: [ConversationID: ConversationRecord]) { self.tasks = tasks; self.conversations = conversations }
    init(_ tx: Transaction) throws {
        tasks = Dictionary(uniqueKeysWithValues: try tx.stagedTasks().map { ($0.id, $0) })
        conversations = Dictionary(uniqueKeysWithValues: try tx.stagedConversations().map { ($0.id, $0) })
    }
}
internal extension TaskState {
    var checkpoint: JSONValue? { switch self { case .pending(let value, _), .running(let value, _), .waiting(let value, _, _, _), .sleeping(let value, _, _): value; default: nil } }
    var outcome: TaskOutcome? { switch self { case .completing(let value, _), .terminal(let value, _): value; default: nil } }
}
internal extension TaskRecord {
    var parent: OwnershipUp { owner.map(OwnershipUp.task) ?? .conversation(conversationId) }
    var failedOutcome: Bool { state.outcome.map { $0.status != "completed" } ?? false }
    func withAbortMark(_ reason: TaskAbortReason? = nil) -> TaskRecord {
        TaskRecord(id: id, conversationId: conversationId, kind: kind, version: version,
                   input: input, state: state, owner: owner, background: background,
                   abortRequested: true, abortReason: reason, abandonOnRestart: abandonOnRestart,
                   startedAt: startedAt, endedAt: endedAt, memos: memos,
                   extensionFields: restartCopyFields)
    }
    func replacing(input: JSONValue? = nil, version: Double? = nil, state: TaskState? = nil,
                   abortRequested: Bool? = nil, memos: JSONObject? = nil, restarts: Double?? = nil) -> TaskRecord {
        let next = state ?? self.state
        return TaskRecord(id: id, conversationId: conversationId, kind: kind, version: version ?? self.version,
                          input: input ?? self.input, state: next, owner: owner, background: background,
                          abortRequested: abortRequested ?? self.abortRequested, abortReason: abortReason,
                          abandonOnRestart: abandonOnRestart, startedAt: startedAt, endedAt: endedAt,
                          memos: next.outcome == nil ? (memos ?? self.memos) : nil,
                          restarts: next.outcome == nil ? (restarts ?? storedRestarts) : nil,
                          extensionFields: restartCopyFields)
    }
    private var restartCopyFields: JSONObject {
        var fields = carrierCopyFields
        fields["restarts"] = nil
        return fields
    }
    func progressed() -> TaskRecord { replacing(restarts: .some(nil)) }
}
private func restartCountText(_ value: Double) -> String {
    (try? JSONValue.number(value).jsonText()) ?? String(value)
}
internal func jsonStructurallyEqual(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
    switch (lhs, rhs) {
    case (.object(let left), .object(let right)):
        guard left.count == right.count else { return false }
        return left.allSatisfy { key, value in right[key].map { jsonStructurallyEqual(value, $0) } ?? false }
    case (.array(let left), .array(let right)): return left.count == right.count && zip(left, right).allSatisfy { jsonStructurallyEqual($0, $1) }
    default: return lhs == rhs
    }
}
