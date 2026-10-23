import Testing
import PiSwiftChord
@testable import PiSwiftDurable

@Suite struct HarnessSchedulerPerformanceTests {
    @Test(.timeLimit(.minutes(1))) func largeAdmissionQueueKeepsFIFOAcrossCompactionAndReuse() async {
        let line = SessionLine(), count = 20_000
        let tickets = (0..<count).map { _ in line.reserve() }
        #expect(line.queuedCount == count - 1)
        for ticket in tickets.prefix(count / 2) { await ticket.wait(); line.release() }
        let later = (0..<count).map { _ in line.reserve() }
        #expect(line.queuedCount == count + count / 2 - 1)
        for ticket in tickets.suffix(count / 2) { await ticket.wait(); line.release() }
        for (index, ticket) in later.enumerated() {
            await ticket.wait()
            if index == count / 2 { #expect(line.queuedCount == count - index - 1) }
            line.release()
        }
        #expect(line.queuedCount == 0)
        let reused = line.reserve()
        await reused.wait(); line.release()
        #expect(line.queuedCount == 0)
    }

    @Test func taskValidationStillRejectsNestedNonFiniteNumbers() async throws {
        let harness = try await harnessOpen([])
        let root = try await harness.root(context: .background)
        let task = harnessOneStep("test.validation.finite") { _, _, _ in }
        let id = try await harnessStart(root, task)
        for value in [Double.nan, .infinity, -.infinity] {
            await #expect(throws: JSONValueError.nonFiniteNumber) {
                try await root.commit({ tx in
                    let record = try #require(await tx.task(id))
                    try tx.setTask(record.replacing(input: .object(["nested": .array([.number(value)])])))
                }, context: .background)
            }
        }
        #expect(try await harness.getTask(id: id, context: .background)?.input == .number(0))
        try await harness.close(context: .background)
    }
}
