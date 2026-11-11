import Darwin
import Foundation
import PiSwiftAgent
import Testing
@testable import PiSwiftCodingAgent

// v1.5.2 C-SESS, upstream 8ddc44ec8 test/session-manager/fork-from.test.ts:29.
@Test func copiesAllEntriesWhileOpeningTheNewSessionFileOnlyOnceForWriting() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("c-sess-fork-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = SessionManager.create(root.path, root.path)
    for index in 0..<50 { source.appendMessage(userMsg("message \(index)")) }
    let sourcePath = try #require(source.getSessionFile())
    let sourceLines = try String(contentsOfFile: sourcePath, encoding: .utf8).split(separator: "\n")

    let fork = try SessionManager.forkFrom(sourcePath, root.path, root.appendingPathComponent("target").path)
    let forkPath = try #require(fork.getSessionFile())
    let forkLines = try String(contentsOfFile: forkPath, encoding: .utf8).split(separator: "\n")
    #expect(forkLines.count == 51)
    #expect(forkLines.dropFirst() == sourceLines.dropFirst())
    #expect(fork.getHeader()?.parentSession == sourcePath)
    #expect(fork.getHeader()?.id != source.getHeader()?.id)
    #expect(fork.getEntries().count == 50)
}

// v1.5.2 C-SESS, upstream 807a5c051 test/session-manager/file-operations.test.ts:477.
@Test func doesNotKeepAnEntryInMemoryWhenWritingItFails() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("c-sess-append-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = SessionManager.create(root.path, root.path)
    let first = try session.appendMessageChecked(userMsg("first question"))
    let path = try #require(session.getSessionFile())
    #expect(chmod(path, 0o444) == 0)
    defer { _ = chmod(path, 0o644) }
    #expect(throws: (any Error).self) { try session.appendMessageChecked(assistantMsg("lost answer")) }
    #expect(session.getLeafId() == first)
    #expect(session.getEntries().map(\.id) == [first])
    #expect(session.getLastWriteError() != nil)
    #expect(chmod(path, 0o644) == 0)
    let second = try session.appendMessageChecked(assistantMsg("second answer"))
    #expect(session.getEntry(second)?.parentId == first)
    #expect(SessionManager.open(path).getBranch().map(\.id) == [first, second])
}

// v1.5.2 C-SESS, upstream 807a5c051 test/session-manager/file-operations.test.ts:495.
@Test func doesNotKeepAnEntryInMemoryWhenCreatingTheFileFails() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("c-sess-create-\(UUID().uuidString)")
    let sessions = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = SessionManager.create(root.path, sessions.path)
    let model = session.appendModelChange("anthropic", "claude-sonnet-4-5")
    #expect(chmod(sessions.path, 0o555) == 0)
    let failedID = session.appendMessage(userMsg("first question"))
    #expect(chmod(sessions.path, 0o755) == 0)
    #expect(failedID.isEmpty)
    #expect(session.getLastWriteError() != nil)
    #expect(session.getLeafId() == model)
    #expect(session.getEntries().map(\.id) == [model])
    let user = try session.appendMessageChecked(userMsg("second question"))
    #expect(session.getEntry(user)?.parentId == model)
    let file = try #require(session.getSessionFile())
    #expect(loadEntriesFromFile(file).count == 3)
}

// v1.5.2 C-SESS, upstream 4ea883792 core/session-cwd.ts:14-55.
@Test func missingSessionCwdIssueAndForkKeepTheOriginal() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("c-sess-cwd-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let missing = root.appendingPathComponent("renamed-away").path
    let source = SessionManager.create(missing, root.path)
    _ = source.appendMessage(userMsg("hello"))
    let original = try #require(source.getSessionFile())
    let originalText = try String(contentsOfFile: original, encoding: .utf8)
    let issue = try #require(getMissingSessionCwdIssue(source, fallbackCwd: root.path))
    #expect(issue.prompt == "Session cwd does not exist: \(missing)")
    #expect(issue.options.count == 3)
    let fork = try SessionManager.forkFrom(original, root.path, root.path)
    #expect(fork.getCwd() == root.path)
    #expect(fork.getHeader()?.parentSession == original)
    #expect(getMissingSessionCwdIssue(fork, fallbackCwd: root.path) == nil)
    #expect(try String(contentsOfFile: original, encoding: .utf8) == originalText)
}

// v1.5.2 C-SESS, DQ4 transactional fork failure beyond upstream 4ea883792.
@Test func failedForkLeavesNoProvisionalFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("c-sess-fork-fail-\(UUID().uuidString)")
    let target = root.appendingPathComponent("target")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = SessionManager.create(root.path, root.path)
    _ = source.appendMessage(userMsg("original"))
    let path = try #require(source.getSessionFile())
    let original = try String(contentsOfFile: path, encoding: .utf8)
    #expect(chmod(target.path, 0o555) == 0)
    #expect(throws: (any Error).self) { try SessionManager.forkFrom(path, root.path, target.path) }
    #expect(chmod(target.path, 0o755) == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    #expect(try String(contentsOfFile: path, encoding: .utf8) == original)
}

// v1.5.2 C-SESS, upstream 807a5c051 _appendEntry rollback also applies after a branch move.
@Test func failedBranchSummaryRestoresTheOriginalLeaf() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("c-sess-summary-fail-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = SessionManager.create(root.path, root.path)
    let first = try session.appendMessageChecked(userMsg("original"))
    let path = try #require(session.getSessionFile())
    #expect(chmod(path, 0o444) == 0)
    #expect(throws: (any Error).self) { try session.branchWithSummary(nil, "lost") }
    #expect(chmod(path, 0o644) == 0)
    #expect(session.getLeafId() == first)
    #expect(session.getEntries().map(\.id) == [first])
}

// v1.5.2 C-SESS, Swift's eager header writers also need write-failure rollback.
@Test func failedEagerSessionHeaderDoesNotAdvanceMemory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("c-sess-header-fail-\(UUID().uuidString)")
    let sessions = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = SessionManager.create(root.path, sessions.path)
    let originalID = manager.getSessionId()
    #expect(chmod(sessions.path, 0o555) == 0)
    #expect(manager.newSession() == nil)
    #expect(manager.getSessionId() == originalID)
    #expect(manager.getSessionFile() == nil)
    #expect(manager.getHeader() == nil)
    #expect(manager.getLastWriteError() != nil)
    manager.startSession(AgentState())
    #expect(manager.getHeader() == nil)
    #expect(manager.getSessionFile() == nil)
    #expect(manager.getLastWriteError() != nil)
    #expect(chmod(sessions.path, 0o755) == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: sessions.path).isEmpty)
}
