import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private struct W3GateOpened: Error {}

/// Each input has one completion signal and one optional abort signal.
final class W3LifetimeControl: Sendable {
    let clock = TestClock()
    let runs = SessionTestLog<Int>()
    let aborts = SessionTestLog<TaskAbortReason?>()
    let abortInputs = SessionTestLog<Int>()
    private let signals = Mutex<[Int: AbortController]>([:])
    private let slowAborts = Mutex<Set<Int>>([])

    private func signal(_ key: Int) -> AbortController {
        signals.withLock { values in
            if let value = values[key] { return value }
            let value = AbortController(); values[key] = value; return value
        }
    }
    func open(_ input: Int) { signal(input).abort(W3GateOpened()) }
    func holdAbort(_ input: Int) { slowAborts.withLock { _ = $0.insert(input) } }
    func openAbort(_ input: Int) { open(-input - 1) }
    func wait(_ key: Int, runtime: TaskRuntime, context: ChordContext) async throws {
        let gate = signal(key)
        if !gate.signal.aborted {
            do { try await runtime.sleep(until: 1_000_000, context: context.withAbortSignal(gate.signal)) }
            catch { if !gate.signal.aborted { throw error } }
        }
        try runtime.signal.throwIfAborted()
    }
    func definition(_ name: String = "test.w3.hold") -> HarnessTestTask {
        harnessOneStep(name, run: { [self] task, runtime, context in
            runs.append(task.input)
            try await wait(task.input, runtime: runtime, context: context)
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(Double(task.input)))) }, context: context)
        }, abort: { [self] task, runtime, context in
            aborts.append(task.record.abortReason)
            abortInputs.append(task.input)
            if slowAborts.withLock({ $0.contains(task.input) }) {
                try await wait(-task.input - 1, runtime: runtime, context: context)
            }
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "test")) }, context: context)
        })
    }
}

func w3Terminal(_ harness: Harness, _ id: TaskID) async throws -> SettledTask {
    try await harnessEventually { try await harness.getTask(id: id, context: .background)?.state.status == "terminal" }
    return try await harness.waitForTask(id: id, context: .background)
}

func w3State(_ harness: Harness, _ id: TaskID, _ status: String) async throws {
    try await harnessEventually { try await harness.getTask(id: id, context: .background)?.state.status == status }
}
