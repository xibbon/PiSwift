import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

@Test func c4CacheDecisionLastExtensionOverrideWins() async {
    let first: HookHandler = { _, _ in CacheWarmingDecisionEventResult(action: .stop) }
    let second: HookHandler = { _, _ in CacheWarmingDecisionEventResult(action: .warm) }
    let hooks = [
        LoadedHook(path: "first", resolvedPath: "first", handlers: ["cache_warming_decision": [first]], isExtension: true),
        LoadedHook(path: "second", resolvedPath: "second", handlers: ["cache_warming_decision": [second]], isExtension: true),
    ]
    let session = SessionManager.inMemory()
    let runner = HookRunner(hooks, "/tmp", session, ModelRegistry(AuthStorage(":memory:")))
    let event = CacheWarmingDecisionEvent(warmCost: 0.01, missCost: 0.20,
                                          continuationProbability: 1, action: .warm)
    #expect(await runner.emitCacheWarmingDecision(event) == .warm)
}

@Test func c4SDKExposesCacheWarmingStatusAndGlobalMode() async {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("c4-cache-sdk-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = SettingsManager.inMemory()
    let created = await createAgentSession(CreateAgentSessionOptions(
        cwd: directory.path, agentDir: directory.path,
        model: getModel(provider: .openai, modelId: "gpt-4o-mini"),
        offline: true, hooks: [], sessionManager: .inMemory(), settingsManager: manager
    ))
    defer { created.session.dispose() }
    #expect(await created.session.cacheWarmingStatus()?.reason == "waiting for first request")
    await created.session.setCacheWarmingMode(.off)
    #expect(manager.getCacheWarmingMode() == .off)
    #expect(await created.session.cacheWarmingStatus()?.reason == "cache warming disabled")
}
