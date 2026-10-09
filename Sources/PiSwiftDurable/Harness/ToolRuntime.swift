import PiSwiftChord

extension ToolExecutionApi {
    internal func taskRuntime() throws -> TaskRuntime {
        guard let runtime else { throw TaskDefinitionError("Tool execution API has no task runtime") }
        return runtime
    }
    public func commit<T>(_ change: (Transaction) async throws -> T, context: PiSwiftChord.Context) async throws -> T {
        try await withTaskCancellationContext(context) { context in
            let runtime = try taskRuntime()
            return try await runtime.scheduler.gated(runtime.invocation, context: context) { tx, _ in try await change(tx) }
        }
    }
    public func createTask<Input, Checkpoint>(_ task: TaskKind<Input, Checkpoint>, input: Input,
                                             options: TaskOptions, context: PiSwiftChord.Context) async throws -> TaskID {
        try await commit({ tx in try await tx.createTask(task, input: input, options: options) }, context: context)
    }
    public func getTask(id: TaskID, context: PiSwiftChord.Context) async throws -> TaskRecord? {
        try await taskRuntime().getTask(id, context: context)
    }
    public func waitForTask(id: TaskID, context: PiSwiftChord.Context) async throws -> SettledTask {
        try await taskRuntime().waitForTask(id, context: context)
    }
    public func conversation(id: ConversationID, context: PiSwiftChord.Context) async throws -> ConversationHandle? {
        try await taskRuntime().conversation(id, context: context)
    }
    public func context(at: EntryID? = nil, context: PiSwiftChord.Context) async throws -> ContextView {
        try await taskRuntime().context(conversationId, at: at, context: context)
    }
}
