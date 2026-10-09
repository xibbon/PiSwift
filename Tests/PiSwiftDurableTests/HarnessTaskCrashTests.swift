import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

/// Crash tests abandon a Harness. Its held writes and handlers do not return.
@Suite struct HarnessTaskCrashTests {
    // upstream harness-tasks-recovery.test.ts:291,307,332,353,388,408
    @Test(arguments: ["mark-in-storage", "marked-before-join", "abort-handler", "abort-outcome-in-storage", "terminal", "reservation-in-storage"])
    func crashStagesReplayOnlyCommittedIntent(stage: String) async throws {
        let storage = ControlledStorage()
        let log = SessionTestLog<String>()
        let never = SessionTestGate()
        let entered = SessionTestGate()
        let proceed = SessionTestGate()
        let original = harnessOneStep("test.crash", run: { _, _, _ in
            log.append("run")
            entered.release()
            await never.wait()
        }, abort: { _, runtime, context in
            log.append("abort")
            entered.release()
            if stage == "abort-handler" { await never.wait() }
            if stage == "abort-outcome-in-storage" { await proceed.wait() }
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "recovered")) }, context: context)
        })
        let first = try await harnessOpen([AnyTaskDefinition(original)], storage: storage)
        let root = try await first.root(context: .background)
        let id = try await harnessStart(root, original)
        switch stage {
        case "reservation-in-storage":
            let held = await storage.holdCommits()
            try first.resume()
            await held.waitUntilEntered()
        case "mark-in-storage", "marked-before-join":
            try first.resume()
            await entered.wait()
            if stage == "mark-in-storage" {
                let held = await storage.holdCommits()
                Task { _ = try? await first.abortTask(id: id, context: .background) }
                await held.waitUntilEntered()
            } else {
                Task { _ = try? await first.abortTask(id: id, context: .background) }
                try await harnessEventually { try await first.getTask(id: id, context: .background)?.abortRequested == true }
            }
        default:
            // As upstream: abortTask does not enable scheduling; resume does.
            _ = try await first.abortTask(id: id, context: .background)
            try first.resume()
            await entered.wait()
            if stage == "abort-outcome-in-storage" {
                let held = await storage.holdCommits()
                proceed.release()
                await held.waitUntilEntered()
            } else if stage == "terminal" {
                _ = try await first.waitForTask(id: id, context: .background)
            }
        }
        await storage.crash()
        let recoveredDefinition = harnessOneStep("test.crash", run: { _, runtime, context in
            log.append("run")
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }, abort: { _, runtime, context in
            log.append("abort")
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "recovered")) }, context: context)
        })
        let recovered = try await harnessOpen([AnyTaskDefinition(recoveredDefinition)], storage: storage)
        let record = try #require(try await recovered.getTask(id: id, context: .background))
        if stage == "mark-in-storage" || stage == "reservation-in-storage" { #expect(!record.abortRequested); #expect(record.state.status == "pending") }
        let receipt = try await recovered.waitForTask(id: id, context: .background)
        switch stage {
        case "reservation-in-storage": #expect(log.values == ["run"]); #expect(receipt.outcome.status == "completed")
        case "mark-in-storage": #expect(log.values == ["run", "run"]); #expect(receipt.outcome.status == "completed")
        case "marked-before-join": #expect(log.values == ["run", "abort"]); #expect(receipt.outcome.status == "aborted")
        case "terminal": #expect(log.values == ["abort"]); #expect(receipt.outcome.status == "aborted")
        default: #expect(log.values == ["abort", "abort"]); #expect(receipt.outcome.status == "aborted")
        }
        try await recovered.close(context: .background)
    }
}
