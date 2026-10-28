import PiSwiftChord
@testable import PiSwiftDurable

/// Holds test work in its invocation. It does not commit a durable sleep.
func holdInvocationUntil(_ deadline: Int64, runtime: TaskRuntime, context: ChordContext) async throws {
    // scheduler.ts:2168 removes TaskRuntime.sleep; invocation timers pace fixture work.
    try await withTaskCancellationContext(context.withAbortSignal(runtime.signal)) { context in
        try context.abortSignal?.throwIfAborted()
        while try runtime.now() < deadline {
            let work = Task { try await InvocationClock(runtime: runtime).sleep(until: deadline) }
            defer { work.cancel() }
            try await awaitWithContext(work, context)
        }
    }
}

/// Matches upstream's gate/abort race for a held phase.
func holdInvocation(on gate: SessionTestGate, runtime: TaskRuntime, context: ChordContext) async throws {
    let work = Task { await gate.wait() }
    try await withTaskCancellationContext(context.withAbortSignal(runtime.signal)) { context in
        try await awaitWithContext(work, context)
    }
}
