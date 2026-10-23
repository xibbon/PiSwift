import PiSwiftChord
import Testing
@testable import PiSwiftDurable

private struct FailureObservedValue: Codable, Sendable {
    var value: Int
}

@Suite struct SessionFailureConcurrencyTests {
    @Test("one concurrent failure claims the latch and all other claims return its cause")
    func concurrentFailureClaimsKeepFirstCause() async throws {
        let latch = SessionFailureLatch()
        let reports = SessionTestLog<any Error>()
        let ready = [SessionTestGate(), SessionTestGate()]
        let release = SessionTestGate()
        let errors = [HarnessStorageFailure("first candidate"), HarnessStorageFailure("second candidate")]
        latch.install { reports.append($0) }

        let claims = await withTaskGroup(of: (HarnessStorageFailure, (any Error)?).self) { group in
            for index in errors.indices {
                group.addTask {
                    ready[index].release()
                    await release.wait()
                    return (errors[index], latch.fail(errors[index]))
                }
            }
            for gate in ready { await gate.wait() }
            release.release()
            var results: [(HarnessStorageFailure, (any Error)?)] = []
            for await result in group { results.append(result) }
            return results
        }

        let winner = try #require(claims.first { $0.1 == nil }?.0)
        #expect(claims.filter { $0.1 == nil }.count == 1)
        let loser = try #require(claims.first { $0.1 != nil })
        #expect((loser.1 as? HarnessStorageFailure) === winner)
        #expect((latch.failure as? HarnessStorageFailure) === winner)
        #expect(reports.count == 1)
        #expect((reports.values.first as? HarnessStorageFailure) === winner)
        do {
            try latch.check()
            Issue.record("A failed latch accepted a health check")
        } catch let error as SessionFailed {
            #expect((error.cause as? HarnessStorageFailure) === winner)
        }
    }

    @Test("document state reports a failed listener and continues other deliveries")
    func documentStateReportsListenerFailure() async throws {
        let reports = SessionTestLog<any Error>()
        let session = try await Session.open(storage: ControlledStorage(), onReport: { reports.append($0) }, context: .background)
        let token = try SessionDocToken<FailureObservedValue>(kind: "failure.state.listener", version: 1,
            initial: { FailureObservedValue(value: 0) })
        try await session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        let state = try #require(try await session.documentState(token, context: .background))
        let failure = HarnessStorageFailure("state listener failed")
        let values = SessionTestLog<Int>()
        state.subscribe { _, _, delivery in
            if delivery.sequence == 1 { throw failure }
        }
        state.subscribe { value, _, _ in
            if let value { values.append(value.value) }
        }
        await state.waitUntilIdle()

        try await session.commit({ tx in try await tx.doc(token).set("value", 1) }, context: .background)
        await state.waitUntilIdle()
        #expect(reports.count == 1)
        #expect((reports.values.first as? HarnessStorageFailure) === failure)
        #expect(session.failure == nil)

        try await session.commit({ tx in try await tx.doc(token).set("value", 2) }, context: .background)
        await state.waitUntilIdle()
        #expect(values.values == [0, 1, 2])
        #expect(state.value?.value == 2)
        #expect(reports.count == 1)
        state.dispose()
        try await session.close(context: .background)
    }
}

extension SessionFailureConcurrencyTests {
    @Test("a typed state decode error is reported and ends only that attachment")
    func typedStateDecodeErrorReportsAndKeepsLastValue() async throws {
        let reports = SessionTestLog<any Error>()
        let session = try await Session.open(storage: ControlledStorage(), onReport: { reports.append($0) }, context: .background)
        let token = try SessionDocToken<FailureObservedValue>(kind: "failure.state.decode", version: 1,
            initial: { FailureObservedValue(value: 0) })
        try await session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        let state = try #require(try await session.documentState(token, context: .background))
        try await session.commit({ tx in try await tx.doc(token).set("value", "invalid") }, context: .background)
        #expect(reports.count == 1)
        #expect(reports.values.first is DecodingError)
        #expect(state.value?.value == 0)
        #expect(session.failure == nil)
        try await session.commit({ tx in try await tx.doc(token).set("value", 1) }, context: .background)
        #expect(state.value?.value == 0)
        #expect(try await session.snapshot(token, context: .background)?.value == 1)
        state.dispose()
        try await session.close(context: .background)
    }
}
