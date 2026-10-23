import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private struct W3EndedBridge: Sendable {
    let owner: TaskID
    let conversation: ConversationID
    let links: [TaskID]
}

private func w3EndedBridge(_ harness: Harness, root: Conversation, definition: HarnessTestTask,
                           control: W3LifetimeControl, depth: Int) async throws -> W3EndedBridge {
    let bridge = try await root.commit({ tx in
        let owner = try await tx.createTask(definition, input: 1, options: .init(ownership: .conversation()))
        var current = owner, links: [TaskID] = []
        for n in 0..<depth {
            current = try await tx.createTask(definition, input: 10 + n, options: .init(ownership: .task(taskId: current)))
            links.append(current)
        }
        let conversation = try await tx.createConversation(ownership: .task(taskId: current)).id
        return W3EndedBridge(owner: owner, conversation: conversation, links: links)
    }, context: .background)
    try harness.resume()
    for n in (0..<depth).reversed() { control.open(10 + n) }
    for id in bridge.links { _ = try await w3Terminal(harness, id) }
    return bridge
}

@Suite struct HarnessW3OwnershipTests {
    // harness-ownership.test.ts:213,336,369. The one-link case also checks an ended direct child.
    @Test(arguments: [1, 2], [false, true])
    func lateWorkBelowEndedTasksHoldsLiveOwner(depth: Int, reopen: Bool) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ended-bridge.sqlite").path
        let control = W3LifetimeControl(), definition = control.definition()
        let first = try await harnessOpen([AnyTaskDefinition(definition)], storage: SqliteStorage.open(path: path), clock: control.clock)
        let root = try await first.root(context: .background)
        let bridge = try await w3EndedBridge(first, root: root, definition: definition, control: control, depth: depth)
        let harness: Harness
        if reopen {
            try await first.close(context: .background)
            harness = try await harnessOpen([AnyTaskDefinition(definition)], storage: SqliteStorage.open(path: path), clock: control.clock)
            try harness.resume()
        } else { harness = first }
        let conversation = try #require(try await harness.conversation(id: bridge.conversation, context: .background))
        let late = try await harnessStart(conversation, definition, input: 100)
        control.open(1)
        try await w3State(harness, bridge.owner, "completing")
        #expect(try await harness.getTask(id: late, context: .background)?.abortRequested == false)
        control.open(100)
        #expect(try await w3Terminal(harness, late).outcome.status == "completed")
        #expect(try await w3Terminal(harness, bridge.owner).outcome.status == "completed")
        try await harness.close(context: .background)
    }

    // harness-ownership.test.ts:236. Cross the background edge through ended tasks.
    @Test func backgroundAbortCrossesEndedTasks() async throws {
        let control = W3LifetimeControl(), definition = control.definition()
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], clock: control.clock)
        let root = try await harness.root(context: .background)
        let bridge = try await w3EndedBridge(harness, root: root, definition: definition, control: control, depth: 1)
        let conversation = try #require(try await harness.conversation(id: bridge.conversation, context: .background))
        let ids = try await conversation.commit({ tx in
            let background = try await tx.createTask(definition, input: 100, options: .init(ownership: .conversation(), background: true))
            let child = try await tx.createTask(definition, input: 101, options: .init(ownership: .task(taskId: background)))
            return (background, child)
        }, context: .background)
        control.open(1)
        _ = try await w3Terminal(harness, bridge.owner)
        try await root.abort(background: true, context: .background)
        #expect(try await w3Terminal(harness, ids.0).outcome.status == "aborted")
        #expect(try await w3Terminal(harness, ids.1).outcome.status == "aborted")
        try await harness.close(context: .background)
    }

    // harness-ownership.test.ts:419. The abort handler starts after descendants end.
    @Test(arguments: [2, 5])
    func ownerAbortReachesBelowEndedTasksAndWaits(depth: Int) async throws {
        let control = W3LifetimeControl(), definition = control.definition()
        control.holdAbort(1)
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], clock: control.clock)
        let root = try await harness.root(context: .background)
        let bridge = try await w3EndedBridge(harness, root: root, definition: definition, control: control, depth: depth)
        let conversation = try #require(try await harness.conversation(id: bridge.conversation, context: .background))
        let late = try await harnessStart(conversation, definition, input: 100)
        _ = try await harness.abortTask(id: bridge.owner, context: .background)
        #expect(try await w3Terminal(harness, late).outcome.status == "aborted")
        try await harnessEventually { control.abortInputs.values.contains(1) }
        #expect(control.abortInputs.values.first == 100)
        #expect(try await harness.getTask(id: bridge.owner, context: .background)?.state.status != "terminal")
        control.openAbort(1)
        #expect(try await w3Terminal(harness, bridge.owner).outcome.status == "aborted")
        try await harness.close(context: .background)
    }

    // harness-ownership.test.ts:430. All tasks above the late work have ended.
    @Test(arguments: [2, 5])
    func rootStaysBusyAndAbortsWorkBelowEndedTasks(depth: Int) async throws {
        let control = W3LifetimeControl(), definition = control.definition()
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], clock: control.clock)
        let root = try await harness.root(context: .background)
        let bridge = try await w3EndedBridge(harness, root: root, definition: definition, control: control, depth: depth)
        control.open(1)
        _ = try await w3Terminal(harness, bridge.owner)
        let conversation = try #require(try await harness.conversation(id: bridge.conversation, context: .background))
        let first = try await harnessStart(conversation, definition, input: 100)
        let second = try await harnessStart(conversation, definition, input: 101)
        try await harnessEventually { control.runs.values.contains(100) && control.runs.values.contains(101) }
        let rootIdle = settled { try await root.waitForIdle(context: .background) }
        let harnessIdle = settled { try await harness.waitForIdle(context: .background) }
        for _ in 0..<100 { await Task.yield() }
        #expect(!rootIdle.isSettled)
        #expect(!harnessIdle.isSettled)
        try await root.abort(context: .background)
        #expect(try await w3Terminal(harness, first).outcome.status == "aborted")
        #expect(try await w3Terminal(harness, second).outcome.status == "aborted")
        try await harnessEventually { rootIdle.isSettled && harnessIdle.isSettled }
        try #require(rootIdle.result).get()
        try #require(harnessIdle.result).get()
        try await harness.close(context: .background)
    }

    // harness-ownership.test.ts:446. An ended task that owns only a task remains a bridge.
    @Test func reachesLateWorkAcrossTwoOwnedConversations() async throws {
        let control = W3LifetimeControl(), definition = control.definition()
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], clock: control.clock)
        let root = try await harness.root(context: .background)
        let tree = try await root.commit({ tx in
            let parent = try await tx.createTask(definition, input: 1, options: .init(ownership: .conversation()))
            let b = try await tx.createTask(definition, input: 2, options: .init(ownership: .task(taskId: parent)))
            let c = try await tx.createConversation(ownership: .task(taskId: b))
            let x = try await tx.createTask(definition, input: 3, options: .init(ownership: .conversation(), conversationId: c.id))
            let a = try await tx.createTask(definition, input: 4, options: .init(ownership: .task(taskId: x)))
            let c2 = try await tx.createConversation(ownership: .task(taskId: a))
            return (parent, b, x, a, c2.id)
        }, context: .background)
        try harness.resume()
        for input in [4, 3, 2] { control.open(input) }
        for id in [tree.3, tree.2, tree.1] { _ = try await w3Terminal(harness, id) }
        let c2 = try #require(try await harness.conversation(id: tree.4, context: .background))
        let late = try await harnessStart(c2, definition, input: 100)
        control.open(1)
        try await w3State(harness, tree.0, "completing")
        let idle = settled { try await root.waitForIdle(context: .background) }
        for _ in 0..<100 { await Task.yield() }
        #expect(!idle.isSettled)
        try await root.abort(context: .background)
        #expect(try await w3Terminal(harness, late).outcome.status == "aborted")
        #expect(try await w3Terminal(harness, tree.0).outcome.status == "completed")
        try await harness.close(context: .background)
    }

    // harness-ownership.test.ts:482. Background work ends before the last foreground task.
    @Test(arguments: [false, true])
    func lastForegroundEndFreesOwnerAfterBackgroundEnd(abort: Bool) async throws {
        let control = W3LifetimeControl(), definition = control.definition()
        control.holdAbort(100)
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], clock: control.clock)
        let root = try await harness.root(context: .background)
        let bridge = try await w3EndedBridge(harness, root: root, definition: definition, control: control, depth: 2)
        let conversation = try #require(try await harness.conversation(id: bridge.conversation, context: .background))
        let background = try await harnessStart(conversation, definition, input: 101, background: true)
        let foreground = try await harnessStart(conversation, definition, input: 100)
        if abort {
            _ = try await harness.abortTask(id: bridge.owner, context: .background)
            try await harnessEventually { try await harness.getTask(id: foreground, context: .background)?.abortRequested == true }
        } else {
            control.open(1)
            try await w3State(harness, bridge.owner, "completing")
        }
        control.open(101)
        _ = try await w3Terminal(harness, background)
        #expect(try await harness.getTask(id: bridge.owner, context: .background)?.state.status != "terminal")
        if abort { control.openAbort(100) } else { control.open(100) }
        _ = try await w3Terminal(harness, foreground)
        #expect(try await w3Terminal(harness, bridge.owner).outcome.status == (abort ? "aborted" : "completed"))
        try await harness.close(context: .background)
    }

    // harness-ownership.test.ts:314. D3 covers behavior at depth 64.
    // The upstream depth-20,000 stack/performance requirement is W11.
    @Test func holdsAndReleasesAnOwnershipChain() async throws {
        let control = W3LifetimeControl(), definition = control.definition(), depth = 64
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], clock: control.clock)
        let root = try await harness.root(context: .background)
        let ids = try await root.commit({ tx in
            var ids: [TaskID] = []
            for n in 0..<(depth + 2) {
                let ownership: TaskOwnership = ids.last.map { .task(taskId: $0) } ?? .conversation()
                ids.append(try await tx.createTask(definition, input: n + 1, options: .init(ownership: ownership)))
            }
            return ids
        }, context: .background)
        try harness.resume()
        for input in 1..<(depth + 2) { control.open(input) }
        try await w3State(harness, ids[0], "completing")
        control.open(depth + 2)
        for id in ids.reversed() { #expect(try await w3Terminal(harness, id).outcome.status == "completed") }
        try await harness.close(context: .background)
    }

    // harness-ownership.test.ts:525. Test settlement at 32 siblings. W11 owns cost bounds.
    @Test func finalizesHeldSiblingsWhenLeavesEndInOneCommit() async throws {
        let control = W3LifetimeControl(), definition = control.definition(), count = 32
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], clock: control.clock)
        let root = try await harness.root(context: .background)
        let tree = try await root.commit({ tx in
            let top = try await tx.createTask(definition, input: 1, options: .init(ownership: .conversation()))
            var siblings: [TaskID] = [], leaves: [TaskID] = []
            for n in 0..<count {
                siblings.append(try await tx.createTask(definition, input: 10 + n, options: .init(ownership: .task(taskId: top))))
            }
            for (n, id) in siblings.enumerated().reversed() {
                leaves.append(try await tx.createTask(definition, input: 100 + n, options: .init(ownership: .task(taskId: id))))
            }
            return (top, siblings, leaves)
        }, context: .background)
        try harness.resume()
        for n in 0..<count { control.open(10 + n) }
        control.open(1)
        for id in tree.1 { try await w3State(harness, id, "completing") }
        try await w3State(harness, tree.0, "completing")
        try await root.commit({ tx in
            var records: [TaskRecord] = []
            for id in tree.2 { records.append(try #require(await tx.task(id))) }
            for record in records { try tx.setTask(record.replacing(state: .terminal(outcome: .completed(result: .null)))) }
        }, context: .background)
        #expect(try await w3Terminal(harness, tree.0).outcome.status == "completed")
        for id in tree.1 { #expect(try await w3Terminal(harness, id).outcome.status == "completed") }
        try await harness.close(context: .background)
    }

    // harness-ownership.test.ts:580. End-state validation checks the whole commit.
    @Test func cannotCreateConversationInCommitThatEndsItsOwner() async throws {
        let child = W3LifetimeControl().definition()
        let spawner = harnessOneStep("test.w3.end-spawner") { task, runtime, context in
            try await runtime.commit({ tx, _ in
                let conversation = try await tx.createConversation(ownership: .task(taskId: task.id))
                _ = try await tx.createTask(child, input: 1, options: .init(ownership: .conversation(), conversationId: conversation.id))
                return .terminal(outcome: .completed(result: .null))
            }, context: context)
        }
        let harness = try await harnessOpen([AnyTaskDefinition(spawner)])
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, spawner)
        try harness.resume()
        let receipt = try await w3Terminal(harness, id)
        guard case .faulted(let error, _) = receipt.outcome else { Issue.record("Expected owner validation fault"); try await harness.close(context: .background); return }
        #expect(error.message.hasPrefix("Conversation owner task \(id.rawValue) is "))
        #expect(error.message.hasSuffix("completing") || error.message.hasSuffix("terminal"))
        try await harness.close(context: .background)
    }

    // harness-ownership.test.ts:261. Preserve settlement behavior. W11 owns walk costs.
    @Test func emptyConversationsBelowFinishedBranchesDoNotHoldOwner() async throws {
        let control = W3LifetimeControl(), definition = control.definition(), count = 8
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], clock: control.clock)
        let root = try await harness.root(context: .background)
        let tree = try await root.commit({ tx in
            let top = try await tx.createTask(definition, input: 1, options: .init(ownership: .conversation()))
            var branches: [TaskID] = []
            for n in 0..<count {
                let first = try await tx.createTask(definition, input: 10 + n * 2, options: .init(ownership: .task(taskId: top)))
                let second = try await tx.createTask(definition, input: 11 + n * 2, options: .init(ownership: .task(taskId: first)))
                _ = try await tx.createConversation(ownership: .task(taskId: second))
                branches.append(contentsOf: [first, second])
            }
            return (top, branches)
        }, context: .background)
        try harness.resume()
        for input in 10..<(10 + count * 2) { control.open(input) }
        for id in tree.1 { _ = try await w3Terminal(harness, id) }
        control.open(1)
        #expect(try await w3Terminal(harness, tree.0).outcome.status == "completed")
        try await harness.close(context: .background)
    }

    // harness-ownership.test.ts:595. A background owner's conversation has its own idle scope.
    @Test func idleStopsAtBackgroundOwnerButChildScopeWaits() async throws {
        let control = W3LifetimeControl(), definition = control.definition()
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], clock: control.clock)
        let root = try await harness.root(context: .background)
        let tree = try await harnessOwnedTree(root, definition: definition, input: 1, childInput: 2, background: true)
        try harness.resume()
        try await root.waitForIdle(context: .background)
        try await harness.waitForIdle(context: .background)
        let child = try #require(try await harness.conversation(id: tree.conversation, context: .background))
        let idle = settled { try await child.waitForIdle(context: .background) }
        try await harnessEventually { control.runs.values.contains(2) }
        for _ in 0..<100 { await Task.yield() }
        #expect(!idle.isSettled)
        try await child.abort(context: .background)
        #expect(try await w3Terminal(harness, tree.child).outcome.status == "aborted")
        try await harnessEventually { idle.isSettled }
        try #require(idle.result).get()
        _ = try await harness.abortTask(id: tree.owner, context: .background)
        try await harness.close(context: .background)
    }
}
