import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting

private struct HarnessExampleWork: TaskCheckpoint {
    enum Phase: String, Codable, Sendable { case start, joined }
    var phase: Phase = .start
    var children: [TaskID] = []
}
private typealias HarnessExampleJob = TaskDefinition<Int, HarnessExampleWork, Int, NoTaskHooks>

@Suite struct HarnessPublicExampleTests {
    @Test func taskOnlySQLiteExampleCompilesAndRuns() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("public-example.sqlite").path
        let heldChild = SessionTestGate()
        defer { heldChild.release() }
        let child = HarnessExampleJob(name: "app.child", version: 1,
            initial: { _ in HarnessExampleWork() }, phase: { _, runtime, context in
                // scheduler.ts:2168: Keep child work active until its invocation is aborted.
                try await holdInvocation(on: heldChild, runtime: runtime, context: context)
                try await runtime.commit({ _, _ in try completed(1) }, context: context)
            }, abort: { _, runtime, context in
                try await runtime.commit({ _, _ in abortedWith("stop") }, context: context)
            })
        let parent = HarnessExampleJob(name: "app.parent", version: 1,
            initial: { _ in HarnessExampleWork() }, phase: { task, runtime, context in
                switch task.checkpoint.phase {
                case .start:
                    try await runtime.commit({ tx, _ in
                        let a = try await tx.createTask(child, input: task.input,
                            options: .init(ownership: .task(taskId: runtime.taskId)))
                        let b = try await tx.createTask(child, input: task.input,
                            options: .init(ownership: .task(taskId: runtime.taskId)))
                        return .waiting(checkpoint: try JSONValue(encoding:
                            HarnessExampleWork(phase: .joined, children: [a, b])), on: [a, b], policy: .failFast)
                    }, context: context)
                case .joined:
                    _ = try await runtime.outcomes(task.checkpoint.children, context: context)
                    try await runtime.commit({ _, _ in try completed(2) }, context: context)
                }
            }, abort: { _, runtime, context in
                try await runtime.commit({ _, _ in abortedWith("stop") }, context: context)
            })
        let registry = createRegistry()
        try registry.install(Extension(name: "app", tasks:
            [AnyTaskDefinition(parent), AnyTaskDefinition(child)]))
        let clock = TestClock()
        let options = HarnessOptions(models: FakeDurableModels(), registry: registry, clock: clock)
        let context = ChordContext.background
        let harness = try await Harness.open(storage: SqliteStorage.open(path: path),
            options: options, context: context)
        let root = try await harness.root(context: context)
        let id = try await root.commit({ tx in
            try await tx.createTask(parent, input: 1_000_000,
                options: .init(ownership: .conversation()))
        }, context: context)
        try harness.resume()
        try await eventually { try await harness.getTask(id: id, context: context)?.state.status == "waiting" }
        _ = try await harness.abortTask(id: id, context: context)
        try await harness.close(context: context)
        let reopened = try await Harness.open(storage: SqliteStorage.open(path: path),
            options: options, context: context)
        try reopened.resume()
        let receipt = try await reopened.waitForTask(id: id, context: context)
        try await reopened.close(context: context)
        #expect(receipt.outcome.status == "aborted")
    }
}
