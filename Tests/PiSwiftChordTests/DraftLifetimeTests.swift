import Dispatch
import Synchronization
import Testing
@testable import PiSwiftChord

private func expectRevoked(_ action: () throws -> Void) {
    do {
        try action()
        Issue.record("Expected a revoked draft to reject access")
    } catch {
        #expect(error as? TrackerError == .settled)
        #expect(String(describing: error) == "Cannot use a settled overlay")
    }
}

@Suite struct DraftLifetimeTests {
    @Test func operationBeforeRevocationFinishesBeforeRevokeReturns() throws {
        let enabled = Mutex(false)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let operationDone = DispatchSemaphore(value: 0)
        let revokeStarted = DispatchSemaphore(value: 0)
        let revokeDone = DispatchSemaphore(value: 0)
        let failure = Mutex<(any Error)?>(nil)
        let returned = Mutex(false)
        let lifetime = DraftLifetime(onAccess: {
            if enabled.withLock({ $0 }) {
                entered.signal()
                release.wait()
            }
        })
        let tracker = try Delta.track(["count": 0])
        let change = tracker.beginChange(lifetime: lifetime)
        let draft = try change.state
        enabled.withLock { $0 = true }
        DispatchQueue(label: "DraftLifetimeTests.operation").async {
            do { try draft.set("count", 1) }
            catch { failure.withLock { $0 = error } }
            operationDone.signal()
        }
        entered.wait()
        DispatchQueue(label: "DraftLifetimeTests.revocation").async {
            revokeStarted.signal()
            lifetime.revoke()
            // The admitted write must be complete when revoke returns.
            do { #expect(try change.prepare().value == ["count": 1]) }
            catch { failure.withLock { $0 = error } }
            returned.withLock { $0 = true }
            revokeDone.signal()
        }
        revokeStarted.wait()
        #expect(!returned.withLock { $0 })
        release.signal()
        operationDone.wait()
        revokeDone.wait()
        #expect(failure.withLock { $0 } == nil)
        #expect(returned.withLock { $0 })
        #expect(lifetime.isRevoked)
    }

    @Test func lateOperationsCannotChangeDraftOrPreparedOperations() throws {
        let lifetime = DraftLifetime()
        let tracker = try Delta.track(["count": 0, "values": [1, 2]])
        let change = tracker.beginChange(lifetime: lifetime)
        let draft = try change.state
        let array = try #require(try draft.child("values"))
        try draft.set("count", 1)
        lifetime.revoke()
        lifetime.revoke()
        expectRevoked { _ = try change.state }
        expectRevoked { _ = try draft.kind }
        expectRevoked { _ = try draft.snapshot() }
        expectRevoked { _ = try draft.get("count") }
        expectRevoked { _ = try draft.get(0) }
        expectRevoked { _ = try draft.child("values") }
        expectRevoked { _ = try draft.child(0) }
        expectRevoked { _ = try draft.keys() }
        expectRevoked { _ = try draft.count() }
        expectRevoked { _ = try draft.contains("count") }
        expectRevoked { try draft.set("count", 2) }
        expectRevoked { try draft.set(0, 2) }
        expectRevoked { try draft.remove("count") }
        expectRevoked { try array.append(3) }
        expectRevoked { try array.append(contentsOf: [3, 4]) }
        expectRevoked { _ = try array.popLast() }
        expectRevoked { _ = try array.popFirst() }
        expectRevoked { try array.prepend(contentsOf: [0]) }
        expectRevoked { _ = try array.splice(0, deleteCount: 1, insert: [3]) }
        expectRevoked { try array.reverse() }
        expectRevoked { try array.setCount(0) }
        let prepared = try change.prepare()
        #expect(prepared.value == ["count": 1, "values": [1, 2]])
        #expect(prepared.ops == [.set(["count"], 1)])
        expectRevoked { try draft.set("count", 3) }
        #expect(prepared.ops == [.set(["count"], 1)])
        try tracker.adopt(prepared)
        #expect(tracker.value == prepared.value)
    }

    @Test func nestedHandlesAndMultipleChangesUseTheSameLifetime() throws {
        let lifetime = DraftLifetime()
        let tracker = try Delta.track(["child": ["deep": ["count": 0]], "values": [["count": 0]]])
        let first = tracker.beginChange(lifetime: lifetime)
        let second = tracker.beginChange(lifetime: lifetime)
        let root = try first.state
        let child = try #require(try root.child("child"))
        let deep = try #require(try child.child("deep"))
        let values = try #require(try root.child("values"))
        let item = try #require(try values.child(0))
        let other = try second.state
        try deep.set("count", 1)
        lifetime.revoke()
        for draft in [root, child, deep, values, item, other] {
            expectRevoked { _ = try draft.snapshot() }
            expectRevoked { try draft.set("count", 2) }
        }
        #expect(try first.prepare().ops == [.set(["child", "deep", "count"], 1)])
        // Abort must remain available after shared revocation.
        second.abort()
        second.abort()
    }

    @Test func changeWithoutLifetimeKeepsExistingBehavior() throws {
        let unrelated = DraftLifetime()
        unrelated.revoke()
        let tracker = try Delta.track(["child": ["count": 0]])
        let change = tracker.beginChange()
        let root = try change.state
        let child = try #require(try root.child("child"))
        try child.set("count", 1)
        #expect(try root.snapshot() == ["child": ["count": 1]])
        let prepared = try change.prepare()
        #expect(prepared.ops == [.set(["child", "count"], 1)])
        expectRevoked { try child.set("count", 2) }
        try tracker.adopt(prepared)
        #expect(tracker.value == ["child": ["count": 1]])
    }
}
