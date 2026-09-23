import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private let orderedNames = ["zeta", "beta", "omega", "alpha", "ten", "three", "seven", "delta", "kappa", "gamma", "epsilon", "theta"]

private func orderedSystem() -> SystemMessage {
    SystemMessage(content: .text("base"), sections: SystemPromptSections(orderedNames.map { ($0, "value-\($0)") }),
        toolsAdded: [AITool(name: "read", description: "Read files", parameters: ["type": AnyCodable("object")])], timestamp: 123)
}

private func projectionText(_ message: AgentMessage) -> String? {
    switch message {
    case .user(let user):
        if case .text(let value) = user.content { return value }
        return nil
    case .assistant(let assistant):
        if case .text(let value) = assistant.content.first { return value.text }
        return nil
    case .toolResult(let result):
        if case .text(let value) = result.content.first { return value.text }
        return nil
    default: return nil
    }
}

@Test func contextEditsAreBranchLocalAndOnlyChangeProjectedContent() throws {
    let manager = SessionManager.inMemory()
    let target = manager.appendMessage(.user(UserMessage(content: .text("original"))))
    _ = try manager.appendContextEdit(target, .text("first"))
    _ = try manager.appendContextEdit(target, nil)
    _ = try manager.appendContextEdit(target, .text("final"))
    #expect(manager.buildSessionProjection().messages.compactMap(projectionText) == ["final"])
    guard case .message(let raw) = manager.getEntry(target) else { Issue.record("missing raw message"); return }
    #expect(projectionText(raw.message) == "original")
    try manager.branch(target)
    #expect(manager.buildSessionProjection().messages.compactMap(projectionText) == ["original"])
    let other = manager.appendMessage(.user(UserMessage(content: .text("other"))))
    try manager.branch(target)
    #expect(throws: SessionManagerError.self) { try manager.appendContextEdit(other, nil) }
    #expect(throws: SessionManagerError.self) { try manager.appendContextEdit("missing", nil) }
}

@Test func assistantAndToolResultStringEditsBecomeTextBlocks() throws {
    let manager = SessionManager.inMemory()
    let assistant = AssistantMessage(content: [.text(TextContent(text: "raw"))], api: .anthropicMessages,
        provider: "anthropic", model: "model", usage: Usage(input: 2, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 3), stopReason: .stop)
    let assistantID = manager.appendMessage(.assistant(assistant))
    let resultID = manager.appendMessage(.toolResult(ToolResultMessage(toolCallId: "c", toolName: "read",
        content: [.text(TextContent(text: "raw result"))], isError: false)))
    let assistantEditID = try manager.appendContextEdit(assistantID, .text("new answer"))
    let resultEditID = try manager.appendContextEdit(resultID, .text("new result"))
    for id in [assistantEditID, resultEditID] {
        guard case .contextEdit(let edit) = manager.getEntry(id), case .blocks(let blocks) = edit.replacement else {
            Issue.record("string edit was not normalized"); return
        }
        #expect(blocks.count == 1)
    }
    #expect(manager.buildSessionContext().messages.compactMap(projectionText) == ["new answer", "new result"])
    #expect(manager.buildSessionProjection().entries.filter { $0.sourceEntry.type == "context_edit" }.allSatisfy { $0.messages.isEmpty })
}

@Test func newestCompactionCheckpointAndRetainNoneWin() {
    let manager = SessionManager.inMemory()
    manager.appendMessage(.system(orderedSystem()))
    let retained = manager.appendMessage(.user(UserMessage(content: .text("kept"))))
    manager.appendCompaction("first", retained, 100)
    let latest = manager.appendCompaction("second", nil, 80)
    guard case .compaction(let entry) = manager.getEntry(latest) else { Issue.record("missing compaction"); return }
    #expect(entry.firstKeptEntryId == latest)
    #expect(entry.systemMessage?.sections?.entries.map(\.name) == orderedNames)
    #expect(entry.systemMessage?.toolsAdded?.map(\.name) == ["read"])
    #expect(manager.buildSessionProjection().messages.map(\.role) == ["system", "compactionSummary"])
    #expect(manager.buildContextEntries().map(\.id) == [latest])
}

@Test func usageEntriesAreOutOfContextAndCountTowardCost() {
    let manager = SessionManager.inMemory()
    let usage = Usage(input: 3, output: 2, cacheRead: 7, cacheWrite: 1, totalTokens: 13,
        cost: UsageCost(input: 0.1, output: 0.2, cacheRead: 0.3, cacheWrite: 0.4, total: 1.0))
    manager.appendUsage("future_kind", "provider", "model", usage)
    #expect(manager.buildSessionProjection().messages.isEmpty)
    let breakdown = getUsageCostBreakdown(manager.getEntries())
    #expect(breakdown.count == 1)
    #expect(breakdown[0].key == "provider/model")
    #expect(breakdown[0].tokens == 13)
    #expect(breakdown[0].cost == 1)
}

@Test func importedUpstreamShapeAndOrderedPathsRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("v087-session-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("import.jsonl")
    let sections = orderedNames.map { "\"\($0)\":\"value-\($0)\"" }.joined(separator: ",")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/upstream-session-v087.jsonl")
    let fixtureText = try String(contentsOf: fixture, encoding: .utf8)
    try fixtureText.replacingOccurrences(of: "__CWD__", with: directory.path)
        .write(to: file, atomically: true, encoding: .utf8)
    let manager = SessionManager.open(file.path)
    #expect(manager.getEntries().count == 5)
    #expect(manager.buildSessionContext().messages.map(\.role) == ["system", "compactionSummary", "user"])
    #expect(manager.buildSessionContext().messages.compactMap(projectionText) == ["edited"])
    guard case .compaction(let checkpoint) = manager.getEntry("c") else { Issue.record("checkpoint missing"); return }
    #expect(checkpoint.systemMessage?.sections?.entries.map(\.name) == orderedNames)
    let exported = try exportSessionToJsonl(manager, outputPath: directory.appendingPathComponent("export.jsonl").path,
        createTrailingEntries: { parent, timestamp in
            [["type": AnyCodable("custom"), "id": AnyCodable("tail"), "parentId": parent.map(AnyCodable.init) ?? AnyCodable(NSNull()),
              "timestamp": AnyCodable(timestamp), "customType": AnyCodable("export-only")]]
        })
    let exportedText = try String(contentsOfFile: exported, encoding: .utf8)
    #expect(exportedText.contains("\"sections\":{\(sections)}"))
    #expect(exportedText.contains("\"systemMessage\":"))
    #expect(try serializeSessionBranch(manager).contains("\"sections\":{\(sections)}"))
    #expect(SessionManager.open(exported).getEntries().count == 6)
    #expect(manager.getEntries().count == 5)
    let branched = try #require(manager.createBranchedSession("v"))
    #expect((try String(contentsOfFile: branched, encoding: .utf8)).contains("\"sections\":{\(sections)}"))
    #expect(SessionManager.open(branched).buildSessionContext().messages.compactMap(projectionText) == ["edited"])
    #expect([file.path, exported, branched].contains(SessionManager.findById(directory.path, "fixture", directory.path) ?? ""))
    let eventJSON = encodeSessionEventJSON(.agent(.messageStart(message: .system(orderedSystem()))))
    #expect(eventJSON.contains("\"sections\":{\(sections)}"))
    let eventSections = try OrderedJSON.parse(eventJSON)["message"]?["sections"]?.objectEntries?.map { $0.0 }
    #expect(eventSections == orderedNames)
}

@Test func migrationRewriteKeepsOrderedCheckpointSections() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("v087-rewrite-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("old.jsonl")
    let sections = orderedNames.map { "\"\($0)\":\"value-\($0)\"" }.joined(separator: ",")
    let system = "{\"role\":\"system\",\"content\":\"base\",\"sections\":{\(sections)},\"timestamp\":123}"
    let lines = [
        "{\"type\":\"session\",\"version\":2,\"id\":\"rewrite\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"\(directory.path)\"}",
        "{\"type\":\"message\",\"id\":\"s\",\"parentId\":null,\"timestamp\":\"2025-01-01T00:00:00Z\",\"message\":\(system)}",
        "{\"type\":\"compaction\",\"id\":\"c\",\"parentId\":\"s\",\"timestamp\":\"2025-01-01T00:00:02Z\",\"summary\":\"summary\",\"firstKeptEntryId\":\"c\",\"tokensBefore\":10,\"systemMessage\":\(system)}"
    ]
    try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    let manager = SessionManager.open(file.path)
    #expect(manager.getHeader()?.version == CURRENT_SESSION_VERSION)
    let rewritten = try String(contentsOf: file, encoding: .utf8)
    #expect(rewritten.components(separatedBy: "\"sections\":{\(sections)}").count == 3)
}

@Test func headerDiscoveryIgnoresUnreadableBodyAndChoosesNewestValidHeader() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("v087-discovery-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let old = directory.appendingPathComponent("old.jsonl")
    let newer = directory.appendingPathComponent("new.jsonl")
    let invalid = directory.appendingPathComponent("invalid.jsonl")
    let prefixed = directory.appendingPathComponent("prefixed.jsonl")
    let header = "{\"type\":\"session\",\"version\":3,\"id\":\"exact-id\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"\(directory.path)\"}\n"
    try (header + String(repeating: "garbage", count: 100_000)).write(to: old, atomically: true, encoding: .utf8)
    try header.write(to: newer, atomically: true, encoding: .utf8)
    try "not json\n".write(to: invalid, atomically: true, encoding: .utf8)
    try ("not json\n" + header.replacingOccurrences(of: "exact-id", with: "prefixed-id"))
        .write(to: prefixed, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: old.path)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: newer.path)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 300)], ofItemAtPath: invalid.path)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 50)], ofItemAtPath: prefixed.path)
    #expect(SessionManager.findById(directory.path, "exact-id", directory.path) != nil)
    #expect(SessionManager.findById(directory.path, "prefixed-id", directory.path) == prefixed.path)
    #expect(findMostRecentSession(directory.path) == newer.path)
}

@Test func repeatedCompactionKeepsOnlyLatestSummaryEvenWhenOlderEntryIsRetained() {
    let manager = SessionManager.inMemory()
    manager.appendMessage(.system(orderedSystem()))
    let retained = manager.appendMessage(.user(UserMessage(content: .text("retained"))))
    manager.appendCompaction("old", retained, 100)
    manager.appendMessage(.user(UserMessage(content: .text("after old"))))
    manager.appendCompaction("new", retained, 80)
    let projection = manager.buildSessionProjection()
    #expect(projection.messages.map(\.role) == ["system", "compactionSummary", "user", "user"])
    #expect(projection.messages.filter { $0.role == "compactionSummary" }.count == 1)
    #expect(projection.entries.filter { $0.sourceEntry.type == "compaction" }.count == 2)
    #expect(projection.entries[2].sourceEntry.type == "compaction")
    #expect(projection.entries[2].messages.isEmpty)
}

@Test func invalidEditTargetsDoNotAppendEntries() throws {
    let manager = SessionManager.inMemory()
    let systemID = manager.appendMessage(.system(orderedSystem()))
    let usageID = manager.appendUsage("cache_warm", "p", "m", Usage(input: 1, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 1))
    let count = manager.getEntries().count
    #expect(throws: SessionManagerError.self) { try manager.appendContextEdit(systemID, nil) }
    #expect(throws: SessionManagerError.self) { try manager.appendContextEdit(usageID, nil) }
    #expect(manager.getEntries().count == count)
}

@Test func sessionStatsIncludeUsageEntriesOutsideProjectedContext() {
    let context = createTestSession()
    defer { context.cleanup() }
    let usage = Usage(input: 5, output: 1, cacheRead: 20, cacheWrite: 0, totalTokens: 26,
        cost: UsageCost(input: 0.1, output: 0.2, cacheRead: 0.3, cacheWrite: 0, total: 0.6))
    context.session.sessionManager.appendUsage("unknown_operation", "provider", "model", usage)
    context.session.refreshContext()
    #expect(context.session.messages.isEmpty)
    let stats = context.session.getSessionStats()
    #expect(stats.tokens.total == 26)
    #expect(stats.cost == 0.6)
}

@Test func refreshContextRestoresCanonicalMessagesAfterExternalStateChange() {
    let context = createTestSession()
    defer { context.cleanup() }
    let manager = context.session.sessionManager
    manager.appendMessage(.user(UserMessage(content: .text("stored"))))
    context.session.agent.messages = [.user(UserMessage(content: .text("temporary")))]
    context.session.refreshContext()
    #expect(context.session.messages.compactMap(projectionText) == ["stored"])
}
