import Foundation
import Darwin
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

#if os(macOS)
private enum D12StepError: Error { case closedPipe, timeout, childFailed(Int32) }

private struct D12TaggedChild {
    let process: Process
    let input: FileHandle
    let output: FileHandle
    let errorLog: URL

    static func start(_ mode: String, path: String, prefix: String, directory: URL) throws -> Self {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/durable-fixtures/d12-tagged-sqlite.mjs")
        let process = Process(), input = Pipe(), output = Pipe()
        let errorLog = directory.appendingPathComponent("tagged-stderr.log")
        #expect(FileManager.default.createFile(atPath: errorLog.path, contents: nil))
        let errorFile = try FileHandle(forWritingTo: errorLog)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "--experimental-strip-types", script.path, mode, path, prefix]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorFile
        try process.run()
        return Self(process: process, input: input.fileHandleForWriting,
            output: output.fileHandleForReading, errorLog: errorLog)
    }

    func next(_ expected: String) throws {
        var line = Data()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw D12StepError.timeout }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, 1_000)
            if ready == 0 { continue }
            if ready < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard let data = try output.read(upToCount: 1), !data.isEmpty else {
                throw D12StepError.closedPipe
            }
            if data == Data([10]) { break }
            line.append(data)
            if line.count > 80 { throw D12StepError.closedPipe }
        }
        #expect(String(data: line, encoding: .utf8) == expected)
    }

    func advance() throws { try input.write(contentsOf: Data([10])) }

    func finish() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while process.isRunning && ContinuousClock.now < deadline { await Task.yield() }
        if process.isRunning { process.terminate(); throw D12StepError.timeout }
        if process.terminationStatus != 0 {
            let message = (try? String(contentsOf: errorLog, encoding: .utf8)) ?? ""
            Issue.record("Tagged SQLite helper: \(message)")
            throw D12StepError.childFailed(process.terminationStatus)
        }
    }

    func stop() { if process.isRunning { process.terminate() } }
}

private func d12NextSequence(_ path: String, prefix: String) throws -> SqliteValue? {
    let database = try AppleSqliteDatabase(path: path)
    defer { try? database.close() }
    return try database.get("SELECT next_seq FROM \(prefix)durable_metadata WHERE singleton = 1")?["next_seq"]
}

@Suite("PiSwiftDurableTests.D12SqliteReadOnly", .serialized)
struct D12SqliteReadOnlyTests {
    // v1.5.2 harness-read-only.test.ts:73–94 and scheduler.ts:452–487.
    @Test(.timeLimit(.minutes(1)), arguments: ["", "pi_"])
    func swiftRefreshesBesideTaggedWriterWithoutChangingItsSequence(prefix: String) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("shared.sqlite").path
        let child = try D12TaggedChild.start("write", path: path, prefix: prefix, directory: directory)
        defer { child.stop() }
        try child.next("ready")
        let firstSequence = try d12NextSequence(path, prefix: prefix)
        for (expected, signal) in [(2, "ready"), (4, "updated")] {
            if signal == "updated" { try child.next(signal) }
            let storage = try await SqliteStorage.open(path: path, prefix: prefix.isEmpty ? nil : prefix)
            let viewer = try await Harness.open(storage: storage,
                options: .init(models: FakeDurableModels(), registry: createRegistry(), readOnly: true,
                    now: { 1_700_000_000_000 }), context: .background)
            let root = try await viewer.root(context: .background)
            #expect(try await allEntries(root).count == expected)
            let before = try d12NextSequence(path, prefix: prefix)
            try await viewer.close(context: .background)
            #expect(try d12NextSequence(path, prefix: prefix) == before)
            if signal == "ready" {
                #expect(before == firstSequence)
                try child.advance()
            }
        }
        try child.advance()
        try await child.finish()
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["", "pi_"])
    func taggedViewerRefreshesBesideSwiftWriter(prefix: String) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("shared.sqlite").path
        let setup = HarnessChatSetup(clock: TestClock(now: 1_700_000_000_000))
        let chat = try await openChat(storage: SqliteStorage.open(path: path, prefix: prefix.isEmpty ? nil : prefix), setup: setup)
        func answer(_ number: Int) -> AssistantMessage { chatAssistant("answer-\(number)") }
        setup.models.setResponses([.message(answer(1))])
        _ = try await chat.root.submit(.input(content: .text("question-1")),
            context: .background).wait(context: .background)
        let child = try D12TaggedChild.start("view", path: path, prefix: prefix, directory: directory)
        defer { child.stop() }
        try child.next("ready")
        setup.models.setResponses([.message(answer(2))])
        _ = try await chat.root.submit(.input(content: .text("question-2")),
            context: .background).wait(context: .background)
        let sequence = try d12NextSequence(path, prefix: prefix)
        try child.advance()
        try child.next("refreshed")
        #expect(try d12NextSequence(path, prefix: prefix) == sequence)
        try child.advance()
        try await child.finish()
        try await chat.harness.close(context: .background)
    }
}
#endif
