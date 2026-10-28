import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private func d1Sleeper(_ id: TaskID, until: Double, owner: TaskID? = nil) throws -> TaskRecord {
    TaskRecord(id: id, conversationId: rootConversationID, kind: "d1.sleep", version: 1,
        input: .number(0), state: .sleeping(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(count: 17)), until: until),
        owner: owner, memos: ["kept": "memo"], restarts: 3,
        trace: ["traceparent": "opaque parent", "baggage": "a=%2F,b=two words"],
        links: [["link": "first"], [:], ["link": "last"]], extensionFields: ["future": ["kept": true]])
}

private func d1Store(_ storage: any DurableStorage, _ records: [TaskRecord]) async throws {
    _ = try await storage.commit([.conversation(value: ConversationRecord(id: rootConversationID))] + records.map { .task(value: $0) }, context: .background)
}

private func d1SleepTask(_ runs: SessionTestLog<Int>, aborts: SessionTestLog<Int> = .init()) -> HarnessTestTask {
    harnessOneStep("d1.sleep", run: { task, runtime, context in
        runs.append(task.checkpoint.count)
        #expect(task.record.restarts == 3)
        #expect(task.record.trace?["traceparent"] == "opaque parent")
        #expect(task.record.links?.count == 3)
        #expect(task.record.memos == ["kept": "memo"])
        try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(17))) }, context: context)
    }, abort: { task, runtime, context in
        aborts.append(task.checkpoint.count)
        try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "d1")) }, context: context)
    })
}

@Suite struct D1SleepingSchedulerTests {
    @Test func sleepingToolCheckpointRetainsEventArguments() throws {
        let id = try TaskID(20), conversation = ConversationRecord(id: rootConversationID)
        let arguments: JSONObject = ["path": "saved.txt", "opaque": ["retained": true]]
        let record = TaskRecord(id: id, conversationId: rootConversationID, kind: "pi.tool", version: 1,
            input: .null, state: .sleeping(checkpoint: ["phase": "execute", "arguments": .object(arguments)], until: 10.5))
        let before = ConversationView(conversation: conversation, entries: [], docs: [:])
        let live = LiveState(tools: [ToolSlot(callId: "call", name: "read", taskId: id, status: .running)])
        let after = ConversationView(conversation: conversation, entries: [],
            docs: ["pi.live": try JSONValue(encoding: live).decode(JSONObject.self)])
        var held = Set<TaskID>()
        let events = try translateDurableEvents(conversationId: rootConversationID, before: before, after: after,
            viewOps: [], publication: CommitPublication(seq: Seq(1), changes: [.task(record)]), held: &held)
        let event = try #require(events.first)
        let json = try JSONValue(encoding: event)
        #expect(json["type"] == "tool_execution_start" && json["args"] == .object(arguments))
    }

    // v1.4.0 scheduler.ts:1358,1430,1482: a stored due sleep resumes at its checkpoint.
    @Test(arguments: [0.0, 100.0, 100.25])
    func dueRecoveryRetainsRecordFields(until: Double) async throws {
        let storage = MemoryStorage(), clock = TestClock(now: 101), runs = SessionTestLog<Int>()
        let id = try TaskID(20), record = try d1Sleeper(id, until: until)
        try await d1Store(storage, [record])
        let harness = try await harnessOpen([AnyTaskDefinition(d1SleepTask(runs))], storage: storage, clock: clock)
        #expect(runs.values.isEmpty)
        let inspection = try await harness.inspect(context: .background)
        guard case .ready(false)? = inspection.tasks.first?.state else { throw TaskDefinitionError("Due sleep was not ready") }
        try harness.resume()
        try await harnessEventually { try await harness.getTask(id: id, context: .background)?.state.status == "terminal" }
        let settled = try await harness.waitForTask(id: id, context: .background)
        #expect(runs.values == [17])
        // upstream scheduler.ts:2473-2477: terminal states remove restart counts.
        #expect(settled.record.storedRestarts == nil)
        #expect(settled.record.trace == record.trace && settled.record.links == record.links)
        #expect(settled.record.extensionFields == record.extensionFields)
        #expect(clock.pendingSleeperCount == 0)
        try await harness.close(context: .background)
    }

    // The integer clock must pass a fractional deadline. No phase holds an invocation during sleep.
    @Test func futureSleepIsVisibleAndRunsOnlyWhenDue() async throws {
        let storage = MemoryStorage(), clock = TestClock(now: 100), runs = SessionTestLog<Int>()
        let id = try TaskID(20), record = try d1Sleeper(id, until: 101.25)
        try await d1Store(storage, [record])
        let harness = try await harnessOpen([AnyTaskDefinition(d1SleepTask(runs))], storage: storage, clock: clock)
        let graph = try await harness.taskGraph(context: .background)
        #expect(graph.value.tasks[String(id.rawValue)]?.state == .sleeping(phase: "run", until: 101.25))
        #expect(try await storage.scanTasks(.init(status: .sleeping), limit: 10, cursor: nil, context: .background).items == [record])
        #expect(clock.pendingSleeperCount == 0)
        try harness.resume()
        try await harnessEventually { clock.pendingSleeperCount == 1 }
        let inspection = try await harness.inspect(context: .background)
        guard case .sleeping(let until)? = inspection.tasks.first?.state else { throw TaskDefinitionError("Future task was not sleeping") }
        #expect(until == 101.25 && runs.values.isEmpty)
        clock.advance(by: 1)
        #expect(try await harness.getTask(id: id, context: .background)?.state == record.state)
        #expect(runs.values.isEmpty)
        clock.advance(by: 1)
        try await harnessEventually { try await harness.getTask(id: id, context: .background)?.state.status == "terminal" }
        #expect(runs.values == [17])
        await graph.waitUntilIdle()
        #expect(graph.value.tasks.isEmpty)
        graph.dispose()
        try await harness.close(context: .background)
    }

    // v1.4.0 harness-sleep.test.ts:140,208: close cancels the wait and leaves the saved sleep intact.
    @Test(arguments: ["sqlite", "jsonl"])
    func sleepSurvivesCloseAndReopen(format: String) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        func openStorage() async throws -> any DurableStorage {
            if format == "sqlite" { return try await SqliteStorage.open(path: directory.appendingPathComponent("sleep.sqlite").path) }
            return try await JsonlStorage.open(directory: directory.appendingPathComponent("jsonl").path)
        }
        let storage = try await openStorage(), clock = TestClock(now: 10), runs = SessionTestLog<Int>()
        let id = try TaskID(20), record = try d1Sleeper(id, until: 20.5)
        try await d1Store(storage, [record])
        let harness = try await harnessOpen([AnyTaskDefinition(d1SleepTask(runs))], storage: storage, clock: clock)
        try harness.resume()
        try await harnessEventually { clock.pendingSleeperCount == 1 }
        try await harness.close(context: .background)
        try await harnessEventually { clock.pendingSleeperCount == 0 }
        let reopenedStorage = try await openStorage()
        #expect(try await reopenedStorage.task(id, context: .background) == record)
        let reopened = try await harnessOpen([AnyTaskDefinition(d1SleepTask(runs))], storage: reopenedStorage, clock: clock)
        try reopened.resume()
        try await harnessEventually { clock.pendingSleeperCount == 1 }
        clock.advance(by: 11)
        try await harnessEventually { try await reopened.getTask(id: id, context: .background)?.state.status == "terminal" }
        #expect(runs.values == [17])
        try await reopened.close(context: .background)
    }

    // v1.4.0 harness-sleep.test.ts:339: an abort mark bypasses the deadline.
    @Test func abortEndsSleepAndRetainsRecordFields() async throws {
        let storage = MemoryStorage(), clock = TestClock(), runs = SessionTestLog<Int>(), aborts = SessionTestLog<Int>()
        let id = try TaskID(20), record = try d1Sleeper(id, until: 1_000_000.5)
        try await d1Store(storage, [record])
        let harness = try await harnessOpen([AnyTaskDefinition(d1SleepTask(runs, aborts: aborts))], storage: storage, clock: clock)
        try harness.resume()
        try await harnessEventually { clock.pendingSleeperCount == 1 }
        #expect(try await harness.abortTask(id: id, context: .background) == .marked)
        try await harnessEventually { try await harness.getTask(id: id, context: .background)?.state.status == "terminal" }
        let settled = try await harness.waitForTask(id: id, context: .background)
        #expect(settled.outcome == .aborted(reason: "d1"))
        // upstream scheduler.ts:2473-2477: terminal states remove restart counts.
        #expect(settled.record.storedRestarts == nil)
        #expect(settled.record.trace == record.trace && settled.record.links == record.links)
        #expect(settled.record.extensionFields == record.extensionFields)
        #expect(runs.values.isEmpty && aborts.values == [17] && clock.now() == 0)
        try await harnessEventually { clock.pendingSleeperCount == 0 }
        try await harness.close(context: .background)
    }

    // v1.4.0 scheduler.ts:1482: any scheduling pass sees a due sleep before its timer fires.
    @Test func schedulingPassChecksClockBeforeTimerFires() async throws {
        let storage = MemoryStorage(), clock = TestClock(), time = Mutex<Int64>(0), runs = SessionTestLog<Int>()
        let id = try TaskID(20)
        try await d1Store(storage, [d1Sleeper(id, until: 10.5)])
        let definition = d1SleepTask(runs), registry = Registry()
        try registry.install(Extension(name: "d1", tasks: [AnyTaskDefinition(definition)]))
        let harness = try await Harness.open(storage: storage, options: .init(models: FakeDurableModels(), registry: registry,
            clock: clock, now: { time.withLock { $0 } }), context: .background)
        try harness.resume()
        try await harnessEventually { clock.pendingSleeperCount == 1 }
        time.withLock { $0 = 11 }
        try registry.install(Extension(name: "d1", tasks: [AnyTaskDefinition(definition)]))
        try await harnessEventually { try await harness.getTask(id: id, context: .background)?.state.status == "terminal" }
        #expect(runs.values == [17] && clock.now() == 0)
        try await harness.close(context: .background)
    }

    @Test func completingOwnerWaitsForSleepingChild() async throws {
        let storage = MemoryStorage(), clock = TestClock(), runs = SessionTestLog<Int>()
        let parent = try TaskID(20), child = try TaskID(21)
        let owner = TaskRecord(id: parent, conversationId: rootConversationID, kind: "d1.owner", version: 1,
            input: .null, state: .completing(outcome: .completed(result: .null)))
        try await d1Store(storage, [owner, d1Sleeper(child, until: 10.5, owner: parent)])
        let harness = try await harnessOpen([AnyTaskDefinition(d1SleepTask(runs))], storage: storage, clock: clock)
        try harness.resume()
        try await d1LabeledWait("owner: timer registration", harness: harness, clock: clock) { clock.pendingSleeperCount == 1 }
        #expect(try await harness.getTask(id: parent, context: .background)?.state.status == "completing")
        clock.advance(by: 11)
        try await d1LabeledWait("owner: terminal after deadline", harness: harness, clock: clock) { try await harness.getTask(id: parent, context: .background)?.state.status == "terminal" }
        #expect(runs.values == [17])
        try await harness.close(context: .background)
    }

    @Test func waitingTaskIncludesSleepingDependency() async throws {
        let storage = MemoryStorage(), clock = TestClock(), runs = SessionTestLog<Int>()
        let waiter = try TaskID(20), sleeper = try TaskID(21)
        let waiting = TaskRecord(id: waiter, conversationId: rootConversationID, kind: "d1.waiter", version: 1,
            input: .number(0), state: .waiting(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(count: 23)), on: [sleeper], policy: .allSettled))
        try await d1Store(storage, [waiting, d1Sleeper(sleeper, until: 10.5)])
        let definition = harnessOneStep("d1.waiter") { task, runtime, context in
            runs.append(task.checkpoint.count)
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }
        let harness = try await harnessOpen([AnyTaskDefinition(definition), AnyTaskDefinition(d1SleepTask(runs))], storage: storage, clock: clock)
        try harness.resume()
        try await d1LabeledWait("waiter: timer registration", harness: harness, clock: clock) { clock.pendingSleeperCount == 1 }
        let inspection = try await harness.inspect(context: .background)
        guard case .waiting(let on)? = inspection.tasks.first(where: { $0.record.id == waiter })?.state else { throw TaskDefinitionError("Dependency was not retained") }
        #expect(on == [sleeper] && runs.values.isEmpty)
        clock.advance(by: 11)
        try await d1LabeledWait("waiter: terminal after deadline", harness: harness, clock: clock) { try await harness.getTask(id: waiter, context: .background)?.state.status == "terminal" }
        #expect(runs.values == [17, 23])
        try await harness.close(context: .background)
    }
}

private func d1LabeledWait(_ label: String, harness: Harness, clock: TestClock,
                           condition: @escaping @Sendable () async throws -> Bool) async throws {
    do {
        try await harnessEventually(condition)
    } catch {
        let detail = harness.tasks.state.withLock { state in
            "live=\(state.live.values.map { "\($0.id.rawValue):\($0.state.status)" }.sorted()) " +
            "runnable=\(state.runnable.map(\.rawValue).sorted()) invocations=\(state.invocations.keys.map(\.rawValue).sorted()) " +
            "sleepAt=\(String(describing: state.sleepAt)) dirty=\(state.dirty) pumping=\(state.pumping) " +
            "wakeScheduled=\(state.wakeScheduled) wakeDirty=\(state.wakeDirty) " +
            "recovery=\(state.reconcilingWork) finalize=\(state.finalizeChecks.map(\.rawValue).sorted())"
        }
        throw TaskDefinitionError("\(label) expired: now=\(clock.now()) work=\(clock.pendingSleeperCount) retention=\(clock.pendingDocumentRetentionCount) \(detail); \(error)")
    }
}
