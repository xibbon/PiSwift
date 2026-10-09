import Foundation
import PiSwiftCodingAgent
import PiSwiftCodingAgentDurable
import PiSwiftDurable
import Testing

@Test func harnessSettingsMapsCodingAgentValues() {
    var source = PiSwiftCodingAgent.Settings()
    source.httpIdleTimeoutMs = 17_000
    source.retry = RetrySettings(
        enabled: false, maxRetries: 7, baseDelayMs: 4_000_000_000,
        maxAgentDelayMs: 8_000_000_000,
        provider: ProviderRetrySettings(timeoutMs: 8_000, maxRetries: 2, maxRetryDelayMs: 19_000)
    )
    source.compaction = CompactionSettingsOverrides(enabled: false, reserveTokens: 321, keepRecentTokens: 654)
    source.steeringMode = "all"
    source.followUpMode = "one-at-a-time"
    let settings = harnessSettings(from: .inMemory(source)).resolve()

    #expect(settings.stream.timeoutMs == 8_000)
    #expect(settings.stream.maxRetries == 2)
    #expect(settings.stream.maxRetryDelayMs == 19_000)
    #expect(settings.retry.enabled == false)
    #expect(settings.retry.maxRetries == 7)
    #expect(settings.retry.baseDelayMs == 4_000_000_000)
    #expect(settings.retry.maxAgentDelayMs == 8_000_000_000)
    #expect(settings.compaction.enabled == false)
    #expect(settings.compaction.reserveTokens == 321)
    #expect(settings.compaction.keepRecentTokens == 654)
    #expect(settings.compaction.backgroundTokens == defaultCompactionPolicy.backgroundTokens)
    #expect(settings.steeringMode == .all)
    #expect(settings.followUpMode == .oneAtATime)
}

@Test(arguments: [0, 23_000]) func harnessSettingsUsesIdleTimeoutWhenProviderTimeoutIsAbsent(idle: Int) {
    var source = PiSwiftCodingAgent.Settings()
    source.httpIdleTimeoutMs = idle
    let settings = harnessSettings(from: .inMemory(source)).resolve()
    #expect(settings.stream.timeoutMs == (idle == 0 ? Int(Int32.max) : idle))
    #expect(settings.stream.maxRetries == nil)
    #expect(settings.stream.maxRetryDelayMs == 60_000)
}

@Test func harnessSettingsKeepsExplicitZeroProviderValues() {
    var source = PiSwiftCodingAgent.Settings()
    source.httpIdleTimeoutMs = 0
    source.retry = RetrySettings(
        maxRetries: 0, baseDelayMs: 0, maxAgentDelayMs: 0,
        provider: ProviderRetrySettings(timeoutMs: 0, maxRetries: 0, maxRetryDelayMs: 0)
    )
    let settings = harnessSettings(from: .inMemory(source)).resolve()
    #expect(settings.stream.timeoutMs == 0)
    #expect(settings.stream.maxRetries == 0)
    #expect(settings.stream.maxRetryDelayMs == 0)
    #expect(settings.retry.maxRetries == 0)
    #expect(settings.retry.baseDelayMs == 0)
    #expect(settings.retry.maxAgentDelayMs == 0)
}

@Test func harnessSettingsUsesDefaultsForUnknownQueueModes() {
    var source = PiSwiftCodingAgent.Settings()
    source.steeringMode = "unknown-steering-mode"
    source.followUpMode = "unknown-follow-up-mode"
    let settings = harnessSettings(from: .inMemory(source)).resolve()
    #expect(settings.steeringMode == .oneAtATime)
    #expect(settings.followUpMode == .oneAtATime)
}

@Test func harnessSettingsReadsChangesAfterProviderCreation() {
    let manager = SettingsManager.inMemory()
    let provider = harnessSettings(from: manager)
    #expect(provider.resolve().stream.timeoutMs == DEFAULT_HTTP_IDLE_TIMEOUT_MS)
    #expect(provider.resolve().steeringMode == .oneAtATime)

    manager.setHttpIdleTimeoutMs(0)
    manager.setSteeringMode("all")
    manager.setFollowUpMode("all")
    manager.setRetryEnabled(false)
    let settings = provider.resolve()
    #expect(settings.stream.timeoutMs == Int(Int32.max))
    #expect(settings.steeringMode == .all)
    #expect(settings.followUpMode == .all)
    #expect(settings.retry.enabled == false)
}

@Test func harnessSettingsReadsReloadedSettings() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settingsFile = directory.appendingPathComponent("settings.json")
    try Data(#"{"httpIdleTimeoutMs":1000,"steeringMode":"one-at-a-time"}"#.utf8).write(to: settingsFile)
    let manager = SettingsManager.create(directory.path, directory.path)
    let provider = harnessSettings(from: manager)
    #expect(provider.resolve().stream.timeoutMs == 1_000)

    try Data(#"{"httpIdleTimeoutMs":2000,"steeringMode":"all","followUpMode":"all","retry":{"enabled":false,"baseDelayMs":3000,"provider":{"maxRetries":4}},"compaction":{"reserveTokens":789}}"#.utf8).write(to: settingsFile)
    await manager.reload()
    let settings = provider.resolve()
    #expect(settings.stream.timeoutMs == 2_000)
    #expect(settings.stream.maxRetries == 4)
    #expect(settings.retry.enabled == false)
    #expect(settings.retry.baseDelayMs == 3_000)
    #expect(settings.compaction.reserveTokens == 789)
    #expect(settings.steeringMode == .all)
    #expect(settings.followUpMode == .all)
}
