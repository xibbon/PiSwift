import PiSwiftChord

/// Holds table data read before the failed run's first table write.
struct GenerationFailure: Sendable {
    let policy: AfterFailedRun
    let boundary: Boundary?
}

func prepareFailure(tx: Transaction, runtime: TaskRuntime) async throws -> GenerationFailure {
    let settings = runtime.settings
    let boundary = settings.afterFailedRun == .continue
        ? try await prepareBoundary(tx: tx, conversationId: runtime.conversationId, modes: settings) : nil
    return GenerationFailure(policy: settings.afterFailedRun, boundary: boundary)
}

func endFailedRun(tx: Transaction, runtime: TaskRuntime, live: JSONDraft, failure: GenerationFailure,
                  settlement: SubmissionSettlement) async throws {
    try endRun(tx: tx, live: live, taskId: runtime.taskId, settlement: settlement)
    if failure.policy == .withdraw {
        try await withdrawQueuedInputs(tx: tx, conversationId: runtime.conversationId, reason: "run_failed")
    }
    guard let boundary = failure.boundary else { return }
    let applied = try await applyBoundary(tx: tx, boundary: boundary, at: .final, now: runtime.now())
    if !applied.users.isEmpty {
        try await startRun(tx: tx, conversationId: runtime.conversationId, live: live, inputs: applied.users)
    }
}
