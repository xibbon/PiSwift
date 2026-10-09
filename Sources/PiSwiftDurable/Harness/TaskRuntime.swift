import PiSwiftChord
import Synchronization

/// Runs each installed hooks value in agent order. A callback selects the typed handler.
public struct HookRunner: Sendable {
    private let runtime: TaskRuntime
    internal init(_ runtime: TaskRuntime) { self.runtime = runtime }
    public func each<Hooks: Sendable>(_ type: Hooks.Type,
                                     context: PiSwiftChord.Context,
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
    public var taskId: TaskID { invocation.taskId }
    public var conversationId: ConversationID { invocation.conversationId }
    public var signal: AbortSignal { invocation.controller.signal }
    public var context: PiSwiftChord.Context { invocation.context }
    public var models: any DurableModels { scheduler.models }
    public var settings: Settings { scheduler.settings() }
    public var registry: RegistrySnapshot { phase.state.withLock { $0.snapshot } }
    public var hooks: HookRunner { HookRunner(self) }
    internal var taskKind: String { phase.state.withLock { $0.definition.name } }
    public func now() throws -> Int64 { try invocation.check(); return scheduler.now() }
    public func report(_ error: any Error) throws { try invocation.check(); scheduler.report(error) }
    public func commit(_ change: (Transaction, TaskRecord) async throws -> TaskState?,
                       context: PiSwiftChord.Context) async throws {
        try await withTaskCancellationContext(context) { context in
            try await scheduler.gated(invocation, context: context) { tx, current in
                if let next = try await change(tx, current) { try await scheduler.commitState(tx, invocation: invocation, current: current, next: next) }
            }
        }
    }
    public func memo(_ name: String, value: JSONValue? = nil, context: PiSwiftChord.Context) async throws -> JSONValue? {
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
    public func agent(context: PiSwiftChord.Context) async throws -> Agent {
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
    public func env(context: PiSwiftChord.Context) async throws -> (any ExecutionEnv)? {
        try await withTaskCancellationContext(context) { context in try invocation.check(); try context.abortSignal?.throwIfAborted(); return try await scheduler.env(conversationId, context) }
    }
    public func sleep(until deadline: Int64, context: PiSwiftChord.Context) async throws {
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
    public func getTask(_ id: TaskID, context: PiSwiftChord.Context) async throws -> TaskRecord? {
        try await withTaskCancellationContext(context) { context in
            try invocation.check()
            return try await scheduler.session.readOnLine { try await scheduler.storage.task(id, context: context) }
        }
    }
    public func waitForTask(_ id: TaskID, context: PiSwiftChord.Context) async throws -> SettledTask {
        try await withTaskCancellationContext(context) { context in
            try invocation.check(); scheduler.resume()
            return try await scheduler.waitForTask(id: id, context: context.withAbortSignal(signal))
        }
    }
    public func outcomes(_ ids: [TaskID], context: PiSwiftChord.Context) async throws -> [TaskOutcome] {
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
    public func conversation(_ id: ConversationID, context: PiSwiftChord.Context) async throws -> ConversationHandle? {
        try await withTaskCancellationContext(context) { context in
            try invocation.check()
            return try await scheduler.conversation(id, .init(signal: signal, check: { [invocation] in try invocation.check() }), context)
        }
    }
    public func entry(_ id: EntryID, context: PiSwiftChord.Context) async throws -> EntryRecord? {
        try await withTaskCancellationContext(context) { context in
            try invocation.check()
            return try await scheduler.session.readOnLine { try await scheduler.storage.entry(conversationId, id: id, context: context)?.entry }
        }
    }
    public func entry<Data>(_ token: EntryKind<Data>, id: EntryID, context: PiSwiftChord.Context) async throws -> TypedEntry<Data>? {
        guard let record = try await entry(id, context: context), record.kind == token.kind else { return nil }
        return try TypedEntry(record)
    }
    public func context(_ id: ConversationID, at: EntryID? = nil, context: PiSwiftChord.Context) async throws -> ContextView {
        try await withTaskCancellationContext(context) { context in try await scheduler.readContext(invocation, id: id, at: at, context: context) }
    }
}
