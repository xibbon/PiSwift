import Foundation
import Testing
@testable import PiSwiftAI

@Suite("Session resources v1.5.2", .serialized)
struct SessionResourcesV152Tests {
    @Test func remembersSessionsUntilCleanup() throws {
        let a = UUID().uuidString
        let b = UUID().uuidString
        defer { cleanupStrictToolLimits(a); cleanupStrictToolLimits(b) }
        markStrictToolLimitsExceeded(a)
        markStrictToolLimitsExceeded(b)
        markStrictToolLimitsExceeded(nil)
        #expect(hasExceededStrictToolLimits(a))
        #expect(!hasExceededStrictToolLimits(nil))
        try cleanupSessionResources(a)
        #expect(!hasExceededStrictToolLimits(a))
        #expect(hasExceededStrictToolLimits(b))
    }

    @Test func capsSessionsAndDoesNotRefreshExistingEntries() {
        var sessions = StrictToolLimitSessions()
        for index in 0..<10_000 { sessions.mark("session-\(index)") }
        sessions.mark("session-0")
        sessions.mark("session-10000")
        #expect(!sessions.ids.contains("session-0"))
        #expect(sessions.ids.contains("session-1"))
        #expect(sessions.ids.contains("session-10000"))
    }

    @Test func runsAllCleanupsAndCollectsErrors() throws {
        enum Failure: Error { case expected }
        let calls = LockedState<[Int]>([])
        let id = UUID().uuidString
        let removeFirst = registerSessionResourceCleanup { session in
            guard session == id else { return }
            calls.withLock { $0.append(1) }
            throw Failure.expected
        }
        let removeSecond = registerSessionResourceCleanup { session in
            guard session == id else { return }
            calls.withLock { $0.append(2) }
            throw Failure.expected
        }
        defer { removeFirst(); removeSecond() }
        do {
            try cleanupSessionResources(id)
            Issue.record("Cleanup did not throw")
        } catch let error as SessionResourceCleanupError {
            #expect(error.errors.count == 2)
        }
        #expect(calls.withLock { $0 } == [1, 2])
        removeFirst()
        removeSecond()
        try cleanupSessionResources(id)
        #expect(calls.withLock { $0 } == [1, 2])
    }
}
