import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

#if os(macOS)
/// Optional measurement: one MiB of four-character faux tokens on SQLite.
@Suite("PiSwiftDurableTests.D7StreamBenchmark", .serialized, .timeLimit(.minutes(15)))
struct D7StreamBenchmarkTests {
    private struct Result: Sendable {
        let storageCommits: Int
        let storedBytes: Int
        let firstWatchMs: Double
    }

    private func measure(window: Double) async throws -> Result {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("d7-stream-bench-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("stream.sqlite")
        let storage = ControlledStorage(try await SqliteStorage.open(path: path.path))
        let setup = HarnessChatSetup(options: .init(minTokenSize: 1, maxTokenSize: 1),
            settings: .init(compaction: .init(enabled: false),
                            progress: .init(partialIntervalMs: 100, persistWithinMs: window)))
        setup.models.setResponses([.message(chatAssistant(String(repeating: "x", count: 1 << 20)))])
        let opened = try await openChat(storage: storage, setup: setup)
        let watch = try #require(try await opened.harness.watchDoc(LiveDoc, conversationId: opened.root.id,
                                                                  context: .background))
        let first = Mutex<UInt64?>(nil)
        try watch.start { call, _ in
            guard case .value(let live, _, _) = call,
                  let text = live.generation?.message?["content"]?.arrayValue?.first?["text"]?.stringValue,
                  !text.isEmpty else { return }
            first.withLock { if $0 == nil { $0 = DispatchTime.now().uptimeNanoseconds } }
        }
        let baseline = await storage.commitBatches.flatMap { $0 }.count
        let started = DispatchTime.now().uptimeNanoseconds
        let submission = try await opened.root.submit(.input(content: .text("go")), context: .background)
        #expect(try await submission.wait(context: .background).status == "done")
        await watch.waitUntilIdle()
        _ = await watch.stop()
        try await opened.harness.close(context: .background)
        let commits = await storage.commitBatches.flatMap { $0 }.count - baseline
        let bytes = try #require((FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.intValue)
        let at = try #require(first.withLock { $0 })
        return Result(storageCommits: commits, storedBytes: bytes,
                      firstWatchMs: Double(at - started) / 1_000_000)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PI_D7_BENCH"] == "1"),
          .timeLimit(.minutes(15)))
    func oneMiBAnswerInFourCharacterTokens() async throws {
        // v1.5.2 D7 generation.ts:717-730: the same throttle stores immediately at
        // window 0 and holds through the default 1,000 ms window.
        let immediateWindow = try await measure(window: 0)
        let defaultWindow = try await measure(window: 1_000)
        #expect(defaultWindow.storageCommits < immediateWindow.storageCommits)
        #expect(defaultWindow.storedBytes < immediateWindow.storedBytes)
        print("D7-BENCH 1MiB/4chars window=0 commits=\(immediateWindow.storageCommits) bytes=\(immediateWindow.storedBytes) firstWatchMs=\(immediateWindow.firstWatchMs)")
        print("D7-BENCH 1MiB/4chars window=1000 commits=\(defaultWindow.storageCommits) bytes=\(defaultWindow.storedBytes) firstWatchMs=\(defaultWindow.firstWatchMs)")
    }
}
#endif
