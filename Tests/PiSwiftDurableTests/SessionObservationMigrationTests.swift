import PiSwiftChord
import Testing
@testable import PiSwiftDurable

@Suite struct SessionObservationMigrationTests {
    // session-checkpoints-migrations.test.ts:376 watch assertions.
    @Test("writes the required base on the first successful transaction, then writes deltas: watches") func requiredBaseWatchFrames() async throws {
        let harness = try await openTestSession()
        let old = try SessionDocToken<JSONObject>(kind: "migration.transition", version: 1, initial: { ["count": 4] })
        let current = try SessionDocToken<JSONObject>(kind: "migration.transition", version: 3, initial: { ["count": 0] }, migrate: { value, from in ["count": .number(value["count"]!.numberValue! + Double(from) - 1)] })
        try await harness.session.commit({ tx in _ = try await tx.doc(old) }, context: .background); try await harness.session.unloadDocuments()
        let watch = try #require(try await harness.session.watchDoc(old, context: .background)); let frames = SessionTestLog<(JSONObject?, [Delta.Op])>()
        try watch.start { value, ops, _ in frames.append((value, ops)) }
        let snapshot = try await harness.session.snapshot(current, context: .background)
        let newer = try #require(try await harness.session.watchDoc(current, context: .background)); let newFrames = SessionTestLog<JSONObject?>()
        try newer.start { value, _, _ in newFrames.append(value) }
        try await harness.session.commit({ tx in _ = try await tx.doc(current) }, context: .background); await watch.waitUntilIdle(); await newer.waitUntilIdle()
        #expect(frames.count == 1); #expect(frames.values[0].0 == ["count": 4]); #expect(frames.values[0].1 == [.replace(["count": 4])]); #expect(newFrames.count == 0)
        #expect(try await harness.session.snapshot(current, context: .background) == snapshot)
        _ = await watch.stop(); _ = await newer.stop()
    }

    // :810. JSONObject can represent both the old and the new shape.
    @Test("sends observers of an older shape a root replacement after a newer token writes") func olderShapeReplacement() async throws {
        let harness = try await openTestSession()
        let old = try SessionDocToken<JSONObject>(kind: "cache", version: 1, initial: { ["name": "first"] })
        let current = try SessionDocToken<JSONObject>(kind: "cache", version: 2, initial: { ["names": []] }, migrate: { value, _ in ["names": .array([value["name"]!])] })
        try await harness.session.commit({ tx in _ = try await tx.doc(old) }, context: .background)
        let state = try #require(try await harness.session.documentState(old, context: .background)); let watch = try #require(try await harness.session.watchDoc(old, context: .background)); let batches = SessionTestLog<[Delta.Op]>()
        try watch.start { _, ops, _ in batches.append(ops) }
        try await harness.session.commit({ tx in try await tx.doc(current).child("names")!.append("second") }, context: .background)
        await watch.waitUntilIdle(); await state.waitUntilIdle()
        #expect(state.value == ["names": ["first", "second"]]); #expect(watch.value == ["names": ["first", "second"]]); #expect(batches.values == [[.replace(["names": ["first", "second"]])]])
        state.dispose(); _ = await watch.stop()
    }
}
