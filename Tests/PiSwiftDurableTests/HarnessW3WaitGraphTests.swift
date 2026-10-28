import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private typealias W3WaitTask = TaskDefinition<String, HarnessTaskCheckpoint, String, NoTaskHooks>

private final class W3WaitNodes: Sendable {
    private struct State: Sendable {
        var ids: [String: TaskID] = [:]
        var runs: [String: W3WaitTask.Handler] = [:]
        var aborts: [String: W3WaitTask.Handler] = [:]
        var gates: [String: SessionTestGate] = [:]
    }
    private let state = Mutex(State())
    var definition: W3WaitTask {
        W3WaitTask(name: "test.w3.wait-node", version: 1, initial: { _ in HarnessTaskCheckpoint() }, phase: { task, runtime, context in
            if task.checkpoint.phase == .run {
                if let run = self.state.withLock({ $0.runs[task.input] }) {
                    try await run(task, runtime, context)
                    return
                }
                await self.gate(task.input).wait()
            }
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .string(task.input))) }, context: context)
        }, abort: { task, runtime, context in
            if let abort = self.state.withLock({ $0.aborts[task.input] }) { try await abort(task, runtime, context) }
            else { try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "test")) }, context: context) }
        })
    }
    func id(_ name: String) throws -> TaskID { try #require(state.withLock { $0.ids[name] }) }
    func contains(_ name: String) -> Bool { state.withLock { $0.ids[name] != nil } }
    func script(_ name: String, run: @escaping W3WaitTask.Handler) { state.withLock { $0.runs[name] = run } }
    func abort(_ name: String, handler: @escaping W3WaitTask.Handler) { state.withLock { $0.aborts[name] = handler } }
    func gate(_ name: String) -> SessionTestGate {
        state.withLock { state in
            if let gate = state.gates[name] { return gate }
            let gate = SessionTestGate(); state.gates[name] = gate; return gate
        }
    }
    @discardableResult
    func create(_ tx: Transaction, _ name: String, owner: TaskID? = nil,
                conversation: ConversationID? = nil, background: Bool = false) async throws -> TaskID {
        let id = try await tx.createTask(definition, input: name,
            options: .init(ownership: owner.map { .task(taskId: $0) } ?? .conversation(),
                           conversationId: conversation, background: background))
        state.withLock { $0.ids[name] = id }
        return id
    }
    @discardableResult
    func start(_ root: Conversation, _ name: String) async throws -> TaskID {
        try await root.commit({ tx in try await self.create(tx, name) }, context: .background)
    }
    func waits(_ name: String, on targets: [String]) {
        script(name) { _, runtime, context in
            let on = try targets.map { try self.id($0) }
            try await runtime.commit({ _, _ in
                .waiting(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined)), on: on, policy: .allSettled)
            }, context: context)
        }
    }
    func spawnsAndFinishes(_ name: String, child: String) {
        script(name) { _, runtime, context in
            try await runtime.commit({ tx, _ in
                try await self.create(tx, child, owner: runtime.taskId)
                return .running(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined)))
            }, context: context)
        }
    }
    func outcome(_ harness: Harness, _ name: String) async throws -> TaskOutcome {
        try await harness.waitForTask(id: id(name), context: .background).outcome
    }
    func status(_ harness: Harness, _ name: String) async throws -> String? {
        try await harness.getTask(id: id(name), context: .background)?.state.status
    }
}

@Suite struct HarnessW3WaitGraphTests {
    // v1.3.0 harness-structured.test.ts:499,679 (#10411, #10533).
    @Test(arguments: [2, 3])
    func rejectsTheWaitThatClosesACycle(length: Int) async throws {
        let nodes = W3WaitNodes(), names = (0..<length).map { "node-\($0)" }
        for index in names.indices { nodes.waits(names[index], on: [names[(index + 1) % length]]) }
        let harness = try await harnessOpen([AnyTaskDefinition(nodes.definition)])
        let root = try await harness.root(context: .background)
        try await root.commit({ tx in for name in names { try await nodes.create(tx, name) } }, context: .background)
        var outcomes: [String] = []
        for name in names { outcomes.append(try await nodes.outcome(harness, name).status) }
        #expect(outcomes.filter { $0 == "faulted" }.count == 1)
        #expect(outcomes.filter { $0 == "completed" }.count == length - 1)
        try await harness.close(context: .background)
    }

    // v1.3.0 harness-structured.test.ts:516,535 (#10411).
    @Test(arguments: [1, 2])
    func rejectsACycleThroughHeldOwners(depth: Int) async throws {
        let nodes = W3WaitNodes()
        nodes.spawnsAndFinishes("held", child: "child")
        if depth == 2 { nodes.spawnsAndFinishes("child", child: "grandchild") }
        let leaf = depth == 1 ? "child" : "grandchild"
        nodes.waits(leaf, on: ["other"])
        nodes.waits("other", on: ["held"])
        let harness = try await harnessOpen([AnyTaskDefinition(nodes.definition)])
        let root = try await harness.root(context: .background)
        try await root.commit({ tx in
            try await nodes.create(tx, "held")
            try await nodes.create(tx, "other")
        }, context: .background)
        try harness.resume()
        try await harnessEventually { nodes.contains(leaf) }
        let outcomes = [try await nodes.outcome(harness, leaf).status, try await nodes.outcome(harness, "other").status]
        #expect(outcomes.sorted() == ["completed", "faulted"])
        #expect(try await nodes.outcome(harness, "held").status == "completed")
        if depth == 2 { #expect(try await nodes.outcome(harness, "child").status == "completed") }
        try await harness.close(context: .background)
    }

    // v1.3.0 harness-structured.test.ts:556 (#10411).
    @Test func backgroundTaskCanWaitOnItsConversationOwner() async throws {
        let nodes = W3WaitNodes()
        nodes.waits("background", on: ["owner"])
        let harness = try await harnessOpen([AnyTaskDefinition(nodes.definition)])
        let root = try await harness.root(context: .background)
        try await root.commit({ tx in
            let owner = try await nodes.create(tx, "owner")
            let conversation = try await tx.createConversation(ownership: .task(taskId: owner))
            try await nodes.create(tx, "background", conversation: conversation.id, background: true)
        }, context: .background)
        try harness.resume()
        try await harnessEventually { try await nodes.status(harness, "background") == "waiting" }
        nodes.gate("owner").release()
        #expect(try await nodes.outcome(harness, "background").status == "completed")
        try await harness.close(context: .background)
    }

    // v1.3.0 harness-structured.test.ts:574 (#10411).
    @Test func rejectsAHoldAndTwoWaitsWithTheExactCyclePath() async throws {
        let nodes = W3WaitNodes(), reviewerWaits = SessionTestGate()
        nodes.spawnsAndFinishes("orchestrator", child: "worker")
        nodes.script("reviewer") { _, runtime, context in
            let owner = try nodes.id("orchestrator")
            try await runtime.commit({ _, _ in
                .waiting(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined)), on: [owner], policy: .allSettled)
            }, context: context)
            reviewerWaits.release()
        }
        nodes.script("worker") { _, runtime, context in
            await reviewerWaits.wait()
            let reviewer = try nodes.id("reviewer")
            try await runtime.commit({ _, _ in
                .waiting(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined)), on: [reviewer], policy: .allSettled)
            }, context: context)
        }
        let harness = try await harnessOpen([AnyTaskDefinition(nodes.definition)])
        let root = try await harness.root(context: .background)
        try await nodes.start(root, "orchestrator")
        try harness.resume()
        try await harnessEventually { try await nodes.status(harness, "orchestrator") == "completing" }
        try await nodes.start(root, "reviewer")
        #expect(try await nodes.outcome(harness, "orchestrator").status == "completed")
        let worker = try await nodes.outcome(harness, "worker")
        #expect(worker.status == "faulted")
        #expect(try await nodes.outcome(harness, "reviewer").status == "completed")
        let workerID = try nodes.id("worker").rawValue, reviewerID = try nodes.id("reviewer").rawValue
        let ownerID = try nodes.id("orchestrator").rawValue
        #expect(worker == .faulted(error: .init(message: "Task \(workerID) cannot wait on \(reviewerID): \(workerID) -> \(reviewerID) -> \(ownerID) -> \(workerID) is a wait cycle")))
        try await harness.close(context: .background)
    }

    // v1.3.0 harness-structured.test.ts:615 (#10411).
    @Test func allowsADiamondOfWaits() async throws {
        let nodes = W3WaitNodes()
        nodes.waits("top", on: ["left", "right"])
        nodes.waits("left", on: ["bottom"])
        nodes.waits("right", on: ["bottom"])
        let harness = try await harnessOpen([AnyTaskDefinition(nodes.definition)])
        let root = try await harness.root(context: .background)
        try await root.commit({ tx in
            for name in ["bottom", "left", "right", "top"] { try await nodes.create(tx, name) }
        }, context: .background)
        try harness.resume()
        for name in ["top", "left", "right"] {
            try await harnessEventually { try await nodes.status(harness, name) == "waiting" }
        }
        nodes.gate("bottom").release()
        #expect(try await nodes.outcome(harness, "top").status == "completed")
        try await harness.close(context: .background)
    }

    // v1.3.0 harness-structured.test.ts:636 (#10411).
    @Test func ignoresTheOldWaitOfAnAbortMarkedTask() async throws {
        let nodes = W3WaitNodes(), cleanup = SessionTestGate(), cleanupEntered = SessionTestGate()
        let aWaits = SessionTestGate(), clock = TestClock()
        nodes.script("b") { _, runtime, context in
            let a = try nodes.id("a")
            try await runtime.commit({ tx, _ in
                try await nodes.create(tx, "c", owner: runtime.taskId)
                return .waiting(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined)), on: [a], policy: .allSettled)
            }, context: context)
        }
        nodes.script("c") { _, runtime, context in
            // Upstream harness-structured.test.ts:649-654 uses defaultRun:83-87.
            // scheduler.ts:2168: keep the child invocation active until abort.
            try await harnessToolAwaitAbort(context.withAbortSignal(runtime.signal))
        }
        nodes.abort("c") { _, runtime, context in
            cleanupEntered.release(); await cleanup.wait()
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "c")) }, context: context)
        }
        nodes.script("a") { _, runtime, context in
            await aWaits.wait()
            let b = try nodes.id("b")
            try await runtime.commit({ _, _ in
                .waiting(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined)), on: [b], policy: .allSettled)
            }, context: context)
        }
        let harness = try await harnessOpen([AnyTaskDefinition(nodes.definition)], clock: clock)
        let root = try await harness.root(context: .background)
        try await root.commit({ tx in
            try await nodes.create(tx, "a")
            try await nodes.create(tx, "b")
        }, context: .background)
        try harness.resume()
        try await harnessEventually { try await nodes.status(harness, "b") == "waiting" }
        #expect(try await harness.abortTask(id: nodes.id("b"), context: .background) == .marked)
        await cleanupEntered.wait()
        aWaits.release()
        try await harnessEventually { try await nodes.status(harness, "a") == "waiting" }
        cleanup.release()
        #expect(try await nodes.outcome(harness, "b").status == "aborted")
        #expect(try await nodes.outcome(harness, "a").status == "completed")
        try await harness.close(context: .background)
    }

    // v1.3.0 harness-scheduler-retention.test.ts:545 (#10411).
    @Test func canWaitOnAForgottenTerminalConversationOwner() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try await SqliteStorage.open(path: directory.appendingPathComponent("wait.sqlite").path)
        let nodes = W3WaitNodes()
        nodes.waits("waiter", on: ["owner"])
        let harness = try await harnessOpen([AnyTaskDefinition(nodes.definition)], storage: storage)
        let root = try await harness.root(context: .background)
        let conversationID = try await root.commit({ tx in
            let owner = try await nodes.create(tx, "owner")
            return try await tx.createConversation(ownership: .task(taskId: owner)).id
        }, context: .background)
        nodes.gate("owner").release()
        #expect(try await nodes.outcome(harness, "owner").status == "completed")
        let owner = try nodes.id("owner")
        #expect(harness.tasks.current(owner) == nil)
        let conversation = try #require(try await harness.conversation(id: conversationID, context: .background))
        try await nodes.start(conversation, "waiter")
        #expect(try await nodes.outcome(harness, "waiter").status == "completed")
        try await harness.close(context: .background)
    }

    @Test func restoresAWaitCycleThroughAnEvictedTerminalBridge() async throws {
        let nodes = W3WaitNodes(), beginWaits = SessionTestGate()
        for (name, target) in [("descendant", "other"), ("other", "parent")] {
            nodes.script(name) { _, runtime, context in
                await beginWaits.wait()
                let targetID = try nodes.id(target)
                try await runtime.commit({ _, _ in
                    .waiting(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined)), on: [targetID], policy: .allSettled)
                }, context: context)
            }
        }
        let harness = try await harnessOpen([AnyTaskDefinition(nodes.definition)])
        let root = try await harness.root(context: .background)
        let conversationID = try await root.commit({ tx in
            let parent = try await nodes.create(tx, "parent")
            let bridge = try await nodes.create(tx, "bridge", owner: parent)
            let endedOwner = try await nodes.create(tx, "ended-owner", owner: bridge)
            return try await tx.createConversation(ownership: .task(taskId: endedOwner)).id
        }, context: .background)
        nodes.gate("bridge").release(); nodes.gate("ended-owner").release()
        #expect(try await nodes.outcome(harness, "bridge").status == "completed")
        let bridge = try nodes.id("bridge"), endedOwner = try nodes.id("ended-owner")
        #expect(harness.tasks.state.withLock { $0.nodes[bridge] == nil })
        #expect(harness.tasks.state.withLock { $0.nodes[endedOwner] == nil })
        try await root.commit({ tx in
            try await nodes.create(tx, "descendant", conversation: conversationID)
            try await nodes.create(tx, "other")
        }, context: .background)
        nodes.gate("parent").release()
        try await harnessEventually { try await nodes.status(harness, "parent") == "completing" }
        beginWaits.release()
        let outcomes = [try await nodes.outcome(harness, "descendant").status, try await nodes.outcome(harness, "other").status]
        #expect(outcomes.sorted() == ["completed", "faulted"])
        #expect(try await nodes.outcome(harness, "parent").status == "completed")
        try await harness.close(context: .background)
    }
}
