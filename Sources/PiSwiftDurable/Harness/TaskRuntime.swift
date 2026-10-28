import Foundation
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
    /// Commits a sleep and resumes at the checkpoint when the deadline is due.
    /// Return from the phase handler after this call.
    public func sleepUntil(_ until: Double, checkpoint: JSONValue, context: ChordContext) async throws {
        try await commit({ _, _ in .sleeping(checkpoint: checkpoint, until: until) }, context: context)
    }
    /// Arms a timer that is disarmed when this invocation ends.
    public func setTimer(_ callback: @escaping @Sendable () -> Void, delay: Double) -> HarnessDisarm {
        setInvocationTimer(callback) { scheduler.timers.setTimer($0, delay: delay) }
    }
    internal func setTimer(_ callback: @escaping @Sendable () -> Void, until deadline: Double) -> HarnessDisarm {
        setInvocationTimer(callback) { scheduler.timers.setTimer($0, until: deadline) }
    }
    private func setInvocationTimer(_ callback: @escaping @Sendable () -> Void,
                                    arm: (@escaping @Sendable () -> Void) -> HarnessDisarm?) -> HarnessDisarm {
        let id = UUID()
        let active = invocation.state.withLock { state in
            guard !state.ended else { return false }
            state.timers[id] = {}; return true
        }
        guard active else { return {} }
        let disarm = arm({ [invocation] in
            let active = invocation.state.withLock { state in
                let timer = state.timers.removeValue(forKey: id)
                return timer != nil && !state.ended
            }
            if active { callback() }
        }) ?? {}
        let installed = invocation.state.withLock { state in
            guard !state.ended, state.timers[id] != nil else { return false }
            state.timers[id] = disarm; return true
        }
        if !installed { disarm() }
        return { [invocation] in
            let stop = invocation.state.withLock { $0.timers.removeValue(forKey: id) }
            stop?()
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
    /// Returns direct live children from all invocations, in ID order.
    public func ownedTasks(context: ChordContext) async throws -> [TaskRecord] {
        try await withTaskCancellationContext(context) { context in
            try invocation.check()
            return try await scheduler.session.readOnLine {
                try invocation.check(); try context.abortSignal?.throwIfAborted()
                return scheduler.state.withLock { state in
                    (state.directOwned[taskId] ?? []).sorted().compactMap { state.live[$0] }
                }
            }
        }
    }
    /// Marks a direct child for abort and waits for its terminal receipt.
    public func abortOwned(_ id: TaskID, context: ChordContext) async throws {
        try await withTaskCancellationContext(context) { context in
            try invocation.check()
            let bound = context.withAbortSignal(signal)
            let record = try await scheduler.session.readOnLine { try await scheduler.storage.task(id, context: bound) }
            guard let record, record.owner == taskId else {
                throw SessionError.message("Task \(id.rawValue) is not owned by task \(taskId.rawValue)")
            }
            if record.state.status == "terminal" { return }
            _ = try await scheduler.abort(id: id, context: bound, keepRestart: true)
            _ = try await scheduler.waitForTask(id: id, context: bound)
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
