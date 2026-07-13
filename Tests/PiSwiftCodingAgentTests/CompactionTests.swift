import Foundation
import Testing
import PiSwiftCodingAgent
import PiSwiftAI
import PiSwiftAgent

private func fixturesRoot() -> String {
    if let resourceURL = Bundle.module.resourceURL {
        return resourceURL.appendingPathComponent("fixtures").path
    }
    let filePath = URL(fileURLWithPath: #file)
    return filePath.deletingLastPathComponent().appendingPathComponent("fixtures").path
}

private func loadLargeSessionEntries() -> [SessionEntry] {
    let path = URL(fileURLWithPath: fixturesRoot()).appendingPathComponent("large-session.jsonl").path
    let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    var entries = parseSessionEntries(content)
    migrateSessionEntries(&entries)
    return entries.compactMap { entry in
        if case .entry(let entry) = entry { return entry }
        return nil
    }
}

private func createMockUsage(_ input: Int, _ output: Int, _ cacheRead: Int = 0, _ cacheWrite: Int = 0) -> Usage {
    Usage(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, totalTokens: input + output + cacheRead + cacheWrite)
}

private func createUserMessage(_ text: String) -> AgentMessage {
    .user(UserMessage(content: .text(text), timestamp: Int64(Date().timeIntervalSince1970 * 1000)))
}

private func createAssistantMessage(_ text: String, usage: Usage? = nil) -> AssistantMessage {
    AssistantMessage(
        content: [.text(TextContent(text: text))],
        api: .anthropicMessages,
        provider: "anthropic",
        model: "claude-sonnet-4-5",
        usage: usage ?? createMockUsage(100, 50),
        stopReason: .stop,
        timestamp: Int64(Date().timeIntervalSince1970 * 1000)
    )
}

private struct EntryBuilder {
    private var counter = 0
    private var lastId: String? = nil

    mutating func reset() {
        counter = 0
        lastId = nil
    }

    mutating func messageEntry(_ message: AgentMessage) -> SessionMessageEntry {
        let id = "test-id-\(counter)"
        counter += 1
        let entry = SessionMessageEntry(id: id, parentId: lastId, timestamp: ISO8601DateFormatter().string(from: Date()), message: message)
        lastId = id
        return entry
    }

    mutating func compactionEntry(_ summary: String, _ firstKeptEntryId: String) -> CompactionEntry {
        let id = "test-id-\(counter)"
        counter += 1
        let entry = CompactionEntry(
            id: id,
            parentId: lastId,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            summary: summary,
            firstKeptEntryId: firstKeptEntryId,
            tokensBefore: 10000,
            details: nil,
            fromHook: nil
        )
        lastId = id
        return entry
    }

    mutating func modelChangeEntry(_ provider: String, _ modelId: String) -> ModelChangeEntry {
        let id = "test-id-\(counter)"
        counter += 1
        let entry = ModelChangeEntry(id: id, parentId: lastId, timestamp: ISO8601DateFormatter().string(from: Date()), provider: provider, modelId: modelId)
        lastId = id
        return entry
    }

    mutating func thinkingLevelEntry(_ level: String) -> ThinkingLevelChangeEntry {
        let id = "test-id-\(counter)"
        counter += 1
        let entry = ThinkingLevelChangeEntry(id: id, parentId: lastId, timestamp: ISO8601DateFormatter().string(from: Date()), thinkingLevel: level)
        lastId = id
        return entry
    }
}

@Test func tokenCalculation() {
    let usage = createMockUsage(1000, 500, 200, 100)
    #expect(calculateContextTokens(usage) == 1800)
    let zero = createMockUsage(0, 0, 0, 0)
    #expect(calculateContextTokens(zero) == 0)
}

@Test func lastAssistantUsage() {
    var builder = EntryBuilder()
    let entries: [SessionEntry] = [
        .message(builder.messageEntry(createUserMessage("Hello"))),
        .message(builder.messageEntry(.assistant(createAssistantMessage("Hi", usage: createMockUsage(100, 50))))),
        .message(builder.messageEntry(createUserMessage("How are you?"))),
        .message(builder.messageEntry(.assistant(createAssistantMessage("Good", usage: createMockUsage(200, 100))))),
    ]

    let usage = getLastAssistantUsage(entries)
    #expect(usage?.input == 200)
}

@Test func lastAssistantUsageSkipsAborted() {
    var builder = EntryBuilder()
    var aborted = createAssistantMessage("Aborted", usage: createMockUsage(300, 150))
    aborted.stopReason = .aborted
    let entries: [SessionEntry] = [
        .message(builder.messageEntry(createUserMessage("Hello"))),
        .message(builder.messageEntry(.assistant(createAssistantMessage("Hi", usage: createMockUsage(100, 50))))),
        .message(builder.messageEntry(createUserMessage("How are you?"))),
        .message(builder.messageEntry(.assistant(aborted))),
    ]
    let usage = getLastAssistantUsage(entries)
    #expect(usage?.input == 100)
}

@Test func lastAssistantUsageNone() {
    var builder = EntryBuilder()
    let entries: [SessionEntry] = [.message(builder.messageEntry(createUserMessage("Hello")))]
    #expect(getLastAssistantUsage(entries) == nil)
}

@Test func shouldCompactChecksThreshold() {
    let settings = CompactionSettings(enabled: true, reserveTokens: 10000, keepRecentTokens: 20000)
    #expect(shouldCompact(95000, 100000, settings))
    #expect(!shouldCompact(89000, 100000, settings))
}

@Test func shouldCompactDisabled() {
    let settings = CompactionSettings(enabled: false, reserveTokens: 10000, keepRecentTokens: 20000)
    #expect(!shouldCompact(95000, 100000, settings))
}

@Test func findCutPointBasic() {
    var builder = EntryBuilder()
    var entries: [SessionEntry] = []
    for i in 0..<10 {
        entries.append(.message(builder.messageEntry(createUserMessage("User \(i)"))))
        let usage = createMockUsage(0, 100, (i + 1) * 1000, 0)
        entries.append(.message(builder.messageEntry(.assistant(createAssistantMessage("Assistant \(i)", usage: usage)))))
    }

    let result = findCutPoint(entries, 0, entries.count, 2500)
    #expect(entries[result.firstKeptEntryIndex].type == "message")
}

@Test func findCutPointNoValid() {
    var builder = EntryBuilder()
    let entries: [SessionEntry] = [.message(builder.messageEntry(.assistant(createAssistantMessage("a"))))]
    let result = findCutPoint(entries, 0, entries.count, 1000)
    #expect(result.firstKeptEntryIndex == 0)
}

@Test func findCutPointKeepsEverything() {
    var builder = EntryBuilder()
    let entries: [SessionEntry] = [
        .message(builder.messageEntry(createUserMessage("1"))),
        .message(builder.messageEntry(.assistant(createAssistantMessage("a", usage: createMockUsage(0, 50, 500, 0))))),
        .message(builder.messageEntry(createUserMessage("2"))),
        .message(builder.messageEntry(.assistant(createAssistantMessage("b", usage: createMockUsage(0, 50, 1000, 0))))),
    ]
    let result = findCutPoint(entries, 0, entries.count, 50000)
    #expect(result.firstKeptEntryIndex == 0)
}

@Test func findCutPointCountsContextVisibleCustomMessages() {
    let content = """
    {"type":"session","version":3,"id":"session","timestamp":"2026-01-01T00:00:00Z","cwd":"/tmp"}
    {"type":"message","id":"user","timestamp":"2026-01-01T00:00:00Z","message":{"role":"user","content":"short","timestamp":0}}
    {"type":"custom_message","id":"custom","parentId":"user","timestamp":"2026-01-01T00:00:01Z","customType":"hook","content":"\(String(repeating: "x", count: 8_000))","display":true}
    """
    let entries = parseSessionEntries(content).compactMap { entry -> SessionEntry? in
        if case .entry(let sessionEntry) = entry { return sessionEntry }
        return nil
    }

    let result = findCutPoint(entries, 0, entries.count, 1_000)
    #expect(entries[result.firstKeptEntryIndex].id == "custom")
    #expect(result.isSplitTurn == false)
}

@Test func findCutPointSplitTurn() {
    var builder = EntryBuilder()
    let entries: [SessionEntry] = [
        .message(builder.messageEntry(createUserMessage("Turn 1"))),
        .message(builder.messageEntry(.assistant(createAssistantMessage("A1", usage: createMockUsage(0, 100, 1000, 0))))),
        .message(builder.messageEntry(createUserMessage("Turn 2"))),
        .message(builder.messageEntry(.assistant(createAssistantMessage("A2-1", usage: createMockUsage(0, 100, 5000, 0))))),
        .message(builder.messageEntry(.assistant(createAssistantMessage("A2-2", usage: createMockUsage(0, 100, 8000, 0))))),
        .message(builder.messageEntry(.assistant(createAssistantMessage("A2-3", usage: createMockUsage(0, 100, 10000, 0))))),
    ]
    let result = findCutPoint(entries, 0, entries.count, 3000)
    if case .message(let entry) = entries[result.firstKeptEntryIndex], case .assistant = entry.message {
        #expect(result.isSplitTurn)
        #expect(result.turnStartIndex == 2)
    }
}

@Test func buildSessionContextNoCompaction() {
    var builder = EntryBuilder()
    let entries: [SessionEntry] = [
        .message(builder.messageEntry(createUserMessage("1"))),
        .message(builder.messageEntry(.assistant(createAssistantMessage("a")))),
        .message(builder.messageEntry(createUserMessage("2"))),
        .message(builder.messageEntry(.assistant(createAssistantMessage("b")))),
    ]
    let loaded = buildSessionContext(entries)
    #expect(loaded.messages.count == 4)
    #expect(loaded.thinkingLevel == "off")
    #expect(loaded.model?.provider == "anthropic")
}

@Test func buildSessionContextSingleCompaction() {
    var builder = EntryBuilder()
    let u1 = builder.messageEntry(createUserMessage("1"))
    let a1 = builder.messageEntry(.assistant(createAssistantMessage("a")))
    let u2 = builder.messageEntry(createUserMessage("2"))
    let a2 = builder.messageEntry(.assistant(createAssistantMessage("b")))
    let compaction = builder.compactionEntry("Summary of 1,a,2,b", u2.id)
    let u3 = builder.messageEntry(createUserMessage("3"))
    let a3 = builder.messageEntry(.assistant(createAssistantMessage("c")))
    let entries: [SessionEntry] = [
        .message(u1), .message(a1), .message(u2), .message(a2), .compaction(compaction), .message(u3), .message(a3),
    ]
    let loaded = buildSessionContext(entries)
    #expect(loaded.messages.count == 5)
    #expect(loaded.messages.first?.role == "compactionSummary")
}

@Test func buildSessionContextMultipleCompactionsFromEntries() {
    var builder = EntryBuilder()
    let u1 = builder.messageEntry(createUserMessage("1"))
    let a1 = builder.messageEntry(.assistant(createAssistantMessage("a")))
    let compact1 = builder.compactionEntry("First summary", u1.id)
    let u2 = builder.messageEntry(createUserMessage("2"))
    let b = builder.messageEntry(.assistant(createAssistantMessage("b")))
    let u3 = builder.messageEntry(createUserMessage("3"))
    let c = builder.messageEntry(.assistant(createAssistantMessage("c")))
    let compact2 = builder.compactionEntry("Second summary", u3.id)
    let u4 = builder.messageEntry(createUserMessage("4"))
    let d = builder.messageEntry(.assistant(createAssistantMessage("d")))
    let entries: [SessionEntry] = [
        .message(u1), .message(a1), .compaction(compact1), .message(u2), .message(b),
        .message(u3), .message(c), .compaction(compact2), .message(u4), .message(d),
    ]
    let loaded = buildSessionContext(entries)
    #expect(loaded.messages.count == 5)
}

@Test func buildSessionContextKeepsAllWhenFirstKeptIsFirst() {
    var builder = EntryBuilder()
    let u1 = builder.messageEntry(createUserMessage("1"))
    let a1 = builder.messageEntry(.assistant(createAssistantMessage("a")))
    let compact1 = builder.compactionEntry("First summary", u1.id)
    let u2 = builder.messageEntry(createUserMessage("2"))
    let b = builder.messageEntry(.assistant(createAssistantMessage("b")))
    let entries: [SessionEntry] = [.message(u1), .message(a1), .compaction(compact1), .message(u2), .message(b)]
    let loaded = buildSessionContext(entries)
    #expect(loaded.messages.count == 5)
}

@Test func buildSessionContextTracksModelAndThinking() {
    var builder = EntryBuilder()
    let entries: [SessionEntry] = [
        .message(builder.messageEntry(createUserMessage("1"))),
        .modelChange(builder.modelChangeEntry("openai", "gpt-4")),
        .message(builder.messageEntry(.assistant(createAssistantMessage("a")))),
        .thinkingLevel(builder.thinkingLevelEntry("high")),
    ]
    let loaded = buildSessionContext(entries)
    #expect(loaded.model?.provider == "anthropic")
    #expect(loaded.thinkingLevel == "high")
}

@Test func largeSessionFixtureParses() {
    let entries = loadLargeSessionEntries()
    #expect(entries.count > 100)
    #expect(entries.filter { $0.type == "message" }.count > 100)
}

@Test func largeSessionFindCutPoint() {
    let entries = loadLargeSessionEntries()
    let result = findCutPoint(entries, 0, entries.count, DEFAULT_COMPACTION_SETTINGS.keepRecentTokens)
    #expect(entries[result.firstKeptEntryIndex].type == "message")
}

@Test func compactionWithApiKey() async throws {
    guard let apiKey = API_KEY else { return }
    let entries = loadLargeSessionEntries()
    let preparation = prepareCompaction(entries, DEFAULT_COMPACTION_SETTINGS)
    guard let prep = preparation else { return }
    let model = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
    let result = try await compact(prep, model, apiKey)
    #expect(result.summary.count > 10)
    #expect(!result.firstKeptEntryId.isEmpty)
    #expect(result.tokensBefore >= 0)
}
