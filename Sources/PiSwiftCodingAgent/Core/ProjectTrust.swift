import Foundation
import PiSwiftAI

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

public struct ProjectTrustExtensionEvaluation: Sendable {
    public var decision: ProjectTrustEventResult?
    public var errors: [HookError]

    public init(decision: ProjectTrustEventResult? = nil, errors: [HookError] = []) {
        self.decision = decision
        self.errors = errors
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

public func hasTrustRequiringProjectResources(_ cwd: String) -> Bool {
    let projectConfigDir = URL(fileURLWithPath: cwd).appendingPathComponent(CONFIG_DIR_NAME)
    let resourceNames = [
        "settings.json",
        "extensions",
        "skills",
        "prompts",
        "themes",
        "SYSTEM.md",
        "APPEND_SYSTEM.md",
    ]
    for name in resourceNames {
        if FileManager.default.fileExists(atPath: projectConfigDir.appendingPathComponent(name).path) {
            return true
        }
    }
    return false
}

public func emitProjectTrustEvent(
    extensionsResult: LoadExtensionsResult,
    cwd: String,
    sessionManager: SessionManager,
    modelRegistry: ModelRegistry,
    mode: HookMode = .print,
    hasUI: Bool = false
) async -> ProjectTrustExtensionEvaluation {
    guard !extensionsResult.hooks.isEmpty else {
        return ProjectTrustExtensionEvaluation()
    }

    let runner = HookRunner(extensionsResult.hooks, cwd, sessionManager, modelRegistry)
    let errors = LockedState<[HookError]>([])
    _ = runner.onError { error in
        errors.withLock { $0.append(error) }
    }
    runner.initialize(
        getModel: { nil },
        isProjectTrusted: { false },
        mode: mode,
        hasUI: hasUI
    )
    let decision = await runner.emitProjectTrust(ProjectTrustEvent(cwd: cwd))
    return ProjectTrustExtensionEvaluation(decision: decision, errors: errors.withLock { $0 })
}
