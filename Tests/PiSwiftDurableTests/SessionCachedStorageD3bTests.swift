import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private func d3bTask(_ number: Int64, _ state: TaskState = .pending(checkpoint: .null)) throws -> TaskRecord {
    TaskRecord(id: try TaskID(number), conversationId: rootConversationID, kind: "test.task",
               version: 1, input: .null, state: state)
}
private func d3bEnd(_ number: Int64) throws -> TaskRecord {
    try d3bTask(number, .terminal(outcome: .completed(result: .number(Double(number)))))
}
private func d3bWrite(_ cache: SessionCachedStorage, _ writes: [StorageWrite]) async throws {
    _ = try await cache.commit([writes], receive: { _, _ in }, context: .background)
    cache.published(writes)
}

@Suite("PiSwiftDurableTests.SessionCachedStorageD3b", .timeLimit(.minutes(2)))
struct SessionCachedStorageD3bTests {
    @Test("serves a written record without a read and follows later writes")
    func writtenAndLaterWrites() async throws {
        let backend = ControlledStorage()
        let cache = SessionCachedStorage(backend)
        try await d3bWrite(cache, [.conversation(value: .init(id: rootConversationID)), .task(value: d3bTask(2))])
        #expect(try await cache.task(TaskID(2), context: .background)?.state.status == "pending")
        try await d3bWrite(cache, [.task(value: d3bTask(2, .running(checkpoint: .null)))])
        #expect(try await cache.task(TaskID(2), context: .background)?.state.status == "running")
        #expect(await backend.taskReadCount == 0)
    }

    @Test("keeps a read only when no commit overlapped it")
    func readOverlap() async throws {
        let backend = ControlledStorage()
        _ = try await backend.commitOne([.conversation(value: .init(id: rootConversationID)), .task(value: d3bTask(2))], context: .background)
        let cache = SessionCachedStorage(backend)
        let held = await backend.holdTaskRead()
        let read = Task { try await cache.task(TaskID(2), context: .background) }
        await held.waitUntilEntered()
        #expect(cache.sizes.readsInFlight == 1)
        let newer = try d3bTask(2, .running(checkpoint: .null))
        try await d3bWrite(cache, [.task(value: newer)])
        await held.release()
        #expect(try await read.value == newer)
        #expect(try await cache.task(TaskID(2), context: .background) == newer)
        #expect(await backend.taskReadCount == 1)
        #expect(cache.sizes.readsInFlight == 0)
    }

    @Test("keeps a bounded number of ended tasks, and every live one until it ends")
    func liveBurstAndEndedBound() async throws {
        let backend = ControlledStorage()
        let cache = SessionCachedStorage(backend, taskCapacity: 4)
        try await d3bWrite(cache, [.conversation(value: .init(id: rootConversationID))])
        for id in 2..<32 { try await d3bWrite(cache, [.task(value: d3bTask(Int64(id)))]) }
        #expect(cache.sizes.liveTasks == 30)
        #expect(cache.sizes.tasks == 0)
        for id in 2..<32 { #expect(try await cache.task(TaskID(Int64(id)), context: .background) != nil) }
        #expect(await backend.taskReadCount == 0)
        for id in 2..<32 { try await d3bWrite(cache, [.task(value: d3bEnd(Int64(id)))]) }
        #expect(cache.sizes.liveTasks == 0)
        #expect(cache.sizes.tasks == 4)
    }

    @Test("applies a batch stored with commit when it is published, not at its receipt")
    func receiptIsNotPublication() async throws {
        let cache = SessionCachedStorage(MemoryStorage())
        try await d3bWrite(cache, [.conversation(value: .init(id: rootConversationID)), .task(value: d3bTask(2))])
        let writes: [StorageWrite] = [.task(value: try d3bTask(2, .running(checkpoint: .null)))]
        let result = try await cache.commit([writes], receive: { _, _ in }, context: .background)
        #expect(result.stored == 1)
        #expect(try await cache.task(TaskID(2), context: .background)?.state.status == "pending")
        cache.published(writes)
        #expect(try await cache.task(TaskID(2), context: .background)?.state.status == "running")
    }

    @Test("drops a read a publication of its record overlapped, and keeps versions only for reads in flight")
    func versionsOnlyInFlight() async throws {
        let backend = ControlledStorage()
        _ = try await backend.commitOne([.conversation(value: .init(id: rootConversationID)), .task(value: d3bTask(2)), .task(value: d3bTask(3))], context: .background)
        let cache = SessionCachedStorage(backend)
        let held = await backend.holdTaskRead()
        let two = Task { try await cache.task(TaskID(2), context: .background) }
        await held.waitUntilEntered()
        let three = Task { try await cache.task(TaskID(3), context: .background) }
        for _ in 0..<10_000 {
            if cache.sizes.readsInFlight == 2 { break }
            await Task.yield()
        }
        #expect(cache.sizes.readsInFlight == 2)
        cache.published([.task(value: try d3bTask(2, .running(checkpoint: .null)))])
        await held.release()
        #expect(try await two.value?.state.status == "running")
        #expect(try await three.value?.state.status == "pending")
        #expect(cache.sizes.readsInFlight == 0)
        #expect(await backend.taskReadCount == 2)
    }

    @Test("keeps the ended tasks a task waits on until it moved on from its wait")
    func awaitedEndedTasks() async throws {
        let backend = ControlledStorage()
        let cache = SessionCachedStorage(backend, taskCapacity: 4)
        try await d3bWrite(cache, [.conversation(value: .init(id: rootConversationID))])
        let on = [try TaskID(3), try TaskID(4)]
        func waiter(_ state: TaskState) throws -> StorageWrite { .task(value: try d3bTask(2, state)) }
        try await d3bWrite(cache, [waiter(.waiting(checkpoint: .null, on: on, policy: .allSettled))])
        try await d3bWrite(cache, [.task(value: d3bEnd(3)), .task(value: d3bEnd(4))])
        for id in 10..<40 { try await d3bWrite(cache, [.task(value: d3bEnd(Int64(id)))]) }
        #expect(cache.sizes.awaited == 2)
        try await d3bWrite(cache, [waiter(.running(checkpoint: .null))])
        for id in on { #expect(try await cache.task(id, context: .background)?.state.status == "terminal") }
        #expect(await backend.taskReadCount == 0)
        try await d3bWrite(cache, [waiter(.pending(checkpoint: .null))])
        #expect(cache.sizes.awaited == 0)
        #expect(cache.sizes.waits == 0)
    }

    @Test("keeps the written record itself, frozen: no copy")
    func writtenValueSharesBacking() async throws {
        let cache = SessionCachedStorage(MemoryStorage())
        let large = JSONValue.array(Array(repeating: .string(String(repeating: "x", count: 1024)), count: 256))
        let written = TaskRecord(id: try TaskID(2), conversationId: rootConversationID,
            kind: "test.task", version: 1, input: large, state: .pending(checkpoint: .null))
        cache.published([.task(value: written)])
        let read = try #require(try await cache.task(TaskID(2), context: .background))
        #expect(read == written)
        // Swift's Array copy-on-write storage remains shared by the record value.
        if case .array(let original) = written.input, case .array(let cached) = read.input {
            #expect(original.withUnsafeBufferPointer { $0.baseAddress } == cached.withUnsafeBufferPointer { $0.baseAddress })
        } else { Issue.record("Expected large array input") }
    }
}
