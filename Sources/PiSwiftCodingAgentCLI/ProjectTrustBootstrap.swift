import Foundation
import PiSwiftCodingAgent

struct CLIProjectTrustBootstrap: Sendable {
    var trust: ProjectTrustResolution
    var trustSettingsManager: SettingsManager
    var settingsManager: SettingsManager
}

func projectTrustChoice(approve: Bool, noApprove: Bool) -> ProjectTrustChoice? {
    if approve { return .trusted }
    if noApprove { return .untrusted }
    return nil
}

func resolveProjectTrustForCLI(
    cwd: String,
    agentDir: String,
    modelRegistry: ModelRegistry,
    eventBus: EventBus,
    choice: ProjectTrustChoice?,
    persistChoice: Bool,
    noExtensions: Bool,
    mode: HookMode,
    hasUI: Bool
) async -> CLIProjectTrustBootstrap {
    let trustSettingsManager = SettingsManager.create(cwd, agentDir, projectTrusted: false)
    let extensionDecision: ProjectTrustEventResult?
    if !noExtensions,
       choice == nil,
       hasTrustRequiringProjectResources(cwd) {
        let preTrustExtensions = await discoverAndLoadExtensions(
            trustSettingsManager.getExtensionPaths(),
            cwd,
            agentDir,
            eventBus,
            includeProjectExtensions: false
        )
        for error in preTrustExtensions.errors {
            fputs("Failed to load extension: \(error.localizedDescription)\n", stderr)
        }
        let evaluation = await emitProjectTrustEvent(
            extensionsResult: preTrustExtensions,
            cwd: cwd,
            sessionManager: SessionManager.inMemory(cwd),
            modelRegistry: modelRegistry,
            mode: mode,
            hasUI: hasUI
        )
        for error in evaluation.errors {
            fputs("Extension \"\(error.hookPath)\" project_trust error: \(error.error)\n", stderr)
        }
        extensionDecision = evaluation.decision
    } else {
        extensionDecision = nil
    }

    let trust = ProjectTrustManager(settingsManager: trustSettingsManager).resolve(
        cwd: cwd,
        choice: choice,
        persistChoice: persistChoice,
        extensionDecision: extensionDecision
    )
    let settingsManager = trust.trusted
        ? SettingsManager.create(cwd, agentDir, projectTrusted: true)
        : trustSettingsManager
    return CLIProjectTrustBootstrap(
        trust: trust,
        trustSettingsManager: trustSettingsManager,
        settingsManager: settingsManager
    )
}

