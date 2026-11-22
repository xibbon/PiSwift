import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private let answerSchema: JSONValue = [
    "type": "object", "properties": ["text": ["type": "string"]], "required": ["text"],
]
private let answerName = "test.answer"

private struct AskInput: Codable, Sendable {
    let keys: [String]
    var until: Double? = nil
}

private struct AskCheckpoint: TaskCheckpoint {
    enum Phase: String, Codable, Sendable { case ask, answered }
    var phase: Phase = .ask
}

private typealias AskTask = TaskDefinition<AskInput, AskCheckpoint, JSONValue, NoTaskHooks>

private func makeAnswer() throws -> SignalToken<JSONValue> {
    try defineSignal(name: answerName, version: 1, schema: answerSchema)
}

private func signalOutcome(_ key: String) -> JSONValue {
    ["reason": "signal", "signal": .string(answerName), "key": .string(key)]
}

private func askTask(_ answer: SignalToken<JSONValue>) -> AskTask {
    AskTask(name: "test.ask", version: 1, initial: { _ in AskCheckpoint() }, phase: { task, runtime, context in
        switch task.checkpoint.phase {
        case .ask:
            try await runtime.sleep(signals: task.input.keys.map(answer.key), until: task.input.until,
                checkpoint: JSONValue(encoding: AskCheckpoint(phase: .answered)), context: context)
        case .answered:
            var states: [JSONValue] = []
            for key in task.input.keys {
                states.append(try await signalState(runtime, answer, key, context))
            }
            let wake = try task.record.state.wakeReason().map { try JSONValue(encoding: $0) }
            var result: JSONObject = ["states": .array(states)]
            result["wake"] = wake
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .object(result))) }, context: context)
        }
    }, abort: { _, runtime, context in
        try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "test")) }, context: context)
    })
}

private func signalState(_ runtime: TaskRuntime, _ token: SignalToken<JSONValue>,
                         _ key: String, _ context: ChordContext) async throws -> JSONValue {
    switch try await runtime.readSignal(token, key: key, context: context) {
    case .value(let value): ["value": value]
    case .expired: ["expired": true]
    case nil: .null
    }
}

private func openSignals(_ tasks: [AnyTaskDefinition], storage: any DurableStorage = MemoryStorage(),
                         clock: any DurableClock = SystemDurableClock(),
                         onWake: @escaping @Sendable (HarnessWake) -> Void = { _ in }) async throws -> Harness {
    let registry = Registry()
    try registry.install(Extension(name: "signal-tests", tasks: tasks))
    return try await Harness.open(storage: storage,
        options: .init(models: FakeDurableModels(), registry: registry, clock: clock, onWake: onWake), context: .background)
}

private func startAsk(_ harness: Harness, _ task: AskTask, keys: [String], until: Double? = nil) async throws -> TaskID {
    let root = try await harness.root(context: .background)
    return try await root.commit({ tx in
        try await tx.createTask(task, input: AskInput(keys: keys, until: until), options: .init(ownership: .conversation()))
    }, context: .background)
}

private func waitForSleep(_ harness: Harness, _ id: TaskID) async throws {
    try await harnessEventually {
        try await harness.getTask(id: id, context: .background)?.state.status == "sleeping"
            && !harness.wake().active
    }
}

private func withSignalDatabase(_ body: (String) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory.appendingPathComponent("session.sqlite").path)
}

@Suite struct HarnessSignalsTests {
    // Upstream harness-signals.test.ts:85.
    @Test func validatesDefinitionAndKeys() throws {
        let schema: JSONValue = ["type": "string"]
        #expect(throws: (any Error).self) {
            let _: SignalToken<JSONValue> = try defineSignal(name: "a/b", version: 1, schema: schema)
        }
        #expect(throws: (any Error).self) {
            let _: SignalToken<JSONValue> = try defineSignal(name: "a", version: 0, schema: schema)
        }
        for type in ["bigint", "bytes"] {
            #expect(throws: (any Error).self) {
                let _: SignalToken<JSONValue> = try defineSignal(name: "a", version: 1,
                    schema: ["type": "object", "properties": ["field": ["type": .string(type)]]])
            }
        }
        #expect(throws: (any Error).self) {
            let _: SignalToken<JSONValue> = try defineSignal(name: "a", version: 1,
                schema: ["type": "object", "dependencies": [
                    "a": ["b"], "b": ["type": "object", "properties": ["field": ["type": "bigint"]]],
                ]])
        }
        let _: SignalToken<JSONValue> = try defineSignal(name: "a", version: 1,
            schema: ["type": "object", "examples": [["type": "bigint"]]])
        let answer = try makeAnswer()
        #expect(throws: (any Error).self) { try answer.key("") }
        #expect(try answer.key("k") == SignalKey(signal: answerName, key: "k"))
    }

    @Test(arguments: [nil, 2_000] as [Double?])
    func signalSleepGraphStateRoundTrips(until: Double?) throws {
        let key = try makeAnswer().key("a")
        let state = TaskGraphState.signalSleeping(phase: "answered", until: until, signals: [key])
        let json = try JSONValue(encoding: state)
        var expected: JSONObject = [
            "status": "sleeping", "phase": "answered", "signals": [["signal": "test.answer", "key": "a"]],
        ]
        expected["until"] = until.map(JSONValue.number)
        #expect(json == .object(expected))
        #expect(try json.decode(TaskGraphState.self) == state)
    }

    // Upstream harness-signals.test.ts:102, 161 and example 38.
    @Test func deliveryResultsAndEarlyWake() async throws {
        let answer = try makeAnswer()
        let ask = askTask(answer)
        let harness = try await openSignals([AnyTaskDefinition(ask)])
        let id = try await startAsk(harness, ask, keys: ["a"])
        #expect(try await harness.commit({ tx in
            try await tx.signal(TaskID(999_999), token: answer, key: "a", value: ["text": "x"])
        }, context: .background) == .not_found)
        #expect(try await harness.commit({ tx in
            try await tx.signal(id, token: answer, key: "a", value: ["text": 1])
        }, context: .background) == .invalid)
        let open: SignalToken<JSONValue> = try defineSignal(name: "test.open", version: 1, schema: answerSchema)
        #expect(try await harness.commit({ tx in
            try await tx.signal(id, token: open, key: "a", value: ["text": "x", "n": .number(.nan)])
        }, context: .background) == .invalid)

        // Deliver and retry while paused to keep scheduling from ending the task between the commits.
        #expect(try await harness.commit({ tx in
            try await tx.signal(id, token: answer, key: "a", value: ["text": "early"])
        }, context: .background) == .delivered)
        #expect(try await harness.commit({ tx in
            try await tx.signal(id, token: answer, key: "a", value: ["text": "again"])
        }, context: .background) == .duplicate)
        let receipt = try await harness.waitForTask(id: id, context: .background)
        #expect(receipt.outcome == .completed(result: [
            "wake": signalOutcome("a"), "states": [["value": ["text": "early"]]],
        ]))
        #expect(try await harness.signal(taskId: id, token: answer, key: "b",
            value: ["text": "late"], context: .background) == .closed)
        try await harness.close(context: .background)
    }

    // Upstream harness-signals.test.ts:120, 387.
    @Test(arguments: [false, true])
    func abortClosesDelivery(parked: Bool) async throws {
        let answer = try makeAnswer()
        let ask = askTask(answer)
        let harness = try await openSignals([AnyTaskDefinition(ask)])
        let id = try await startAsk(harness, ask, keys: ["a"])
        if parked {
            try harness.resume()
            try await waitForSleep(harness, id)
        }
        #expect(try await harness.abortTask(id: id, context: .background) == .marked)
        #expect(try await harness.signal(taskId: id, token: answer, key: "a",
            value: ["text": "yes"], context: .background) == .closed)
        #expect(try await harness.waitForTask(id: id, context: .background).outcome == .aborted(reason: "test"))
        try await harness.close(context: .background)
    }

    // Upstream harness-signals.test.ts:128.
    @Test func concurrentOperationsInOneCommitShareTheirResults() async throws {
        let answer = try makeAnswer()
        let ask = askTask(answer)
        let storage = ControlledStorage()
        // Seed before open. A task created through this Session is a cache hit,
        // which would bypass the held backend reads and make admission depend on task scheduling.
        let id = try TaskID(10)
        let record = TaskRecord(id: id, conversationId: rootConversationID, kind: ask.name, version: 1,
            input: try JSONValue(encoding: AskInput(keys: ["a", "b"])),
            state: .pending(checkpoint: try JSONValue(encoding: AskCheckpoint())))
        _ = try await storage.commitOne([.conversation(value: ConversationRecord(id: rootConversationID)),
            .task(value: record)], context: .background)
        let harness = try await openSignals([AnyTaskDefinition(ask)], storage: storage)
        let hold = await storage.holdTaskRead()
        let results = try await harness.commit({ tx in
            async let first = tx.signal(id, token: answer, key: "a", value: ["text": "first"])
            async let second = tx.signal(id, token: answer, key: "a", value: ["text": "second"])
            async let other = tx.signal(id, token: answer, key: "b", value: ["text": "bee"])
            await tx.waitUntilPendingOperations(3)
            await hold.release()
            return try await [first, second, other]
        }, context: .background)
        #expect(results.filter { $0 == .delivered }.count == 2)
        #expect(results[2] == .delivered)
        #expect(results.filter { $0 == .duplicate }.count == 1)
        let winner: JSONValue = results[0] == .delivered ? "first" : "second"
        let receipt = try await harness.waitForTask(id: id, context: .background)
        #expect(receipt.outcome == .completed(result: [
            "wake": signalOutcome("a"), "states": [["value": ["text": winner]], ["value": ["text": "bee"]]],
        ]))
        try await harness.close(context: .background)
    }

    // Upstream harness-signals.test.ts:148.
    @Test func sequentialDeliveryReadsAfterWriteAndRollsBack() async throws {
        let answer = try makeAnswer()
        let ask = askTask(answer)
        let harness = try await openSignals([AnyTaskDefinition(ask)])
        let id = try await startAsk(harness, ask, keys: ["a"])
        await #expect(throws: ReadAfterWrite.self) {
            try await harness.commit({ tx in
                _ = try await tx.signal(id, token: answer, key: "a", value: ["text": "one"])
                _ = try await tx.signal(id, token: answer, key: "b", value: ["text": "two"])
            }, context: .background)
        }
        #expect(try await harness.getTask(id: id, context: .background)?.memos == nil)
        try await harness.close(context: .background)
    }

    // Separate host commits can race on the same key.
    @Test func concurrentHostDeliveriesHaveOneWinner() async throws {
        let answer = try makeAnswer()
        // Keep this task parked on a different key until all host commits finish.
        let ask = askTask(answer)
        let harness = try await openSignals([AnyTaskDefinition(ask)])
        let id = try await startAsk(harness, ask, keys: ["parked"])
        try harness.resume()
        try await waitForSleep(harness, id)
        let count = 24
        let results = try await withThrowingTaskGroup(of: SignalResult.self) { group in
            for index in 0..<count {
                group.addTask {
                    try await harness.signal(taskId: id, token: answer, key: "race",
                        value: ["text": .string(String(index))], context: .background)
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.filter { $0 == .delivered }.count == 1)
        #expect(results.filter { $0 == .duplicate }.count == count - 1)
        #expect(try await harness.getTask(id: id, context: .background)?.state.status == "sleeping")
        try await harness.close(context: .background)
    }

    @Test func deliveryWaitsForAnUnpublishedSignal() async throws {
        let answer = try makeAnswer()
        let ask = askTask(answer)
        let h = try await openTestSession()
        let conversation = try await createConversation(h.session)
        let id = try await h.session.commit({ tx in
            try await tx.createTask(ask, input: AskInput(keys: ["a"]),
                options: .init(ownership: .conversation(), conversationId: conversation))
        }, context: .background)
        let hold = await h.storage.holdCommits()
        let first = Task {
            try await h.session.commit({ tx in
                try await tx.signal(id, token: answer, key: "a", value: ["text": "first"])
            }, context: .background)
        }
        await hold.waitUntilEntered()
        let entered = SessionTestGate()
        let decisions = SessionTestLog<SignalResult>()
        let second = Task {
            try await h.session.commit({ tx in
                async let pending = tx.signal(id, token: answer, key: "a", value: ["text": "second"])
                await tx.waitUntilPendingOperations(1)
                entered.release()
                let decision = try await pending
                decisions.append(decision)
                return decision
            }, context: .background)
        }
        await entered.wait()
        #expect(decisions.values.isEmpty)
        await hold.release()
        #expect(try await first.value == .delivered)
        #expect(try await second.value == .duplicate)
        try await h.session.close(context: .background)
    }

    // Upstream harness-signals.test.ts:177 and example 38.
    @Test func signalOnlySleepHasNoInvocationOrDeadline() async throws {
        let answer = try makeAnswer()
        let ask = askTask(answer)
        let harness = try await openSignals([AnyTaskDefinition(ask)])
        let graph = try await harness.taskGraph(context: .background)
        let id = try await startAsk(harness, ask, keys: ["a", "b"])
        try harness.resume()
        try await waitForSleep(harness, id)
        let node = try #require(graph.value.tasks[String(id.rawValue)])
        #expect(try node.sleepSignals() == [answer.key("a"), answer.key("b")])
        let inspection = try await harness.inspect(context: .background)
        guard case .sleeping(let until) = inspection.tasks.first(where: { $0.record.id == id })?.state else {
            Issue.record("Expected a sleeping task")
            return
        }
        #expect(until == nil)
        #expect(harness.tasks.state.withLock { $0.invocations[id] == nil })
        #expect(harness.wake() == HarnessWake(active: false))
        #expect(try await harness.signal(taskId: id, token: answer, key: "b",
            value: ["text": "bee"], context: .background) == .delivered)
        #expect(try await harness.waitForTask(id: id, context: .background).outcome == .completed(result: [
            "wake": signalOutcome("b"), "states": [.null, ["value": ["text": "bee"]]],
        ]))
        graph.dispose()
        try await harness.close(context: .background)
    }

    // Upstream harness-signals.test.ts:207, 225.
    @Test(arguments: [false, true])
    func deadlineExpiresSignals(deliverBeforeReserve: Bool) async throws {
        let clock = TestClock(now: 1_000)
        let answer = try makeAnswer()
        let ask = askTask(answer)
        let harness = try await openSignals([AnyTaskDefinition(ask)], clock: clock)
        let id = try await startAsk(harness, ask, keys: ["a"], until: 2_000)
        try harness.resume()
        try await waitForSleep(harness, id)
        #expect(harness.wake() == HarnessWake(active: false, at: 2_000))
        clock.advance(by: 1_000)
        if deliverBeforeReserve {
            #expect(try await harness.signal(taskId: id, token: answer, key: "a",
                value: ["text": "late"], context: .background) == .closed)
        } else {
            try harness.resume()
        }
        #expect(try await harness.waitForTask(id: id, context: .background).outcome == .completed(result: [
            "wake": ["reason": "expired"], "states": [["expired": true]],
        ]))
        #expect(try await harness.signal(taskId: id, token: answer, key: "a",
            value: ["text": "late"], context: .background) == .closed)
        try await harness.close(context: .background)
    }
}

extension HarnessSignalsTests {
    // Upstream harness-signals.test.ts:241, 342.
    @Test(arguments: ["consumed", "expired", "empty"])
    func rejectsInvalidNextSleep(mode: String) async throws {
        let clock = TestClock(now: 1_000)
        let answer = try makeAnswer()
        let key = try answer.key("a")
        let task = harnessOneStep("test.retry-sleep") { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                try await runtime.sleep(signals: mode == "empty" ? [] : [key],
                    until: mode == "expired" ? 2_000 : nil,
                    checkpoint: JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined)), context: context)
            case .joined:
                try await runtime.sleep(signals: [key], checkpoint: JSONValue(encoding: task.checkpoint), context: context)
            }
        }
        let harness = try await openSignals([AnyTaskDefinition(task)], clock: clock)
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, task)
        if mode == "consumed" {
            #expect(try await harness.signal(taskId: id, token: answer, key: "a",
                value: ["text": "once"], context: .background) == .delivered)
        } else if mode == "expired" {
            try harness.resume()
            try await waitForSleep(harness, id)
            clock.advance(by: 1_000)
        }
        let receipt = try await harness.waitForTask(id: id, context: .background)
        guard case .faulted(let error, _) = receipt.outcome else {
            Issue.record("Expected sleep validation to fault the task")
            try await harness.close(context: .background)
            return
        }
        switch mode {
        case "consumed": #expect(error.message.contains("already woke a wait"))
        case "expired": #expect(error.message.contains("expired"))
        default: #expect(error.message.contains("until") && error.message.contains("signals"))
        }
        try await harness.close(context: .background)
    }

    // Upstream harness-signals.test.ts:291.
    @Test func prefersKeyOrderAndKeepsLosingValue() async throws {
        let answer = try makeAnswer()
        let keys = try ["a", "b"].map(answer.key)
        let task = harnessOneStep("test.two-sleeps") { task, runtime, context in
            switch (task.checkpoint.phase, task.checkpoint.count) {
            case (.run, _):
                try await runtime.sleep(signals: keys,
                    checkpoint: JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined)), context: context)
            case (.joined, 0):
                #expect(try task.record.state.wakeReason() == .signal(signal: answerName, key: "a"))
                #expect(try await signalState(runtime, answer, "b", context) == ["value": ["text": "bee"]])
                try await runtime.sleep(signals: [keys[1]],
                    checkpoint: JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined, count: 1)), context: context)
            case (.joined, _):
                #expect(try task.record.state.wakeReason() == .signal(signal: answerName, key: "b"))
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
            }
        }
        let harness = try await openSignals([AnyTaskDefinition(task)])
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, task)
        for (key, text) in [("b", "bee"), ("a", "ay")] {
            #expect(try await harness.commit({ tx in
                try await tx.signal(id, token: answer, key: key, value: ["text": .string(text)])
            }, context: .background) == .delivered)
        }
        #expect(try await harness.waitForTask(id: id, context: .background).outcome == .completed(result: .null))
        try await harness.close(context: .background)
    }

    // Upstream harness-signals.test.ts:398, 433.
    @Test(arguments: ["newer", "no-migration", "migrates"])
    func readsVersionedValues(mode: String) async throws {
        let name = "test.versioned"
        let numeric: JSONValue = ["type": "object", "properties": ["n": ["type": "integer"]], "required": ["n"]]
        let string: JSONValue = ["type": "object", "properties": ["n": ["type": "string"]], "required": ["n"]]
        let older: SignalToken<JSONValue> = try defineSignal(name: name, version: 1,
            schema: mode == "migrates" ? string : numeric)
        let newer: SignalToken<JSONValue> = try defineSignal(name: name, version: 2, schema: numeric)
        let migrating: SignalToken<JSONValue> = try defineSignal(name: name, version: 2, schema: numeric) { value, version in
            #expect(version == 1)
            let text = try #require(value["n"]?.stringValue)
            return ["n": .number(try #require(Double(text)))]
        }
        let put = mode == "newer" ? newer : older
        let get = switch mode { case "newer": older; case "migrates": migrating; default: newer }
        let task = harnessOneStep("test.read-versions") { _, runtime, context in
            if mode == "migrates" {
                #expect(try await signalState(runtime, get, "k", context) == ["value": ["n": 42]])
            } else {
                do {
                    _ = try await runtime.readSignal(get, key: "k", context: context)
                    Issue.record("Expected the read to reject the saved version")
                } catch {
                    #expect(String(describing: error).contains(mode == "newer" ? "newer than 1" : "no migration from version 1"))
                }
            }
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }
        let harness = try await openSignals([AnyTaskDefinition(task)])
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, task)
        #expect(try await harness.signal(taskId: id, token: put, key: "k",
            value: ["n": mode == "migrates" ? "42" : 2], context: .background) == .delivered)
        #expect(try await harness.waitForTask(id: id, context: .background).outcome == .completed(result: .null))
        try await harness.close(context: .background)
    }

    // Upstream harness-signals.test.ts:463.
    @Test func ownSignalAndSleepCommitTogether() async throws {
        let answer = try makeAnswer()
        let key = try answer.key("self")
        let task = harnessOneStep("test.self-signal") { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                try await runtime.commit({ tx, _ in
                    #expect(try await tx.signal(runtime.taskId, token: answer, key: "self",
                        value: ["text": "me"]) == .delivered)
                    return try .sleeping(checkpoint: JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined)),
                        until: nil, signals: [key])
                }, context: context)
            case .joined:
                let wake = try JSONValue(encoding: task.record.state.wakeReason())
                #expect(try await signalState(runtime, answer, "self", context) == ["value": ["text": "me"]])
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: wake)) }, context: context)
            }
        }
        let harness = try await openSignals([AnyTaskDefinition(task)])
        let id = try await harnessStart(harness.root(context: .background), task)
        #expect(try await harness.waitForTask(id: id, context: .background).outcome == .completed(result: signalOutcome("self")))
        try await harness.close(context: .background)
    }

    // Upstream harness-signals.test.ts:556.
    @Test func signalSleepSurvivesReopenAndDeliveryMakesItActive() async throws {
        try await withSignalDatabase { path in
            let answer = try makeAnswer()
            let ask = askTask(answer)
            let definitions = [AnyTaskDefinition(ask)]
            let first = try await openSignals(definitions, storage: SqliteStorage.open(path: path))
            let id = try await startAsk(first, ask, keys: ["a"])
            try first.resume()
            try await waitForSleep(first, id)
            try await first.close(context: .background)

            let reopened = try await openSignals(definitions, storage: SqliteStorage.open(path: path))
            try await waitForSleep(reopened, id)
            #expect(reopened.wake() == HarnessWake(active: false))
            #expect(try await reopened.commit({ tx in
                try await tx.signal(id, token: answer, key: "a", value: ["text": "later"])
            }, context: .background) == .delivered)
            try await harnessEventually { reopened.wake().active }
            #expect(try await reopened.waitForTask(id: id, context: .background).outcome == .completed(result: [
                "wake": signalOutcome("a"), "states": [["value": ["text": "later"]]],
            ]))
            try await reopened.close(context: .background)
        }
    }

    // Upstream harness-signals.test.ts:576.
    @Test func recommittingWokenCheckpointKeepsRestartCount() async throws {
        let seen = SessionTestLog<Double>()
        let checkpoint = try JSONValue(encoding: HarnessTaskCheckpoint())
        let next = try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined))
        let definition = harnessOneStep("test.recommit-wake") { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                try await runtime.commit({ _, _ in .running(checkpoint: checkpoint) }, context: context)
                let record = try #require(try await runtime.getTask(runtime.taskId, context: context))
                seen.append(record.restarts)
                #expect(try record.state.wakeReason() == .time())
                try await runtime.commit({ _, _ in .running(checkpoint: next) }, context: context)
            case .joined:
                let record = try #require(try await runtime.getTask(runtime.taskId, context: context))
                seen.append(record.restarts)
                #expect(try record.state.wakeReason() == nil)
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
            }
        }
        try await withSignalDatabase { path in
            let storage = try await SqliteStorage.open(path: path)
            let id = try TaskID(10)
            let wake: JSONValue = ["reason": "time"]
            let record = TaskRecord(id: id, conversationId: rootConversationID, kind: definition.name, version: 1,
                input: 0, state: .running(checkpoint: checkpoint, extensions: ["wake": wake]))
            _ = try await storage.commitOne([.conversation(value: ConversationRecord(id: rootConversationID)),
                .task(value: record)], context: .background)
            let harness = try await openSignals([AnyTaskDefinition(definition)], storage: storage)
            #expect(try await harness.getTask(id: id, context: .background)?.state ==
                .pending(checkpoint: checkpoint, extensions: ["wake": wake]))
            #expect(try await harness.waitForTask(id: id, context: .background).outcome == .completed(result: .null))
            #expect(seen.values == [1, 0])
            try await harness.close(context: .background)
        }
    }

    // Upstream harness-signals.test.ts:627.
    @Test func signalWakeSurvivesSameCheckpointAndReopen() async throws {
        let answer = try makeAnswer()
        let key = try answer.key("k")
        let seen = SessionTestLog<WakeReason?>()
        let checkpoint: JSONValue = ["phase": "joined", "count": 0, "ids": []]
        let isFirst = Mutex(true)
        let task = harnessOneStep("test.keep-wake") { task, runtime, context in
            switch (task.checkpoint.phase, task.checkpoint.count) {
            case (.run, _):
                try await runtime.sleep(signals: [key], checkpoint: checkpoint, context: context)
            case (.joined, 0):
                seen.append(try task.record.state.wakeReason())
                try await runtime.commit({ _, _ in .running(checkpoint: checkpoint) }, context: context)
                seen.append(try await runtime.getTask(runtime.taskId, context: context)?.state.wakeReason())
                let first = isFirst.withLock { previous in defer { previous = false }; return previous }
                if first {
                    let aborted = SessionTestGate()
                    let registration = runtime.signal.addAbortListener { _ in aborted.release() }
                    defer { runtime.signal.removeAbortListener(registration) }
                    if runtime.signal.aborted { aborted.release() }
                    await aborted.wait()
                    try runtime.signal.throwIfAborted()
                }
                try await runtime.commit({ _, _ in
                    .running(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined, count: 1)))
                }, context: context)
            case (.joined, _):
                seen.append(try task.record.state.wakeReason())
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
            }
        }
        try await withSignalDatabase { path in
            let definitions = [AnyTaskDefinition(task)]
            let first = try await openSignals(definitions, storage: SqliteStorage.open(path: path))
            let id = try await harnessStart(first.root(context: .background), task)
            #expect(try await first.signal(taskId: id, token: answer, key: "k",
                value: ["text": "go"], context: .background) == .delivered)
            try await harnessEventually { seen.count == 2 }
            let wake = WakeReason.signal(signal: answerName, key: "k")
            #expect(seen.values == [wake, wake])
            try await first.close(context: .background)

            let reopened = try await openSignals(definitions, storage: SqliteStorage.open(path: path))
            #expect(try await reopened.getTask(id: id, context: .background)?.state ==
                .pending(checkpoint: checkpoint, extensions: ["wake": signalOutcome("k")]))
            #expect(try await reopened.waitForTask(id: id, context: .background).outcome == .completed(result: .null))
            #expect(seen.values == [wake, wake, wake, wake, nil])
            try await reopened.close(context: .background)
        }
    }
}

private struct PersonQuestion: Codable, Sendable {
    let question: String
}

private typealias AskPersonTask = TaskDefinition<PersonQuestion, AskCheckpoint, JSONValue, NoTaskHooks>

@Suite struct UpstreamSignalExamplesTests {
    // Upstream test/examples/38-signals.ts.
    @Test func greeterAcceptsAnEarlyGreetingAndSleepsForALaterOne() async throws {
        struct Greeting: Codable, Sendable {
            let text: String
        }
        typealias Greeter = TaskDefinition<Bool, AskCheckpoint, String, NoTaskHooks>
        let greeting: SignalToken<Greeting> = try defineSignal(name: "example.greeting", version: 1, schema: answerSchema)
        let key = try greeting.key("hello")
        let beginSleep = SessionTestGate()
        let greeter = Greeter(name: "example.greeter", version: 1, initial: { _ in AskCheckpoint() },
            phase: { task, runtime, context in
                switch task.checkpoint.phase {
                case .ask:
                    if task.input { await beginSleep.wait() }
                    try await runtime.sleep(signals: [key], checkpoint: JSONValue(encoding: AskCheckpoint(phase: .answered)),
                        context: context)
                case .answered:
                    #expect(try task.record.state.wakeReason() == .signal(signal: "example.greeting", key: "hello"))
                    guard case .value(let value) = try await runtime.readSignal(greeting, key: "hello", context: context) else {
                        throw TaskDefinitionError("Missing greeting")
                    }
                    try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .string(value.text))) },
                        context: context)
                }
            }, abort: { _, runtime, context in
                try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
            })
        let harness = try await openSignals([AnyTaskDefinition(greeter)])
        let root = try await harness.root(context: .background)
        func create(hold: Bool) async throws -> TaskID {
            try await root.commit({ tx in
                try await tx.createTask(greeter, input: hold, options: .init(ownership: .conversation()))
            }, context: .background)
        }
        let early = try await create(hold: true)
        defer { beginSleep.release() }
        #expect(try await harness.signal(taskId: early, token: greeting, key: "hello",
            value: Greeting(text: "hi there"), context: .background) == .delivered)
        #expect(try await harness.signal(taskId: early, token: greeting, key: "hello",
            value: Greeting(text: "hi again"), context: .background) == .duplicate)
        let rawGreeting: SignalToken<JSONValue> = try defineSignal(name: "example.greeting", version: 1, schema: answerSchema)
        #expect(try await harness.signal(taskId: early, token: rawGreeting, key: "other",
            value: ["text": 42], context: .background) == .invalid)
        #expect(try await harness.signal(taskId: TaskID(999_999), token: greeting, key: "hello",
            value: Greeting(text: "?"), context: .background) == .not_found)
        beginSleep.release()
        #expect(try await harness.waitForTask(id: early, context: .background).outcome == .completed(result: "hi there"))
        #expect(try await harness.signal(taskId: early, token: greeting, key: "hello",
            value: Greeting(text: "too late"), context: .background) == .closed)

        let late = try await create(hold: false)
        try await waitForSleep(harness, late)
        #expect(harness.wake() == HarnessWake(active: false))
        #expect(try await harness.signal(taskId: late, token: greeting, key: "hello",
            value: Greeting(text: "good morning"), context: .background) == .delivered)
        #expect(try await harness.waitForTask(id: late, context: .background).outcome == .completed(result: "good morning"))
        try await harness.close(context: .background)
    }

    // Upstream test/examples/39-ask-a-person.ts.
    @Test func asksAPersonAndExpiresUnansweredQuestions() async throws {
        let hour: Int64 = 60 * 60 * 1_000
        let clock = TestClock(now: 1_794_214_800_000)
        let inbox = Mutex<[TaskID: String]>([:])
        let wakes = SessionTestLog<HarnessWake>()
        let answer: SignalToken<JSONValue> = try defineSignal(name: "example.answer", version: 1, schema: answerSchema)
        let key = try answer.key("answer")
        let task = AskPersonTask(name: "example.ask-person", version: 1, initial: { _ in AskCheckpoint() },
            phase: { task, runtime, context in
                switch task.checkpoint.phase {
                case .ask:
                    inbox.withLock { $0[runtime.taskId] = task.input.question }
                    try await runtime.sleep(signals: [key], until: Double(runtime.now() + 4 * hour),
                        checkpoint: JSONValue(encoding: AskCheckpoint(phase: .answered)), context: context)
                case .answered:
                    inbox.withLock { $0[runtime.taskId] = nil }
                    let state = try await signalState(runtime, answer, "answer", context)
                    let text = state["value"]?["text"] ?? .null
                    let wake = try task.record.state.wakeReason()
                    if text == .null {
                        #expect(wake == .expired())
                        #expect(state == ["expired": true])
                    } else {
                        #expect(wake == .signal(signal: "example.answer", key: "answer"))
                    }
                    try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: ["answer": text])) },
                        context: context)
                }
            }, abort: { _, runtime, context in
                try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
            })
        let harness = try await openSignals([AnyTaskDefinition(task)], clock: clock, onWake: { wakes.append($0) })
        let root = try await harness.root(context: .background)
        func create(_ question: String) async throws -> TaskID {
            try await root.commit({ tx in
                try await tx.createTask(task, input: PersonQuestion(question: question),
                    options: .init(ownership: .conversation()))
            }, context: .background)
        }
        let first = try await create("Deploy to production?")
        try harness.resume()
        try await waitForSleep(harness, first)
        #expect(inbox.withLock { $0 } == [first: "Deploy to production?"])
        #expect(harness.wake() == HarnessWake(active: false, at: Double(clock.now() + 4 * hour)))
        #expect(try await harness.signal(taskId: first, token: answer, key: "answer",
            value: ["text": "yes"], context: .background) == .delivered)
        #expect(try await harness.waitForTask(id: first, context: .background).outcome == .completed(result: ["answer": "yes"]))

        let second = try await create("Delete the staging database?")
        try await waitForSleep(harness, second)
        #expect(inbox.withLock { $0 } == [second: "Delete the staging database?"])
        clock.advance(by: 4 * hour)
        try harness.resume()
        #expect(try await harness.waitForTask(id: second, context: .background).outcome == .completed(result: ["answer": .null]))
        #expect(try await harness.signal(taskId: second, token: answer, key: "answer",
            value: ["text": "yes"], context: .background) == .closed)
        #expect(inbox.withLock { $0 }.isEmpty)
        try await harnessEventually { wakes.values.last == HarnessWake(active: false) }
        try await harness.close(context: .background)
    }
}
