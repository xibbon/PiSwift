import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessW3OwnedRuntimeTests {
    // harness-scheduler-indexes.test.ts:203-258. No index cost assertion.
    @Test func listsDirectLiveTasksInOrderAcrossInvocationsAndRejectsOldRuntime() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("owned-runtime.sqlite").path
        let control = W3LifetimeControl(), hold = control.definition(), runtimes = SessionTestLog<TaskRuntime>()
        let probe = harnessOneStep("test.w3.probe") { _, runtime, context in
            runtimes.append(runtime)
            try await runtime.sleep(until: 1_000_000, context: context)
        }
        let definitions = [AnyTaskDefinition(hold), AnyTaskDefinition(probe)]
        let first = try await harnessOpen(definitions, storage: SqliteStorage.open(path: path), clock: control.clock)
        let root = try await first.root(context: .background)
        let ids = try await root.commit({ tx in
            let probe = try await tx.createTask(probe, input: 0, options: .init(ownership: .conversation()))
            let first = try await tx.createTask(hold, input: 1, options: .init(ownership: .task(taskId: probe)))
            let ends = try await tx.createTask(hold, input: 2, options: .init(ownership: .task(taskId: probe)))
            let second = try await tx.createTask(hold, input: 3, options: .init(ownership: .task(taskId: probe)))
            _ = try await tx.createTask(hold, input: 4, options: .init(ownership: .task(taskId: first)))
            let conversation = try await tx.createConversation(ownership: .task(taskId: probe))
            _ = try await tx.createTask(hold, input: 5, options: .init(ownership: .conversation(), conversationId: conversation.id))
            return (probe, first, ends, second)
        }, context: .background)
        try first.resume()
        control.open(2)
        _ = try await w3Terminal(first, ids.2)
        control.open(1)
        try await w3State(first, ids.1, "completing")
        try await harnessEventually { runtimes.count == 1 }
        let old = runtimes.values[0]
        #expect(try await old.ownedTasks(context: .background).map(\.id) == [ids.1, ids.3])
        try await first.close(context: .background)
        await #expect(throws: (any Error).self) { _ = try await old.ownedTasks(context: .background) }
        await #expect(throws: (any Error).self) { try await old.abortOwned(ids.1, context: .background) }
        let harness = try await harnessOpen(definitions, storage: SqliteStorage.open(path: path), clock: control.clock)
        try harness.resume()
        try await harnessEventually { runtimes.count == 2 }
        let current = runtimes.values[1]
        #expect(try await current.ownedTasks(context: .background).map(\.id) == [ids.1, ids.3])
        _ = try await harness.abortTask(id: ids.0, context: .background)
        _ = try await w3Terminal(harness, ids.0)
        await #expect(throws: (any Error).self) { _ = try await current.ownedTasks(context: .background) }
        await #expect(throws: (any Error).self) { try await current.abortOwned(ids.3, context: .background) }
        try await harness.close(context: .background)
    }

    // TaskRuntime.abortOwned: ownership admission, terminal idempotence and receipt wait.
    @Test func abortOwnedValidatesDirectOwnerAndWaitsForTerminalReceipt() async throws {
        let control = W3LifetimeControl(), runtimes = SessionTestLog<TaskRuntime>()
        control.holdAbort(1)
        let hold = control.definition()
        let probe = harnessOneStep("test.w3.abort-probe") { _, runtime, context in
            runtimes.append(runtime)
            try await runtime.sleep(until: 1_000_000, context: context)
        }
        let harness = try await harnessOpen([AnyTaskDefinition(hold), AnyTaskDefinition(probe)], clock: control.clock)
        let root = try await harness.root(context: .background)
        let ids = try await root.commit({ tx in
            let probe = try await tx.createTask(probe, input: 0, options: .init(ownership: .conversation()))
            let owned = try await tx.createTask(hold, input: 1, options: .init(ownership: .task(taskId: probe)))
            let ended = try await tx.createTask(hold, input: 2, options: .init(ownership: .task(taskId: probe)))
            let grandchild = try await tx.createTask(hold, input: 3, options: .init(ownership: .task(taskId: owned)))
            let unrelated = try await tx.createTask(hold, input: 4, options: .init(ownership: .conversation()))
            let conversation = try await tx.createConversation(ownership: .task(taskId: probe))
            let inside = try await tx.createTask(hold, input: 5, options: .init(ownership: .conversation(), conversationId: conversation.id))
            return (probe, owned, ended, grandchild, unrelated, inside)
        }, context: .background)
        try harness.resume()
        try await harnessEventually { runtimes.count == 1 }
        let runtime = runtimes.values[0]
        for id in [ids.3, ids.4, ids.5, try TaskID(999_999)] {
            await #expect(throws: (any Error).self) { try await runtime.abortOwned(id, context: .background) }
        }
        #expect(try await harness.getTask(id: ids.4, context: .background)?.abortRequested == false)
        control.open(2)
        _ = try await w3Terminal(harness, ids.2)
        try await runtime.abortOwned(ids.2, context: .background)
        #expect(try await harness.getTask(id: ids.2, context: .background)?.abortRequested == false)
        let aborting = settled { try await runtime.abortOwned(ids.1, context: .background) }
        try await harnessEventually { control.aborts.count >= 2 }
        #expect(try await w3Terminal(harness, ids.3).outcome.status == "aborted")
        #expect(!aborting.isSettled)
        #expect(try await harness.getTask(id: ids.1, context: .background)?.state.status != "terminal")
        control.openAbort(1)
        try await harnessEventually { aborting.isSettled }
        try #require(aborting.result).get()
        #expect(try await w3Terminal(harness, ids.1).outcome.status == "aborted")
        #expect(try await runtime.ownedTasks(context: .background).isEmpty)
        _ = try await harness.abortTask(id: ids.0, context: .background)
        _ = try await harness.abortTask(id: ids.4, context: .background)
        try await harness.close(context: .background)
    }

    @Test func toolAdapterListsAndAbortsChildrenAndEndsWithInvocation() async throws {
        let control = W3LifetimeControl(), hold = control.definition()
        let setup = HarnessChatSetup(clock: control.clock), retained = Mutex<ToolExecutionApi?>(nil)
        try setup.registry.install(Extension(name: "worker", tasks: [AnyTaskDefinition(hold)]))
        try installHarnessTool(harnessTestTool(execute: { _, api, context in
            retained.withLock { $0 = api }
            let child = try await api.createTask(hold, input: 1, options: .init(ownership: .task(taskId: api.taskId)), context: context)
            #expect(try await api.ownedTasks(context: context).map(\.id) == [child])
            try await api.abortOwned(id: child, context: context)
            #expect(try await api.waitForTask(id: child, context: context).outcome.status == "aborted")
            #expect(try await api.ownedTasks(context: context).isEmpty)
            return .init(output: [])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "owned")])), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup)
        _ = try await opened.root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        let api = try #require(retained.withLock { $0 })
        await #expect(throws: (any Error).self) { _ = try await api.ownedTasks(context: .background) }
        await #expect(throws: (any Error).self) { try await api.abortOwned(id: api.taskId, context: .background) }
        try await opened.harness.close(context: .background)
    }

    @Test func abortOwnedKeepsRestartReasonWhileDefinitionIsMissing() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("owned-restart-wait.sqlite").path
        let control = W3LifetimeControl(), worker = control.definition(), runtimes = SessionTestLog<TaskRuntime>()
        let probe = harnessOneStep("test.w3.restart-probe") { _, runtime, context in
            runtimes.append(runtime)
            try await runtime.sleep(until: 1_000_000, context: context)
        }
        let first = try await harnessOpen([AnyTaskDefinition(probe), AnyTaskDefinition(worker)], storage: SqliteStorage.open(path: path), clock: control.clock)
        let root = try await first.root(context: .background)
        let ids = try await root.commit({ tx in
            let parent = try await tx.createTask(probe, input: 0, options: .init(ownership: .conversation()))
            let child = try await tx.createTask(worker, input: 1, options: .init(ownership: .task(taskId: parent), abandonOnRestart: true))
            return (parent, child)
        }, context: .background)
        try first.resume()
        try await harnessEventually { runtimes.count == 1 && control.runs.count == 1 }
        try await first.close(context: .background)
        let registry = Registry()
        let harness = try await harnessOpen([AnyTaskDefinition(probe)], storage: SqliteStorage.open(path: path), registry: registry, clock: control.clock)
        try harness.resume()
        try await harnessEventually { runtimes.count == 2 }
        try await harnessEventually { try await harness.getTask(id: ids.1, context: .background)?.abortReason == .restart }
        let runtime = runtimes.values[1]
        let aborting = settled { try await runtime.abortOwned(ids.1, context: .background) }
        for _ in 0..<100 { await Task.yield() }
        #expect(!aborting.isSettled)
        #expect(try await harness.getTask(id: ids.1, context: .background)?.abortReason == .restart)
        #expect(try await harness.getTask(id: ids.1, context: .background)?.state.status != "terminal")
        try registry.install(Extension(name: "worker", tasks: [AnyTaskDefinition(worker)]))
        #expect(try await w3Terminal(harness, ids.1).record.abortReason == .restart)
        #expect(control.aborts.values == [.restart])
        try await harnessEventually { aborting.isSettled }
        try #require(aborting.result).get()
        #expect(control.runs.count == 1)
        _ = try await harness.abortTask(id: ids.0, context: .background)
        try await harness.close(context: .background)
    }
}
