import Foundation
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

@Suite("PiSwiftDurableTests.JsonlRecoveryEdges")
struct JsonlRecoveryEdgeTests {
    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-jsonl-edge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    @Test(arguments: ["main.jsonl", "doc-2.jsonl"])
    func rejectsInvalidUTF8InCompleteLines(_ file: String) async throws {
        try await withDirectory { directory in
            try Data([0xFF, 0x0A]).write(to: directory.appendingPathComponent(file))
            do {
                _ = try await JsonlStorage.open(directory: directory.path)
                Issue.record("Invalid UTF-8 was accepted")
            } catch let error as JsonlCorruptionError {
                #expect(String(describing: error) == "Invalid UTF-8 in complete \(file) line 1")
            }
        }
    }

    @Test func acceptsBOMAtTheStartOfEachCompleteLine() async throws {
        try await withDirectory { directory in
            let text = "\u{FEFF}{\"format\":1,\"type\":\"commit\",\"seq\":1,\"writes\":[{\"type\":\"conversation\",\"value\":{\"id\":1}}]}\n\u{FEFF}{\"format\":1,\"type\":\"commit\",\"seq\":2,\"writes\":[]}\n"
            try Data(text.utf8).write(to: directory.appendingPathComponent("main.jsonl"))
            let storage = try await JsonlStorage.open(directory: directory.path)
            #expect(try await storage.conversation(rootConversationID, context: .background) != nil)
            #expect(try await storage.commit([], context: .background) == Seq(3))
            try await storage.close(context: .background)
        }
    }

    @Test func preservesSequenceGapsAndAdvancesFromTheLastMarker() async throws {
        try await withDirectory { directory in
            let text = "{\"format\":1,\"type\":\"commit\",\"seq\":2,\"writes\":[]}\n{\"format\":1,\"type\":\"commit\",\"seq\":9,\"writes\":[]}\n"
            try Data(text.utf8).write(to: directory.appendingPathComponent("main.jsonl"))
            let storage = try await JsonlStorage.open(directory: directory.path)
            #expect(try await storage.commit([], context: .background) == Seq(10))
            try await storage.close(context: .background)
        }
    }

    @Test func rejectsAnOutOfRangeIntegerWithoutOverflow() async throws {
        try await withDirectory { directory in
            let text = "{\"format\":1,\"type\":\"commit\",\"seq\":-9223372036854775808,\"writes\":[]}\n"
            try Data(text.utf8).write(to: directory.appendingPathComponent("main.jsonl"))
            await #expect(throws: JsonlCorruptionError.self) {
                _ = try await JsonlStorage.open(directory: directory.path)
            }
        }
    }

    @Test func removesOnlyRecognizedReclaimFilesAndIgnoresOtherNames() async throws {
        try await withDirectory { directory in
            let ignored = ["doc-02.jsonl", "task--1.jsonl", "notes.jsonl", "doc-2.jsonl.reclaim.extra"]
            for name in ignored + ["doc-2.jsonl.reclaim", "task-3.jsonl.reclaim"] {
                try Data("{bad}\n".utf8).write(to: directory.appendingPathComponent(name))
            }
            let storage = try await JsonlStorage.open(directory: directory.path)
            for name in ignored { #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)) }
            for name in ["doc-2.jsonl.reclaim", "task-3.jsonl.reclaim"] {
                #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
            }
            try await storage.close(context: .background)
        }
    }
}
