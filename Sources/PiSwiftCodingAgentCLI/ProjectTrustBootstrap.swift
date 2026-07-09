import Foundation
import PiSwiftCodingAgent

typealias ProjectTrustOptionSelector = @Sendable (String, SettingsManager) async -> ProjectTrustOption?

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
    hasUI: Bool,
    selectTrustOption: ProjectTrustOptionSelector? = nil
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

    var trust = ProjectTrustManager(settingsManager: trustSettingsManager).resolve(
        cwd: cwd,
        choice: choice,
        persistChoice: persistChoice,
        extensionDecision: extensionDecision,
        hasUI: hasUI
    )

    if trust.source == "ask-unhandled", hasUI, mode == .tui {
        let selected = if let selectTrustOption {
            await selectTrustOption(cwd, trustSettingsManager)
        } else {
            await selectProjectTrustOption(cwd: cwd, settingsManager: trustSettingsManager)
        }

        if let selected {
            trustSettingsManager.applyProjectTrustUpdates(selected.updates)
            trust = ProjectTrustResolution(
                trusted: selected.trusted,
                source: selected.updates.isEmpty ? "prompt-session" : "prompt-saved"
            )
        } else {
            trust = ProjectTrustResolution(trusted: false, source: "ask-cancelled")
        }
    }

    let settingsManager = trust.trusted
        ? SettingsManager.create(cwd, agentDir, projectTrusted: true)
        : trustSettingsManager
    return CLIProjectTrustBootstrap(
        trust: trust,
        trustSettingsManager: trustSettingsManager,
        settingsManager: settingsManager
    )
}
