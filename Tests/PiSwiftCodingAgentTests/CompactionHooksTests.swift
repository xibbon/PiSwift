import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

private struct HookTestContext {
    var session: AgentSession
    var tempDir: String
    var cleanup: () -> Void
}

private actor EventStore<T> {
    private var items: [T] = []

    func append(_ item: T) {
        items.append(item)
    }

    func snapshot() -> [T] {
        items
    }
}

private actor ValueBox<T> {
    private var value: T?

    func set(_ newValue: T) {
        value = newValue
    }

    func get() -> T? {
        value
    }
}

private func withTempDir(_ body: (String) async throws -> Void) async rethrows {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-compaction-hooks-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    try await body(tempDir)
}

private func createSession(tempDir: String, hooks: [LoadedHook]) -> HookTestContext {
    let model = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
    let agent = Agent(AgentOptions(
        initialState: AgentState(
            systemPrompt: "You are a helpful assistant. Be concise.",
            model: model,
            tools: createCodingTools(cwd: tempDir)
        ),
        convertToLlm: { messages in
            convertToLlm(messages)
        },
        getApiKey: { _ in API_KEY }
    ))

    let sessionManager = SessionManager.create(tempDir, tempDir)
    let settingsManager = SettingsManager.create(tempDir, tempDir)
    let authStorage = AuthStorage(URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path)
    let modelRegistry = ModelRegistry(authStorage)

    if let apiKey = API_KEY {
        authStorage.setRuntimeApiKey("anthropic", apiKey)
    }

    let hookRunner = HookRunner(hooks, tempDir, sessionManager, modelRegistry)
    hookRunner.initialize(getModel: { [weak agent] in
        agent?.state.model
    }, hasUI: false)

    let session = AgentSession(config: AgentSessionConfig(
        agent: agent,
        sessionManager: sessionManager,
        settingsManager: settingsManager,
        resourceLoader: TestResourceLoader(),
        hookRunner: hookRunner,
        modelRegistry: modelRegistry
    ))

    let cleanup = {
        session.dispose()
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    return HookTestContext(session: session, tempDir: tempDir, cleanup: cleanup)
}

@Test func compactionHooksEmitEvents() async throws {
    guard API_KEY != nil else { return }

    try await withTempDir { tempDir in
        let capturedEvents = EventStore<any HookEvent>()

        let hook = createHook(
            onBeforeCompact: { event in
                await capturedEvents.append(event)
                return nil
            },
            onCompact: { event in
                await capturedEvents.append(event)
            }
        )

        let ctx = createSession(tempDir: tempDir, hooks: [hook])
        defer { ctx.cleanup() }

        try await ctx.session.prompt("What is 2+2? Reply with just the number.")
        await ctx.session.agent.waitForIdle()
        try await ctx.session.prompt("What is 3+3? Reply with just the number.")
        await ctx.session.agent.waitForIdle()

        _ = try await ctx.session.compact()

        let snapshot = await capturedEvents.snapshot()
        let beforeEvents = snapshot.compactMap { $0 as? SessionBeforeCompactEvent }
        let compactEvents = snapshot.compactMap { $0 as? SessionCompactEvent }

        #expect(beforeEvents.count == 1)
        #expect(compactEvents.count == 1)
        #expect(beforeEvents[0].preparation.tokensBefore >= 0)
        #expect(compactEvents[0].compactionEntry.summary.count > 0)
        #expect(compactEvents[0].fromHook == false)
    }
}

@Test func compactionHooksCanCancel() async throws {
    guard API_KEY != nil else { return }

    try await withTempDir { tempDir in
        let hook = createHook(onBeforeCompact: { _ in SessionBeforeCompactResult(cancel: true) })
        let ctx = createSession(tempDir: tempDir, hooks: [hook])
        defer { ctx.cleanup() }

        try await ctx.session.prompt("What is 2+2? Reply with just the number.")
        await ctx.session.agent.waitForIdle()

        do {
            _ = try await ctx.session.compact()
            #expect(Bool(false), "Expected compaction to throw")
        } catch {
            #expect(error.localizedDescription.contains("Compaction cancelled"))
        }
    }
}

@Test func compactionHooksCanProvideCustomCompaction() async throws {
    guard API_KEY != nil else { return }

    try await withTempDir { tempDir in
        let customSummary = "Custom summary from hook"
        let hook = createHook(onBeforeCompact: { event in
            SessionBeforeCompactResult(
                cancel: false,
                compaction: CompactionResult(
                    summary: customSummary,
                    firstKeptEntryId: event.preparation.firstKeptEntryId,
                    tokensBefore: event.preparation.tokensBefore,
                    details: nil
                )
            )
        })
        let ctx = createSession(tempDir: tempDir, hooks: [hook])
        defer { ctx.cleanup() }

        try await ctx.session.prompt("What is 2+2? Reply with just the number.")
        await ctx.session.agent.waitForIdle()
        try await ctx.session.prompt("What is 3+3? Reply with just the number.")
        await ctx.session.agent.waitForIdle()

        let result = try await ctx.session.compact()
        #expect(result.summary == customSummary)

        let compactionEntries = ctx.session.sessionManager.getEntries().compactMap { entry -> CompactionEntry? in
            if case .compaction(let compaction) = entry { return compaction }
            return nil
        }
        #expect(compactionEntries.count == 1)
        #expect(compactionEntries[0].summary == customSummary)
        #expect(compactionEntries[0].fromHook == true)
    }
}

@Test func compactionHooksContinueWhenHookThrows() async throws {
    guard API_KEY != nil else { return }

    try await withTempDir { tempDir in
        let throwingHook = LoadedHook(
            path: "throwing-hook",
            resolvedPath: "/test/throwing-hook.swift",
            handlers: [
                "session_before_compact": [
                    { _event, _ctx in
                        struct HookError: Error {}
                        throw HookError()
                    },
                ],
                "session_compact": [
                    { _event, _ctx in
                        return nil
                    },
                ],
            ]
        )

        let ctx = createSession(tempDir: tempDir, hooks: [throwingHook])
        defer { ctx.cleanup() }

        try await ctx.session.prompt("What is 2+2? Reply with just the number.")
        await ctx.session.agent.waitForIdle()

        let result = try await ctx.session.compact()
        #expect(!result.summary.isEmpty)
    }
}

@Test func compactionHooksCallOrder() async throws {
    guard API_KEY != nil else { return }

    try await withTempDir { tempDir in
        let callOrder = EventStore<String>()

        let hook1 = createHook(
            onBeforeCompact: { _ in
                await callOrder.append("hook1-before")
                return nil
            },
            onCompact: { _ in
                await callOrder.append("hook1-after")
            }
        )
        let hook2 = createHook(
            onBeforeCompact: { _ in
                await callOrder.append("hook2-before")
                return nil
            },
            onCompact: { _ in
                await callOrder.append("hook2-after")
            }
        )

        let ctx = createSession(tempDir: tempDir, hooks: [hook1, hook2])
        defer { ctx.cleanup() }

        try await ctx.session.prompt("What is 2+2? Reply with just the number.")
        await ctx.session.agent.waitForIdle()
        _ = try await ctx.session.compact()

        let snapshot = await callOrder.snapshot()
        #expect(snapshot == ["hook1-before", "hook2-before", "hook1-after", "hook2-after"])
    }
}

@Test func compactionHooksEventData() async throws {
    guard API_KEY != nil else { return }

    try await withTempDir { tempDir in
        let captured = ValueBox<SessionBeforeCompactEvent>()

        let hook = createHook(onBeforeCompact: { event in
            await captured.set(event)
            return nil
        })

        let ctx = createSession(tempDir: tempDir, hooks: [hook])
        defer { ctx.cleanup() }

        try await ctx.session.prompt("What is 2+2? Reply with just the number.")
        await ctx.session.agent.waitForIdle()
        try await ctx.session.prompt("What is 3+3? Reply with just the number.")
        await ctx.session.agent.waitForIdle()
        _ = try await ctx.session.compact()

        let capturedEvent = await captured.get()
        #expect(capturedEvent != nil)
        #expect(capturedEvent?.preparation.firstKeptEntryId.isEmpty == false)
        #expect(capturedEvent?.preparation.tokensBefore ?? 0 >= 0)
        #expect(capturedEvent?.branchEntries.isEmpty == false)
        let apiKey = await ctx.session.modelRegistry.getApiKeyForProvider("anthropic")
        #expect(apiKey != nil)
    }
}

private func createHook(
    onBeforeCompact: (@Sendable (SessionBeforeCompactEvent) async -> SessionBeforeCompactResult?)? = nil,
    onCompact: (@Sendable (SessionCompactEvent) async -> Void)? = nil
) -> LoadedHook {
    let beforeHandler: HookHandler = { event, _context in
        guard let beforeEvent = event as? SessionBeforeCompactEvent else { return nil }
        return await onBeforeCompact?(beforeEvent)
    }
    let compactHandler: HookHandler = { event, _context in
        guard let compactEvent = event as? SessionCompactEvent else { return nil }
        await onCompact?(compactEvent)
        return nil
    }

    return LoadedHook(
        path: "test-hook",
        resolvedPath: "/test/test-hook.swift",
        handlers: [
            "session_before_compact": [beforeHandler],
            "session_compact": [compactHandler],
        ]
    )
}
