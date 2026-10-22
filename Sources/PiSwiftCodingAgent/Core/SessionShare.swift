import Foundation

public enum SessionShareError: LocalizedError, Sendable, Equatable {
    case radiusUnavailable

    public var errorDescription: String? {
        "Radius sharing is not available in this version."
    }
}

/// Check the destination before the host starts authentication, export, or upload.
/// The host supplies its gist route. Radius support is deferred.
public func shareSession<Result>(
    settingsManager: SettingsManager,
    isolation: isolated (any Actor)? = #isolation,
    uploadGist: () async throws -> Result
) async throws -> Result {
    switch settingsManager.getSessionShareDestination() {
    case .auto, .gist:
        return try await uploadGist()
    case .radius:
        throw SessionShareError.radiusUnavailable
    }
}
