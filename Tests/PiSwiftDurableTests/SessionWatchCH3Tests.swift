import PiSwiftChord
import Synchronization
import Testing
@testable import PiSwiftDurable

final class SessionObserverWeak<Value: AnyObject & Sendable>: Sendable {
    private struct State { weak var value: Value? }
    private let state: Mutex<State>
    init(_ value: Value) { state = Mutex(State(value: value)) }
    var value: Value? { state.withLock { $0.value } }
}

private final class ObservedReference: Codable, Sendable {
    let value: Int
    init(value: Int) { self.value = value }
}

@Suite(.timeLimit(.minutes(1))) struct SessionWatchCH3Tests {
    // v1.5.2 CH3 session-watches.test.ts:203.
    @Test("replaces the root once more than 10,000 ops are pending after folding") func remainingOpsLimit() async throws {
        let h = try await openTestSession()
        let token = try SessionDocToken<JSONObject>(kind: "watch.keys", version: 1, initial: { ["keys": [:]] }, checkpointWhen: { _, _, _ in false })
        try await h.session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        let watch = try #require(try await h.session.watchDoc(token, context: .background))
        for range in [0..<4_000, 4_000..<8_000, 8_000..<10_001] {
            try await h.session.commit({ tx in
                let keys = try await tx.doc(token).child("keys")!
                for index in range { try keys.set("k\(index)", .number(Double(index))) }
            }, context: .background)
        }
        let calls = SessionTestLog<WatchCall<JSONObject>>()
        try watch.start { call, _ in calls.append(call) }; await watch.waitUntilIdle()
        #expect(calls.values == [.value(value: watch.value, ops: [.replace(.object(watch.value))], retired: false)])
        #expect(watch.value["keys"]?.objectValue?.count == 10_001)
        _ = await watch.stop(); try await h.session.close(context: .background)
    }

    // v1.5.2 CH3 session-watches.test.ts:370.
    @Test("reports a change and retirement in one commit with the value it was given before") func changedThenRetired() async throws {
        let (h, token) = try await createObservationState()
        let watch = try #require(try await h.session.watchDoc(token, context: .background)); let before = watch.value
        let calls = SessionTestLog<WatchCall<ObservationValue>>()
        try watch.start { call, _ in calls.append(call) }
        try await h.session.commit({ tx in try await tx.doc(token).set("value", 5); try await tx.retireDoc(token) }, context: .background)
        await watch.waitUntilIdle()
        #expect(calls.values == [.value(value: before, ops: [], retired: true)])
        #expect(await h.storage.commits.last?.count == 2)
        _ = await watch.stop(); try await h.session.close(context: .background)
    }

    // v1.5.2 CH3 session-watches.test.ts:118. Both commits finish before the listener's gate is released.
    @Test("a slow listener does not delay a Session commit") func slowListener() async throws {
        let (h, token) = try await createObservationState()
        let watch = try #require(try await h.session.watchDoc(token, context: .background))
        let entered = SessionTestGate(); let release = SessionTestGate(); let calls = SessionTestLog<Int>()
        defer { release.release() }
        try watch.start { call, _ in
            if case .value(let value, _, _) = call { calls.append(value.value) }
            entered.release(); await release.wait()
        }
        try await setObservation(1, h, token); await entered.wait()
        try await setObservation(2, h, token)
        #expect(try await h.session.snapshot(token, context: .background)?.value == 2)
        #expect(calls.values == [1])
        release.release(); await watch.waitUntilIdle(); #expect(calls.values == [1, 2])
        _ = await watch.stop(); try await h.session.close(context: .background)
    }

    // v1.5.2 CH3 session-watches.test.ts:624.
    @Test("ignores the same kind in another conversation and under another family key") func addressIsolation() async throws {
        let h = try await openTestSession(); let id = try await createConversation(h.session); let other = try await createConversation(h.session)
        let token = try ConversationDocToken<JSONObject>(kind: "watch.address", version: 1, fork: .initial,
            initial: { ["text": ""] }, checkpointWhen: { _, _, _ in false })
        let family = try SessionDocFamilyToken<JSONObject, Int>(kind: "watch.family", version: 1,
            initial: { _ in ["text": ""] }, checkpointWhen: { _, _, _ in false })
        try await h.session.commit({ tx in
            try await tx.doc(token, conversationId: id).set("text", "a")
            try await tx.doc(family, key: "watched", seed: 0).set("text", "a")
        }, context: .background)
        let watch = try #require(try await h.session.watchDoc(token, conversationId: id, context: .background))
        let member = try #require(try await h.session.watchDoc(family, key: "watched", context: .background))
        let calls = SessionTestLog<WatchCall<JSONObject>>()
        try watch.start { call, _ in calls.append(call) }; try member.start { call, _ in calls.append(call) }
        for text in ["other", "again"] {
            try await h.session.commit({ tx in
                try await tx.doc(token, conversationId: other).set("text", .string(text))
                try await tx.doc(family, key: "other", seed: 0).set("text", .string(text))
            }, context: .background)
            try await h.session.commit({ tx in
                try await tx.retireDoc(token, conversationId: other); try await tx.retireDoc(family, key: "other")
            }, context: .background)
        }
        await watch.waitUntilIdle(); await member.waitUntilIdle()
        #expect(calls.count == 0); #expect(h.session.documentCacheSizes.attached == 2)
        _ = await watch.stop(); _ = await member.stop(); try await h.session.close(context: .background)
    }

    // v1.5.2 CH3 session-watches.test.ts:679.
    @Test("takes the version of a recreation written by a newer definition, then its ops") func recreationVersion() async throws {
        let h = try await openTestSession()
        let old = try SessionDocToken<JSONObject>(kind: "watch.version", version: 1, initial: { ["value": 1] }, checkpointWhen: { _, _, _ in false })
        let current = try SessionDocToken<JSONObject>(kind: "watch.version", version: 2,
            initial: { ["value": 0, "migrated": false] }, migrate: { value, _ in ["value": value["value"]!, "migrated": true] }, checkpointWhen: { _, _, _ in false })
        try await h.session.commit({ tx in _ = try await tx.doc(old) }, context: .background)
        let watch = try #require(try await h.session.watchDoc(old, context: .background)); let calls = SessionTestLog<WatchCall<JSONObject>>()
        try watch.start { call, _ in calls.append(call) }
        try await h.session.commit({ tx in try await tx.retireDoc(current); try await tx.doc(current).set("value", 5) }, context: .background)
        await watch.waitUntilIdle()
        try await h.session.commit({ tx in try await tx.doc(current).set("value", 6) }, context: .background)
        await watch.waitUntilIdle()
        #expect(calls.values == [
            .value(value: ["value": 5, "migrated": false], ops: [.replace(["value": 5, "migrated": false])], retired: true),
            .value(value: ["value": 6, "migrated": false], ops: [.set(["value"], 6)], retired: false)])
        _ = await watch.stop(); try await h.session.close(context: .background)
    }

    // v1.5.2 CH3 session-watches.test.ts:724. Immutable Swift class values make ARC release observable.
    @Test("keeps no earlier incarnation alive after retirement and recreation", arguments: [0.0, 600_000.0])
    func releasedIncarnation(retention: Double) async throws {
        let session = try await Session.open(storage: MemoryStorage(), documentRetentionMs: retention, context: .background)
        let token = try SessionDocToken<ObservedReference>(kind: "watch.arc", version: 1,
            initial: { ObservedReference(value: 0) }, checkpointWhen: { _, _, _ in false })
        try await session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        let watch = try #require(try await session.watchDoc(token, context: .background))
        let first = SessionObserverWeak(watch.value)
        try watch.start { _, _ in }
        try await session.commit({ tx in try await tx.retireDoc(token); try await tx.doc(token).set("value", 2) }, context: .background)
        await watch.waitUntilIdle(); try await session.unloadDocuments()
        #expect(watch.value.value == 2); #expect(first.value == nil)
        _ = await watch.stop(); try await session.close(context: .background)
    }

    // v1.5.2 CH3 session-watches.test.ts:764.
    @Test("keeps a retired document watch until stopped, then releases it") func stoppedWatchReleased() async throws {
        let (h, token) = try await createObservationState()
        func acquire() async throws -> SessionObserverWeak<Watch<ObservationValue>> {
            let watch = try #require(try await h.session.watchDoc(token, context: .background))
            try watch.start { _, _ in }
            try await h.session.commit({ tx in try await tx.retireDoc(token) }, context: .background)
            await watch.waitUntilIdle(); return SessionObserverWeak(watch)
        }
        let weak = try await acquire(); #expect(weak.value != nil)
        _ = await weak.value?.stop(); #expect(weak.value == nil)
        try await h.session.close(context: .background)
    }

    // v1.5.2 CH3 session-watches.test.ts:810, plus Session close's ARC boundary.
    @Test("a stopped or closed watch retains neither Session nor listener", arguments: [false, true])
    func releasedSession(close: Bool) async throws {
        final class ListenerToken: Sendable {}
        func acquire() async throws -> (Watch<ObservationValue>, SessionObserverWeak<Session>, SessionObserverWeak<ListenerToken>) {
            let session = try await Session.open(storage: MemoryStorage(), documentRetentionMs: .infinity, context: .background)
            let token = try observationToken()
            try await session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
            let watch = try #require(try await session.watchDoc(token, context: .background))
            let listener = ListenerToken(); let weakListener = SessionObserverWeak(listener)
            try watch.start { [listener] _, _ in _ = listener }
            try await session.commit({ tx in try await tx.doc(token).set("value", 1) }, context: .background)
            await watch.waitUntilIdle()
            if close { try await session.close(context: .background) } else { _ = await watch.stop() }
            return (watch, SessionObserverWeak(session), weakListener)
        }
        let (watch, session, listener) = try await acquire()
        #expect(session.value == nil); #expect(listener.value == nil)
        #expect(watch.value.value == 1); #expect(await watch.closed == (close ? .ended : .stopped))
    }

    // v1.5.2 CH3 session-observers.test.ts:265.
    @Test("keeps no detached observer alive") func detachedObserverReleased() async throws {
        final class ListenerToken: Sendable {}
        let (h, token) = try await createObservationState()
        func acquire() async throws -> (Observation<ObservationValue>, SessionObserverWeak<ListenerToken>) {
            let listener = ListenerToken()
            let attached = try await h.session.observeDoc(token,
                observer: Observer(advance: { [listener] _, _ in _ = listener }, end: { _ in }), context: .background)
            let observation = try #require(attached)
            return (observation, SessionObserverWeak(listener))
        }
        let (observation, listener) = try await acquire(); #expect(listener.value != nil)
        observation.detach(); #expect(listener.value == nil)
        try await h.session.close(context: .background)
    }

    // v1.5.2 CH3 session-observers.test.ts:309.
    @Test("an attached observer keeps no latest value of a document retired for good") func retiredObserverValueReleased() async throws {
        let h = try await openTestSession()
        let token = try SessionDocToken<ObservedReference>(kind: "observer.arc", version: 1,
            initial: { ObservedReference(value: 0) }, checkpointWhen: { _, _, _ in false })
        try await h.session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        let latest = Mutex<SessionObserverWeak<ObservedReference>?>(nil)
        let observation = try #require(try await h.session.observeDoc(token, observer: Observer(advance: { call, _ in
            if case .value(let value, _, false) = call { latest.withLock { $0 = SessionObserverWeak(value) } }
        }, end: { _ in }), context: .background))
        try await h.session.commit({ tx in try await tx.doc(token).set("value", 7) }, context: .background)
        try await h.session.commit({ tx in try await tx.retireDoc(token) }, context: .background)
        try await h.session.unloadDocuments()
        #expect(latest.withLock { $0?.value } == nil)
        observation.detach(); try await h.session.close(context: .background)
    }
}
