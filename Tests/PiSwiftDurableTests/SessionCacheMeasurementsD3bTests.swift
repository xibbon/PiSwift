import Foundation
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private func d3bSeconds(_ duration: Duration) -> Double {
    let value = duration.components
    return Double(value.seconds) + Double(value.attoseconds) / 1e18
}
private func d3bResidentKB() throws -> Int {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "rss=", "-p", String(getpid())]
    let pipe = Pipe(); process.standardOutput = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Int(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
}

@Suite("PiSwiftDurableTests.SessionCacheMeasurementsD3b", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PI_D3B_MEASURE"] == "1"),
       .timeLimit(.minutes(5)))
struct SessionCacheMeasurementsD3bTests {
    @Test("100,000 task-record reads over 1,000 live tasks", arguments: ["memory", "sqlite", "jsonl"])
    func readHeavy(_ kind: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("d3b-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend: any DurableStorage
        switch kind {
        case "sqlite": backend = try await SqliteStorage.open(path: directory.appendingPathComponent("store.sqlite").path)
        case "jsonl": backend = try await JsonlStorage.open(directory: directory.appendingPathComponent("store").path)
        default: backend = MemoryStorage()
        }
        var writes: [StorageWrite] = [.conversation(value: .init(id: rootConversationID))]
        let ids = try (2...1_001).map { try TaskID(Int64($0)) }
        for id in ids {
            writes.append(.task(value: TaskRecord(id: id, conversationId: rootConversationID,
                kind: "bench", version: 1, input: .null, state: .pending(checkpoint: .null))))
        }
        _ = try await backend.commit(writes, context: .background)
        let cache = SessionCachedStorage(backend)
        cache.published(writes)
        let clock = ContinuousClock()
        let before = clock.now
        for index in 0..<100_000 { _ = try await backend.task(ids[index % ids.count], context: .background) }
        let direct = d3bSeconds(before.duration(to: clock.now))
        let after = clock.now
        for index in 0..<100_000 { _ = try await cache.task(ids[index % ids.count], context: .background) }
        let cached = d3bSeconds(after.duration(to: clock.now))
        print("D3B-READ \(kind) direct=\(direct) cached=\(cached) live=\(cache.sizes.liveTasks)")
        #expect(cache.sizes.liveTasks == 1_000)
        try await cache.close(context: .background)
    }

    @Test("Session with 100,000 ended tasks and 10,000 conversations has bounded caches")
    func residentBound() async throws {
        let backend = MemoryStorage()
        var writes: [StorageWrite] = []
        for id in 1...10_000 { writes.append(.conversation(value: .init(id: try ConversationID(Int64(id))))) }
        for id in 10_001...110_000 {
            writes.append(.task(value: TaskRecord(id: try TaskID(Int64(id)), conversationId: rootConversationID,
                kind: "bench", version: 1, input: .null,
                state: .terminal(outcome: .completed(result: .null)))))
        }
        _ = try await backend.commit(writes, context: .background)
        writes.removeAll(keepingCapacity: false)
        let session = try await Session.open(storage: backend, context: .background)
        let before = try d3bResidentKB()
        for id in 1...10_000 { _ = try await session.storage.conversation(ConversationID(Int64(id)), context: .background) }
        for id in 10_001...110_000 { _ = try await session.storage.task(TaskID(Int64(id)), context: .background) }
        let after = try d3bResidentKB()
        let sizes = session.recordCacheSizes
        let tailSizes = session.tailCacheSizes
        print("D3B-SIZE conversation=\(MemoryLayout<ConversationRecord>.size) task=\(MemoryLayout<TaskRecord>.size) submission=\(MemoryLayout<SubmissionRecord>.size) entry=\(MemoryLayout<EntryRecord>.size) json=\(MemoryLayout<JSONValue>.size)")
        print("D3B-MEM rssBeforeKB=\(before) rssAfterKB=\(after) conversations=\(sizes.conversations) tasks=\(sizes.tasks) live=\(sizes.liveTasks) awaited=\(sizes.awaited) waits=\(sizes.waits) submissions=\(sizes.submissions) latest=\(tailSizes.latest) markers=\(tailSizes.markers)")
        #expect(sizes.conversations == 4096)
        #expect(sizes.tasks == 256)
        #expect(sizes.liveTasks == 0)
        try await session.close(context: .background)
    }
}
