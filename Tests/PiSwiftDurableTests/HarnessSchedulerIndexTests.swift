import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private final class SchedulerIndexProbe: Sendable {
    let control = W3LifetimeControl()
    let runtimes = SessionTestLog<TaskRuntime>()
    let owned = SessionTestLog<[TaskID]>()
    func definition() -> HarnessTestTask {
        harnessOneStep("test.index.probe") { [self] task, runtime, context in
            runtimes.append(runtime)
            try await control.wait(100 + task.input, runtime: runtime, context: context)
            owned.append(try await runtime.ownedTasks(context: context).map(\.id))
            try await control.wait(task.input, runtime: runtime, context: context)
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }
    }
}

/// Ports all five cases in v1.3.0 harness-scheduler-indexes.test.ts.
@Suite struct HarnessSchedulerIndexTests {
    @Test func cascadeUsesTheNearestCancellingOwnerReason() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("nearest-owner.sqlite").path
        let control = W3LifetimeControl(), hold = control.definition("test.index.hold")
        let session = try await Session.open(storage: SqliteStorage.open(path: path), context: .background)
        let ids = try await session.commit({ tx in
            let conversation = try await tx.createConversation(ownership: .ownerless())
            let top = try await tx.createTask(hold, input: 1, options: .init(ownership: .conversation(), conversationId: conversation.id))
            let middle = try await tx.createTask(hold, input: 2, options: .init(ownership: .task(taskId: top)))
            let leaf = try await tx.createTask(hold, input: 3, options: .init(ownership: .task(taskId: middle)))
            return (top, middle, leaf)
        }, context: .background)
        try await session.commit({ tx in
            let top = try #require(await tx.task(ids.0))
            let middle = try #require(await tx.task(ids.1))
            try tx.setTask(top.withAbortMark())
            try tx.setTask(middle.withAbortMark(.restart))
        }, context: .background)
        try await session.close(context: .background)
        let storage = SchedulerIndexStorage(try await SqliteStorage.open(path: path))
        let harness = try await harnessOpen([AnyTaskDefinition(hold)], storage: storage, clock: control.clock)
        try harness.resume()
        for id in [ids.2, ids.1, ids.0] { _ = try await w3Terminal(harness, id) }
        let reasons = storage.commits.values.flatMap { commit in
            commit.writes.compactMap { write -> TaskRecord? in
                guard case .task(let record, _) = write, record.id == ids.2, record.abortRequested else { return nil }
                return record
            }
        }.map(\.abortReason)
        #expect(!reasons.isEmpty)
        #expect(reasons.first == .some(.restart))
        try await harness.close(context: .background)
    }

    @Test func finalizesHeldOwnersInOneCommitAfterTheLastLeafEnds() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = W3LifetimeControl(), hold = control.definition("test.index.hold")
        let storage = SchedulerIndexStorage(try await SqliteStorage.open(path: directory.appendingPathComponent("finalize.sqlite").path))
        let harness = try await harnessOpen([AnyTaskDefinition(hold)], storage: storage, clock: control.clock)
        let root = try await harness.root(context: .background)
        try harness.resume()
        let ids = try await root.commit({ tx in
            let top = try await tx.createTask(hold, input: 1, options: .init(ownership: .conversation()))
            let middle = try await tx.createTask(hold, input: 2, options: .init(ownership: .task(taskId: top)))
            let leaf = try await tx.createTask(hold, input: 3, options: .init(ownership: .task(taskId: middle)))
            return (top, middle, leaf)
        }, context: .background)
        control.open(1); control.open(2)
        try await w3State(harness, ids.0, "completing")
        try await w3State(harness, ids.1, "completing")
        control.open(3)
        #expect(try await w3Terminal(harness, ids.0).outcome.status == "completed")
        var endedIn: [TaskID: Int] = [:]
        for commit in storage.commits.values {
            for write in commit.writes {
                if case .task(let record, _) = write, record.state.status == "terminal" { endedIn[record.id] = commit.number }
            }
        }
        let topCommit = try #require(endedIn[ids.0])
        let middleCommit = try #require(endedIn[ids.1])
        let leafCommit = try #require(endedIn[ids.2])
        #expect(topCommit == middleCommit)
        #expect(middleCommit > leafCommit)
        try await harness.close(context: .background)
    }

    @Test func reopenedScopeStaysBusyWhileAnEndedOwnerChainIsNotLoaded() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("unloaded-chain.sqlite").path
        let control = W3LifetimeControl(), hold = control.definition("test.index.hold")
        let first = try await harnessOpen([AnyTaskDefinition(hold)], storage: SqliteStorage.open(path: path), clock: control.clock)
        let root = try await first.root(context: .background)
        try first.resume()
        let ids = try await root.commit({ tx in
            let owner = try await tx.createTask(hold, input: 1, options: .init(ownership: .conversation()))
            let child = try await tx.createConversation(ownership: .task(taskId: owner))
            return (owner, child.id)
        }, context: .background)
        control.open(1)
        _ = try await w3Terminal(first, ids.0)
        let child = try #require(try await first.conversation(id: ids.1, context: .background))
        let inner = try await harnessStart(child, hold, input: 2)
        try await first.close(context: .background)
        let nextControl = W3LifetimeControl(), nextHold = nextControl.definition("test.index.hold")
        let storage = SchedulerIndexStorage(try await SqliteStorage.open(path: path))
        storage.holdConversation(ids.1)
        let harness = try await harnessOpen([AnyTaskDefinition(nextHold)], storage: storage, clock: nextControl.clock)
        await storage.readEntered.wait()
        #expect(!harness.tasks.idle(nil))
        #expect(!harness.tasks.idle(root.id))
        #expect(harness.tasks.state.withLock { $0.edges[ids.1] == nil })
        let idle = settled { try await harness.waitForIdle(context: .background) }
        for _ in 0..<100 { await Task.yield() }
        #expect(!idle.isSettled)
        storage.readRelease.release()
        let reopenedRoot = try await harness.root(context: .background)
        try harness.resume()
        nextControl.open(2)
        _ = try await w3Terminal(harness, inner)
        try await reopenedRoot.waitForIdle(context: .background)
        try await harnessEventually { idle.isSettled }
        try #require(idle.result).get()
        try await harness.close(context: .background)
    }

    @Test func ownedTasksListsDirectLiveTasksInIDOrderAfterReopen() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("owned.sqlite").path
        let probe = SchedulerIndexProbe(), hold = probe.control.definition("test.index.hold"), definition = probe.definition()
        let first = try await harnessOpen([AnyTaskDefinition(hold), AnyTaskDefinition(definition)], storage: SqliteStorage.open(path: path), clock: probe.control.clock)
        let root = try await first.root(context: .background)
        try first.resume()
        let ids = try await root.commit({ tx in
            let owner = try await tx.createTask(definition, input: 0, options: .init(ownership: .conversation()))
            let first = try await tx.createTask(hold, input: 1, options: .init(ownership: .task(taskId: owner)))
            let ends = try await tx.createTask(hold, input: 2, options: .init(ownership: .task(taskId: owner)))
            let second = try await tx.createTask(hold, input: 3, options: .init(ownership: .task(taskId: owner)))
            _ = try await tx.createTask(hold, input: 4, options: .init(ownership: .task(taskId: first)))
            let child = try await tx.createConversation(ownership: .task(taskId: owner))
            _ = try await tx.createTask(hold, input: 5, options: .init(ownership: .conversation(), conversationId: child.id))
            return (owner, first, ends, second)
        }, context: .background)
        probe.control.open(2)
        _ = try await w3Terminal(first, ids.2)
        probe.control.open(1)
        try await w3State(first, ids.1, "completing")
        probe.control.open(100)
        try await harnessEventually { probe.owned.count == 1 }
        #expect(probe.owned.values == [[ids.1, ids.3]])
        try await first.close(context: .background)
        let next = SchedulerIndexProbe()
        let harness = try await harnessOpen([AnyTaskDefinition(next.control.definition("test.index.hold")), AnyTaskDefinition(next.definition())], storage: SqliteStorage.open(path: path), clock: next.control.clock)
        try harness.resume()
        next.control.open(100)
        try await harnessEventually { next.owned.count == 1 }
        #expect(next.owned.values == [[ids.1, ids.3]])
        #expect(try await harness.getTask(id: ids.1, context: .background)?.state.status == "completing")
        #expect(try await harness.getTask(id: ids.2, context: .background)?.state.status == "terminal")
        try await harness.close(context: .background)
    }

    @Test func ownedTasksRejectsAfterItsInvocationEnds() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = SchedulerIndexProbe(), definition = probe.definition()
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], storage: SqliteStorage.open(path: directory.appendingPathComponent("ended-invocation.sqlite").path), clock: probe.control.clock)
        let root = try await harness.root(context: .background)
        try harness.resume()
        let id = try await harnessStart(root, definition)
        try await harnessEventually { probe.runtimes.count == 1 }
        let runtime = try #require(probe.runtimes.values.first)
        _ = try await harness.abortTask(id: id, context: .background)
        await #expect(throws: SessionError.message("Task \(id.rawValue) invocation has ended")) {
            _ = try await runtime.ownedTasks(context: .background)
        }
        try await harness.close(context: .background)
    }

    @Test func stagedWaitCycleCrossesAPrunedTerminalBridge() async throws {
        let control = W3LifetimeControl(), hold = control.definition("test.index.staged-wait")
        let harness = try await harnessOpen([AnyTaskDefinition(hold)], clock: control.clock)
        let root = try await harness.root(context: .background)
        let ids = try await root.commit({ tx in
            let parent = try await tx.createTask(hold, input: 1, options: .init(ownership: .conversation()))
            let bridge = try await tx.createTask(hold, input: 2, options: .init(ownership: .task(taskId: parent)))
            let conversation = try await tx.createConversation(ownership: .task(taskId: bridge))
            let other = try await tx.createTask(hold, input: 3, options: .init(ownership: .conversation()))
            return (parent, bridge, conversation.id, other)
        }, context: .background)
        try harness.resume()
        control.open(2)
        _ = try await w3Terminal(harness, ids.1)
        try await harnessEventually {
            harness.tasks.state.withLock { $0.nodes[ids.1] == nil && $0.edges[ids.2] == nil }
        }
        let expected = SessionTestLog<SessionError>()
        do {
            try await root.commit({ tx in
                let other = try #require(await tx.task(ids.3))
                let staged = try await tx.createTask(hold, input: 4, options: .init(ownership: .conversation(), conversationId: ids.2))
                let record = try #require(try tx.stagedTasks().first { $0.id == staged })
                try tx.setTask(record.replacing(state: .waiting(
                    checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint()), on: [ids.3], policy: .allSettled)))
                expected.append(.message("Task \(ids.3.rawValue) cannot wait on \(ids.0.rawValue): \(ids.3.rawValue) -> \(ids.0.rawValue) -> \(staged.rawValue) -> \(ids.3.rawValue) is a wait cycle"))
                let invocation = TaskInvocation(other, abort: false, context: .background)
                try await harness.tasks.validateWait(tx, invocation: invocation, current: other, on: [ids.0], policy: .allSettled)
            }, context: .background)
            Issue.record("Expected the staged ownership path to form a wait cycle")
        } catch let error as SessionError {
            #expect(error == expected.values.first)
        }
        try await harness.close(context: .background)
    }

}
