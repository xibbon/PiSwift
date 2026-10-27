import PiSwiftAI

/// A host can read locked state here to change identity between requests.
public typealias ClientIdentityProvider = @Sendable () -> ClientIdentity?

// Upstream v1.4.0 core/client-identity.ts: read install telemetry for each request.
public func getCodingAgentClientIdentity(_ settingsManager: SettingsManager = SettingsManager.create()) -> ClientIdentity {
    ClientIdentity(
        userAgent: .detailed,
        attribution: settingsManager.getInstallTelemetryEnabled() ? .value(PI_ATTRIBUTION) : .disabled,
        version: VERSION
    )
}
