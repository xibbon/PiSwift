import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private struct ScaleHoldCheckpoint: TaskCheckpoint {
    enum Phase: String, Codable, Sendable { case hold }
    var phase: Phase = .hold
}

@Suite(.timeLimit(.minutes(5))) struct HarnessSchedulerScaleTests {
    // harness-ownership.test.ts:261. Finished branches must leave the ownership index.
    @Test func ownershipQueriesDoNotVisitFiftyFinishedChains() async throws {
        let control = W3LifetimeControl(), definition = control.definition(), chains = 50
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], clock: control.clock)
        let root = try await harness.root(context: .background)
        let owner = try await harnessStart(root, definition, input: 1)
        try harness.resume()
        var tasks: [TaskID] = []
        for n in 0..<chains {
            let ids = try await root.commit({ tx in
                let first = try await tx.createTask(definition, input: 10 + n * 2,
                                                    options: .init(ownership: .task(taskId: owner)))
                let second = try await tx.createTask(definition, input: 11 + n * 2,
                                                     options: .init(ownership: .task(taskId: first)))
                _ = try await tx.createConversation(ownership: .task(taskId: second))
                return [first, second]
            }, context: .background)
            tasks += ids
        }
        for n in 0..<chains { control.open(11 + n * 2); control.open(10 + n * 2) }
        for id in tasks { _ = try await harness.waitForTask(id: id, context: .background) }
        harness.tasks.resetCandidateEntries()
        control.open(1)
        #expect(try await harness.waitForTask(id: owner, context: .background).outcome.status == "completed")
        let candidates = harness.tasks.candidateEntries
        print("E11b finished-branches candidates=\(candidates) bound=\(chains)")
        #expect(candidates < chains)
        try await harness.close(context: .background)
    }

    // harness-ownership.test.ts:314. The full upstream depth must fit on the stack.
    @Test(.timeLimit(.minutes(1))) func holdsAndReleasesTwentyThousandLinks() async throws {
        // This case checks ownership holds, not disk persistence.
        let storage = try await SqliteStorage.open(path: ":memory:")
        let started = ContinuousClock.now
        let control = W3LifetimeControl(), depth = 20_000
        let definition = TaskDefinition<Int, ScaleHoldCheckpoint, JSONValue, NoTaskHooks>(
            name: "test.scale.deep-hold", version: 1, initial: { _ in ScaleHoldCheckpoint() },
            phase: { task, runtime, context in
                try await control.wait(task.input, runtime: runtime, context: context)
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
            }, abort: { _, runtime, context in
                try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
            })
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], storage: storage, clock: control.clock)
        let root = try await harness.root(context: .background)
        let ends = try await root.commit({ tx in
            let top = try await tx.createTask(definition, input: 1, options: .init(ownership: .conversation()))
            var owner = top
            for n in 0..<depth {
                owner = try await tx.createTask(definition, input: n + 2,
                                                options: .init(ownership: .task(taskId: owner)))
            }
            let leaf = try await tx.createTask(definition, input: depth + 2,
                                               options: .init(ownership: .task(taskId: owner)))
            return (top, leaf)
        }, context: .background)
        let created = ContinuousClock.now
        for input in 1..<(depth + 2) { control.open(input) }
        try harness.resume()
        try await scaleEventually {
            try await harness.getTask(id: ends.0, context: .background)?.state.status == "completing"
        }
        let holding = ContinuousClock.now
        control.open(depth + 2)
        #expect(try await harness.waitForTask(id: ends.1, context: .background).outcome.status == "completed")
        #expect(try await harness.waitForTask(id: ends.0, context: .background).outcome.status == "completed")
        print("E11b deep-ownership create=\(started.duration(to: created)) hold=\(created.duration(to: holding)) release=\(holding.duration(to: .now))")
        try await harness.close(context: .background)
    }

    // harness-ownership.test.ts:525. Check a holder once per round, not once per sibling.
    @Test func finalizesOneThousandHeldSiblingsWithLinearWork() async throws {
        let control = W3LifetimeControl(), definition = control.definition(), count = 1_000
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], clock: control.clock)
        let root = try await harness.root(context: .background)
        let tree = try await root.commit({ tx in
            let top = try await tx.createTask(definition, input: 1, options: .init(ownership: .conversation()))
            var siblings: [TaskID] = [], leaves: [TaskID] = []
            for n in 0..<count {
                siblings.append(try await tx.createTask(definition, input: 10 + n,
                                                        options: .init(ownership: .task(taskId: top))))
            }
            for n in (0..<count).reversed() {
                leaves.append(try await tx.createTask(definition, input: 10_000 + n,
                                                      options: .init(ownership: .task(taskId: siblings[n]))))
            }
            return (top, siblings, leaves)
        }, context: .background)
        for n in 0..<count { control.open(10 + n) }
        control.open(1)
        try harness.resume()
        for id in tree.1 {
            try await scaleEventually { try await harness.getTask(id: id, context: .background)?.state.status == "completing" }
        }
        try await scaleEventually { try await harness.getTask(id: tree.0, context: .background)?.state.status == "completing" }
        try await root.commit({ tx in
            var records: [TaskRecord] = []
            for id in tree.2 { records.append(try #require(await tx.task(id))) }
            for record in records {
                try tx.setTask(record.replacing(state: .terminal(outcome: .completed(result: .null))))
            }
        }, context: .background)
        harness.tasks.resetCandidateEntries()
        #expect(try await harness.waitForTask(id: tree.0, context: .background).outcome.status == "completed")
        let candidates = harness.tasks.candidateEntries
        print("E11b held-siblings candidates=\(candidates) bound=\(count * 20)")
        #expect(candidates < count * 20)
        for id in tree.1 {
            #expect(try await harness.waitForTask(id: id, context: .background).outcome.status == "completed")
        }
        try await harness.close(context: .background)
    }

    // A target change must not scan unrelated waiters or active sleeping tasks.
    // The failFast case also checks the reverse failure index.
    @Test(arguments: [false, true])
    func oneTargetWakesOnlyItsWaiterAmongOneThousand(failFast: Bool) async throws {
        let control = W3LifetimeControl(), definition = control.definition(), count = 1_000
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], clock: control.clock)
        let root = try await harness.root(context: .background)
        let pairs = try await root.commit({ tx in
            var pairs: [(TaskID, TaskID)] = []
            for n in 0..<count {
                let parent = try await tx.createTask(definition, input: 10_000 + n,
                                                     options: .init(ownership: .conversation()))
                let child = try await tx.createTask(definition, input: n + 1,
                                                    options: .init(ownership: .task(taskId: parent)))
                pairs.append((parent, child))
            }
            // Use staged records because task creation has already started table writes.
            let records = Dictionary(uniqueKeysWithValues: try tx.stagedTasks().map { ($0.id, $0) })
            let checkpoint = try JSONValue(encoding: HarnessTaskCheckpoint())
            for pair in pairs {
                let parent = try #require(records[pair.0])
                try tx.setTask(parent.replacing(state: .waiting(checkpoint: checkpoint, on: [pair.1],
                                                                policy: failFast ? .failFast : .allSettled)))
            }
            return pairs
        }, context: .background)
        control.open(10_000)
        try harness.resume()
        // Wait until the first reservation and recovery passes consume their candidates.
        try await scaleEventually {
            harness.tasks.state.withLock {
                $0.runnable.isEmpty && !$0.pumping && !$0.reconcileScheduled && $0.reconciles.isEmpty && !$0.sweepScheduled
            }
        }
        #expect(control.runs.values.filter { $0 >= 10_000 }.isEmpty)
        harness.tasks.resetCandidateEntries()
        try await root.commit({ tx in
            let child = try #require(await tx.task(pairs[0].1))
            let outcome: TaskOutcome = failFast ? .failed(error: .init(message: "test failure")) : .completed(result: .null)
            try tx.setTask(child.replacing(state: .terminal(outcome: outcome)))
        }, context: .background)
        #expect(try await harness.waitForTask(id: pairs[0].0, context: .background).outcome.status == "completed")
        let candidates = harness.tasks.candidateEntries
        let name = failFast ? "fail-fast-wake" : "waiter-wake"
        print("E11b \(name) candidates=\(candidates) bound=100")
        #expect(candidates < 100)
        #expect(control.runs.values.filter { $0 >= 10_000 } == [10_000])
        #expect(try await harness.getTask(id: pairs[count - 1].0, context: .background)?.state.status == "waiting")
        #expect(try await harness.getTask(id: pairs[count - 1].1, context: .background)?.state.status == "running")
        try await harness.close(context: .background)
    }
}

private func scaleEventually(_ condition: @escaping @Sendable () async throws -> Bool) async throws {
    let clock = ContinuousClock(), deadline = ContinuousClock.now + .seconds(180)
    while try await !condition() {
        try #require(clock.now < deadline, "Scheduler scale operation exceeded three minutes")
        try await Task.sleep(for: .milliseconds(1))
    }
}
