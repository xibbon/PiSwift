import PiSwiftChord

extension ToolExecutionApi {
    internal func taskRuntime() throws -> TaskRuntime {
        guard let runtime else { throw TaskDefinitionError("Tool execution API has no task runtime") }
        try runtime.invocation.check()
        return runtime
    }
    public func commit<T>(_ change: (Transaction) async throws -> T, context: ChordContext) async throws -> T {
        try await withTaskCancellationContext(context) { context in
            let runtime = try taskRuntime()
            return try await runtime.scheduler.gated(runtime.invocation, context: context) { tx, _ in
                return try await change(tx)
            }
        }
    }
    public func createTask<Input, Checkpoint>(_ task: TaskKind<Input, Checkpoint>, input: Input,
                                             options: TaskOptions, context: ChordContext) async throws -> TaskID {
        try await commit({ tx in try await tx.createTask(task, input: input, options: options) }, context: context)
    }
    public func createTask<Input, Checkpoint, Result, Hooks>(
        _ task: TaskDefinition<Input, Checkpoint, Result, Hooks>, input: Input,
        options: TaskOptions, context: ChordContext
    ) async throws -> TaskID {
        try await commit({ tx in try await tx.createTask(task, input: input, options: options) }, context: context)
    }
    public func getTask(id: TaskID, context: ChordContext) async throws -> TaskRecord? {
        try await taskRuntime().getTask(id, context: context)
    }
    public func waitForTask(id: TaskID, context: ChordContext) async throws -> SettledTask {
        try await taskRuntime().waitForTask(id, context: context)
    }
    public func conversation(id: ConversationID, context: ChordContext) async throws -> ConversationHandle? {
        try await taskRuntime().conversation(id, context: context)
    }
    public func context(at: EntryID? = nil, context: ChordContext) async throws -> ContextView {
        try await taskRuntime().context(conversationId, at: at, context: context)
    }
}
