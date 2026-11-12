import Testing
import PiSwiftChord
@testable import PiSwiftDurable

@Suite("PiSwiftDurableTests.D5aDecisionRegions", .timeLimit(.minutes(1)))
struct D5aDecisionRegionTests {
    // v1.5.2 D5a scheduler.ts:1377–1408 and e5c6182ba: a memory
    // decision must discard a value read before an unpublished task write.
    @Test func waitsForPublishedTaskAndRetriesTheDecision() async throws {
        let storage = ControlledStorage()
        let definition = harnessOneStep("d5a.region") { _, _, _ in }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], storage: storage)
        let id = try await harnessStart(harness.root(context: .background), definition)

        let hold = await storage.holdCommits()
        let writing = Task {
            try await harness.session.commit({ tx in
                let old = try #require(await tx.task(id))
                try tx.setTask(old.replacing(memos: ["marker": .number(1)]))
            }, context: .background)
        }
        await hold.waitUntilEntered()
        let staleRead = SessionTestGate()
        let reading = Task {
            try await harness.tasks.region {
                let value = harness.tasks.current(id)?.memos?["marker"]
                staleRead.release()
                return value
            }
        }
        await staleRead.wait()
        await hold.release()
        try await writing.value
        #expect(try await reading.value == .number(1))
        try await harness.close(context: .background)
    }
}
