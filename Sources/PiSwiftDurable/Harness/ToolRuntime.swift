import PiSwiftChord

extension ToolExecutionApi {
    internal func taskRuntime() throws -> TaskRuntime {
        guard let runtime else { throw TaskDefinitionError("Tool execution API has no task runtime") }
        try runtime.invocation.check()
        return runtime
    }
    /// Commits the supplied changes atomically and publishes them after storage succeeds.
    public func commit<T>(_ change: (Transaction) async throws -> T, context: ChordContext) async throws -> T {
        try await withTaskCancellationContext(context) { context in
            let runtime = try taskRuntime()
            return try await runtime.scheduler.gated(runtime.invocation, context: context) { tx, _ in
                return try await change(tx)
            }
        }
    }
    /// Creates a typed task and stores its encoded input and initial checkpoint.
    public func createTask<Input, Checkpoint>(_ task: TaskKind<Input, Checkpoint>, input: Input,
                                             options: TaskOptions, context: ChordContext) async throws -> TaskID {
        let selected = childOptions(options)
        return try await commit({ tx in try await tx.createTask(task, input: input, options: selected) }, context: context)
    }
    /// Creates a typed task and stores its encoded input and initial checkpoint.
    public func createTask<Input, Checkpoint, Result, Hooks>(
        _ task: TaskDefinition<Input, Checkpoint, Result, Hooks>, input: Input,
        options: TaskOptions, context: ChordContext
    ) async throws -> TaskID {
        let selected = childOptions(options)
        return try await commit({ tx in try await tx.createTask(task, input: input, options: selected) }, context: context)
    }
    private func childOptions(_ options: TaskOptions) -> TaskOptions {
        guard abandonCreatedTasks, !options.hasRestartPolicy, case .task = options.ownership else { return options }
        return TaskOptions(ownership: options.ownership, conversationId: options.conversationId,
                           background: options.background, abandonOnRestart: true)
    }
    /// Calls a tool by key and waits for its program result. Cancelling this wait leaves the child running.
    public func executeTool(_ name: String, arguments: JSONObject, context: ChordContext,
                            options: NestedToolOptions = .init()) async throws -> NestedToolExecutionResult {
        guard let nestedCalls else { throw TaskDefinitionError("Tool execution API has no nested call service") }
        return try await withTaskCancellationContext(context) { context in
            try await nestedCalls.execute(name, arguments: arguments, context: context, options: options)
        }
    }
    /// Returns the current durable task record, or nil when it is absent.
    public func getTask(id: TaskID, context: ChordContext) async throws -> TaskRecord? {
        try await taskRuntime().getTask(id, context: context)
    }
    /// Waits for a terminal task outcome and returns its durable receipt.
    public func waitForTask(id: TaskID, context: ChordContext) async throws -> SettledTask {
        try await taskRuntime().waitForTask(id, context: context)
    }
    /// Returns direct live children from all invocations, in ID order.
    public func ownedTasks(context: ChordContext) async throws -> [TaskRecord] {
        try await taskRuntime().ownedTasks(context: context)
    }
    /// Marks a direct child for abort and waits for its terminal receipt.
    public func abortOwned(id: TaskID, context: ChordContext) async throws {
        try await taskRuntime().abortOwned(id, context: context)
    }
    /// Returns a conversation by ID, or nil when that ID is absent.
    public func conversation(id: ConversationID, context: ChordContext) async throws -> ConversationHandle? {
        try await taskRuntime().conversation(id, context: context)
    }
    /// Reads the visible model context through the optional inclusive entry boundary.
    public func context(at: EntryID? = nil, context: ChordContext) async throws -> ContextView {
        try await taskRuntime().context(conversationId, at: at, context: context)
    }
}
