import PiSwiftChord

/// Rejections from one afterRun hook; valid requests still become child tasks.
public struct RunEndTaskRequestErrors: Error, Sendable, CustomStringConvertible {
    public let errors: [String]
    public var description: String { "\(errors.count) afterRun task requests were rejected" }
    public init(errors: [String]) { self.errors = errors }
}

/// A request checked before the task creation commit.
struct PreparedRunEndTask: Sendable {
    let kind: TaskKind<JSONValue, JSONValue>
    let input: JSONValue
}

/// v1.5.2 generation.ts:906–924. Settle inputs and retain the answered run.
func holdRun(tx: Transaction, live: JSONDraft, runtime: TaskRuntime,
             reason: GenerationRunSummary.Reason, answer: EntryID, last: EntryID) throws -> TaskState? {
    guard let run = try live.get("run")?.decode(LiveRun.self), run.taskId == runtime.taskId,
          let held = try live.child("run") else { return nil }
    for id in run.inputs { try tx.settleSubmission(id, settlement: .done(answer: answer)) }
    try held.set("inputs", .array([]))
    try held.set("afterRun", .object([:]))
    try live.remove("generation"); try live.remove("tools"); try live.remove("nestedTools")
    let summary = GenerationRunSummary(reason: reason, first: run.first ?? answer, answer: answer, last: last)
    return try generationTask.running(GenerationCheckpoint(phase: .finish, run: summary))
}

/// v1.5.2 generation.ts:929–960. Check requests off the Session line.
func prepareRunEndTasks(_ requests: [RunEndTask], runtime: TaskRuntime,
                        prepared: inout [PreparedRunEndTask]) throws {
    var rejected: [any Error] = []
    for request in requests {
        do {
            let name = request.task.name
            if name.hasPrefix("pi.") { throw TaskDefinitionError("An afterRun hook cannot start the built-in task \(name)") }
            guard let installed = runtime.registry.task(name: name) else {
                throw TaskDefinitionError("Task \(name) is not installed")
            }
            let checkpoint = try installed.initial(request.input)
            guard case .object(let object) = checkpoint, case .string = object["phase"] else {
                throw TaskDefinitionError("Task \(name) starts at an unknown phase")
            }
            let kind = TaskKind<JSONValue, JSONValue>(name: name, version: installed.version,
                                                      initial: { _ in checkpoint })
            prepared.append(PreparedRunEndTask(kind: kind, input: request.input))
        } catch { rejected.append(error) }
    }
    if rejected.count == 1 { throw rejected[0] }
    if rejected.count > 1 { throw RunEndTaskRequestErrors(errors: rejected.map { String(describing: $0) }) }
}

/// v1.5.2 generation.ts:365–390. A restart in finish asks again; drain only waits.
func finishAnsweredRun(runtime: TaskRuntime, run: GenerationRunSummary, context: ChordContext) async throws {
    var prepared: [PreparedRunEndTask] = []
    try await runtime.hooks.each(GenerationHooks.self, context: context) { hooks in
        guard let afterRun = hooks.afterRun, let asked = try await afterRun(run, runtime.hookApi, context) else { return }
        try prepareRunEndTasks(asked.tasks, runtime: runtime, prepared: &prepared)
    }
    guard !prepared.isEmpty else { return try await endAnsweredRun(runtime: runtime, answer: run.answer, context: context) }
    try await runtime.commit({ tx, _ in
        var ids: [TaskID] = []
        for request in prepared {
            ids.append(try await tx.createTask(request.kind, input: request.input,
                options: .init(ownership: .task(taskId: runtime.taskId))))
        }
        let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
        if let liveRun = try live.child("run"), try liveRun.get("taskId")?.decode(TaskID.self) == runtime.taskId,
           let afterRun = try liveRun.child("afterRun") {
            try afterRun.set("tasks", JSONValue(encoding: ids))
        }
        return try generationTask.waiting(GenerationCheckpoint(phase: .drain, answer: run.answer, tasks: ids),
                                          on: ids, policy: .allSettled)
    }, context: context)
}
