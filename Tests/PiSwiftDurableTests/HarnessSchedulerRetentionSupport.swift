import Synchronization
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

struct RetentionInput: Codable, Sendable {
    var name: String
    var into: ConversationID?
}
struct RetentionCheckpoint: TaskCheckpoint {
    enum Phase: String, Codable, Sendable { case hold }
    var phase: Phase = .hold
}
typealias RetentionTask = TaskDefinition<RetentionInput, RetentionCheckpoint, JSONValue, NoTaskHooks>
private struct RetentionGateOpened: Error {}

/// Each test has separate gates, run counts, and commit errors.
final class RetentionControl: Sendable {
    private let gates = Mutex<[String: AbortController]>([:])
    let runs = SessionTestLog<String>()
    let rejections = SessionTestLog<String>()
    func gate(_ name: String) -> AbortController {
        gates.withLock { values in
            if let value = values[name] { return value }
            let value = AbortController(); values[name] = value; return value
        }
    }
    func open(_ name: String) { gate(name).abort(RetentionGateOpened()) }
    func clearGates() { gates.withLock { $0.removeAll() } }
    func wait(_ name: String, runtime: TaskRuntime) async throws -> Bool {
        let signal = gate(name).signal
        let result = HarnessPromise<Bool>()
        let opened = signal.addAbortListener { _ in result.finish(.success(true)) }
        let aborted = runtime.signal.addAbortListener { _ in result.finish(.success(false)) }
        defer {
            signal.removeAbortListener(opened)
            runtime.signal.removeAbortListener(aborted)
        }
        if runtime.signal.aborted { result.finish(.success(false)) }
        else if signal.aborted { result.finish(.success(true)) }
        return try await result.value()
    }
    var hold: RetentionTask {
        RetentionTask(name: "test.retention.hold", version: 1, initial: { _ in RetentionCheckpoint() }, phase: { [self] task, runtime, context in
            runs.append(task.input.name)
            guard try await wait(task.input.name, runtime: runtime) else { return }
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }, abort: Self.abort)
    }
    var spawner: RetentionTask {
        RetentionTask(name: "test.retention.spawner", version: 1, initial: { _ in RetentionCheckpoint() }, phase: { [self] task, runtime, context in
            guard try await wait(task.input.name, runtime: runtime) else { return }
            try await runtime.commit({ tx, current in
                let input = try current.input.decode(RetentionInput.self)
                let into = try #require(input.into)
                _ = try await tx.createTask(hold, input: .init(name: "inside.\(input.name)"), options: .init(ownership: .conversation(), conversationId: into))
                return .terminal(outcome: .completed(result: .null))
            }, context: context)
        }, abort: Self.abort)
    }
    var rejected: RetentionTask {
        RetentionTask(name: "test.retention.rejected", version: 1, initial: { _ in RetentionCheckpoint() }, phase: { [self] _, runtime, context in
            guard try await wait("rejected", runtime: runtime) else { return }
            do {
                try await runtime.commit({ tx, current in
                    let into = try #require(try current.input.decode(RetentionInput.self).into)
                    _ = try await tx.createTask(hold, input: .init(name: "staged"), options: .init(ownership: .conversation(), conversationId: into))
                    _ = try await tx.createTask(hold, input: .init(name: "child"), options: .init(ownership: .task(taskId: current.id)))
                    return .terminal(outcome: .completed(result: .null))
                }, context: context)
            } catch { rejections.append(String(describing: error)) }
            _ = try await wait("rejected.finish", runtime: runtime)
        }, abort: Self.abort)
    }
    private static let abort: RetentionTask.Handler = { _, runtime, context in
        try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
    }
    func opened(storage: any DurableStorage) async throws -> (harness: Harness, root: Conversation) {
        let harness = try await harnessOpen([AnyTaskDefinition(hold), AnyTaskDefinition(spawner), AnyTaskDefinition(rejected)], storage: storage)
        let root = try await harness.root(context: .background)
        try harness.resume()
        return (harness, root)
    }
    func cycle(harness: Harness, root: Conversation, parent: TaskID, number: Int) async throws -> ConversationID {
        let tree = try await root.commit({ tx in
            let tool = try await tx.createTask(hold, input: .init(name: "tool\(number)"), options: .init(ownership: .task(taskId: parent)))
            let child = try await tx.createConversation(ownership: .task(taskId: tool))
            let inner = try await tx.createTask(hold, input: .init(name: "inner\(number)"), options: .init(ownership: .conversation(), conversationId: child.id))
            return (tool, inner, child.id)
        }, context: .background)
        open("inner\(number)"); open("tool\(number)")
        _ = try await harness.waitForTask(id: tree.1, context: .background)
        _ = try await harness.waitForTask(id: tree.0, context: .background)
        return tree.2
    }
}

func retentionStart(_ root: Conversation, _ definition: RetentionTask, name: String) async throws -> TaskID {
    try await root.commit({ tx in
        try await tx.createTask(definition, input: .init(name: name), options: .init(ownership: .conversation()))
    }, context: .background)
}
func retentionBusy(_ conversation: Conversation, task: TaskID) async throws {
    try await conversation.commit({ tx in
        let live = try await tx.doc(LiveDoc, conversationId: conversation.id)
        try live.set("run", JSONValue(encoding: LiveRun(taskId: task, inputs: [])))
    }, context: .background)
}
func retentionSizes(_ harness: Harness) -> [String: Int] { harness.tasks.indexSizes }
