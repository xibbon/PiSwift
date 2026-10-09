import PiSwiftChord
import Synchronization

/// Runs each installed hooks value in agent order. A callback selects the typed handler.
public struct HookRunner: Sendable {
    private let runtime: TaskRuntime
    internal init(_ runtime: TaskRuntime) { self.runtime = runtime }
    /// Invokes the matching hooks in selected extension order.
    public func each<Hooks: Sendable>(_ type: Hooks.Type,
                                     context: ChordContext,
                                     invoke: (Hooks) async throws -> Void) async throws {
        try await withTaskCancellationContext(context) { context in
            let agent = try await runtime.agent(context: context)
            for registration in agentHooks(agent, taskName: runtime.taskKind) {
                guard let handlers = registration.handlers(as: type) else { continue }
                do { try await invoke(handlers) }
                catch { if runtime.signal.aborted || context.abortSignal?.aborted == true { throw error }; runtime.scheduler.report(error) }
            }
        }
    }
}

/// One invocation runtime. The same instance serves each phase in that invocation.
public final class TaskRuntime: Sendable {
    internal let scheduler: TaskScheduler
    internal let invocation: TaskInvocation
    internal let phase: RuntimePhase
    internal init(scheduler: TaskScheduler, invocation: TaskInvocation, phase: RuntimePhase) {
        self.scheduler = scheduler; self.invocation = invocation; self.phase = phase
    }
    /// The ID of the task bound to this value or invocation.
    public var taskId: TaskID { invocation.taskId }
    /// The conversation that owns or is addressed by this value.
    public var conversationId: ConversationID { invocation.conversationId }
    /// The cancellation signal bound to this invocation.
    public var signal: AbortSignal { invocation.controller.signal }
    /// The context and cancellation signal bound to this invocation.
    public var context: ChordContext { invocation.context }
    /// The model service used by this harness or task.
    public var models: any DurableModels { scheduler.models }
    /// The current host settings or resolved task settings.
    public var settings: Settings { scheduler.settings() }
    /// The installed extension and task definitions used by this harness.
    public var registry: RegistrySnapshot { phase.state.withLock { $0.snapshot } }
    /// Hook callbacks supplied by the selected extensions.
    public var hooks: HookRunner { HookRunner(self) }
    internal var taskKind: String { phase.state.withLock { $0.definition.name } }
    /// Returns the clock time in milliseconds.
    public func now() throws -> Int64 { try invocation.check(); return scheduler.now() }
    /// Sends a nonfatal handler error to the host report callback.
    public func report(_ error: any Error) throws { try invocation.check(); scheduler.report(error) }
    /// Commits state only while this invocation still owns the task.
    public func commit(_ change: (Transaction, TaskRecord) async throws -> TaskState?,
                       context: ChordContext) async throws {
        try await withTaskCancellationContext(context) { context in
            try await scheduler.gated(invocation, context: context) { tx, current in
                if let next = try await change(tx, current) { try await scheduler.commitState(tx, invocation: invocation, current: current, next: next) }
            }
        }
    }
    /// Reads a durable task memo or installs the candidate only when the memo is absent.
    public func memo(_ name: String, value: JSONValue? = nil, context: ChordContext) async throws -> JSONValue? {
        try await withTaskCancellationContext(context) { context in
            try invocation.check()
            try context.abortSignal?.throwIfAborted()
            guard let value else { return scheduler.current(taskId)?.memos?[name] }
            return try await scheduler.gated(invocation, context: context) { tx, current in
                if let winner = current.memos?[name] { return winner }
                var memos = current.memos ?? [:]; memos[name] = value
                try tx.setTask(current.replacing(memos: memos)); return value
            }
        }
    }
    /// Returns the resolved agent configuration for the conversation.
    public func agent(context: ChordContext) async throws -> Agent {
        try await withTaskCancellationContext(context) { context in
            try invocation.check()
            let work = phase.state.withLock { state -> Task<Agent, any Error> in
                if let work = state.agent { return work }
                let snapshot = state.snapshot
                let work = Task { try await scheduler.resolveAgent(conversationId, snapshot, invocation.context) }
                state.agent = work; return work
            }
            return try await awaitWithContext(work, context)
        }
    }
    /// Returns the execution environment selected for this conversation.
    public func env(context: ChordContext) async throws -> (any ExecutionEnv)? {
        try await withTaskCancellationContext(context) { context in try invocation.check(); try context.abortSignal?.throwIfAborted(); return try await scheduler.env(conversationId, context) }
    }
    /// Waits until the clock deadline or context cancellation.
    public func sleep(until deadline: Int64, context: ChordContext) async throws {
        try await withTaskCancellationContext(context) { context in
            try invocation.check()
            let bound = context.withAbortSignal(signal)
            while true {
                try bound.abortSignal?.throwIfAborted()
                let now = scheduler.now()
                if deadline <= now { return }
                let step = now + min(deadline - now, 2_147_483_647)
                let work = Task { try await scheduler.clock.sleep(until: step) }
                defer { work.cancel() }
                try await awaitWithContext(work, bound)
            }
        }
    }
    /// Returns the current durable task record, or nil when it is absent.
    public func getTask(_ id: TaskID, context: ChordContext) async throws -> TaskRecord? {
        try await withTaskCancellationContext(context) { context in
            try invocation.check()
            return try await scheduler.session.readOnLine { try await scheduler.storage.task(id, context: context) }
        }
    }
    /// Waits for a terminal task outcome and returns its durable receipt.
    public func waitForTask(_ id: TaskID, context: ChordContext) async throws -> SettledTask {
        try await withTaskCancellationContext(context) { context in
            try invocation.check(); scheduler.resume()
            return try await scheduler.waitForTask(id: id, context: context.withAbortSignal(signal))
        }
    }
    /// Returns the terminal outcomes of the supplied tasks in ID-list order.
    public func outcomes(_ ids: [TaskID], context: ChordContext) async throws -> [TaskOutcome] {
        try await withTaskCancellationContext(context) { context in
            try invocation.check()
            return try await scheduler.session.readOnLine {
                var values: [TaskOutcome] = []
                for id in ids {
                    guard let record = try await scheduler.storage.task(id, context: context), case .terminal(let outcome, _) = record.state else { throw SessionError.message("Task \(id.rawValue) is not terminal") }
                    values.append(outcome)
                }
                return values
            }
        }
    }
    /// Returns a conversation by ID, or nil when that ID is absent.
    public func conversation(_ id: ConversationID, context: ChordContext) async throws -> ConversationHandle? {
        try await withTaskCancellationContext(context) { context in
            try invocation.check()
            return try await scheduler.conversation(id, .init(signal: signal, check: { [invocation] in try invocation.check() }), context)
        }
    }
    /// Reads the entry identified by ID, or nil when it is absent.
    public func entry(_ id: EntryID, context: ChordContext) async throws -> EntryRecord? {
        try await withTaskCancellationContext(context) { context in
            try invocation.check()
            return try await scheduler.session.readOnLine { try await scheduler.storage.entry(conversationId, id: id, context: context)?.entry }
        }
    }
    /// Reads the entry identified by ID, or nil when it is absent.
    public func entry<Data>(_ token: EntryKind<Data>, id: EntryID, context: ChordContext) async throws -> TypedEntry<Data>? {
        guard let record = try await entry(id, context: context), record.kind == token.kind else { return nil }
        return try TypedEntry(record)
    }
    /// Reads the visible model context through the optional inclusive entry boundary.
    public func context(_ id: ConversationID, at: EntryID? = nil, context: ChordContext) async throws -> ContextView {
        try await withTaskCancellationContext(context) { context in try await scheduler.readContext(invocation, id: id, at: at, context: context) }
    }
}
