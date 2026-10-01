import Testing
import PiSwiftAI
import PiSwiftCodingAgent

@Test(.timeLimit(.minutes(1))) func manualCompactionWorks() async throws {
    guard API_KEY != nil else { return }

    var overrides = Settings()
    overrides.compaction = CompactionSettingsOverrides(keepRecentTokens: 1)
    let ctx = createTestSession(options: TestSessionOptions(settingsOverrides: overrides))
    defer { ctx.cleanup() }

    try await ctx.session.prompt("What is 2+2? Reply with just the number.")
    await ctx.session.agent.waitForIdle()
    try await ctx.session.prompt("What is 3+3? Reply with just the number.")
    await ctx.session.agent.waitForIdle()

    let result = try await ctx.session.compact()
    #expect(!result.summary.isEmpty)
    #expect(result.tokensBefore > 0)

    let messages = ctx.session.messages
    #expect(messages.isEmpty == false)
    #expect(messages.first?.role == "compactionSummary")
}

@Test(.timeLimit(.minutes(1))) func compactionKeepsSessionUsable() async throws {
    guard API_KEY != nil else { return }

    var overrides = Settings()
    overrides.compaction = CompactionSettingsOverrides(keepRecentTokens: 1)
    let ctx = createTestSession(options: TestSessionOptions(settingsOverrides: overrides))
    defer { ctx.cleanup() }

    try await ctx.session.prompt("What is the capital of France? One word answer.")
    await ctx.session.agent.waitForIdle()
    try await ctx.session.prompt("What is the capital of Germany? One word answer.")
    await ctx.session.agent.waitForIdle()

    _ = try await ctx.session.compact()

    try await ctx.session.prompt("What is the capital of Italy? One word answer.")
    await ctx.session.agent.waitForIdle()

    let assistantMessages = ctx.session.messages.filter { $0.role == "assistant" }
    #expect(assistantMessages.count > 0)
}

@Test(.timeLimit(.minutes(1))) func compactionPersistsEntry() async throws {
    guard API_KEY != nil else { return }

    let ctx = createTestSession()
    defer { ctx.cleanup() }

    try await ctx.session.prompt("Say hello")
    await ctx.session.agent.waitForIdle()
    try await ctx.session.prompt("Say goodbye")
    await ctx.session.agent.waitForIdle()

    _ = try await ctx.session.compact()

    let compactionEntries = ctx.session.sessionManager.getEntries().compactMap { entry -> CompactionEntry? in
        if case .compaction(let compaction) = entry { return compaction }
        return nil
    }
    #expect(compactionEntries.count == 1)
    #expect(compactionEntries[0].summary.count > 0)
    #expect(!compactionEntries[0].firstKeptEntryId.isEmpty)
    #expect(compactionEntries[0].tokensBefore > 0)
}

@Test(.timeLimit(.minutes(1))) func compactionWorksInMemory() async throws {
    guard API_KEY != nil else { return }

    let ctx = createTestSession(options: TestSessionOptions(inMemory: true))
    defer { ctx.cleanup() }

    try await ctx.session.prompt("What is 2+2? Reply with just the number.")
    await ctx.session.agent.waitForIdle()
    try await ctx.session.prompt("What is 3+3? Reply with just the number.")
    await ctx.session.agent.waitForIdle()

    let result = try await ctx.session.compact()
    #expect(!result.summary.isEmpty)

    let compactionEntries = ctx.session.sessionManager.getEntries().compactMap { entry -> CompactionEntry? in
        if case .compaction(let compaction) = entry { return compaction }
        return nil
    }
    #expect(compactionEntries.count == 1)
}

@Test(.timeLimit(.minutes(1))) func manualCompactionDoesNotEmitAutoEvents() async throws {
    guard API_KEY != nil else { return }

    let ctx = createTestSession()
    defer { ctx.cleanup() }

    let events = LockedState<[AgentSessionEvent]>([])
    _ = ctx.session.subscribe { event in
        events.withLock { $0.append(event) }
    }

    try await ctx.session.prompt("Say hello")
    await ctx.session.agent.waitForIdle()
    _ = try await ctx.session.compact()

    let autoEvents = events.withLock { events in
        events.filter { $0.type == "auto_compaction_start" || $0.type == "auto_compaction_end" }
    }
    #expect(autoEvents.isEmpty)
}
