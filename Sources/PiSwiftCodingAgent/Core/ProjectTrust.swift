import Foundation

public enum ProjectTrustChoice: String, Sendable {
    case trusted
    case untrusted
}

public struct ProjectTrustResolution: Sendable {
    public var trusted: Bool
    public var source: String

    public init(trusted: Bool, source: String) {
        self.trusted = trusted
        self.source = source
    }
}

public final class ProjectTrustManager: Sendable {
    private let settingsManager: SettingsManager

    public init(settingsManager: SettingsManager) {
        self.settingsManager = settingsManager
    }

    public func resolve(
        cwd: String,
        choice: ProjectTrustChoice? = nil,
        persistChoice: Bool = false,
        extensionDecision: ProjectTrustEventResult? = nil,
        defaultTrusted: Bool = true
    ) -> ProjectTrustResolution {
        if let choice {
            let trusted = choice == .trusted
            if persistChoice {
                settingsManager.setProjectTrust(cwd, trusted: trusted)
            }
            return ProjectTrustResolution(trusted: trusted, source: persistChoice ? "override-saved" : "override")
        }

        if let trusted = settingsManager.getProjectTrust(cwd) {
            return ProjectTrustResolution(trusted: trusted, source: "settings")
        }

        if let extensionDecision {
            switch extensionDecision.trusted {
            case .yes, .no:
                let trusted = extensionDecision.trusted == .yes
                if extensionDecision.remember == true {
                    settingsManager.setProjectTrust(cwd, trusted: trusted)
                }
                return ProjectTrustResolution(
                    trusted: trusted,
                    source: extensionDecision.remember == true ? "extension-saved" : "extension"
                )
            case .undecided:
                break
            }
        }

        return ProjectTrustResolution(trusted: defaultTrusted, source: "default")
    }
}
