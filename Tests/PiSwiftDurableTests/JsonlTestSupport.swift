import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting

func jsonlWithStorage(fsync: Bool = false, _ body: (JsonlStorage, URL, FaultInjectingFileSystem) async throws -> Void) async throws {
    let directory = try jsonlTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fs = FaultInjectingFileSystem(LocalExecutionEnv(cwd: directory.path))
    let storage = try await JsonlStorage.open(directory: directory.path, fileSystem: fs, options: .init(fsync: fsync))
    do { try await body(storage, directory, fs) }
    catch { try? await storage.close(context: .background); throw error }
    try await storage.close(context: .background)
}
func jsonlOpen(_ directory: URL, fsync: Bool = false, fileSystem: (any FileSystem)? = nil) async throws -> JsonlStorage {
    try await JsonlStorage.open(directory: directory.path, fileSystem: fileSystem ?? LocalExecutionEnv(cwd: directory.path), options: .init(fsync: fsync))
}
func jsonlRoot(_ storage: any DurableStorage) async throws {
    _ = try await storage.commit([.conversation(value: .init(id: rootConversationID))], context: .background)
}
func jsonlTask(_ id: TaskID, phase: String = "ready", terminal: Bool = false) -> TaskRecord {
    .init(id: id, conversationId: rootConversationID, kind: "test.task", version: 1, input: .null,
          state: terminal ? .terminal(outcome: .completed(result: .null)) : .pending(checkpoint: ["phase": .string(phase)]))
}
func jsonlCreate(_ id: DocumentID, kind: String = "test.document", value: JSONObject = ["count": 0], scope: DocumentScope = .session(), history: DocumentHistory? = nil, fork: DocumentFork? = nil) -> StorageWrite {
    .documentCreate(record: .init(id: id, kind: kind, scope: scope, history: history, fork: fork), content: .init(version: 1, value: value))
}
func jsonlBase(_ id: DocumentID, _ count: Int) -> StorageWrite {
    .documentChange(id: id, content: .base(version: 1, value: ["count": .number(Double(count))]))
}
func jsonlDelta(_ id: DocumentID, _ count: Int) -> StorageWrite {
    .documentChange(id: id, content: .delta(version: 1, ops: [.set([.key("count")], .number(Double(count)))]))
}
func jsonlLines(_ directory: URL, _ name: String) throws -> [String] {
    let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    return text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
}
func jsonlDocName(_ id: DocumentID) -> String { "doc-\(id.rawValue).jsonl" }
func jsonlTaskName(_ id: TaskID) -> String { "task-\(id.rawValue).jsonl" }
func jsonlExists(_ directory: URL, _ name: String) -> Bool {
    FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
}
func jsonlNoReclaims(_ directory: URL) throws {
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".reclaim") }.isEmpty)
}
func jsonlAppendBytes(_ directory: URL, _ name: String, bytes: [UInt8]) throws {
    var data = try Data(contentsOf: directory.appendingPathComponent(name))
    data.append(contentsOf: bytes)
    try data.write(to: directory.appendingPathComponent(name))
}
func jsonlExpectError(_ text: String, _ body: () async throws -> Void) async throws {
    do { try await body(); Issue.record("Expected error: \(text)") }
    catch { #expect(String(describing: error).contains(text), "Expected \(text), got \(error)") }
}
