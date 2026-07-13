import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

private func cacheStatsAssistant(timestamp: Int64, input: Int, cacheRead: Int) -> AssistantMessage {
    AssistantMessage(
        content: [.text(TextContent(text: "response"))],
        api: .openAIResponses,
        provider: "openai",
        model: "gpt-4o-mini",
        usage: Usage(
            input: input,
            output: 20,
            cacheRead: cacheRead,
            cacheWrite: 0,
            totalTokens: input + cacheRead + 20,
            cost: UsageCost(input: Double(input) / 1_000_000, cacheRead: Double(cacheRead) / 10_000_000)
        ),
        stopReason: .stop,
        timestamp: timestamp
    )
}

@Test func cacheStatsReportsSignificantRebilledPromptTokens() throws {
    let first = cacheStatsAssistant(timestamp: 1_000, input: 1_000, cacheRead: 9_000)
    let second = cacheStatsAssistant(timestamp: 1_000 + CACHE_TTL_MS, input: 10_000, cacheRead: 0)
    let entries: [SessionEntry] = [
        .message(SessionMessageEntry(id: "first", timestamp: "2026-01-01T00:00:00Z", message: .assistant(first))),
        .message(SessionMessageEntry(id: "second", parentId: "first", timestamp: "2026-01-01T00:05:00Z", message: .assistant(second))),
    ]

    let registry = ModelRegistry(AuthStorage(":memory:"))
    let misses = collectCacheMisses(entries, modelRegistry: registry)
    let miss = try #require(misses["second"])
    #expect(miss.missedTokens == 10_000)
    #expect(miss.idleMs == CACHE_TTL_MS)
    #expect(computeCacheWaste(entries, modelRegistry: registry).missCount == 1)
}

@Test func cacheStatsResetsAtCompactionBoundary() {
    let first = cacheStatsAssistant(timestamp: 1_000, input: 1_000, cacheRead: 9_000)
    let second = cacheStatsAssistant(timestamp: 2_000, input: 10_000, cacheRead: 0)
    let entries: [SessionEntry] = [
        .message(SessionMessageEntry(id: "first", timestamp: "2026-01-01T00:00:00Z", message: .assistant(first))),
        .compaction(CompactionEntry(id: "compact", parentId: "first", timestamp: "2026-01-01T00:00:01Z", summary: "summary", firstKeptEntryId: "first", tokensBefore: 10_000)),
        .message(SessionMessageEntry(id: "second", parentId: "compact", timestamp: "2026-01-01T00:00:02Z", message: .assistant(second))),
    ]

    #expect(computeCacheWaste(entries, modelRegistry: ModelRegistry(AuthStorage(":memory:"))).missCount == 0)
}
