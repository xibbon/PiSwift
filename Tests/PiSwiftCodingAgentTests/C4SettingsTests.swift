import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

@Test func c4CompactionModelOverridesMergeAndResolveIndependently() throws {
    var global = Settings()
    global.compaction = CompactionSettingsOverrides(
        reserveTokens: 8_000, keepRecentTokens: 12_000,
        modelOverrides: ["openai/gpt-4-turbo": CompactionModelOverride(reserveTokens: 3_000)]
    )
    let manager = SettingsManager.inMemory(global)
    var project = Settings()
    project.compaction = CompactionSettingsOverrides(
        keepRecentTokens: 10_000,
        modelOverrides: ["openai/gpt-4-turbo": CompactionModelOverride(keepRecentTokens: 4_000)]
    )
    manager.applyOverrides(project)
    let model = try #require(ModelRegistry(AuthStorage(":memory:"), "").find("openai", "gpt-4-turbo"))
    let matching = try manager.validatedCompactionSettings(model: model)
    #expect(matching.reserveTokens == 3_000)
    #expect(matching.keepRecentTokens == 4_000)
    let ordinary = try manager.validatedCompactionSettings()
    #expect(ordinary.reserveTokens == 8_000)
    #expect(ordinary.keepRecentTokens == 10_000)
}

@Test func c4CompactionSettingsParseValidateAndSerialize() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("c4-settings-\(UUID().uuidString)")
    let agent = root.appendingPathComponent("agent")
    try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = agent.appendingPathComponent("settings.json")
    try Data(#"{"cacheWarming":"idle","compaction":{"reserveTokens":7000,"modelOverrides":{"openai/gpt-4-turbo":{"keepRecentTokens":9000}}}}"#.utf8).write(to: path)
    let manager = SettingsManager.create(root.path, agent.path)
    #expect(manager.getCacheWarmingMode() == .idle)
    #expect(manager.getCompactionSettingsOverrides().modelOverrides?["openai/gpt-4-turbo"]?.keepRecentTokens == 9_000)
    manager.setCacheWarmingMode(.streaming)
    let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    #expect(saved["cacheWarming"] as? String == "streaming")
    let compaction = try #require(saved["compaction"] as? [String: Any])
    let overrides = try #require(compaction["modelOverrides"] as? [String: [String: Int]])
    #expect(overrides["openai/gpt-4-turbo"]?["keepRecentTokens"] == 9_000)

    try Data(#"{"compaction":{"modelOverrides":{"openai/gpt-4-turbo":{"keepRecentTokens":-1}}}}"#.utf8).write(to: path)
    let invalid = SettingsManager.create(root.path, agent.path)
    #expect(invalid.drainErrors().contains { $0.message.contains("keepRecentTokens") })
}

@Test func c4CacheWarmingModeIgnoresProjectOverride() {
    var global = Settings()
    global.cacheWarming = .idle
    var project = Settings()
    project.cacheWarming = .off
    let manager = SettingsManager.inMemory(global)
    manager.applyOverrides(project)
    #expect(manager.getCacheWarmingMode() == .idle)
}
