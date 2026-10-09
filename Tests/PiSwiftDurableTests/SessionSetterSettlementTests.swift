import Dispatch
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private enum SessionSetter: CaseIterable, Sendable {
    case settleSubmission
    case placeSubmission
    case setTask

    func apply(to tx: Transaction) throws {
        switch self {
        case .settleSubmission:
            try tx.settleSubmission(SubmissionID(2), settlement: .unanswered(reason: "test"))
        case .placeSubmission:
            try tx.placeSubmission(SubmissionID(2), entry: EntryID(3))
        case .setTask:
            try tx.setTask(TaskRecord(id: TaskID(4), conversationId: ConversationID(1),
                                     kind: "setter.test", version: 1, input: [:],
                                     state: .pending(checkpoint: [:])))
        }
    }
}

private enum SessionSetterFailure: Error, Equatable { case callback }

@Suite struct SessionSetterSettlementTests {
    @Test(arguments: SessionSetter.allCases, [false, true])
    fileprivate func SessionSetterPendingAtSettlementIsDrainedAndRolledBack(
        setter: SessionSetter, callbackFails: Bool
    ) async throws {
        let harness = try await openTestSession()
        let commitsBefore = await harness.storage.commits.count
        let publicationsBefore = harness.publications.count
        let tableLockEntered = SessionTestGate()
        let callbackReady = SessionTestGate()
        let releaseTableLock = DispatchSemaphore(value: 0)
        defer { releaseTableLock.signal() }
        let transactions = SessionTestLog<Transaction>()
        let holders = SessionTestLog<Task<Void, Never>>()
        let operations = SessionTestLog<Task<Void, any Error>>()
        let completions = SessionTestLog<Bool>()

        let commit = Task {
            defer { completions.append(true) }
            try await harness.session.commit({ tx in
                transactions.append(tx)
                holders.append(Task.detached {
                    tx.tableState.withLock { _ in
                        tableLockEntered.release()
                        releaseTableLock.wait()
                    }
                })
                await tableLockEntered.wait()
                operations.append(Task.detached { try setter.apply(to: tx) })
                await tx.waitUntilPendingOperations(1)
                callbackReady.release()
                if callbackFails { throw SessionSetterFailure.callback }
            }, context: .background)
        }

        await callbackReady.wait()
        let tx = try #require(transactions.values.first)
        await tx.waitUntilSettled()
        // The setter remains inside the operation until the table lock is released.
        #expect(completions.values.isEmpty)
        #expect(await harness.storage.commits.count == commitsBefore)
        #expect(harness.publications.count == publicationsBefore)
        releaseTableLock.signal()
        let operation = try #require(operations.values.first)
        let holder = try #require(holders.values.first)
        try await operation.value
        await holder.value
        if callbackFails {
            await #expect(throws: SessionSetterFailure.callback) { try await commit.value }
        } else {
            await #expect(throws: SessionError.pendingOperations) { try await commit.value }
        }
        #expect(completions.values == [true])
        #expect(await harness.storage.commits.count == commitsBefore)
        #expect(harness.publications.count == publicationsBefore)
        _ = try await createConversation(harness.session)
        #expect(await harness.storage.commits.count == commitsBefore + 1)
        try await harness.session.close(context: .background)
    }

    @Test(arguments: SessionSetter.allCases, [false, true])
    fileprivate func SessionSetterAfterSettlementRejectsWithoutChanges(
        setter: SessionSetter, callbackFails: Bool
    ) async throws {
        let harness = try await openTestSession()
        let transactions = SessionTestLog<Transaction>()
        let commit = Task {
            try await harness.session.commit({ tx in
                transactions.append(tx)
                if callbackFails { throw SessionSetterFailure.callback }
            }, context: .background)
        }
        if callbackFails {
            await #expect(throws: SessionSetterFailure.callback) { try await commit.value }
        } else {
            try await commit.value
        }
        let tx = try #require(transactions.values.first)
        #expect(throws: SessionError.settled) { try setter.apply(to: tx) }
        #expect(tx.tableState.withLock { $0.writes.isEmpty })
        #expect(tx.tableState.withLock { $0.submissionChanges.isEmpty })
        #expect(tx.tableState.withLock { $0.tasks.isEmpty })
        #expect(await harness.storage.commits.isEmpty)
        #expect(harness.publications.values.isEmpty)
        try await harness.session.close(context: .background)
    }
}
