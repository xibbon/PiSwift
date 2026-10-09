import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private struct GraphCheckpoint: TaskCheckpoint {
    enum Phase: String, Codable, Sendable { case spawn, join, finish, work }
    let phase: Phase
    var child: TaskID?
}
private typealias GraphTask = TaskDefinition<Int, GraphCheckpoint, Int, NoTaskHooks>

private func graphFamily(_ clock: TestClock) -> (parent: GraphTask, child: GraphTask) {
    let child = GraphTask(name: "test.graph-child", version: 1, initial: { _ in GraphCheckpoint(phase: .work) },
        phase: { task, runtime, context in
            try await runtime.sleep(until: task.input == 0 ? 100 : 200, context: context)
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }, abort: { _, runtime, context in
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "test")) }, context: context)
        })
    let parent = GraphTask(name: "test.graph-parent", version: 1, initial: { _ in GraphCheckpoint(phase: .spawn) },
        phase: { task, runtime, context in
            switch task.checkpoint.phase {
            case .spawn:
                try await runtime.commit({ tx, _ in
                    _ = try await tx.createConversation(ownership: .task(taskId: task.id))
                    _ = try await tx.createConversation(ownership: .task(taskId: task.id))
                    return nil
                }, context: context)
                try await runtime.commit({ tx, _ in
                    let id = try await tx.createTask(child, input: 0, options: .init(ownership: .task(taskId: task.id)))
                    return .waiting(checkpoint: try JSONValue(encoding: GraphCheckpoint(phase: .join, child: id)),
                        on: [id], policy: .allSettled)
                }, context: context)
            case .join:
                try await runtime.commit({ tx, _ in
                    _ = try await tx.createTask(child, input: 1, options: .init(ownership: .task(taskId: task.id)))
                    return .running(checkpoint: try JSONValue(encoding: GraphCheckpoint(phase: .finish)))
                }, context: context)
            case .finish:
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
            case .work: Issue.record("Parent entered a child phase")
            }
        }, abort: { _, runtime, context in
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "test")) }, context: context)
        })
    return (parent, child)
}
private func graphObserve(_ harness: Harness, _ seen: SessionTestLog<TaskGraph>) async throws -> AttachedReplicatedState<TaskGraph> {
    let graph = try await harness.taskGraph(context: .background)
    graph.subscribe { value, _, delivery in if case .update = delivery { seen.append(value) } }
    return graph
}
private func graphRebuild(_ harness: Harness, _ graph: AttachedReplicatedState<TaskGraph>,
    _ seen: SessionTestLog<TaskGraph>) async throws -> AttachedReplicatedState<TaskGraph> {
    let advanced = graph.value
    await graph.waitUntilIdle()
    graph.dispose()
    let rebuilt = try await graphObserve(harness, seen)
    #expect(rebuilt.value !== advanced)
    #expect(rebuilt.value == advanced)
    return rebuilt
}

@Suite struct HarnessTaskGraphTests {
    // upstream harness-task-graph.test.ts:84.
    @Test func followsLiveStatusesOwnerEdgesAndOwnedConversations() async throws {
        let clock = TestClock(now: 0), family = graphFamily(clock)
        let harness = try await harnessOpen([AnyTaskDefinition(family.parent), AnyTaskDefinition(family.child)], clock: clock)
        let root = try await harness.root(context: .background)
        let seen = SessionTestLog<TaskGraph>()
        var graph = try await graphObserve(harness, seen)
        #expect(graph.value == TaskGraph())
        let parent = try await root.commit({ tx in
            try await tx.createTask(family.parent, input: 0, options: .init(ownership: .conversation()))
        }, context: .background)
        let parentKey = String(parent.rawValue)
        let pending = try #require(graph.value.tasks[parentKey])
        #expect(pending.id == parent && pending.kind == "test.graph-parent" && pending.conversationId == root.id)
        #expect(pending.owner == nil && !pending.background && !pending.abortRequested)
        #expect(pending.state == .pending(phase: "spawn") && pending.conversations.isEmpty)
        try harness.resume()
        let firstGraph = graph
        try await eventually { firstGraph.value.tasks.count == 2 &&
            firstGraph.value.tasks.values.contains { $0.kind == "test.graph-child" && $0.state.status == "running" } }
        let first = try #require(graph.value.tasks.values.first { $0.kind == "test.graph-child" })
        let parentNode = try #require(graph.value.tasks[parentKey])
        #expect(parentNode.state == .waiting(phase: "join", on: [first.id], policy: .allSettled))
        #expect(parentNode.conversations.count == 2 && parentNode.conversations == parentNode.conversations.sorted())
        #expect(first.owner == parent && first.conversationId == root.id)
        #expect(try await harness.conversation(id: #require(parentNode.conversations.first), context: .background) != nil)
        graph = try await graphRebuild(harness, graph, seen)
        clock.advance(by: 100)
        let secondGraph = graph
        try await eventually { secondGraph.value.tasks[parentKey]?.state.status == "completing" &&
            secondGraph.value.tasks.values.contains { $0.kind == "test.graph-child" && $0.state.status == "running" } }
        #expect(graph.value.tasks[parentKey]?.state == .completing(outcome: "completed"))
        #expect(graph.value.tasks[String(first.id.rawValue)] == nil)
        #expect(graph.value.tasks[parentKey]?.conversations == parentNode.conversations)
        graph = try await graphRebuild(harness, graph, seen)
        clock.advance(by: 100)
        _ = try await harness.waitForTask(id: parent, context: .background)
        await graph.waitUntilIdle()
        #expect(graph.value == TaskGraph())
        let revisions = seen.values
        for (previous, next) in zip(revisions, revisions.dropFirst()) { #expect(previous != next) }
        #expect(revisions.contains { $0.tasks[parentKey]?.conversations.count == 2 })
        graph.dispose()
        try await harness.close(context: .background)
    }

    // upstream harness-task-graph.test.ts:168. TestClock supplies abortable work gates.
    @Test func buildsCommittedTasksAfterReopenAndPublishesExactAbortFrames() async throws {
        let directory = try sqliteTestDirectory(), path = directory.appendingPathComponent("graph.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(now: 0)
        let work = harnessOneStep("test.graph-work") { _, runtime, context in
            try await runtime.sleep(until: 100, context: context)
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }
        var harness = try await harnessOpen([AnyTaskDefinition(work)], storage: SqliteStorage.open(path: path.path), clock: clock)
        let root = try await harness.root(context: .background)
        let ids = try await root.commit({ tx in
            let foreground = try await tx.createTask(work, input: 0, options: .init(ownership: .conversation()))
            let background = try await tx.createTask(work, input: 0, options: .init(ownership: .conversation(), background: true))
            let owned = try await tx.createConversation(ownership: .task(taskId: foreground)).id
            return (foreground, background, owned)
        }, context: .background)
        try harness.resume()
        let original = harness
        try await eventually { try await original.inspect(context: .background).tasks.allSatisfy { $0.record.state.status == "running" } }
        let running = try await harness.taskGraph(context: .background)
        #expect(running.value.tasks.values.allSatisfy { $0.state.status == "running" })
        try await harness.close(context: .background)
        harness = try await harnessOpen([AnyTaskDefinition(work)], storage: SqliteStorage.open(path: path.path), clock: clock)
        let watch = try await harness.watchTaskGraph(context: .background)
        #expect(watch.value.tasks.values.allSatisfy { $0.state.status == "pending" })
        let foreground = String(ids.0.rawValue), background = String(ids.1.rawValue)
        #expect(watch.value.tasks[foreground]?.conversations == [ids.2])
        #expect(watch.value.tasks[background]?.background == true)
        let replica = Mutex<JSONValue?>(try JSONValue(encoding: watch.value))
        let frames = SessionTestLog<[Delta.Op]>()
        try watch.start { value, ops, context in
            let next = try replica.withLock { tree in
                tree = try Delta.applyImmutable(tree, ops)
                return tree
            }
            #expect(next == (try JSONValue(encoding: value)))
            #expect(context.abortSignal == nil)
            frames.append(ops)
        }
        try harness.resume()
        try await eventually { watch.value.tasks[background]?.state.status == "running" }
        #expect(try await harness.abortTask(id: ids.1, context: .background) == .marked)
        _ = try await harness.waitForTask(id: ids.1, context: .background)
        await watch.waitUntilIdle()
        #expect(frames.values.contains { ops in
            guard ops.count == 1, case let .set(path, value) = ops[0] else { return false }
            return path == ["tasks", .key(background)] && value.objectValue?["abortRequested"] == .bool(true)
        })
        #expect(frames.values.last == [.delete(["tasks", .key(background)])])
        #expect(replica.withLock { $0?.objectValue?["tasks"]?.objectValue?.keys } == [foreground])
        _ = await watch.stop()
        clock.advance(by: 100)
        _ = try await harness.waitForTask(id: ids.0, context: .background)
        try await harness.close(context: .background)
    }

    // upstream harness-task-graph.test.ts:240.
    @Test func sortsOwnedConversationsFromOneCommitAndRebuildsTheSameGraph() async throws {
        let clock = TestClock(now: 0), created = SessionTestLog<ConversationID>(), entry = Mutex<EntryID?>(nil)
        let spawner = harnessOneStep("test.graph-spawner") { task, runtime, context in
            try await runtime.commit({ tx, _ in
                let at = try #require(entry.withLock { $0 })
                async let forked = tx.forkConversation(runtime.conversationId, at: at, ownership: .task(taskId: task.id))
                async let fresh = tx.createConversation(ownership: .task(taskId: task.id))
                let records = try await [forked, fresh]
                for record in records { created.append(record.id) }
                return nil
            }, context: context)
            try await runtime.sleep(until: 100, context: context)
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }
        let harness = try await harnessOpen([AnyTaskDefinition(spawner)], clock: clock)
        let root = try await harness.root(context: .background)
        let graph = try await harness.taskGraph(context: .background)
        let id = try await root.commit({ tx in
            let at = try await tx.appendEntry(root.id, value: .init(kind: "note")).id
            entry.withLock { $0 = at }
            return try await tx.createTask(spawner, input: 0, options: .init(ownership: .conversation()))
        }, context: .background)
        try harness.resume()
        let key = String(id.rawValue)
        try await eventually { graph.value.tasks[key]?.conversations.count == 2 }
        let advanced = graph.value
        #expect(advanced.tasks[key]?.conversations == created.values.sorted())
        graph.dispose()
        let rebuilt = try await harness.taskGraph(context: .background)
        #expect(rebuilt.value == advanced && rebuilt.value !== advanced)
        rebuilt.dispose()
        clock.advance(by: 100)
        _ = try await harness.waitForTask(id: id, context: .background)
        try await harness.close(context: .background)
    }

    // upstream harness-task-graph.test.ts:284.
    @Test func cancellationWhileQueuedRegistersNoObserver() async throws {
        let storage = ControlledStorage()
        let work = harnessOneStep("test.graph-paused") { _, _, _ in }
        let harness = try await harnessOpen([AnyTaskDefinition(work)], storage: storage)
        let root = try await harness.root(context: .background)
        _ = try await harnessStart(root, work)
        let held = await storage.holdCommits()
        let blocking = Task { try await root.commit({ tx in
            _ = try await tx.appendEntry(root.id, value: .init(kind: "blocker"))
        }, context: .background) }
        await held.waitUntilEntered()
        let controller = AbortController()
        let cancelled = Task { try await harness.watchTaskGraph(context: .background.withAbortSignal(controller.signal)) }
        try await eventually { harness.session.line.queuedCount >= 1 }
        controller.abort(TaskDefinitionError("cancelled"))
        await held.release()
        try await blocking.value
        await #expect(throws: TaskDefinitionError("cancelled")) { _ = try await cancelled.value }
        let first = try await harness.taskGraph(context: .background), value = first.value
        first.dispose()
        let second = try await harness.taskGraph(context: .background)
        #expect(second.value !== value && second.value == value)
        second.dispose()
        try await harness.close(context: .background)
    }

    // upstream harness-task-graph.test.ts:312.
    @Test func sharesOneMountAndPublishesNoRevisionForMemos() async throws {
        let clock = TestClock(now: 0), reached = SessionTestGate()
        let memo = harnessOneStep("test.graph-memo") { _, runtime, context in
            _ = try await runtime.memo("seen", value: true, context: context)
            reached.release()
            try await runtime.sleep(until: 100, context: context)
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }
        let harness = try await harnessOpen([AnyTaskDefinition(memo)], clock: clock)
        let root = try await harness.root(context: .background), id = try await harnessStart(root, memo)
        let first = try await harness.taskGraph(context: .background), second = try await harness.taskGraph(context: .background)
        #expect(first.value === second.value)
        let updates = SessionTestLog<String>(), key = String(id.rawValue)
        first.subscribe { value, _, delivery in if case .update = delivery { updates.append(value.tasks[key]?.state.status ?? "gone") } }
        try harness.resume()
        await reached.wait()
        await first.waitUntilIdle()
        #expect(updates.values == ["running"])
        clock.advance(by: 100)
        _ = try await harness.waitForTask(id: id, context: .background)
        await first.waitUntilIdle()
        #expect(updates.values == ["running", "gone"])
        let last = first.value
        first.dispose(); second.dispose()
        let rebuilt = try await harness.taskGraph(context: .background)
        #expect(rebuilt.value == last && rebuilt.value !== last)
        rebuilt.dispose()
        try await harness.close(context: .background)
    }
}
