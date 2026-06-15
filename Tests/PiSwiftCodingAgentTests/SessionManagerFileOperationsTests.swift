import Foundation
import Testing
@testable import PiSwiftCodingAgent

// MARK: - loadEntriesFromFile tests

@Test func loadEntriesFromFileNonExistent() {
    let entries = loadEntriesFromFile("/nonexistent/path/file.jsonl")
    #expect(entries.isEmpty)
}

@Test func loadEntriesFromFileEmpty() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let file = tempDir.appendingPathComponent("empty.jsonl")
    try "".write(to: file, atomically: true, encoding: .utf8)

    let entries = loadEntriesFromFile(file.path)
    #expect(entries.isEmpty)
}

@Test func loadEntriesFromFileNoHeader() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let file = tempDir.appendingPathComponent("no-header.jsonl")
    try "{\"type\":\"message\",\"id\":\"1\"}\n".write(to: file, atomically: true, encoding: .utf8)

    let entries = loadEntriesFromFile(file.path)
    #expect(entries.isEmpty)
}

@Test func loadEntriesFromFileMalformed() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let file = tempDir.appendingPathComponent("malformed.jsonl")
    try "not json\n".write(to: file, atomically: true, encoding: .utf8)

    let entries = loadEntriesFromFile(file.path)
    #expect(entries.isEmpty)
}

@Test func loadEntriesFromFileValid() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let file = tempDir.appendingPathComponent("valid.jsonl")
    let content = """
    {"type":"session","id":"abc","timestamp":"2025-01-01T00:00:00Z","cwd":"/tmp"}
    {"type":"message","id":"1","parentId":null,"timestamp":"2025-01-01T00:00:01Z","message":{"role":"user","content":"hi","timestamp":1}}
    """
    try content.write(to: file, atomically: true, encoding: .utf8)

    let entries = loadEntriesFromFile(file.path)
    #expect(entries.count == 2)
    #expect(entries[0].type == "session")
    #expect(entries[1].type == "message")
}

@Test func loadEntriesFromFileSkipsMalformedLines() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let file = tempDir.appendingPathComponent("mixed.jsonl")
    let content = """
    {"type":"session","id":"abc","timestamp":"2025-01-01T00:00:00Z","cwd":"/tmp"}
    not valid json
    {"type":"message","id":"1","parentId":null,"timestamp":"2025-01-01T00:00:01Z","message":{"role":"user","content":"hi","timestamp":1}}
    """
    try content.write(to: file, atomically: true, encoding: .utf8)

    let entries = loadEntriesFromFile(file.path)
    #expect(entries.count == 2)
}

// MARK: - isValidSessionFile tests

@Test func isValidSessionFileNonExistent() {
    #expect(!isValidSessionFile("/nonexistent/path/file.jsonl"))
}

@Test func isValidSessionFileEmpty() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let file = tempDir.appendingPathComponent("empty.jsonl")
    try "".write(to: file, atomically: true, encoding: .utf8)

    #expect(!isValidSessionFile(file.path))
}

@Test func isValidSessionFileNoHeader() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let file = tempDir.appendingPathComponent("no-header.jsonl")
    try "{\"type\":\"message\",\"id\":\"1\"}\n".write(to: file, atomically: true, encoding: .utf8)

    #expect(!isValidSessionFile(file.path))
}

@Test func isValidSessionFileValid() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let file = tempDir.appendingPathComponent("valid.jsonl")
    try "{\"type\":\"session\",\"id\":\"abc\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n".write(to: file, atomically: true, encoding: .utf8)

    #expect(isValidSessionFile(file.path))
}

// MARK: - findMostRecentSession tests

@Test func findMostRecentSessionEmptyDir() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    #expect(findMostRecentSession(tempDir.path) == nil)
}

@Test func findMostRecentSessionNonExistent() {
    #expect(findMostRecentSession("/nonexistent/path") == nil)
}

@Test func findMostRecentSessionIgnoresNonJsonl() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try "hello".write(to: tempDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    try "{}".write(to: tempDir.appendingPathComponent("file.json"), atomically: true, encoding: .utf8)

    #expect(findMostRecentSession(tempDir.path) == nil)
}

@Test func findMostRecentSessionIgnoresInvalid() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try "{\"type\":\"message\"}\n".write(to: tempDir.appendingPathComponent("invalid.jsonl"), atomically: true, encoding: .utf8)

    #expect(findMostRecentSession(tempDir.path) == nil)
}

@Test func findMostRecentSessionSingleValid() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let file = tempDir.appendingPathComponent("session.jsonl")
    try "{\"type\":\"session\",\"id\":\"abc\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n".write(to: file, atomically: true, encoding: .utf8)

    #expect(findMostRecentSession(tempDir.path) == file.path)
}

@Test func findMostRecentSessionReturnsNewest() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let file1 = tempDir.appendingPathComponent("older.jsonl")
    let file2 = tempDir.appendingPathComponent("newer.jsonl")

    try "{\"type\":\"session\",\"id\":\"old\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n".write(to: file1, atomically: true, encoding: .utf8)
    try await Task.sleep(for: .milliseconds(50))
    try "{\"type\":\"session\",\"id\":\"new\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n".write(to: file2, atomically: true, encoding: .utf8)

    #expect(findMostRecentSession(tempDir.path) == file2.path)
}

@Test func findMostRecentSessionSkipsInvalidReturnsValid() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let invalid = tempDir.appendingPathComponent("invalid.jsonl")
    let valid = tempDir.appendingPathComponent("valid.jsonl")

    try "{\"type\":\"not-session\"}\n".write(to: invalid, atomically: true, encoding: .utf8)
    try await Task.sleep(for: .milliseconds(50))
    try "{\"type\":\"session\",\"id\":\"abc\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n".write(to: valid, atomically: true, encoding: .utf8)

    #expect(findMostRecentSession(tempDir.path) == valid.path)
}

// MARK: - SessionManager.open with corrupted files

@Test func openTruncatesEmptyFile() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let emptyFile = tempDir.appendingPathComponent("empty.jsonl")
    try "".write(to: emptyFile, atomically: true, encoding: .utf8)

    let sm = SessionManager.open(emptyFile.path, tempDir.path)

    #expect(!sm.getSessionId().isEmpty)
    #expect(sm.getHeader() != nil)
    #expect(sm.getHeader()?.type == "session")

    let content = try String(contentsOf: emptyFile, encoding: .utf8)
    let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == 1)
    let header = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
    #expect(header?["type"] as? String == "session")
    #expect(header?["id"] as? String == sm.getSessionId())
}

@Test func openTruncatesFileWithoutHeader() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let noHeaderFile = tempDir.appendingPathComponent("no-header.jsonl")
    try "{\"type\":\"message\",\"id\":\"abc\",\"parentId\":\"orphaned\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"message\":{\"role\":\"assistant\",\"content\":\"test\"}}\n".write(to: noHeaderFile, atomically: true, encoding: .utf8)

    let sm = SessionManager.open(noHeaderFile.path, tempDir.path)

    #expect(!sm.getSessionId().isEmpty)
    #expect(sm.getHeader() != nil)
    #expect(sm.getHeader()?.type == "session")

    let content = try String(contentsOf: noHeaderFile, encoding: .utf8)
    let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == 1)
    let header = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
    #expect(header?["type"] as? String == "session")
    #expect(header?["id"] as? String == sm.getSessionId())
}

@Test func openPreservesExplicitPath() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let explicitPath = tempDir.appendingPathComponent("my-session.jsonl")
    try "".write(to: explicitPath, atomically: true, encoding: .utf8)

    let sm = SessionManager.open(explicitPath.path, tempDir.path)

    #expect(sm.getSessionFile() == explicitPath.path)
}

@Test func createUsesExplicitSessionIdForPersistedHeader() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sm = SessionManager.create(tempDir.path, tempDir.path, sessionId: "fixed-session-id")
    sm.appendMessage(userMsg("hello"))
    sm.appendMessage(assistantMsg("hi"))

    #expect(sm.getSessionId() == "fixed-session-id")
    guard let sessionFile = sm.getSessionFile() else {
        Issue.record("expected persisted session file")
        return
    }
    let content = try String(contentsOfFile: sessionFile, encoding: .utf8)
    let firstLine = content.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    let header = try JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any]
    #expect(header?["id"] as? String == "fixed-session-id")
}

@Test func sessionDirEnvironmentOverrideExpandsTilde() {
    let resolved = getSessionDirEnvironmentOverride([
        ENV_CODING_AGENT_SESSION_DIR: "~/pi-sessions"
    ])
    #expect(resolved == URL(fileURLWithPath: getHomeDir()).appendingPathComponent("pi-sessions").path)
}

@Test func openRecoveredFileLoadsCorrectly() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let corruptedFile = tempDir.appendingPathComponent("corrupted.jsonl")
    try "garbage content\n".write(to: corruptedFile, atomically: true, encoding: .utf8)

    // First open recovers the file
    let sm1 = SessionManager.open(corruptedFile.path, tempDir.path)
    let sessionId = sm1.getSessionId()

    // Second open should load the recovered file successfully
    let sm2 = SessionManager.open(corruptedFile.path, tempDir.path)
    #expect(sm2.getSessionId() == sessionId)
    #expect(sm2.getHeader()?.type == "session")
}
