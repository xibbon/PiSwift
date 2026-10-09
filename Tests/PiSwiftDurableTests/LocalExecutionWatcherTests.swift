import Foundation
import Synchronization
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

struct LocalExecutionWatcherTests {
    @Test func rejectsNullPathsBeforeOpeningCoverage() async {
        let result = await LocalFileWatcher.start(targets: [.init(path: "/tmp/bad\u{0}path")], mode: .polling,
                                                  onChange: { _ in }, context: .background)
        guard case .failure(let error) = result else { Issue.record("Null path was accepted"); return }
        #expect(error.code == .invalid)
    }

    @Test func preAbortedWatchDoesNotDeliverAChange() async {
        let controller = AbortController()
        controller.abort()
        let changes = Mutex(0)
        let result = await LocalFileWatcher.start(targets: [.init(path: "/tmp/bad\u{0}path")], mode: .native,
            forceNativeFailure: true, onChange: { _ in changes.withLock { $0 += 1 } },
            context: ChordContext.background.withAbortSignal(controller.signal))
        guard case .failure(let error) = result else { Issue.record("Aborted watch was opened"); return }
        #expect(error.code == .aborted)
        #expect(changes.withLock { $0 } == 0)
    }

    #if os(macOS)
    @Test func nativeCoverageFailureReportsOverflowAndUsesPolling() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let overflow = Mutex(0)
        let opened = await LocalFileWatcher.start(targets: [.init(path: directory)], mode: .native,
            forceNativeFailure: true, onChange: { change in
                if case .overflow = change { overflow.withLock { $0 += 1 } }
            }, context: .background)
        let watcher = try opened.get()
        #expect(watcher.mode == .polling)
        #expect(overflow.withLock { $0 } == 1)
        await watcher.close(context: .background)
        await watcher.close(context: .background)
    }
    #endif
}
