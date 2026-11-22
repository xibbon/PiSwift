import PiSwiftChord
import Synchronization

/// The durable status of a live task, without checkpoint and outcome data.
public enum TaskGraphState: Sendable, Equatable, Codable {
    /// Work is saved and waits for scheduler admission.
    case pending(phase: String)
    /// Work is executing with its saved checkpoint.
    case running(phase: String)
    /// Work waits for the selected tasks under its join policy.
    case waiting(phase: String, on: [TaskID], policy: JoinPolicy)
    /// Work waits for a deadline, signal keys, or both.
    case sleeping(phase: String, until: Double?)
    /// Work waits for signal keys, with an optional deadline.
    case signalSleeping(phase: String, until: Double?, signals: [SignalKey])
    /// An outcome is saved while ordinary owned work finishes.
    case completing(outcome: String)

    /// The stored execution or submission state tag.
    public var status: String {
        switch self {
        case .pending: "pending"
        case .running: "running"
        case .waiting: "waiting"
        case .sleeping, .signalSleeping: "sleeping"
        case .completing: "completing"
        }
    }
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        let status: String = try recordRequired(object, "status")
        switch status {
        case "pending": self = .pending(phase: try recordRequired(object, "phase"))
        case "running": self = .running(phase: try recordRequired(object, "phase"))
        case "waiting": self = .waiting(phase: try recordRequired(object, "phase"),
            on: try recordRequired(object, "on"), policy: try recordRequired(object, "policy"))
        case "sleeping":
            let until: Double? = try recordOptional(object, "until")
            let signals: [SignalKey]? = try recordOptional(object, "signals")
            if let until { try recordValidateDeadline(until) }
            if let signals, signals.isEmpty { throw recordUnknown("sleep signals", "empty list") }
            if until == nil && signals == nil { throw recordUnknown("sleep", "missing until and signals") }
            let phase: String = try recordRequired(object, "phase")
            if let signals { self = .signalSleeping(phase: phase, until: until, signals: signals) }
            else { self = .sleeping(phase: phase, until: until) }
        case "completing": self = .completing(outcome: try recordRequired(object, "outcome"))
        default: throw recordUnknown("status", status)
        }
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .sleeping(_, let until):
            guard let until else { throw recordUnknown("sleep", "missing until and signals") }
            try recordValidateDeadline(until)
        case .signalSleeping(_, let until, let signals):
            if signals.isEmpty { throw recordUnknown("sleep signals", "empty list") }
            if let until { try recordValidateDeadline(until) }
        default: break
        }
        try json.encode(to: encoder)
    }
    fileprivate var json: JSONValue {
        var object: JSONObject = ["status": .string(status)]
        switch self {
        case .pending(let phase), .running(let phase): object["phase"] = .string(phase)
        case let .waiting(phase, on, policy):
            object["phase"] = .string(phase)
            object["on"] = .array(on.map { .number(Double($0.rawValue)) })
            object["policy"] = .string(policy.rawValue)
        case let .sleeping(phase, until):
            object["phase"] = .string(phase)
            if let until { object["until"] = .number(until) }
        case let .signalSleeping(phase, until, signals):
            object["phase"] = .string(phase)
            if let until { object["until"] = .number(until) }
            object["signals"] = (try? JSONValue(encoding: signals)) ?? .array([])
        case .completing(let outcome): object["outcome"] = .string(outcome)
        }
        return .object(object)
    }
}

/// One task, its ownership edges, and its current graph state.
public struct TaskGraphNode: Sendable, Equatable, Codable {
    /// The stable identifier of this record or handle.
    public let id: TaskID
    /// The stable definition name stored with this task.
    public let kind: String
    /// The conversation in which this task executes.
    public let conversationId: ConversationID
    /// The task that owns this node, when present.
    public let owner: TaskID?
    /// Whether the task can outlive ordinary work of its owner.
    public let background: Bool
    /// Whether an abort request has been saved for this task.
    public let abortRequested: Bool
    /// The task status and join or terminal outcome represented by this node.
    public let state: TaskGraphState
    /// The reason this task cannot run with the current definitions and settings.
    public let blocked: TaskBlockedReason?
    /// Conversations owned by the task, in ID order.
    public let conversations: [ConversationID]
    /// Raw signal keys from the sleep state, retained for graph round trips.
    private let rawSignals: JSONValue?
    /// The keys named by a signal sleep.
    public func sleepSignals() throws -> [SignalKey]? {
        guard let rawSignals else { return nil }
        return try rawSignals.decode([SignalKey].self)
    }

    fileprivate init(record: TaskRecord, conversations: [ConversationID], blocked: TaskBlockedReason?) {
        id = record.id; kind = record.kind; conversationId = record.conversationId
        owner = record.owner; background = record.background; abortRequested = record.abortRequested
        self.conversations = conversations
        self.blocked = blocked
        if case .sleeping(_, _, let fields) = record.state { rawSignals = fields["signals"] }
        else { rawSignals = nil }
        func phase(_ checkpoint: JSONValue) -> String { checkpoint.objectValue?["phase"]?.stringValue ?? "" }
        switch record.state {
        case .pending(let checkpoint, _): state = .pending(phase: phase(checkpoint))
        case .running(let checkpoint, _): state = .running(phase: phase(checkpoint))
        case let .waiting(checkpoint, on, policy, _): state = .waiting(phase: phase(checkpoint), on: on, policy: policy)
        case let .sleeping(checkpoint, until, _):
            if let keys = try? record.state.sleepSignals() {
                state = .signalSleeping(phase: phase(checkpoint), until: until, signals: keys)
            } else { state = .sleeping(phase: phase(checkpoint), until: until) }
        case .completing(let outcome, _), .terminal(let outcome, _): state = .completing(outcome: outcome.status)
        }
    }
    private init(node: Self, conversations: [ConversationID], blocked: TaskBlockedReason?) {
        id = node.id; kind = node.kind; conversationId = node.conversationId; owner = node.owner
        background = node.background; abortRequested = node.abortRequested; state = node.state
        self.conversations = conversations
        self.blocked = blocked
        rawSignals = node.rawSignals
    }
    fileprivate func owning(_ conversations: [ConversationID]) -> Self {
        Self(node: self, conversations: conversations, blocked: blocked)
    }
    fileprivate func blocking(_ reason: TaskBlockedReason?) -> Self {
        Self(node: self, conversations: conversations, blocked: reason)
    }
    /// Decodes a graph node from its JSON representation.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        id = try recordRequired(object, "id")
        kind = try recordRequired(object, "kind")
        conversationId = try recordRequired(object, "conversationId")
        owner = try recordOptional(object, "owner")
        background = try recordRequired(object, "background")
        abortRequested = try recordRequired(object, "abortRequested")
        state = try recordRequired(object, "state")
        let stateObject: JSONObject = try recordRequired(object, "state")
        rawSignals = stateObject["signals"]
        conversations = try recordRequired(object, "conversations")
        if let reason: String = try recordOptional(object, "blocked") {
            guard let value = TaskBlockedReason(rawValue: reason) else { throw recordUnknown("blocked", reason) }
            blocked = value
        } else { blocked = nil }
    }
    /// Encodes a graph node with its JSON representation.
    public func encode(to encoder: any Encoder) throws {
        switch state {
        case .sleeping(_, let until):
            guard let until else { throw recordUnknown("sleep", "missing until and signals") }
            try recordValidateDeadline(until)
        case .signalSleeping(_, let until, let signals):
            if signals.isEmpty { throw recordUnknown("sleep signals", "empty list") }
            if let until { try recordValidateDeadline(until) }
        default: break
        }
        try json.encode(to: encoder)
    }
    fileprivate var json: JSONValue {
        var stateObject = state.json.objectValue ?? [:]
        if let rawSignals { stateObject["signals"] = rawSignals }
        var object: JSONObject = ["id": .number(Double(id.rawValue)), "kind": .string(kind),
            "conversationId": .number(Double(conversationId.rawValue)), "background": .bool(background),
            "abortRequested": .bool(abortRequested), "state": .object(stateObject),
            "conversations": .array(conversations.map { .number(Double($0.rawValue)) })]
        if let owner { object["owner"] = .number(Double(owner.rawValue)) }
        if let blocked { object["blocked"] = .string(blocked.rawValue) }
        return .object(object)
    }
}

/// An immutable revision of all live tasks in the Session. Keys are decimal task IDs.
public final class TaskGraph: Sendable, Equatable, Codable {
    /// Graph nodes indexed by the decimal string of their task ID.
    public let tasks: [String: TaskGraphNode]
    /// Creates an ownership graph indexed by task ID.
    public init(tasks: [String: TaskGraphNode] = [:]) { self.tasks = tasks }
    /// Orders values by their numeric record identifier.
    public static func == (lhs: TaskGraph, rhs: TaskGraph) -> Bool { lhs.tasks == rhs.tasks }
    fileprivate var json: JSONValue { .object(["tasks": .object(JSONObject(tasks.map { ($0.key, $0.value.json) }))]) }
}
/// A stream of committed task graphs. Call stop() to release its observer.
public typealias TaskGraphWatch = Watch<TaskGraph>

private final class TaskGraphObserverID: Sendable {}
private enum TaskGraphObserver: Sendable {
    case state(CommittedStateSource<TaskGraph>)
    case watch(TaskGraphWatch)
    case observer(GuardedObserver<WatchCall<TaskGraph>>)
    func advance(_ value: TaskGraph, _ ops: [Delta.Op], _ context: ChordContext) {
        switch self {
        case .state(let source): source.advance(value: value, ops: ops, context: context)
        case .watch(let watch): watch.advance(.value(value: value, ops: ops, retired: false), context: context)
        case .observer(let observer): observer.advance(.value(value: value, ops: ops, retired: false), context: context)
        }
    }
    func close(_ error: (any Error)? = nil) {
        switch self {
        case .state(let source): source.closeSession()
        case .watch(let watch): watch.end(error.map { .failed(.message(String(describing: $0))) } ?? .ended)
        case .observer(let observer): observer.end(.failed(.message(error.map { String(describing: $0) } ?? "session closed")))
        }
    }
}
private final class TaskGraphMount: Sendable {
    struct State {
        var value: TaskGraph
        var records: [String: TaskBlockedSubject]
        var observers: [ObjectIdentifier: TaskGraphObserver] = [:]
    }
    let storage: Mutex<State>
    init(_ value: TaskGraph, records: [String: TaskBlockedSubject]) {
        storage = Mutex(State(value: value, records: records))
    }
}

/// The record fields needed to derive a blocked reason, without task payloads.
internal struct TaskBlockedSubject: Sendable {
    let id: TaskID
    let kind: String
    let version: Double
    let abortRequested: Bool
    let abortReason: TaskAbortReason?
    let restarts: Double
    let status: String
    let input: JSONValue
    let checkpoint: JSONValue?
    let policy: JoinPolicy?
    let signals: JSONValue?
    let wake: JSONValue?

    init(record: TaskRecord) {
        id = record.id; kind = record.kind; version = record.version
        abortRequested = record.abortRequested; abortReason = record.abortReason
        restarts = record.restarts; status = record.state.status
        input = record.input; checkpoint = record.state.checkpoint
        switch record.state {
        case .waiting(_, _, let policyValue, _): policy = policyValue
        default: policy = nil
        }
        switch record.state {
        case .sleeping(_, _, let fields): signals = fields["signals"]
        default: signals = nil
        }
        switch record.state {
        case .pending(_, let fields), .running(_, let fields): wake = fields["wake"]
        default: wake = nil
        }
    }
}

/// Build on the Session line for the first observer. Release with the last observer.
internal final class TaskGraphView: Sendable {
    private struct State { var mount: TaskGraphMount?; var closed = false }
    private let state = Mutex(State())
    private let subscriptions = Mutex<[SessionSubscription]>([])
    private let session: Session
    private let storage: any DurableStorage
    private let blockedReason: @Sendable (TaskBlockedSubject) -> TaskBlockedReason?

    init(session: Session, storage: any DurableStorage,
         blockedReason: @escaping @Sendable (TaskBlockedSubject) -> TaskBlockedReason? = { _ in nil }) throws {
        self.session = session; self.storage = storage
        self.blockedReason = blockedReason
        let commits = try session.observeCommits { [weak self] publication, context in self?.advance(publication, context) }
        subscriptions.withLock { $0.append(commits) }
        do {
            let close = try session.subscribeClose { [weak self] in self?.close() }
            subscriptions.withLock { $0.append(close) }
        } catch { commits.cancel(); throw error }
    }
    deinit { for subscription in subscriptions.withLock({ $0 }) { subscription.cancel() } }

    func attached(context: ChordContext) async throws -> AttachedReplicatedState<TaskGraph> {
        try await session.readOnLine {
            let source = try await attach(context: context) { value, release in
                let source = CommittedStateSource(value: value, release: release)
                return (source, .state(source))
            }
            do {
                let attached = try replicatedState(source, onError: { self.session.report($0) })
                do { try context.abortSignal?.throwIfAborted() }
                catch { attached.dispose(); throw error }
                return attached
            } catch { source.closeSession(); throw error }
        }
    }
    // v1.5.2 CH3: Host observers receive every publication, without watch folding.
    func observe(_ observer: Observer<TaskGraph>, context: ChordContext) async throws -> Observation<TaskGraph> {
        let (value, guarded) = try await session.readOnLine {
            try await attach(context: context) { value, release in
                let guarded = GuardedObserver(advance: observer.advance, end: observer.end,
                    detach: release, report: { self.session.report($0) })
                return ((value, guarded), .observer(guarded))
            }
        }
        do { try context.abortSignal?.throwIfAborted() }
        catch { guarded.detach(); throw error }
        return Observation(value: value, detach: { guarded.detach() })
    }
    func watch(context: ChordContext) async throws -> TaskGraphWatch {
        let watch = try await session.readOnLine {
            try await attach(context: context) { value, release in
                let watch = TaskGraphWatch(value: value, replacement: { $0.json }, detach: release, report: { self.session.report($0) })
                return (watch, .watch(watch))
            }
        }
        do {
            try context.abortSignal?.throwIfAborted()
            if let signal = context.abortSignal { try watch.observeAbort(signal) }
            try context.abortSignal?.throwIfAborted()
            return watch
        } catch { watch.abort(); throw error }
    }
    private func attach<Observer: Sendable>(context: ChordContext,
        create: (TaskGraph, @escaping @Sendable () -> Void) -> (Observer, TaskGraphObserver)
    ) async throws -> Observer {
        try context.abortSignal?.throwIfAborted()
        let existing = state.withLock { $0.mount }
        let candidate: TaskGraphMount
        if let existing { candidate = existing }
        else { candidate = try await build(context) }
        return try state.withLock { state in
            guard !state.closed else { throw closedError() }
            try context.abortSignal?.throwIfAborted()
            let mount = state.mount ?? candidate
            let id = TaskGraphObserverID()
            let release: @Sendable () -> Void = { [weak self] in self?.detach(mount, id) }
            let observer = mount.storage.withLock { state in
                let (observer, entry) = create(state.value, release)
                state.observers[ObjectIdentifier(id)] = entry
                return observer
            }
            state.mount = mount
            return observer
        }
    }
    private func detach(_ mount: TaskGraphMount, _ id: TaskGraphObserverID) {
        state.withLock { state in
            let empty = mount.storage.withLock { mount in
                mount.observers.removeValue(forKey: ObjectIdentifier(id))
                return mount.observers.isEmpty
            }
            if empty, state.mount === mount { state.mount = nil }
        }
    }
    private func close() {
        let mount = state.withLock { state in
            state.closed = true
            let mount = state.mount; state.mount = nil
            return mount
        }
        let observers = mount?.storage.withLock { Array($0.observers.values) } ?? []
        for observer in observers { observer.close(session.failure) }
    }
    private func build(_ context: ChordContext) async throws -> TaskGraphMount {
        var records: [TaskRecord] = []
        for status in [TaskStatus.pending, .running, .waiting, .sleeping, .completing] {
            records += try await scanAll { try await storage.scanTasks(.init(status: status), limit: 256, cursor: $0, context: context) }
        }
        var tasks: [String: TaskGraphNode] = [:]
        var subjects: [String: TaskBlockedSubject] = [:]
        for record in records.sorted(by: { $0.id < $1.id }) {
            let owned = try await scanAll { try await storage.scanConversations(.init(ownerTaskId: record.id), limit: 256, cursor: $0, context: context) }
            let key = String(record.id.rawValue), subject = TaskBlockedSubject(record: record)
            subjects[key] = subject
            tasks[key] = TaskGraphNode(record: record, conversations: owned.map(\.id).sorted(), blocked: blockedReason(subject))
        }
        return TaskGraphMount(TaskGraph(tasks: tasks), records: subjects)
    }
    /// Call on the Session line after definitions or failed migrations change.
    func refreshBlocked(context: ChordContext) {
        guard let mount = state.withLock({ $0.closed ? nil : $0.mount }) else { return }
        let frame = mount.storage.withLock { state -> (TaskGraph, [Delta.Op], [TaskGraphObserver])? in
            var tasks = state.value.tasks
            var ops: [Delta.Op] = []
            for subject in state.records.values.sorted(by: { $0.id < $1.id }) {
                let key = String(subject.id.rawValue)
                guard let node = tasks[key] else { continue }
                let reason = blockedReason(subject)
                guard reason != node.blocked else { continue }
                tasks[key] = node.blocking(reason)
                if let reason { ops.append(.set(["tasks", .key(key), "blocked"], .string(reason.rawValue))) }
                else { ops.append(.delete(["tasks", .key(key), "blocked"])) }
            }
            guard !ops.isEmpty else { return nil }
            let value = TaskGraph(tasks: tasks)
            state.value = value
            return (value, ops, Array(state.observers.values))
        }
        guard let (value, ops, observers) = frame else { return }
        for observer in observers { observer.advance(value, ops, context.withoutAbortSignal()) }
    }
    private func advance(_ publication: ObservedCommit, _ context: ChordContext) {
        guard let mount = state.withLock({ $0.mount }) else { return }
        let frame = mount.storage.withLock { state -> (TaskGraph, [Delta.Op], [TaskGraphObserver])? in
            var tasks = state.value.tasks
            var ops: [Delta.Op] = []
            for change in publication.changes {
                guard case .task(let record) = change else { continue }
                let key = String(record.id.rawValue)
                if record.state.status == "terminal" {
                    state.records.removeValue(forKey: key)
                    if tasks.removeValue(forKey: key) != nil { ops.append(.delete(["tasks", .key(key)])) }
                } else {
                    let subject = TaskBlockedSubject(record: record)
                    state.records[key] = subject
                    let next = TaskGraphNode(record: record, conversations: tasks[key]?.conversations ?? [], blocked: blockedReason(subject))
                    if next != tasks[key] { tasks[key] = next; ops.append(.set(["tasks", .key(key)], next.json)) }
                }
            }
            var created: [String: [ConversationID]] = [:]
            var ownerOrder: [String] = []
            for change in publication.changes {
                guard case .conversation(let conversation) = change, let owner = conversation.owner else { continue }
                let key = String(owner.taskId.rawValue)
                guard tasks[key] != nil else { continue }
                if created[key] == nil { ownerOrder.append(key) }
                created[key, default: []].append(conversation.id)
            }
            for key in ownerOrder {
                guard let node = tasks[key], let ids = created[key] else { continue }
                let conversations = (node.conversations + ids).sorted()
                tasks[key] = node.owning(conversations)
                ops.append(.set(["tasks", .key(key), "conversations"], .array(conversations.map { .number(Double($0.rawValue)) })))
            }
            guard !ops.isEmpty else { return nil }
            let value = TaskGraph(tasks: tasks)
            state.value = value
            return (value, ops, Array(state.observers.values))
        }
        guard let (value, ops, observers) = frame else { return }
        for observer in observers { observer.advance(value, ops, context.withoutAbortSignal()) }
    }
}

extension Harness {
    /// Observe each graph change on the Session line. Detach to release the observer.
    public func observeTaskGraph(_ observer: Observer<TaskGraph>, context: ChordContext) async throws -> Observation<TaskGraph> {
        try await withTaskCancellationContext(context) { context in
            try assertOpen()
            return try await graph.observe(observer, context: context)
        }
    }
    /// A disposable read-only Chord state of every live task.
    public func taskGraph(context: ChordContext) async throws -> AttachedReplicatedState<TaskGraph> {
        try await withTaskCancellationContext(context) { context in
            try assertOpen()
            return try await graph.attached(context: context)
        }
    }
    /// Committed graph changes. Pending changes are folded into one delivery.
    public func watchTaskGraph(context: ChordContext) async throws -> TaskGraphWatch {
        try await withTaskCancellationContext(context) { context in
            try assertOpen()
            return try await graph.watch(context: context)
        }
    }
}
