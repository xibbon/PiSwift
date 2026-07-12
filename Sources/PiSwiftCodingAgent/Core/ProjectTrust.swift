import Foundation
import PiSwiftAI

public enum ProjectTrustChoice: String, Sendable {
    case trusted
    case untrusted
}

public struct ProjectTrustUpdate: Sendable, Equatable {
    public var path: String
    public var decision: Bool?

    public init(path: String, decision: Bool?) {
        self.path = path
        self.decision = decision
    }
}

public struct ProjectTrustOption: Sendable, Equatable {
    public var label: String
    public var trusted: Bool
    public var updates: [ProjectTrustUpdate]
    public var savedPath: String?

    public init(label: String, trusted: Bool, updates: [ProjectTrustUpdate], savedPath: String? = nil) {
        self.label = label
        self.trusted = trusted
        self.updates = updates
        self.savedPath = savedPath
    }
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

public func normalizeProjectTrustPathForOptions(_ path: String) -> String {
    URL(fileURLWithPath: path).standardized.path
}

public func getProjectTrustParentPath(_ cwd: String) -> String? {
    let trustPath = normalizeProjectTrustPathForOptions(cwd)
    let parent = URL(fileURLWithPath: trustPath).deletingLastPathComponent().path
    return parent == trustPath ? nil : parent
}

public func getProjectTrustOptions(_ cwd: String, includeSessionOnly: Bool = false) -> [ProjectTrustOption] {
    let trustPath = normalizeProjectTrustPathForOptions(cwd)
    var options = [
        ProjectTrustOption(
            label: "Trust",
            trusted: true,
            updates: [ProjectTrustUpdate(path: trustPath, decision: true)],
            savedPath: trustPath
        )
    ]

    if let parentPath = getProjectTrustParentPath(cwd) {
        options.append(ProjectTrustOption(
            label: "Trust parent folder (\(parentPath))",
            trusted: true,
            updates: [
                ProjectTrustUpdate(path: parentPath, decision: true),
                ProjectTrustUpdate(path: trustPath, decision: nil),
            ],
            savedPath: parentPath
        ))
    }

    if includeSessionOnly {
        options.append(ProjectTrustOption(label: "Trust (this session only)", trusted: true, updates: []))
    }

    options.append(ProjectTrustOption(
        label: "Do not trust",
        trusted: false,
        updates: [ProjectTrustUpdate(path: trustPath, decision: false)],
        savedPath: trustPath
    ))

    if includeSessionOnly {
        options.append(ProjectTrustOption(label: "Do not trust (this session only)", trusted: false, updates: []))
    }

    return options
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
        defaultProjectTrust: DefaultProjectTrust? = nil,
        hasUI: Bool = false
    ) -> ProjectTrustResolution {
        if let choice {
            let trusted = choice == .trusted
            if persistChoice {
                settingsManager.setProjectTrust(cwd, trusted: trusted)
            }
            return ProjectTrustResolution(trusted: trusted, source: persistChoice ? "override-saved" : "override")
        }

        if !hasTrustRequiringProjectResources(cwd) {
            return ProjectTrustResolution(trusted: true, source: "no-project-resources")
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

        switch defaultProjectTrust ?? settingsManager.getDefaultProjectTrust() {
        case .always:
            return ProjectTrustResolution(trusted: true, source: "default-always")
        case .never:
            return ProjectTrustResolution(trusted: false, source: "default-never")
        case .ask:
            return ProjectTrustResolution(trusted: false, source: hasUI ? "ask-unhandled" : "ask-no-ui")
        }
    }
}

public func hasTrustRequiringProjectResources(_ cwd: String) -> Bool {
    let homeDir = URL(fileURLWithPath: getHomeDir()).standardized.path
    let userAgentsSkillsDir = URL(fileURLWithPath: homeDir)
        .appendingPathComponent(".agents")
        .appendingPathComponent("skills")
        .standardized
        .path
    var currentDir = URL(fileURLWithPath: cwd).standardized.path
    let projectConfigDir = URL(fileURLWithPath: currentDir).appendingPathComponent(CONFIG_DIR_NAME)
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

    while true {
        let agentsSkillsDir = URL(fileURLWithPath: currentDir)
            .appendingPathComponent(".agents")
            .appendingPathComponent("skills")
            .standardized
            .path
        if agentsSkillsDir != userAgentsSkillsDir,
           FileManager.default.fileExists(atPath: agentsSkillsDir) {
            return true
        }

        let parentDir = URL(fileURLWithPath: currentDir).deletingLastPathComponent().path
        if parentDir == currentDir {
            return false
        }
        currentDir = parentDir
    }
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
