import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private actor JsonlAppendGate {
    private var entered = false
    private var released = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func holdOnce() async {
        guard !entered else { return }
        entered = true
        entryWaiter?.resume(); entryWaiter = nil
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { entryWaiter = $0 } }
    }
    func release() {
        released = true
        releaseWaiter?.resume(); releaseWaiter = nil
    }
}
private enum JsonlQueueTestError: Error { case admissionTimeout }

@Suite("PiSwiftDurableTests.JsonlConcurrency")
struct JsonlConcurrencyTests {
    private func waitForQueue(_ storage: JsonlStorage, count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await storage.queuedOperationCount < count {
            guard ContinuousClock.now < deadline else { throw JsonlQueueTestError.admissionTimeout }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func holdsReadsCommitsAndCloseInOneFIFOOrderAcrossFileIO() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-jsonl-line-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fs = FaultInjectingFileSystem(LocalExecutionEnv(cwd: directory.path))
        let storage = try await JsonlStorage.open(directory: directory.path, fileSystem: fs)
        let gate = JsonlAppendGate()
        fs.beforeOperation = { operation, path in
            if operation == .append && URL(fileURLWithPath: path).lastPathComponent == "main.jsonl" {
                await gate.holdOnce()
            }
        }
        let first = Task { try await storage.commit([.conversation(value: ConversationRecord(id: rootConversationID))], context: .background) }
        await gate.waitForEntry()
        let read = Task { try await storage.conversation(rootConversationID, context: .background) }
        do { try await waitForQueue(storage, count: 1) }
        catch { await gate.release(); throw error }
        let entry = EntryRecord(id: try EntryID(2), conversationId: rootConversationID, kind: "message")
        let second = Task { try await storage.commit([.entry(value: entry)], context: .background) }
        do { try await waitForQueue(storage, count: 2) }
        catch { await gate.release(); throw error }
        let close = Task { try await storage.close(context: .background) }
        do { try await waitForQueue(storage, count: 3) }
        catch { await gate.release(); throw error }
        #expect(fs.operations == ["append:main.jsonl"])
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("main.jsonl").path))
        await gate.release()
        #expect(try await first.value == Seq(1))
        #expect(try await read.value == ConversationRecord(id: rootConversationID))
        #expect(try await second.value == Seq(2))
        try await close.value
        await #expect(throws: (any Error).self) { _ = try await storage.commit([], context: .background) }
        let reopened = try await JsonlStorage.open(directory: directory.path)
        #expect(try await reopened.entry(entry.id, context: .background)?.entry == entry)
        #expect(try await reopened.commit([], context: .background) == Seq(3))
        try await reopened.close(context: .background)
    }
}
