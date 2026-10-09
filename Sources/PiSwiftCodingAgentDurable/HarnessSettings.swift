import PiSwiftCodingAgent
import PiSwiftDurable

/// Creates a provider that reads the current coding-agent settings at each use.
/// Settings changes and reloads apply to the next call to `resolve()`.
/// HTTP timeouts apply to each request. Swift needs no shared HTTP dispatcher.
public func harnessSettings(from settingsManager: SettingsManager) -> HarnessSettingsProvider {
    HarnessSettingsProvider {
        let provider = settingsManager.getProviderRetrySettings()
        let idle = settingsManager.getHttpIdleTimeoutMs()
        let retry = settingsManager.getRetrySettings()
        let compaction = settingsManager.getCompactionSettings()
        return HarnessSettings(
            stream: ConversationStreamOptions(
                timeoutMs: provider.timeoutMs ?? (idle == 0 ? Int(Int32.max) : idle),
                maxRetries: provider.maxRetries,
                maxRetryDelayMs: provider.maxRetryDelayMs
            ),
            retry: RetryPolicyOverrides(
                enabled: retry.enabled,
                maxRetries: retry.maxRetries,
                baseDelayMs: retry.baseDelayMs.map { Int64($0) },
                maxAgentDelayMs: retry.maxAgentDelayMs.map { Int64($0) }
            ),
            compaction: CompactionPolicyOverrides(
                enabled: compaction.enabled,
                reserveTokens: compaction.reserveTokens,
                keepRecentTokens: compaction.keepRecentTokens,
                backgroundTokens: nil
            ),
            steeringMode: QueueMode(rawValue: settingsManager.getSteeringMode()),
            followUpMode: QueueMode(rawValue: settingsManager.getFollowUpMode())
        )
    }
}
