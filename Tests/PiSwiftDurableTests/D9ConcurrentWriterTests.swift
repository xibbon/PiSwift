import CryptoKit
import Foundation
import PiSwiftChord
import PiSwiftDurable
import Testing

private struct D9FileFingerprint: Equatable {
    let size: UInt64
    let modificationDate: Date
    let hash: Data
}

private func d9Fingerprints(_ directory: URL) throws -> [String: D9FileFingerprint] {
    var result: [String: D9FileFingerprint] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() {
        let path = directory.appendingPathComponent(name).path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        result[name] = D9FileFingerprint(
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modificationDate: try #require(attributes[.modificationDate] as? Date),
            hash: Data(SHA256.hash(data: data)))
    }
    return result
}

private func d9Writer(_ directory: URL, signal: URL, commits: Int, paceMs: Int,
                      progress: URL? = nil, readerOpens: Int = 0) throws -> (Process, URL) {
    let process = Process()
    let output = URL(fileURLWithPath: signal.path + ".log")
    try Data().write(to: output)
    let outputHandle = try FileHandle(forWritingTo: output)
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", "--experimental-strip-types", "Scripts/durable-fixtures/d9-tagged-jsonl.mjs", "write",
                         directory.path, signal.path, String(commits), String(paceMs),
                         progress?.path ?? "-", String(readerOpens)]
    process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    process.standardOutput = outputHandle
    process.standardError = outputHandle
    try process.run()
    return (process, output)
}

private func d9NodeViewer(_ directory: URL, signal: URL, opens: Int) throws -> (Process, URL) {
    let process = Process()
    let output = URL(fileURLWithPath: signal.path + ".log")
    try Data().write(to: output)
    let outputHandle = try FileHandle(forWritingTo: output)
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", "--experimental-strip-types", "Scripts/durable-fixtures/d9-tagged-jsonl.mjs", "read",
                         directory.path, signal.path, String(opens)]
    process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    process.standardOutput = outputHandle
    process.standardError = outputHandle
    try process.run()
    return (process, output)
}

private func d9WaitForReady(_ process: Process, _ signal: URL) async throws {
    for _ in 0..<400 {
        if FileManager.default.fileExists(atPath: signal.path) { return }
        if !process.isRunning { throw D9WriterError.earlyExit }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw D9WriterError.readyTimeout
}

private func d9AwaitExit(_ process: Process) async throws {
    for _ in 0..<15_000 {
        if !process.isRunning { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    process.terminate()
    throw D9WriterError.exitTimeout
}

private enum D9WriterError: Error { case earlyExit, readyTimeout, exitTimeout, writerFailed(Int32) }

@Suite(.serialized) struct D9ConcurrentWriterTests {
    @Test func taggedNodeWriterAndSwiftReadOnlyViewerKeepCommittedPrefixes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("piswift-d9-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let live = root.appendingPathComponent("live")
        let control = root.appendingPathComponent("control")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        let count = 400
        let opens = ProcessInfo.processInfo.environment["PISWIFT_D9_FULL"] == "1" ? 2_000 : 200
        let signal = root.appendingPathComponent("ready")
        let progress = root.appendingPathComponent("swift-reader-progress")
        let (writer, output) = try d9Writer(live, signal: signal, commits: count,
            paceMs: 0, progress: progress, readerOpens: opens)
        defer { if writer.isRunning { writer.terminate() } }
        try await d9WaitForReady(writer, signal)
        var lastPhase = 0
        var opensWhileWriting = 0
        var stableOpens = 0
        var seed: UInt32 = 0xD9A152
        let taskId = try TaskID(2)
        for index in 0..<opens {
            if writer.isRunning { opensWhileWriting += 1 }
            let before = try d9Fingerprints(live)
            let viewer = try await JsonlStorage.open(directory: live.path,
                options: .init(readOnly: true))
            let rootRecord = try await viewer.conversation(rootConversationID, context: .background)
            #expect(rootRecord != nil)
            let task = try #require(await viewer.task(taskId, context: .background))
            let state = try JSONValue(encoding: task)
            let phase = try #require(state["state"]?["checkpoint"]?["phase"]?.stringValue)
            let number = Int(phase.split(separator: ".").first ?? "0") ?? 0
            #expect(number >= lastPhase && number <= count)
            lastPhase = number
            try await viewer.close(context: .background)
            let after = try d9Fingerprints(live)
            if before == after { stableOpens += 1 }
            try Data(String(index + 1).utf8).write(to: progress)
            seed = seed &* 1_664_525 &+ 1_013_904_223
            try await Task.sleep(for: .milliseconds(Int(seed % 3)))
        }
        try await d9AwaitExit(writer)
        let writerText = try String(contentsOf: output, encoding: .utf8)
        guard writer.terminationStatus == 0 else { throw D9WriterError.writerFailed(writer.terminationStatus) }
        #expect(writerText.contains("commits=802 refused=0"))
        let (controlWriter, controlOutput) = try d9Writer(control, signal: root.appendingPathComponent("control-ready"), commits: count, paceMs: 0)
        defer { if controlWriter.isRunning { controlWriter.terminate() } }
        try await d9AwaitExit(controlWriter)
        let controlText = try String(contentsOf: controlOutput, encoding: .utf8)
        guard controlWriter.terminationStatus == 0 else { throw D9WriterError.writerFailed(controlWriter.terminationStatus) }
        #expect(controlText.contains("commits=802 refused=0"))
        #expect(opensWhileWriting >= opens / 2)
        let liveFiles = try d9Fingerprints(live)
        let controlFiles = try d9Fingerprints(control)
        #expect(liveFiles.keys == controlFiles.keys)
        for name in liveFiles.keys { #expect(liveFiles[name]?.hash == controlFiles[name]?.hash) }
        print("d9 live node writer opens=\(opens) whileWriting=\(opensWhileWriting) stableByteChecks=\(stableOpens) commits=802 refused=0 finalEqual=1")
    }

    @Test func taggedNodeReadOnlyViewerTracksSwiftWriterWithoutChangingItsBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("piswift-d9-reverse-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let live = root.appendingPathComponent("live")
        let control = root.appendingPathComponent("control")
        let writer = try await JsonlStorage.open(directory: live.path)
        try await jsonlRoot(writer)
        let taskId: TaskID = try await writer.mintId()
        #expect(taskId.rawValue == 2)
        _ = try await writer.commitOne([.task(value: jsonlTask(taskId, phase: "initial"))], context: .background)
        let opens = ProcessInfo.processInfo.environment["PISWIFT_D9_FULL"] == "1" ? 2_000 : 200
        let (viewer, output) = try d9NodeViewer(live, signal: root.appendingPathComponent("viewer-ready"), opens: opens)
        defer { if viewer.isRunning { viewer.terminate() } }
        try await d9WaitForReady(viewer, root.appendingPathComponent("viewer-ready"))
        let count = 400
        for i in 1...count {
            let result = try await writer.commit([
                [.task(value: jsonlTask(taskId, phase: "\(i).a"))],
                [.task(value: jsonlTask(taskId, phase: "\(i).b"))]
            ], receive: { _, _ in }, context: .background)
            #expect(result.stored == 2 && result.refused == nil)
            let target = i * opens / count
            let progressPath = root.appendingPathComponent("viewer-ready.progress")
            while true {
                let progress = Int((try? String(contentsOf: progressPath, encoding: .utf8)) ?? "0") ?? 0
                if progress >= target { break }
                if !viewer.isRunning { throw D9WriterError.earlyExit }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        try await writer.close(context: .background)
        try Data("done".utf8).write(to: root.appendingPathComponent("viewer-ready.done"))
        try await d9AwaitExit(viewer)
        let text = try String(contentsOf: output, encoding: .utf8)
        guard viewer.terminationStatus == 0 else { throw D9WriterError.writerFailed(viewer.terminationStatus) }
        #expect(text.contains("opens=\(opens) whileWriting=") && text.contains("read-only root=1 commitRejected=\(opens)"), "\(text)")
        let controlWriter = try await JsonlStorage.open(directory: control.path)
        try await jsonlRoot(controlWriter)
        let controlTaskId: TaskID = try await controlWriter.mintId()
        _ = try await controlWriter.commitOne([.task(value: jsonlTask(controlTaskId, phase: "initial"))], context: .background)
        for i in 1...count {
            _ = try await controlWriter.commit([
                [.task(value: jsonlTask(controlTaskId, phase: "\(i).a"))],
                [.task(value: jsonlTask(controlTaskId, phase: "\(i).b"))]
            ], receive: { _, _ in }, context: .background)
        }
        try await controlWriter.close(context: .background)
        let liveFiles = try d9Fingerprints(live)
        let controlFiles = try d9Fingerprints(control)
        #expect(liveFiles.keys == controlFiles.keys)
        for name in liveFiles.keys { #expect(liveFiles[name]?.hash == controlFiles[name]?.hash) }
        print("d9 live swift writer node viewer opens=\(opens) commits=802 refused=0 finalEqual=1")
    }
}
