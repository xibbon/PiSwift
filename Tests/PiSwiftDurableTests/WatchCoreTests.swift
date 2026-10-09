import PiSwiftChord
import Testing
@testable import PiSwiftDurable

@Suite("Watch and state source generic core")
struct WatchCoreTests {
    @Test("Generic overflow uses the supplied JSON representation")
    func genericReplacement() async throws {
        let watch = CommittedWatch<Int>(value: 0, replacement: { .string("value:\($0)") }, detach: {})
        for value in 1...101 {
            watch.advance(value: value, ops: [.set(["value"], .number(Double(value)))], context: .background)
        }
        #expect(watch.value == 0)
        let values = SessionTestLog<Int>()
        let operations = SessionTestLog<[Delta.Op]>()
        try watch.start { value, ops, _ in values.append(value); operations.append(ops) }
        await watch.waitUntilIdle()
        #expect(values.values == [101])
        #expect(operations.values == [[.replace(.string("value:101"))]])
        #expect(watch.value == 101)
        _ = await watch.stop()
    }

    @Test("An overflow replacement can publish a later frame without a lock")
    func reentrantReplacement() async throws {
        let watches = SessionTestLog<CommittedWatch<Int>>()
        let watch = CommittedWatch<Int>(value: 0, replacement: { .number(Double($0)) }, detach: {}, replace: {
            watches.values[0].advance(value: 102, ops: [.replace(102)], context: .background)
            return 101
        })
        watches.append(watch)
        for value in 1...101 { watch.advance(value: value, ops: [], context: .background) }
        let values = SessionTestLog<Int>()
        try watch.start { value, _, _ in values.append(value) }
        await watch.waitUntilIdle()
        #expect(values.values == [101, 102])
        _ = await watch.stop()
    }

    @Test("Generic overflow can replace an event batch with a source snapshot")
    func genericSnapshotReplacement() async throws {
        let current = SessionTestLog<Int>()
        let replacements = SessionTestLog<Int>()
        let watch = CommittedWatch<[Int]>(value: [], replacement: { .array($0.map { .number(Double($0)) }) },
                                         detach: {}, replace: { replacements.append(1); return current.values })
        for value in 1...101 {
            current.append(value)
            watch.advance(value: [value], ops: [], context: .background)
        }
        let values = SessionTestLog<[Int]>()
        let operations = SessionTestLog<[Delta.Op]>()
        try watch.start { value, ops, _ in values.append(value); operations.append(ops) }
        await watch.waitUntilIdle()
        #expect(values.values == [Array(1...101)])
        #expect(replacements.values == [1])
        #expect(operations.values == [[.replace(.array((1...101).map { .number(Double($0)) }))]])
        _ = await watch.stop()
        watch.advance(value: [102], ops: [], context: .background)
        #expect(replacements.values == [1])
    }

    @Test("Retirement at overflow keeps the canonical terminal operations")
    func retirementAtOverflow() async throws {
        let watch = CommittedWatch<Int?>(value: 0, replacement: { value in
            value.map { .number(Double($0)) } ?? .null
        }, detach: {})
        for value in 1...100 {
            watch.advance(value: value, ops: [], context: .background)
        }
        watch.advance(value: nil, ops: [], context: .background, retired: true)
        watch.advance(value: 999, ops: [], context: .background)
        let values = SessionTestLog<Int?>()
        let operations = SessionTestLog<[Delta.Op]>()
        try watch.start { value, ops, _ in values.append(value); operations.append(ops) }
        await watch.waitUntilIdle()
        #expect(values.values == [nil])
        #expect(operations.values == [[.replace(.null)]])
        guard case .retired = await watch.closed else { Issue.record("Expected retirement"); return }
    }

    @Test("Source attachment registration captures its value and buffers later frames")
    func attachmentBoundary() throws {
        let releases = SessionTestLog<Int>()
        let source = CommittedStateSource<Int>(value: 0) { releases.append(1) }
        let attachment = try source.attach()
        source.advance(value: 1, ops: [.replace(1)], context: .background)
        #expect(attachment.snapshot.value == 0)
        #expect(attachment.snapshot.cursor == 0)
        let frames = SessionTestLog<ReplicatedStateSourceFrame<Int>>()
        try attachment.activate { frames.append($0) }
        #expect(frames.values.map(\.value) == [1])
        #expect(frames.values.map(\.cursor) == [1])
        source.advance(value: 2, ops: [.replace(2)], context: .background)
        #expect(frames.values.map(\.cursor) == [1, 2])
        attachment.dispose()
        attachment.dispose()
        #expect(releases.values == [1])
        #expect(throws: SessionError.self) { _ = try source.attach() }
    }

    @Test("Source callbacks can publish reentrant commits without a lock")
    func reentrantSource() throws {
        let source = CommittedStateSource<Int>(value: 0, release: {})
        let attachment = try source.attach()
        let frames = SessionTestLog<ReplicatedStateSourceFrame<Int>>()
        try attachment.activate { frame in
            frames.append(frame)
            if frame.value == 1 {
                source.advance(value: 2, ops: [.replace(2)], context: .background)
            }
        }
        source.advance(value: 1, ops: [.replace(1)], context: .background)
        #expect(frames.values.map(\.value) == [1, 2])
        #expect(frames.values.map(\.cursor) == [1, 2])
        source.closeSession()
    }

    @Test("Generic state uses exact operations and removes producer cancellation")
    func genericStateContext() async throws {
        let source = CommittedStateSource<Int?>(value: 0, release: {})
        let state = try replicatedState(source)
        let key = ContextKey<String>("commit")
        let child = Context.background.withValue("kept", for: key).withCancel()
        let contexts = SessionTestLog<PiSwiftChord.Context>()
        let operations = SessionTestLog<[Delta.Op]>()
        let subscription = state.subscribeOperations { ops, _, context in
            operations.append(ops)
            contexts.append(context)
        }
        let exact: [Delta.Op] = [.set(["unrelated"], true), .set(["unrelated"], true)]
        source.advance(value: 9, ops: exact, context: child.context)
        child.cancel()
        #expect(state.value == 9)
        #expect(operations.values == [exact])
        #expect(contexts.values[0].value(key) == "kept")
        #expect(contexts.values[0].abortSignal == nil)
        source.advance(value: nil, ops: [], context: .background, retired: true)
        source.advance(value: 99, ops: [], context: .background)
        #expect(state.value == nil)
        #expect(operations.values == [exact, [.replace(.null)]])
        await state.waitUntilIdle()
        subscription.cancel()
        state.dispose()
    }
}
