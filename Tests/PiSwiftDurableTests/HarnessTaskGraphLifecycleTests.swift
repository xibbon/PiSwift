import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessTaskGraphLifecycleTests {
    @Test(arguments: [
        JSONValue.object(["status": "pending", "phase": "work"]),
        JSONValue.object(["status": "running", "phase": "work"]),
        JSONValue.object(["status": "waiting", "phase": "join", "on": [3], "policy": "allSettled"]),
        JSONValue.object(["status": "completing", "outcome": "faulted"])
    ])
    func graphCodableKeepsTheUpstreamShape(_ state: JSONValue) throws {
        let tree: JSONValue = ["tasks": ["2": ["id": 2, "kind": "test.work", "conversationId": 1,
            "background": false, "abortRequested": true, "state": state, "conversations": [4, 5]]]]
        let graph = try tree.decode(TaskGraph.self)
        #expect(try JSONValue(encoding: graph) == tree)
        #expect(graph.tasks["2"]?.owner == nil)
        #expect(graph.tasks["2"]?.conversations == [try ConversationID(4), try ConversationID(5)])
    }

    // H5/H6 harness-lifecycle.test.ts:393 and :450, task graph acquisitions.
    @Test func closeRejectsQueuedAndNewGraphAcquisitions() async throws {
        let storage = ControlledStorage(), harness = try await harnessOpen([], storage: storage)
        let root = try await harness.root(context: .background)
        let state = try await harness.taskGraph(context: .background)
        let watch = try await harness.watchTaskGraph(context: .background)
        let held = await storage.holdCommits()
        let blocking = Task { try await root.commit({ tx in
            _ = try await tx.appendEntry(root.id, value: .init(kind: "blocker"))
        }, context: .background) }
        await held.waitUntilEntered()
        let queuedState = Task { try await harness.taskGraph(context: .background) }
        try await eventually { harness.session.line.queuedCount >= 1 }
        let queuedWatch = Task { try await harness.watchTaskGraph(context: .background) }
        try await eventually { harness.session.line.queuedCount >= 2 }
        let close = Task { try await harness.close(context: .background) }
        try await eventually { harness.tasks.closing }
        await #expect(throws: HarnessClosedError.self) { _ = try await harness.taskGraph(context: .background) }
        await #expect(throws: HarnessClosedError.self) { _ = try await harness.watchTaskGraph(context: .background) }
        if case .sessionClosed = await watch.closed {} else { Issue.record("Close must end the graph watch") }
        await held.release()
        try await blocking.value
        await #expect(throws: (any Error).self) { _ = try await queuedState.value }
        await #expect(throws: (any Error).self) { _ = try await queuedWatch.value }
        try await close.value
        #expect(state.value == TaskGraph())
        state.dispose()
    }

    // H5/H6 harness-lifecycle.test.ts:533, task graph viewers.
    @Test func graphViewersReadCommittedTasksWithoutSchedulingOrWriting() async throws {
        let ran = Mutex(false), storage = ControlledStorage()
        let task = harnessOneStep("test.graph-read-only") { _, runtime, context in
            ran.withLock { $0 = true }
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }
        let harness = try await harnessOpen([AnyTaskDefinition(task)], storage: storage)
        let root = try await harness.root(context: .background), id = try await harnessStart(root, task)
        let writes = await storage.admittedCommits.count
        let state = try await harness.taskGraph(context: .background)
        let watch = try await harness.watchTaskGraph(context: .background)
        #expect(state.value === watch.value)
        #expect(state.value.tasks[String(id.rawValue)]?.state == .pending(phase: "run"))
        #expect(!ran.withLock { $0 })
        #expect(try await harness.inspect(context: .background).scheduling == .paused)
        #expect(await storage.admittedCommits.count == writes)
        state.dispose(); _ = await watch.stop()
        try await harness.close(context: .background)
    }

    @Test func watchOverflowReplacesOnlyPendingSuffixAndKeepsExactFrames() async throws {
        let task = harnessOneStep("test.graph-overflow") { _, _, _ in }
        let harness = try await harnessOpen([AnyTaskDefinition(task)])
        let root = try await harness.root(context: .background)
        let watch = try await harness.watchTaskGraph(context: .background)
        let replica = Mutex<JSONValue?>(try JSONValue(encoding: watch.value))
        let firstEntered = SessionTestGate(), releaseFirst = SessionTestGate()
        let frames = SessionTestLog<[Delta.Op]>()
        try watch.start { value, ops, context in
            let tree = try replica.withLock { tree in
                tree = try Delta.applyImmutable(tree, ops)
                return tree
            }
            #expect(tree == (try JSONValue(encoding: value)))
            #expect(context.abortSignal == nil)
            frames.append(ops)
            if frames.count == 1 { firstEntered.release(); await releaseFirst.wait() }
        }
        _ = try await harnessStart(root, task)
        await firstEntered.wait()
        for _ in 0..<101 { _ = try await harnessStart(root, task) }
        #expect(frames.count == 1)
        #expect(watch.value.tasks.count == 1)
        releaseFirst.release()
        await watch.waitUntilIdle()
        #expect(frames.count == 2)
        if case .replace(let replacement) = frames.values.last?.first {
            #expect(replacement == (try JSONValue(encoding: watch.value)))
        } else { Issue.record("Pending overflow must use a replacement frame") }
        #expect(watch.value.tasks.count == 102)
        _ = await watch.stop()
        try await harness.close(context: .background)
    }

    @Test func contextCancellationEndsOnlyItsWatchAndReleasesTheLastMount() async throws {
        let task = harnessOneStep("test.graph-cancel") { _, _, _ in }
        let harness = try await harnessOpen([AnyTaskDefinition(task)])
        let root = try await harness.root(context: .background)
        let controller = AbortController()
        let watch = try await harness.watchTaskGraph(context: .background.withAbortSignal(controller.signal))
        let initial = watch.value
        controller.abort()
        if case .cancelled = await watch.closed {} else { Issue.record("Context cancellation must end the graph watch") }
        let state = try await harness.taskGraph(context: .background)
        #expect(state.value !== initial && state.value == initial)
        _ = try await harnessStart(root, task)
        #expect(state.value.tasks.count == 1 && watch.value.tasks.isEmpty)
        state.dispose()
        try await harness.close(context: .background)
    }
}
