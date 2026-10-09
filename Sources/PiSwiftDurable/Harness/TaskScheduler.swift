import Foundation
import PiSwiftChord
import Synchronization

internal struct InvocationBinding: Sendable {
    let signal: AbortSignal
    let check: @Sendable () throws -> Void
}
internal final class TaskInvocation: Sendable {
    let taskId: TaskID
    let conversationId: ConversationID
    let abort: Bool
    let controller = AbortController()
    let context: PiSwiftChord.Context
    let done = HarnessPromise<Void>()
    struct State: Sendable {
        var ended = false
        var work: Task<Void, Never>?
        var watches: [UUID: @Sendable () -> Void] = [:]
    }
    let state = Mutex(State())
    init(_ record: TaskRecord, abort: Bool, context: PiSwiftChord.Context) {
        taskId = record.id; conversationId = record.conversationId; self.abort = abort
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
    init(_ definition: AnyTaskDefinition, _ snapshot: RegistrySnapshot) { state = Mutex(State(definition: definition, snapshot: snapshot)) }
}

/// Every decision that changes a task runs in one callback on the Session line.
internal final class TaskScheduler: Sendable {
    internal let toolServices = ToolServices()
    let session: Session
    let storage: any DurableStorage
    let registry: any RegistryReader
    let models: any DurableModels
    let clock: any DurableClock
    let now: @Sendable () -> Int64
    let settings: @Sendable () -> Settings
    let resolveAgent: @Sendable (ConversationID, RegistrySnapshot, PiSwiftChord.Context) async throws -> Agent
    let env: @Sendable (ConversationID, PiSwiftChord.Context) async throws -> (any ExecutionEnv)?
    let conversation: @Sendable (ConversationID, InvocationBinding, PiSwiftChord.Context) async throws -> ConversationHandle?
    let report: @Sendable (any Error) -> Void
    let context: PiSwiftChord.Context
    let settleOutcome: @Sendable (Transaction, TaskRecord, TaskOutcome) async throws -> Void
    let withdrawInputs: @Sendable (Transaction, ConversationID) async throws -> Void
    struct KeptContext: Sendable { let range: ContextRange; var idleSince: Int64? }
    struct State: Sendable {
        var live: [TaskID: TaskRecord] = [:]
        var order: [TaskID] = []
        var nodes: [TaskID: TaskRecord] = [:]
        // An entry with nil owner is a loaded, ownerless conversation.
        var edges: [ConversationID: ConversationRecord] = [:]
        var invocations: [TaskID: TaskInvocation] = [:]
        var joining: [UUID: TaskInvocation] = [:]
        var failedMigrations: [TaskID: (UUID, any Error)] = [:]
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
        var expiry: Task<Void, Never>?
        var expiryAt: Int64?
        var expiryID = UUID()
    }
    let state = Mutex(State())
    let taskWaiters = Waiters<TaskID, SettledTask>()
    let idleWaiters = Waiters<ConversationID?, Void>()
    init(session: Session, registry: any RegistryReader, models: any DurableModels,
         clock: any DurableClock, now: @escaping @Sendable () -> Int64,
         settings: @escaping @Sendable () -> Settings,
         agent: @escaping @Sendable (ConversationID, RegistrySnapshot, PiSwiftChord.Context) async throws -> Agent,
         env: @escaping @Sendable (ConversationID, PiSwiftChord.Context) async throws -> (any ExecutionEnv)?,
         conversation: @escaping @Sendable (ConversationID, InvocationBinding, PiSwiftChord.Context) async throws -> ConversationHandle?,
         report: @escaping @Sendable (any Error) -> Void, context: PiSwiftChord.Context,
         settleOutcome: @escaping @Sendable (Transaction, TaskRecord, TaskOutcome) async throws -> Void = { _, _, _ in },
         withdrawInputs: @escaping @Sendable (Transaction, ConversationID) async throws -> Void = { _, _ in }) {
        self.session = session; storage = session.storage; self.registry = registry; self.models = models
        self.clock = clock; self.now = now; self.settings = settings; resolveAgent = agent; self.env = env
        self.conversation = conversation; self.report = report; self.context = context.withoutAbortSignal()
        self.settleOutcome = settleOutcome; self.withdrawInputs = withdrawInputs
    }
    var closing: Bool { state.withLock { $0.closing } }
    func records() -> [TaskRecord] { state.withLock { state in state.order.compactMap { state.live[$0] } } }
    func current(_ id: TaskID) -> TaskRecord? { state.withLock { $0.live[id] } }
    func open(context: PiSwiftChord.Context) async throws {
        let commits = try session.subscribeCommits { [weak self] publication, _ in self?.observe(publication) }
        let close = try session.subscribeClose { [weak self] in self?.seal() }
        let unsubscribe = registry.subscribe { [weak self] in self?.kick() }
        state.withLock { $0.subscriptions = [commits, close]; $0.unsubscribe = unsubscribe }
        try await session.commit({ tx in
            var found: [TaskRecord] = []
            for status in [TaskStatus.pending, .running, .waiting, .completing] {
                found += try await scanAll { cursor in try await tx.scanTasks(.init(status: status), limit: 256, cursor: cursor) }
            }
            state.withLock { state in
                for record in found { state.live[record.id] = record; state.nodes[record.id] = record; state.order.append(record.id) }
            }
            for record in found {
                if case .running(let checkpoint, _) = record.state { try tx.setTask(record.replacing(state: .pending(checkpoint: checkpoint))) }
            }
        }, context: context)
        state.withLock { $0.cascadePending = true }
        scheduleReconcile()
    }
    func resume() { state.withLock { $0.enabled = true }; kick() }
    func join() async {
        let (invocations, worker, reconciles) = state.withLock { (Array($0.joining.values), $0.worker, Array($0.reconciles.values)) }
        for invocation in invocations { _ = try? await invocation.done.value() }
        await worker?.value
        for work in reconciles { await work.value }
    }
    private func seal() {
        let (invocations, expiry, unsubscribe) = state.withLock { state in
            state.closing = true; state.contexts = [:]
            let expiry = state.expiry; state.expiry = nil; state.expiryAt = nil
            let unsubscribe = state.unsubscribe; state.unsubscribe = nil
            return (Array(state.joining.values), expiry, unsubscribe)
        }
        unsubscribe?(); expiry?.cancel()
        taskWaiters.rejectAll(closedError()); idleWaiters.rejectAll(closedError())
        for invocation in invocations { invocation.controller.abort() }
    }
    private func observe(_ publication: CommitPublication) {
        var aborts: [TaskInvocation] = [], settled: [TaskRecord] = [], updated: [TaskRecord] = []
        var failed = Set<TaskID>(), repair = false, changed = false
        state.withLock { state in
            for change in publication.changes {
                switch change {
                case .task(let record):
                    changed = true
                    let previous = state.live[record.id]
                    if record.failedOutcome && previous?.failedOutcome != true { failed.insert(record.id) }
                    state.nodes[record.id] = record
                    if record.state.status == "terminal" {
                        if !state.edges.values.contains(where: { $0.owner?.taskId == record.id }) { state.nodes.removeValue(forKey: record.id) }
                        state.live.removeValue(forKey: record.id); state.order.removeAll { $0 == record.id }
                        state.failedMigrations.removeValue(forKey: record.id); settled.append(record); repair = true
                    } else {
                        if previous == nil { state.order.append(record.id) }
                        state.live[record.id] = record; updated.append(record)
                        if record.abortRequested && previous?.abortRequested != true {
                            state.cascadePending = true
                            if let invocation = state.invocations[record.id], !invocation.abort { aborts.append(invocation) }
                        }
                        if record.state.status == "completing" && previous?.state.status != "completing" {
                            repair = true
                            if record.abortRequested || record.failedOutcome { state.cascadePending = true }
                        }
                        if case .waiting(_, _, .failFast, _) = record.state, previous?.state.status != "waiting" { repair = true }
                    }
                case .conversation(let record): state.edges[record.id] = record
                default: break
                }
            }
            if !failed.isEmpty {
                for record in state.live.values {
                    if case .waiting(_, let on, .failFast, _) = record.state, on.contains(where: { failed.contains($0) }) { repair = true }
                }
            }
        }
        for record in updated {
            if above(record.parent).contains(where: { if case .unknown = $0 { return true }; return false }) { repair = true }
            else if !record.background && !record.abortRequested && belowCancelled(record.parent) {
                state.withLock { $0.cascadePending = true }
            }
        }
        for change in publication.changes {
            if case .submission(let input) = change, input.type == "input", input.status == "queued" {
                let up = OwnershipUp.conversation(input.conversationId)
                if above(up).contains(where: { if case .unknown = $0 { return true }; return false }) || belowCancelled(up) {
                    state.withLock { $0.cascadePending = true }
                }
            }
        }
        for invocation in aborts { invocation.controller.abort() }
        for record in settled { taskWaiters.resolve(record.id, value: SettledTask(record: record)) }
        if repair || state.withLock({ $0.cascadePending }) { scheduleReconcile() }
        if changed { settleIdle(); kick() }
    }
    /// A Task is created under the lock. It cannot enter the pump until the lock is released.
    func kick() {
        state.withLock { state in
            guard !state.closing else { return }
            state.dirty = true
            guard !state.pumping && state.enabled else { return }
            state.pumping = true
            state.worker = Task { [weak self] in await self?.pump() }
        }
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
            } catch { if !closing { report(error) } }
            settleIdle()
        }
    }
    /// Repair durable intent separately from handler scheduling, including while paused.
    func scheduleReconcile() {
        state.withLock { state in
            guard !state.closing, !state.reconcileScheduled else { return }
            state.reconcileScheduled = true
            let id = UUID()
            state.reconciles[id] = Task { [weak self] in
                guard let self else { return }
                self.state.withLock { $0.reconcileScheduled = false; $0.cascadePending = false }
                do { try await self.reconcile() }
                catch { self.state.withLock { $0.cascadePending = true }; if !self.closing { self.report(error) } }
                self.settleIdle()
                _ = self.state.withLock { $0.reconciles.removeValue(forKey: id) }
            }
        }
    }
    func loadChain(_ start: OwnershipUp, overlay: TaskOverlay = .empty) async throws {
        var at: OwnershipUp? = start
        var seen = Set<OwnershipUp>()
        while let step = at, seen.insert(step).inserted {
            switch step {
            case .task(let id):
                var record = overlay.tasks[id] ?? state.withLock { $0.nodes[id] }
                if record == nil {
                    record = try await storage.task(id, context: context)
                    if let record { state.withLock { $0.nodes[id] = record } }
                }
                guard let record else { return }; at = record.parent
            case .conversation(let id):
                var record = overlay.conversations[id] ?? state.withLock { $0.edges[id] }
                if record == nil {
                    record = try await storage.conversation(id, context: context)
                    if let record { state.withLock { $0.edges[id] = record } }
                }
                at = record?.owner.map { .task($0.taskId) }
            }
        }
    }
    func loadScopes() async throws { for record in records() { try await loadChain(record.parent) } }
    func loadQueuedScopes() async throws -> Set<ConversationID> {
        let submissions = try await scanAll { cursor in
            try await storage.scanSubmissions(.init(status: .queued), limit: 256, cursor: cursor, context: context)
        }
        let ids = Set(submissions.map(\.conversationId))
        for id in ids { try await loadChain(.conversation(id)) }
        return ids
    }
    func above(_ start: OwnershipUp, overlay: TaskOverlay = .empty) -> [OwnershipStep] {
        state.withLock { state in
            var result: [OwnershipStep] = [], at: OwnershipUp? = start, seen = Set<OwnershipUp>()
            while let step = at, seen.insert(step).inserted {
                switch step {
                case .task(let id):
                    guard let record = overlay.tasks[id] ?? state.nodes[id] else { result.append(.unknown); return result }
                    result.append(.task(record)); at = record.parent
                case .conversation(let id):
                    result.append(.conversation(id))
                    guard let record = overlay.conversations[id] ?? state.edges[id] else { result.append(.unknown); return result }
                    at = record.owner.map { .task($0.taskId) }
                }
            }
            return result
        }
    }
    func liveRecords(_ overlay: TaskOverlay = .empty) -> [TaskRecord] {
        var records = records().map { overlay.tasks[$0.id] ?? $0 }
        let ids = Set(records.map(\.id))
        records += overlay.tasks.values.filter { !ids.contains($0.id) }
        return records.filter { $0.state.status != "terminal" }
    }
    func ownedWork(_ overlay: TaskOverlay = .empty) -> [TaskID: [TaskID]] {
        var owned: [TaskID: [TaskID]] = [:]
        for record in liveRecords(overlay) where !record.background {
            for step in above(record.parent, overlay: overlay) {
                if case .task(let owner) = step { owned[owner.id, default: []].append(record.id); if owner.background { break } }
            }
        }
        return owned
    }
    func ownedLive(_ overlay: TaskOverlay = .empty) -> Set<TaskID> { Set(ownedWork(overlay).keys) }
    func inScope(_ start: OwnershipUp, conversationId: ConversationID?, background: Bool = false) -> Bool? {
        for step in above(start) {
            switch step {
            case .unknown: return nil
            case .conversation(let id): if id == conversationId { return true }
            case .task(let record): if record.background && !background { return false }
            }
        }
        return conversationId == nil
    }
    func belowCancelled(_ start: OwnershipUp) -> Bool {
        for step in above(start) {
            if case .task(let record) = step {
                if let live = current(record.id), live.abortRequested || live.failedOutcome { return true }
                if record.background { return false }
            }
        }
        return false
    }
    func idle(_ id: ConversationID?) -> Bool { !records().contains { !$0.background && inScope($0.parent, conversationId: id) != false } }
    func waitingOn(_ record: TaskRecord, owned: Set<TaskID>) -> [TaskID] {
        if record.abortRequested { return owned.contains(record.id) ? (ownedWork()[record.id] ?? []) : [] }
        if case .waiting(_, let on, _, _) = record.state { return on.filter { current($0) != nil } }
        return []
    }
    private func reconcile() async throws {
        try await session.commit({ tx in
            guard !closing else { return }
            try await loadScopes()
            let queued = try await loadQueuedScopes()
            var marks = Set<TaskID>()
            for record in records() {
                if !record.background && belowCancelled(record.parent) { marks.insert(record.id) }
                if case .waiting(_, let on, .failFast, _) = record.state {
                    var failed = false
                    for id in on {
                        let found: TaskRecord?
                        if let live = current(id) { found = live } else { found = try await storage.task(id, context: context) }
                        if found?.failedOutcome == true { failed = true; break }
                    }
                    if failed { for id in on { if let live = current(id), !live.failedOutcome { marks.insert(id) } } }
                }
            }
            for id in marks { if let record = current(id), !record.abortRequested { try tx.setTask(record.replacing(abortRequested: true)) } }
            for id in queued where belowCancelled(.conversation(id)) { try await withdrawInputs(tx, id) }
            while true {
                let overlay = try TaskOverlay(tx), owned = ownedLive(overlay)
                let done = liveRecords(overlay).filter { $0.state.status == "completing" && !owned.contains($0.id) }
                if done.isEmpty { break }
                for record in done {
                    if let outcome = record.state.outcome {
                        try tx.setTask(record.replacing(state: .terminal(outcome: outcome)))
                        if outcome.status == "faulted" || outcome.status == "orphaned" { try await settleOutcome(tx, record, outcome) }
                    }
                }
            }
        }, context: context)
    }
    func terminate(_ tx: Transaction, record: TaskRecord, outcome: TaskOutcome) async throws {
        try await loadScopes()
        let overlay = try TaskOverlay(tx)
        for record in overlay.tasks.values { try await loadChain(record.parent, overlay: overlay) }
        let held = ownedLive(overlay).contains(record.id)
        try tx.setTask(record.replacing(state: held ? .completing(outcome: outcome) : .terminal(outcome: outcome)))
        if !held && (outcome.status == "faulted" || outcome.status == "orphaned") { try await settleOutcome(tx, record, outcome) }
    }
    func fit(_ record: TaskRecord, definition: AnyTaskDefinition?) -> (reason: String?, error: (any Error)?, migrates: Bool) {
        guard let definition else { return ("missing_task", nil, false) }
        if definition.version < record.version { return ("task_too_old", nil, false) }
        if definition.version == record.version { return (nil, nil, false) }
        if let failed = state.withLock({ $0.failedMigrations[record.id] }), failed.0 == definition.identity { return ("migration_failed", failed.1, false) }
        return (nil, nil, true)
    }
    struct Reservation: Sendable { let invocation: TaskInvocation; let definition: AnyTaskDefinition; let snapshot: RegistrySnapshot; let joinID: UUID }
    private func reserve() async throws -> [Reservation] {
        var reservations: [Reservation] = []
        do {
            try await session.commit({ tx in
                guard !closing else { return }
                try await loadScopes()
                let owned = ownedLive(), snapshot = registry.snapshot()
                for original in records() {
                    if state.withLock({ $0.invocations[original.id] != nil }) || original.state.status == "completing" || !waitingOn(original, owned: owned).isEmpty { continue }
                    var record = original
                    let definition = snapshot.task(name: record.kind)
                    var resolution = fit(record, definition: definition)
                    if resolution.reason == nil, resolution.migrates, let definition {
                        do {
                            guard let migrate = definition.migrate else { throw SessionError.message("Task \(record.kind) version \(definition.version) has no migration from \(record.version)") }
                            let next = try migrate(record.input, record.state.checkpoint!, record.version)
                            record = record.replacing(input: next.input, version: definition.version, state: .running(checkpoint: next.checkpoint))
                        } catch {
                            state.withLock { $0.failedMigrations[record.id] = (definition.identity, error) }; report(error)
                            resolution = ("migration_failed", error, false)
                        }
                    }
                    if let reason = resolution.reason {
                        if record.abortRequested { try await terminate(tx, record: record, outcome: .orphaned(reason: reason)) }
                        continue
                    }
                    guard let definition, let checkpoint = record.state.checkpoint else { continue }
                    if original.state.status != "running" || resolution.migrates {
                        try tx.setTask(record.replacing(state: .running(checkpoint: checkpoint)))
                    }
                    let invocation = TaskInvocation(record, abort: record.abortRequested, context: context), id = UUID()
                    state.withLock { $0.invocations[record.id] = invocation; $0.joining[id] = invocation }
                    reservations.append(Reservation(invocation: invocation, definition: definition, snapshot: snapshot, joinID: id))
                }
            }, context: context)
            return reservations
        } catch {
            for reservation in reservations { end(reservation.invocation); finish(reservation) }
            throw error
        }
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
            let watches = Array(state.watches.values); state.watches = [:]; return watches
        }
        guard let watches else { return }
        state.withLock { if $0.invocations[invocation.taskId] === invocation { $0.invocations.removeValue(forKey: invocation.taskId) } }
        for stop in watches { stop() }
        invocation.controller.abort(SessionError.message("Task \(invocation.taskId.rawValue) invocation has ended"))
    }
    enum Decision { case proceed, end, fault(any Error) }
    private func step(_ invocation: TaskInvocation, decide: (Transaction, TaskRecord) throws -> Decision) async -> TaskRecord? {
        do {
            return try await session.commit({ tx in
                guard let current = current(invocation.taskId), current.state.status == "running", !closing else { end(invocation); return nil }
                switch try decide(tx, current) {
                case .proceed: return current
                case .end: end(invocation); return nil
                case .fault(let error):
                    end(invocation)
                    try await terminate(tx, record: current, outcome: .faulted(error: .init(message: String(describing: error))))
                    return nil
                }
            }, context: context)
        } catch { end(invocation); if !closing { report(error) }; return nil }
    }
    private func run(_ reservation: Reservation) async {
        let invocation = reservation.invocation, phase = RuntimePhase(reservation.definition, reservation.snapshot)
        let runtime = TaskRuntime(scheduler: self, invocation: invocation, phase: phase)
        if invocation.abort {
            guard let current = current(invocation.taskId), !closing else { return }
            var failure: (any Error)?
            do { try await reservation.definition.abort(current, runtime, invocation.context) } catch { failure = error }
            _ = await step(invocation) { _, _ in .fault(failure ?? SessionError.message("Abort handler of task \(invocation.taskId.rawValue) returned without a terminal outcome")) }
            return
        }
        var previous: JSONValue?, failure: (any Error)?
        while true {
            let found = await step(invocation) { tx, current in
                if current.abortRequested { return .end }
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
                        try tx.setTask(current.replacing(state: .pending(checkpoint: current.state.checkpoint!))); return .end
                    }
                    let shouldReport = phase.state.withLock { state -> Bool in
                        if let next { if state.reported == next.identity && !state.reportedMissing { return false }; state.reported = next.identity; state.reportedMissing = false }
                        else { if state.reportedMissing { return false }; state.reported = nil; state.reportedMissing = true }
                        return true
                    }
                    if shouldReport { report(TaskHandoverError(taskId: current.id, kind: current.kind, cause: next == nil ? .missingTask : .incompatibleTask)) }
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
internal enum OwnershipStep: Sendable { case task(TaskRecord), conversation(ConversationID), unknown }
internal struct TaskOverlay: Sendable {
    let tasks: [TaskID: TaskRecord]
    let conversations: [ConversationID: ConversationRecord]
    static let empty = TaskOverlay(tasks: [:], conversations: [:])
    init(tasks: [TaskID: TaskRecord], conversations: [ConversationID: ConversationRecord]) { self.tasks = tasks; self.conversations = conversations }
    init(_ tx: Transaction) throws {
        tasks = Dictionary(uniqueKeysWithValues: try tx.stagedTasks().map { ($0.id, $0) })
        conversations = Dictionary(uniqueKeysWithValues: try tx.stagedConversations().map { ($0.id, $0) })
    }
}
internal extension TaskState {
    var checkpoint: JSONValue? { switch self { case .pending(let value, _), .running(let value, _), .waiting(let value, _, _, _): value; default: nil } }
    var outcome: TaskOutcome? { switch self { case .completing(let value, _), .terminal(let value, _): value; default: nil } }
}
internal extension TaskRecord {
    var parent: OwnershipUp { owner.map(OwnershipUp.task) ?? .conversation(conversationId) }
    var failedOutcome: Bool { state.outcome.map { $0.status != "completed" } ?? false }
    func replacing(input: JSONValue? = nil, version: Double? = nil, state: TaskState? = nil,
                   abortRequested: Bool? = nil, memos: JSONObject? = nil) -> TaskRecord {
        let next = state ?? self.state
        return TaskRecord(id: id, conversationId: conversationId, kind: kind, version: version ?? self.version,
                          input: input ?? self.input, state: next, owner: owner, background: background,
                          abortRequested: abortRequested ?? self.abortRequested, startedAt: startedAt, endedAt: endedAt,
                          memos: next.outcome == nil ? (memos ?? self.memos) : nil, extensionFields: extensionFields)
    }
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
