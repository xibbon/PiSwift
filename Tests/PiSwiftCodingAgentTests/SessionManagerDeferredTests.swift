import Foundation
import Testing
@testable import PiSwiftCodingAgent

// MARK: - NewSessionOptions with custom id

@Test func newSessionWithCustomId() {
    let sm = SessionManager.inMemory()
    sm.newSession(NewSessionOptions(id: "custom-id-123"))
    #expect(sm.getSessionId() == "custom-id-123")
}

@Test func newSessionWithCustomIdAndParent() {
    let sm = SessionManager.inMemory()
    sm.newSession(NewSessionOptions(parentSession: "parent-abc", id: "child-xyz"))
    #expect(sm.getSessionId() == "child-xyz")
    #expect(sm.getHeader()?.parentSession == "parent-abc")
}

@Test func newSessionWithoutCustomIdGeneratesUUID() {
    let sm = SessionManager.inMemory()
    sm.newSession()
    let id = sm.getSessionId()
    #expect(!id.isEmpty)
    #expect(id != "custom-id-123") // Just verify it's generated, not empty
}

// MARK: - getDefaultSessionDir with agentDir parameter

@Test func getDefaultSessionDirWithExplicitSessionDir() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID().uuidString)")
    let sessionDir = tempDir.appendingPathComponent("explicit-sessions").path
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let result = getDefaultSessionDir(cwd: "/tmp/myproject", sessionDir: sessionDir)
    #expect(result == sessionDir)
    #expect(FileManager.default.fileExists(atPath: sessionDir))
}

@Test func getDefaultSessionDirWithAgentDir() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID().uuidString)")
    let agentDir = tempDir.appendingPathComponent("agent").path
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let result = getDefaultSessionDir(cwd: "/tmp/myproject", agentDir: agentDir)
    // Should resolve to agentDir/sessions/--<safe-cwd>--
    #expect(result.hasPrefix(agentDir))
    #expect(result.contains("sessions"))
    #expect(FileManager.default.fileExists(atPath: result))
}

@Test func getDefaultSessionDirSessionDirTakesPrecedenceOverAgentDir() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID().uuidString)")
    let sessionDir = tempDir.appendingPathComponent("explicit").path
    let agentDir = tempDir.appendingPathComponent("agent").path
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let result = getDefaultSessionDir(cwd: "/tmp", sessionDir: sessionDir, agentDir: agentDir)
    #expect(result == sessionDir)
}

// MARK: - Deferred persistence: no file until assistant message

@Test func deferredPersistenceDoesNotWriteUntilAssistantMessage() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sm = SessionManager.create(tempDir.path, tempDir.path)

    // Append a user message — should NOT create a file yet
    sm.appendMessage(userMsg("hello"))

    let sessionFile = sm.getSessionFile()
    #expect(sessionFile != nil)
    // The file should NOT exist on disk yet (deferred)
    #expect(!FileManager.default.fileExists(atPath: sessionFile!))
}

@Test func deferredPersistenceWritesOnAssistantMessage() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sm = SessionManager.create(tempDir.path, tempDir.path)

    // Append user message, then assistant message
    sm.appendMessage(userMsg("hello"))
    sm.appendMessage(assistantMsg("hi there"))

    let sessionFile = sm.getSessionFile()
    #expect(sessionFile != nil)
    // NOW the file should exist on disk
    #expect(FileManager.default.fileExists(atPath: sessionFile!))

    // Verify it contains the header + both messages
    let content = try String(contentsOfFile: sessionFile!, encoding: .utf8)
    let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == 3) // header + user + assistant
}
