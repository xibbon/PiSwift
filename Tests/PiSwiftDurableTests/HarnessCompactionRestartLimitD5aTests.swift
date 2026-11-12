import Testing
import PiSwiftChord
@testable import PiSwiftDurable

@Suite(.timeLimit(.minutes(1))) struct HarnessCompactionRestartLimitD5aTests {
    // v1.5.2 D5a harness-restart-failure.test.ts:438–477; compaction.ts:121–122,501–509.
    @Test func cutOffCompactionEndsWithStoredFailure() async throws {
        let chat = try await compactionOpen(resume: false)
        chat.setup.updateSettings { $0.restartLimit = 1 }
        let id = try await chat.root.commit({ tx in
            try await createCompaction(tx: tx, conversationId: chat.root.id,
                input: CompactionInput(reason: .manual))
        }, context: .background)
        try await chat.root.commit({ tx in
            let record = try #require(await tx.task(id))
            try tx.setTask(record.replacing(restarts: .some(1)))
        }, context: .background)

        try chat.harness.resume()
        let outcome = try await compactionOutcome(chat, id)
        guard case .failed(let error, _, _) = outcome else {
            Issue.record("Expected a failed compaction, got \(outcome.status)")
            try await chat.harness.close(context: .background)
            return
        }
        #expect(error.message == "Compaction was interrupted once")
        #expect(error.detail == .object(["reason": .string("restart_limit")]))
        let live = try await compactionLive(chat)
        #expect(live.compactions == nil)
        #expect(live.compactionFailure == .init(taskId: id, reason: .manual, error: "Compaction was interrupted once"))
        #expect(chat.script.summaryRequests.isEmpty)
        #expect(try await chat.harness.inspect(context: .background).tasks.isEmpty)
        try await chat.harness.close(context: .background)
    }
}
