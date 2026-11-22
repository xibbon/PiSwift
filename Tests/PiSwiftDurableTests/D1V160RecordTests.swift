import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private func v160Task(_ state: JSONValue, kind: String = "pi.tool", version: Double = 4) -> JSONValue {
    ["id": 13, "conversationId": 1, "kind": .string(kind), "version": .number(version),
     "input": ["kind": "model", "assistant": 12, "callId": "c"],
     "background": false, "abortRequested": false, "startedAt": 1_700_000_000_000,
     "state": state]
}

@Suite struct D1V160RecordTests {
    // v1.6.0 types.ts:405-421,685-724.
    @Test(arguments: [
        JSONValue.object(["reason": "time"]),
        ["reason": "expired"],
        ["reason": "signal", "signal": "app.answer", "key": "k"],
        ["reason": "tasks", "ended": [13, 14]]
    ])
    func wakeReasonsRoundTrip(_ wake: JSONValue) throws {
        let json = v160Task(["status": "pending", "checkpoint": ["phase": "call"], "wake": wake])
        let record = try json.decode(TaskRecord.self)
        #expect(try record.state.wakeReason() != nil)
        #expect(try JSONValue(encoding: record) == json)
    }

    @Test(arguments: [
        JSONValue.object(["status": "sleeping", "checkpoint": ["phase": "parked", "arguments": [:], "replay": "safe"],
                          "signals": [["signal": "app.answer", "key": "k"]]]),
        ["status": "sleeping", "checkpoint": ["phase": "parked", "arguments": [:], "replay": "safe"],
         "until": 1_700_000_000_100, "signals": [["signal": "app.answer", "key": "k"]]]
    ])
    func signalSleepsRoundTrip(_ state: JSONValue) throws {
        let json = v160Task(state)
        let record = try json.decode(TaskRecord.self)
        #expect(try record.state.sleepSignals()?.count == 1)
        #expect(try JSONValue(encoding: record) == json)
    }

    @Test func anyWaitRoundTrips() throws {
        let json = v160Task(["status": "waiting", "checkpoint": ["phase": "parked", "arguments": [:], "replay": "safe"],
                             "on": [14, 15], "policy": "any"])
        let record = try json.decode(TaskRecord.self)
        guard case .waiting(_, _, let policy, _) = record.state else { Issue.record("Expected wait"); return }
        #expect(policy == .any)
        #expect(try JSONValue(encoding: record) == json)
    }

    @Test func parkedToolNestedCheckpointRoundTrips() throws {
        let source: JSONValue = ["phase": "parked", "arguments": ["x": 1], "replay": "safe",
                                 "checkpoint": ["nested": ["step": 2]]]
        let checkpoint = try source.decode(ToolTaskCheckpoint.self)
        #expect(checkpoint.phase == .parked)
        #expect(checkpoint.checkpoint == ["nested": ["step": 2]])
        #expect(try JSONValue(encoding: checkpoint) == source)
    }

    @Test(arguments: ["afterTools", "yield"])
    func generationV3PhasesRoundTrip(_ phase: String) throws {
        let source: JSONValue = phase == "afterTools"
            ? ["phase": "afterTools", "assistant": 12, "tools": [13], "tasks": [14]]
            : ["phase": "yield", "answer": 12, "tasks": [14]]
        let checkpoint = try source.decode(GenerationCheckpoint.self)
        #expect(try JSONValue(encoding: checkpoint) == source)
    }

    @Test(arguments: [1.0, 2.0, 3.0])
    func toolMigrationPreservesAllEarlierShapes(_ version: Double) throws {
        let migrate = try #require(toolTask.migrate)
        let input: JSONValue = version == 1 ? ["assistant": 12, "callId": "c"]
            : ["kind": "model", "assistant": 12, "callId": "c"]
        let checkpoint: JSONValue = ["phase": "execute", "arguments": ["x": 1], "replay": "safe"]
        let result = try migrate(input, checkpoint, version)
        #expect(try JSONValue(encoding: result.input) == ["kind": "model", "assistant": 12, "callId": "c"])
        #expect(try JSONValue(encoding: result.checkpoint) == checkpoint)
    }

    @Test(arguments: [1.0, 2.0])
    func generationMigrationKeepsEarlierCheckpoint(_ version: Double) throws {
        let migrate = try #require(generationTask.migrate)
        let checkpoint: JSONValue = ["phase": "prepare", "attempt": 1]
        let result = try migrate([:], checkpoint, version)
        #expect(try JSONValue(encoding: result.input) == [:])
        #expect(try JSONValue(encoding: result.checkpoint) == checkpoint)
    }

    @Test(arguments: [
        JSONValue.object(["status": "sleeping", "checkpoint": ["phase": "parked"], "signals": []]),
        ["status": "sleeping", "checkpoint": ["phase": "parked"]],
        ["status": "pending", "checkpoint": ["phase": "call"], "wake": ["reason": "unknown"]],
        ["status": "waiting", "checkpoint": ["phase": "parked"], "on": [14], "policy": "unknown"]
    ])
    func rejectsInvalidNewState(_ state: JSONValue) {
        #expect(throws: (any Error).self) { try v160Task(state).decode(TaskRecord.self) }
    }
}
