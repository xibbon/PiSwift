import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private func d4Seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}

private func d4ResidentKB() throws -> Int {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "rss=", "-p", String(getpid())]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
}

@Suite("PiSwiftDurableTests.HarnessViewMeasurementsD4", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PI_D4_MEASURE"] == "1"),
       .timeLimit(.minutes(10)))
struct HarnessViewMeasurementsD4Tests {
    // v1.5.2 D4: harness/view.ts:277–310 and conversation-view-bench.ts.
    @Test(arguments: ["sqlite", "jsonl"], [1_000, 100_000])
    func boundedViewOpen(kind: String, count: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("d4-view-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage: any DurableStorage = kind == "sqlite"
            ? try await SqliteStorage.open(path: directory.appendingPathComponent("store.sqlite").path)
            : try await JsonlStorage.open(directory: directory.appendingPathComponent("store").path)
        var writes: [StorageWrite] = [.conversation(value: .init(id: rootConversationID))]
        writes.reserveCapacity(count + 1)
        for raw in 2...count + 1 {
            writes.append(.entry(value: .init(id: try EntryID(Int64(raw)), conversationId: rootConversationID, kind: "note")))
        }
        _ = try await storage.commit(writes, context: .background)
        writes.removeAll(keepingCapacity: false)
        let harness = try await Harness.open(storage: storage,
            options: .init(models: FakeDurableModels(), registry: createRegistry()), context: .background)
        let root = try #require(await harness.conversation(id: rootConversationID, context: .background))
        let beforeKB = try d4ResidentKB()
        let clock = ContinuousClock()
        let began = clock.now
        let watch = try await root.watch(context: .background)
        let seconds = d4Seconds(began.duration(to: clock.now))
        let afterKB = try d4ResidentKB()
        print("D4-VIEW kind=\(kind) entries=\(count) seconds=\(seconds) rssBeforeKB=\(beforeKB) rssAfterKB=\(afterKB) deltaKB=\(afterKB - beforeKB) window=\(watch.value.entries.count)")
        #expect(watch.value.entries.count == 50)
        #expect(watch.value.before != nil)
        _ = await watch.stop()
        try await harness.close(context: .background)
    }
}
