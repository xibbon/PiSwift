import PiSwiftCodingAgent
import PiSwiftDurable

/// Creates a provider that reads the current coding-agent settings at each use.
/// Settings changes and reloads apply to the next call to `resolve()`.
/// HTTP timeouts apply to each request. Swift needs no shared HTTP dispatcher.
/// Coding-agent settings have no restart limit. The core default remains 5.
/// The maintained host keeps queued inputs after failure. Custom Harness hosts can select another policy.
public func harnessSettings(from settingsManager: SettingsManager, afterFailedRun: AfterFailedRun = .keep) -> HarnessSettingsProvider {
    HarnessSettingsProvider {
        let provider = settingsManager.getProviderRetrySettings()
        let idle = settingsManager.getHttpIdleTimeoutMs()
        let retry = settingsManager.getRetrySettings()
        let compaction = settingsManager.getCompactionSettingsOverrides()
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
                backgroundTokens: nil,
                modelOverrides: compaction.modelOverrides?.mapValues {
                    PiSwiftDurable.CompactionModelOverride(reserveTokens: $0.reserveTokens, keepRecentTokens: $0.keepRecentTokens)
                }
            ),
            steeringMode: QueueMode(rawValue: settingsManager.getSteeringMode()),
            followUpMode: QueueMode(rawValue: settingsManager.getFollowUpMode()),
            afterFailedRun: afterFailedRun
        )
    }
}
