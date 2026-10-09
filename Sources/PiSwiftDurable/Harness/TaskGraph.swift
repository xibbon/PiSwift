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
    /// An outcome is saved while ordinary owned work finishes.
    case completing(outcome: String)

    /// The stored execution or submission state tag.
    public var status: String {
        switch self {
        case .pending: "pending"
        case .running: "running"
        case .waiting: "waiting"
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
        case "completing": self = .completing(outcome: try recordRequired(object, "outcome"))
        default: throw recordUnknown("status", status)
        }
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws { try json.encode(to: encoder) }
    fileprivate var json: JSONValue {
        var object: JSONObject = ["status": .string(status)]
        switch self {
        case .pending(let phase), .running(let phase): object["phase"] = .string(phase)
        case let .waiting(phase, on, policy):
            object["phase"] = .string(phase)
            object["on"] = .array(on.map { .number(Double($0.rawValue)) })
            object["policy"] = .string(policy.rawValue)
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
    /// Conversations owned by the task, in ID order.
    public let conversations: [ConversationID]

    fileprivate init(record: TaskRecord, conversations: [ConversationID]) {
        id = record.id; kind = record.kind; conversationId = record.conversationId
        owner = record.owner; background = record.background; abortRequested = record.abortRequested
        self.conversations = conversations
        func phase(_ checkpoint: JSONValue) -> String { checkpoint.objectValue?["phase"]?.stringValue ?? "" }
        switch record.state {
        case .pending(let checkpoint, _): state = .pending(phase: phase(checkpoint))
        case .running(let checkpoint, _): state = .running(phase: phase(checkpoint))
        case let .waiting(checkpoint, on, policy, _): state = .waiting(phase: phase(checkpoint), on: on, policy: policy)
        case .completing(let outcome, _), .terminal(let outcome, _): state = .completing(outcome: outcome.status)
        }
    }
    private init(node: Self, conversations: [ConversationID]) {
        id = node.id; kind = node.kind; conversationId = node.conversationId; owner = node.owner
        background = node.background; abortRequested = node.abortRequested; state = node.state
        self.conversations = conversations
    }
    fileprivate func owning(_ conversations: [ConversationID]) -> Self { Self(node: self, conversations: conversations) }
    fileprivate var json: JSONValue {
        var object: JSONObject = ["id": .number(Double(id.rawValue)), "kind": .string(kind),
            "conversationId": .number(Double(conversationId.rawValue)), "background": .bool(background),
            "abortRequested": .bool(abortRequested), "state": state.json,
            "conversations": .array(conversations.map { .number(Double($0.rawValue)) })]
        if let owner { object["owner"] = .number(Double(owner.rawValue)) }
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
public typealias TaskGraphWatch = CommittedWatch<TaskGraph>

private final class TaskGraphObserverID: Sendable {}
private enum TaskGraphObserver: Sendable {
    case state(CommittedStateSource<TaskGraph>)
    case watch(TaskGraphWatch)
    func advance(_ value: TaskGraph, _ ops: [Delta.Op], _ context: ChordContext) {
        switch self {
        case .state(let source): source.advance(value: value, ops: ops, context: context)
        case .watch(let watch): watch.advance(value: value, ops: ops, context: context)
        }
    }
    func close() {
        switch self {
        case .state(let source): source.closeSession()
        case .watch(let watch): watch.closeSession()
        }
    }
}
private final class TaskGraphMount: Sendable {
    struct State { var value: TaskGraph; var observers: [ObjectIdentifier: TaskGraphObserver] = [:] }
    let storage: Mutex<State>
    init(_ value: TaskGraph) { storage = Mutex(State(value: value)) }
}

/// Build on the Session line for the first observer. Release with the last observer.
internal final class TaskGraphView: Sendable {
    private struct State { var mount: TaskGraphMount?; var closed = false }
    private let state = Mutex(State())
    private let subscriptions = Mutex<[SessionSubscription]>([])
    private let session: Session
    private let storage: any DurableStorage

    init(session: Session, storage: any DurableStorage) throws {
        self.session = session; self.storage = storage
        let commits = try session.subscribeCommits { [weak self] publication, context in self?.advance(publication, context) }
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
                let attached = try replicatedState(source)
                do { try context.abortSignal?.throwIfAborted() }
                catch { attached.dispose(); throw error }
                return attached
            } catch { source.closeSession(); throw error }
        }
    }
    func watch(context: ChordContext) async throws -> TaskGraphWatch {
        let watch = try await session.readOnLine {
            try await attach(context: context) { value, release in
                let watch = TaskGraphWatch(value: value, replacement: { $0.json }, detach: release)
                return (watch, .watch(watch))
            }
        }
        do {
            try context.abortSignal?.throwIfAborted()
            if let signal = context.abortSignal { try watch.observeCancellation(signal) }
            try context.abortSignal?.throwIfAborted()
            return watch
        } catch { watch.cancel(); throw error }
    }
    private func attach<Observer: Sendable>(context: ChordContext,
        create: (TaskGraph, @escaping @Sendable () -> Void) -> (Observer, TaskGraphObserver)
    ) async throws -> Observer {
        try context.abortSignal?.throwIfAborted()
        let existing = state.withLock { $0.mount }
        let candidate: TaskGraphMount
        if let existing { candidate = existing }
        else { candidate = TaskGraphMount(try await build(context)) }
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
        for observer in observers { observer.close() }
    }
    private func build(_ context: ChordContext) async throws -> TaskGraph {
        var records: [TaskRecord] = []
        for status in [TaskStatus.pending, .running, .waiting, .completing] {
            records += try await scanAll { try await storage.scanTasks(.init(status: status), limit: 256, cursor: $0, context: context) }
        }
        var tasks: [String: TaskGraphNode] = [:]
        for record in records.sorted(by: { $0.id < $1.id }) {
            let owned = try await scanAll { try await storage.scanConversations(.init(ownerTaskId: record.id), limit: 256, cursor: $0, context: context) }
            tasks[String(record.id.rawValue)] = TaskGraphNode(record: record, conversations: owned.map(\.id).sorted())
        }
        return TaskGraph(tasks: tasks)
    }
    private func advance(_ publication: CommitPublication, _ context: ChordContext) {
        guard let mount = state.withLock({ $0.mount }) else { return }
        let frame = mount.storage.withLock { state -> (TaskGraph, [Delta.Op], [TaskGraphObserver])? in
            var tasks = state.value.tasks
            var ops: [Delta.Op] = []
            for change in publication.changes {
                guard case .task(let record) = change else { continue }
                let key = String(record.id.rawValue)
                if record.state.status == "terminal" {
                    if tasks.removeValue(forKey: key) != nil { ops.append(.delete(["tasks", .key(key)])) }
                } else {
                    let next = TaskGraphNode(record: record, conversations: tasks[key]?.conversations ?? [])
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
    /// A disposable read-only Chord state of every live task.
    public func taskGraph(context: ChordContext) async throws -> AttachedReplicatedState<TaskGraph> {
        try await withTaskCancellationContext(context) { context in
            try assertOpen()
            return try await graph.attached(context: context)
        }
    }
    /// Exact committed graph frames. The watch keeps at most 100 pending frames.
    public func watchTaskGraph(context: ChordContext) async throws -> TaskGraphWatch {
        try await withTaskCancellationContext(context) { context in
            try assertOpen()
            return try await graph.watch(context: context)
        }
    }
}
