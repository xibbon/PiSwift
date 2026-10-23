import Foundation
import Synchronization
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

// Port of upstream harness-scheduler-retention.test.ts at v1.3.0.
@Suite(.timeLimit(.minutes(5))) struct HarnessSchedulerRetentionTests {
    @Test func forgetsEndedSubagentChains() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = RetentionControl()
        let (harness, root) = try await control.opened(storage: SqliteStorage.open(path: directory.appendingPathComponent("retention.sqlite").path))
        let parent = try await retentionStart(root, control.hold, name: "parent")
        _ = try await control.cycle(harness: harness, root: root, parent: parent, number: 0)
        let baseline = retentionSizes(harness)
        for number in 1...200 { _ = try await control.cycle(harness: harness, root: root, parent: parent, number: number) }
        #expect(retentionSizes(harness) == baseline)
        control.open("parent")
        _ = try await harness.waitForTask(id: parent, context: .background)
        try await harness.close(context: .background)
    }

    @Test func loadsForgottenChainForNewWorkAndHoldsLiveOwner() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = RetentionProbeStorage(try await SqliteStorage.open(path: directory.appendingPathComponent("retention.sqlite").path))
        let control = RetentionControl()
        let (harness, root) = try await control.opened(storage: storage)
        let tree = try await chain(root, control: control, depth: 2)
        control.open("a"); control.open("b")
        _ = try await harness.waitForTask(id: tree.b, context: .background)
        let before = retentionSizes(harness), loaded = storage.reads
        let conversation = try #require(try await harness.conversation(id: tree.c, context: .background))
        let child = try await retentionStart(conversation, control.hold, name: "d")
        control.open("p")
        try await w3State(harness, tree.p, "completing")
        #expect(storage.reads > loaded)
        control.open("d")
        #expect(try await harness.waitForTask(id: child, context: .background).outcome.status == "completed")
        #expect(try await harness.waitForTask(id: tree.p, context: .background).outcome.status == "completed")
        #expect(try #require(retentionSizes(harness)["settled"]) <= #require(before["settled"]))
        try await harness.close(context: .background)
    }

    @Test func terminalCommitCreatesWorkBelowForgottenChain() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = RetentionControl()
        let (harness, root) = try await control.opened(storage: SqliteStorage.open(path: directory.appendingPathComponent("retention.sqlite").path))
        let tree = try await chain(root, control: control, depth: 2, parent: control.spawner)
        try await setDestination(root, id: tree.p, conversation: tree.c, name: "p")
        control.open("a"); control.open("b")
        _ = try await harness.waitForTask(id: tree.b, context: .background)
        control.open("p")
        try await harnessEventually { try await harness.getTask(id: tree.p, context: .background)?.state.status != "running" }
        #expect(try await harness.getTask(id: tree.p, context: .background)?.state.status == "completing")
        control.open("inside.p")
        #expect(try await harness.waitForTask(id: tree.p, context: .background).outcome.status == "completed")
        try await harness.close(context: .background)
    }

    @Test func withdrawsInputBelowForgottenAbortMarkedOwner() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = RetentionControl()
        let (harness, root) = try await control.opened(storage: SqliteStorage.open(path: directory.appendingPathComponent("retention.sqlite").path))
        let tree = try await chain(root, control: control, keep: true)
        control.open("b")
        _ = try await harness.waitForTask(id: tree.b, context: .background)
        let conversation = try #require(try await harness.conversation(id: tree.c, context: .background))
        try await retentionBusy(conversation, task: #require(tree.keep))
        let queued = try await conversation.submit(.input(content: .text("later")), context: .background)
        _ = try await harness.abortTask(id: tree.p, context: .background)
        try await harnessEventually { try await queued.status(context: .background).status == "unanswered" }
        #expect(try await queued.wait(context: .background).reason == "aborted")
        _ = try await harness.waitForTask(id: tree.p, context: .background)
        try await harness.close(context: .background)
    }

    @Test func abortsNewWorkBelowForgottenAbortMarkedOwnerBeforeItRuns() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = RetentionControl()
        let (harness, root) = try await control.opened(storage: SqliteStorage.open(path: directory.appendingPathComponent("retention.sqlite").path))
        let tree = try await chain(root, control: control, keep: true)
        control.open("b")
        _ = try await harness.waitForTask(id: tree.b, context: .background)
        try await harness.commit({ tx in
            let record = try #require(try await tx.task(tree.p))
            try tx.setTask(record.withAbortMark())
        }, context: .background)
        let keep = try #require(tree.keep)
        try await harnessEventually { try await harness.getTask(id: keep, context: .background)?.abortRequested == true }
        let conversation = try #require(try await harness.conversation(id: tree.c, context: .background))
        let late = try await retentionStart(conversation, control.hold, name: "late")
        #expect(try await harness.waitForTask(id: late, context: .background).outcome.status == "aborted")
        #expect(control.runs.values.filter { $0 == "late" }.count == 0)
        try await harness.close(context: .background)
    }

    @Test func scopeStaysBusyDuringForgottenChainLoad() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = RetentionProbeStorage(try await SqliteStorage.open(path: directory.appendingPathComponent("retention.sqlite").path))
        let control = RetentionControl()
        let (harness, root) = try await control.opened(storage: storage)
        let tree = try await root.commit({ tx in
            let owner = try await tx.createTask(control.hold, input: .init(name: "b"), options: .init(ownership: .conversation()))
            let conversation = try await tx.createConversation(ownership: .task(taskId: owner))
            return (owner, conversation.id)
        }, context: .background)
        control.open("b")
        _ = try await harness.waitForTask(id: tree.0, context: .background)
        let conversation = try #require(try await harness.conversation(id: tree.1, context: .background))
        storage.holdSecondRead(of: tree.1)
        _ = try await retentionStart(conversation, control.hold, name: "d")
        await storage.reached.wait()
        let settled = Mutex(false)
        let idle = Task { try await harness.waitForIdle(context: .background); settled.withLock { $0 = true } }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!settled.withLock { $0 })
        storage.release.release(); control.open("d")
        try await idle.value
        try await harness.close(context: .background)
    }

    @Test func oneCommitReplacesLastWorkWithoutDroppingChain() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = RetentionControl()
        let (harness, root) = try await control.opened(storage: SqliteStorage.open(path: directory.appendingPathComponent("retention.sqlite").path))
        let tree = try await chain(root, control: control, background: true)
        control.open("b")
        _ = try await harness.waitForTask(id: tree.b, context: .background)
        let old = try #require(tree.old)
        let replacement = try await harness.commit({ tx in
            let record = try #require(try await tx.task(old))
            let id = try await tx.createTask(control.hold, input: .init(name: "new"), options: .init(ownership: .conversation(), conversationId: tree.c))
            try tx.setTask(record.replacing(state: .terminal(outcome: .completed(result: .null))))
            return id
        }, context: .background)
        control.open("p")
        try await w3State(harness, tree.p, "completing")
        control.open("new")
        _ = try await harness.waitForTask(id: replacement, context: .background)
        #expect(try await harness.waitForTask(id: tree.p, context: .background).outcome.status == "completed")
        try await harness.close(context: .background)
    }

    @Test func rejectedCommitDropsLoadedChainWithoutPublication() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = RetentionControl()
        let (harness, root) = try await control.opened(storage: SqliteStorage.open(path: directory.appendingPathComponent("retention.sqlite").path))
        let tree = try await chain(root, control: control, parent: control.rejected)
        try await setDestination(root, id: tree.p, conversation: tree.c, name: "p")
        control.open("b")
        _ = try await harness.waitForTask(id: tree.b, context: .background)
        let baseline = retentionSizes(harness)
        control.open("rejected")
        try await harnessEventually { control.rejections.count > 0 }
        try await harnessEventually { retentionSizes(harness)["dropQueue"] == 0 }
        #expect(retentionSizes(harness) == baseline)
        try await harness.close(context: .background)
    }

    @Test func readAfterReopenDropsLoadedChainWithoutPublication() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("retention.sqlite").path
        let control = RetentionControl()
        let first = try await control.opened(storage: SqliteStorage.open(path: path))
        let tree = try await first.root.commit({ tx in
            let owner = try await tx.createTask(control.hold, input: .init(name: "b"), options: .init(ownership: .conversation()))
            let conversation = try await tx.createConversation(ownership: .task(taskId: owner))
            let child = try await tx.createTask(control.hold, input: .init(name: "d"), options: .init(ownership: .conversation(), conversationId: conversation.id))
            return (owner, child)
        }, context: .background)
        control.open("b")
        try await w3State(first.harness, tree.0, "completing")
        try await first.harness.close(context: .background)
        control.clearGates()
        let reopened = try await control.opened(storage: SqliteStorage.open(path: path))
        _ = try await reopened.harness.inspect(context: .background)
        #expect(retentionSizes(reopened.harness)["unloaded"] == 0)
        control.open("d")
        _ = try await reopened.harness.waitForTask(id: tree.1, context: .background)
        _ = try await reopened.harness.waitForTask(id: tree.0, context: .background)
        try await harnessEventually { retentionSizes(reopened.harness)["dropQueue"] == 0 }
        for key in ["settled", "below", "unloaded"] { #expect(retentionSizes(reopened.harness)[key] == 0) }
        try await reopened.harness.close(context: .background)
    }

    @Test func laterFailureWithdrawsInputTwoEndedLevelsBelowOwner() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = RetentionControl()
        let (harness, root) = try await control.opened(storage: SqliteStorage.open(path: directory.appendingPathComponent("retention.sqlite").path))
        let tree = try await chain(root, control: control, depth: 2, keep: true)
        control.open("a"); control.open("b")
        _ = try await harness.waitForTask(id: tree.b, context: .background)
        let conversation = try #require(try await harness.conversation(id: tree.c, context: .background))
        try await retentionBusy(conversation, task: #require(tree.keep))
        let queued = try await conversation.submit(.input(content: .text("later")), context: .background)
        try await harnessEventually { retentionSizes(harness)["dropQueue"] == 0 }
        try await harness.commit({ tx in
            let record = try #require(try await tx.task(tree.p))
            try tx.setTask(record.replacing(state: .completing(outcome: .failed(error: .init(message: "x")))))
        }, context: .background)
        try await harnessEventually { try await queued.status(context: .background).status == "unanswered" }
        #expect(try await queued.wait(context: .background).reason == "aborted")
        try await harness.close(context: .background)
    }

    @Test(.timeLimit(.minutes(1))) func forgetsTwentyThousandEndedTasksWithoutRecursion() async throws {
        let started = ContinuousClock.now
        let control = RetentionControl()
        let (harness, root) = try await control.opened(storage: SqliteStorage.open(path: ":memory:"))
        let depth = 20_000
        let baseline = retentionSizes(harness)
        let tree = try await root.commit({ tx in
            var owner = try await tx.createTask(control.hold, input: .init(name: "link0"), options: .init(ownership: .conversation()))
            var links = [owner]
            for number in 1..<depth {
                owner = try await tx.createTask(control.hold, input: .init(name: "link\(number)"), options: .init(ownership: .task(taskId: owner)))
                links.append(owner)
            }
            let leaf = try await tx.createTask(control.hold, input: .init(name: "leaf"), options: .init(ownership: .task(taskId: owner)))
            return (links, leaf)
        }, context: .background)
        let created = ContinuousClock.now
        for number in 0..<depth { control.open("link\(number)") }
        control.open("leaf")
        let opened = ContinuousClock.now
        _ = try await harness.waitForTask(id: tree.1, context: .background)
        _ = try await harness.waitForTask(id: tree.0[0], context: .background)
        try await harness.waitForIdle(context: .background)
        #expect(retentionSizes(harness) == baseline)
        print("E11b deep-retention create=\(started.duration(to: created)) gates=\(created.duration(to: opened)) settle=\(opened.duration(to: .now))")
        try await harness.close(context: .background)
    }

    @Test func endedWorkKeepsNoMoreThanFreshReopen() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("retention.sqlite").path
        let control = RetentionControl()
        let first = try await control.opened(storage: SqliteStorage.open(path: path))
        let parent = try await retentionStart(first.root, control.hold, name: "parent")
        for number in 0..<20 { _ = try await control.cycle(harness: first.harness, root: first.root, parent: parent, number: number) }
        control.open("parent")
        _ = try await first.harness.waitForTask(id: parent, context: .background)
        try await first.harness.waitForIdle(context: .background)
        let ended = retentionSizes(first.harness)
        try await first.harness.close(context: .background)
        let reopened = try await control.opened(storage: SqliteStorage.open(path: path))
        try await reopened.harness.waitForIdle(context: .background)
        #expect(ended == retentionSizes(reopened.harness))
        try await reopened.harness.close(context: .background)
    }

    @Test func inputWithoutCancellationDoesNotScanQueuedSubmissions() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = RetentionProbeStorage(try await SqliteStorage.open(path: directory.appendingPathComponent("retention.sqlite").path))
        let control = RetentionControl()
        let (harness, root) = try await control.opened(storage: storage)
        let busy = try await retentionStart(root, control.hold, name: "busy")
        try await retentionBusy(root, task: busy)
        let before = storage.queuedScans
        _ = try await root.submit(.input(content: .text("queued")), context: .background)
        try await Task.sleep(for: .milliseconds(20))
        #expect(storage.queuedScans == before)
        control.open("busy")
        try await harness.close(context: .background)
    }

    @Test func taskCanWaitOnForgottenEndedOwner() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = RetentionControl()
        let waiter = harnessOneStep("test.retention.waiter") { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                let owner = try TaskID(Int64(task.input))
                try await runtime.commit({ _, _ in .waiting(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined)), on: [owner], policy: .allSettled) }, context: context)
            case .joined:
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
            }
        }
        let harness = try await harnessOpen([AnyTaskDefinition(control.hold), AnyTaskDefinition(waiter)], storage: SqliteStorage.open(path: directory.appendingPathComponent("retention.sqlite").path))
        let root = try await harness.root(context: .background)
        try harness.resume()
        let tree = try await root.commit({ tx in
            let owner = try await tx.createTask(control.hold, input: .init(name: "b"), options: .init(ownership: .conversation()))
            let conversation = try await tx.createConversation(ownership: .task(taskId: owner))
            return (owner, conversation.id)
        }, context: .background)
        control.open("b")
        _ = try await harness.waitForTask(id: tree.0, context: .background)
        let conversation = try #require(try await harness.conversation(id: tree.1, context: .background))
        let id = try await harnessStart(conversation, waiter, input: Int(tree.0.rawValue))
        #expect(try await harness.waitForTask(id: id, context: .background).outcome.status == "completed")
        try await harness.close(context: .background)
    }

    private struct Chain: Sendable {
        var p: TaskID
        var b: TaskID
        var c: ConversationID
        var keep: TaskID?
        var old: TaskID?
    }
    private func chain(_ root: Conversation, control: RetentionControl, depth: Int = 1,
                       parent: RetentionTask? = nil, keep: Bool = false, background: Bool = false) async throws -> Chain {
        try await root.commit({ tx in
            let p = try await tx.createTask(parent ?? control.hold, input: .init(name: "p"), options: .init(ownership: .conversation()))
            let b = try await tx.createTask(control.hold, input: .init(name: "b"), options: .init(ownership: .task(taskId: p)))
            var owner = b
            if depth == 2 { owner = try await tx.createTask(control.hold, input: .init(name: "a"), options: .init(ownership: .task(taskId: b))) }
            let c = try await tx.createConversation(ownership: .task(taskId: owner)).id
            var result = Chain(p: p, b: b, c: c)
            if keep { result.keep = try await tx.createTask(control.hold, input: .init(name: "keep"), options: .init(ownership: .task(taskId: p))) }
            if background { result.old = try await tx.createTask(control.hold, input: .init(name: "old"), options: .init(ownership: .conversation(), conversationId: c, background: true)) }
            return result
        }, context: .background)
    }
    private func setDestination(_ root: Conversation, id: TaskID, conversation: ConversationID, name: String) async throws {
        try await root.commit({ tx in
            let record = try #require(try await tx.task(id))
            try tx.setTask(record.replacing(input: try JSONValue(encoding: RetentionInput(name: name, into: conversation))))
        }, context: .background)
    }
}
