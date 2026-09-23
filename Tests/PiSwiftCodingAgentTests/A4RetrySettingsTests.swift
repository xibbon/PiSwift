import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

@Test func a4RetrySettingsDefaultAndOverride() {
    let defaults = SettingsManager.inMemory().getRetrySettings()
    #expect(defaults.maxAgentDelayMs == 60_000)
    var base = Settings()
    base.retry = RetrySettings(enabled: true, maxRetries: 2, baseDelayMs: 500, maxAgentDelayMs: 10_000,
        provider: ProviderRetrySettings(maxRetryDelayMs: 90_000))
    let manager = SettingsManager.inMemory(base)
    var override = Settings()
    override.retry = RetrySettings(maxAgentDelayMs: 5_000)
    manager.applyOverrides(override)
    let retry = manager.getRetrySettings()
    #expect(retry.maxAgentDelayMs == 5_000)
    #expect(retry.baseDelayMs == 500)
    #expect(retry.provider?.maxRetryDelayMs == 90_000)
}

@Test func a4RetrySettingsParsesFromFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("a4-retry-\(UUID().uuidString)")
    let agent = root.appendingPathComponent("agent")
    try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"retry":{"baseDelayMs":2000,"maxAgentDelayMs":5000,"provider":{"maxRetryDelayMs":90000}}}"#.utf8)
        .write(to: agent.appendingPathComponent("settings.json"))
    let manager = SettingsManager.create(root.path, agent.path)
    #expect(manager.getRetrySettings().maxAgentDelayMs == 5_000)
    #expect(manager.getProviderRetrySettings().maxRetryDelayMs == 90_000)
    manager.setRetryEnabled(false)
    let saved = try #require(JSONSerialization.jsonObject(with:
        Data(contentsOf: agent.appendingPathComponent("settings.json"))) as? [String: Any])
    let retry = try #require(saved["retry"] as? [String: Any])
    #expect(retry["maxAgentDelayMs"] as? Int == 5_000)
}
