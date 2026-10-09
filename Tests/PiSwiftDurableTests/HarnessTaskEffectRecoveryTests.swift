import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private struct HarnessTransferCheckpoint: TaskCheckpoint {
    enum Phase: String, Codable, Sendable { case prepare, apply }
    let phase: Phase
    let key: String?
}
private struct HarnessTransferReceipt: Codable, Sendable { let receipt: Int }

@Suite struct HarnessTaskEffectRecoveryTests {
    // upstream harness-tasks-recovery.test.ts:112,148
    @Test func replaysIdempotentEffectFromDurableIntentAndKeepsStartTime() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("effect-recovery.sqlite").path
        let applied = Mutex<[String: Int]>([:])
        let calls = SessionTestLog<String>()
        let interrupt = Mutex(true)
        let clock = TestClock(now: 2_000)
        let definition = TaskDefinition<Int, HarnessTransferCheckpoint, HarnessTransferReceipt, NoTaskHooks>(name: "test.transfer", version: 1,
            initial: { _ in HarnessTransferCheckpoint(phase: .prepare, key: nil) }, phase: { task, runtime, context in
                switch task.checkpoint.phase {
                case .prepare:
                    _ = try await runtime.memo("requested", value: .number(Double(task.input)), context: context)
                    try await runtime.commit({ _, _ in
                        .running(checkpoint: try JSONValue(encoding: HarnessTransferCheckpoint(phase: .apply, key: "transfer-\(task.id.rawValue)")))
                    }, context: context)
                case .apply:
                    let key = try #require(task.checkpoint.key)
                    calls.append(key)
                    let receipt = applied.withLock { values in
                        if let result = values[key] { return result }
                        let result = task.input * 10; values[key] = result; return result
                    }
                    let stop = interrupt.withLock { value in let wasSet = value; value = false; return wasSet }
                    if stop { try await runtime.sleep(until: 1_000_000, context: context) }
                    try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: try JSONValue(encoding: HarnessTransferReceipt(receipt: receipt)))) }, context: context)
                }
            }, abort: { _, runtime, context in try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context) })
        let first = try await harnessOpen([AnyTaskDefinition(definition)], storage: SqliteStorage.open(path: path), clock: clock)
        let root = try await first.root(context: .background)
        let id = try await root.commit({ tx in try await tx.createTask(definition, input: 7, options: .init(ownership: .conversation())) }, context: .background)
        try first.resume()
        try await harnessEventually { calls.count == 1 }
        clock.advance(by: 1_000)
        try await first.close(context: .background)
        clock.advance(by: 6_000)
        let second = try await harnessOpen([AnyTaskDefinition(definition)], storage: SqliteStorage.open(path: path), clock: clock)
        let record = try #require(try await second.getTask(id: id, context: .background))
        #expect(record.state.status == "pending")
        #expect(record.startedAt == 2_000)
        #expect(record.endedAt == nil)
        #expect(record.memos?["requested"] == .number(7))
        #expect(calls.count == 1)
        let receipt = try await second.waitForTask(id: id, context: .background)
        #expect(receipt.outcome == .completed(result: ["receipt": 70]))
        #expect(receipt.record.startedAt == 2_000)
        #expect(receipt.record.endedAt == 9_000)
        #expect(calls.count == 2)
        #expect(applied.withLock { $0.count } == 1)
        try await second.close(context: .background)
        let third = try await harnessOpen([AnyTaskDefinition(definition)], storage: SqliteStorage.open(path: path), clock: clock)
        #expect(try await third.waitForTask(id: id, context: .background) == receipt)
        #expect(calls.count == 2)
        try await third.close(context: .background)
    }
}
