import Foundation
import Testing
@testable import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentCLI
import PiSwiftCodingAgentTui

private func withFirstTimeSetupTempDirs(_ body: (String, String, String) async throws -> Void) async rethrows {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pi-first-time-setup-\(UUID().uuidString)")
        .path
    let cwd = URL(fileURLWithPath: tempDir).appendingPathComponent("project").path
    let agentDir = URL(fileURLWithPath: tempDir).appendingPathComponent("agent").path
    let settingsPath = URL(fileURLWithPath: agentDir).appendingPathComponent("settings.json").path
    try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    try await body(cwd, agentDir, settingsPath)
}

@Test func firstTimeSetupGateMatchesPiMonoConditions() throws {
    let settingsPath = "/tmp/pi-first-time-setup-settings-\(UUID().uuidString).json"
    let experimentalEnv = ["PI_EXPERIMENTAL": "1"]

    #expect(shouldRunFirstTimeSetup(
        settingsPath: settingsPath,
        env: experimentalEnv,
        fileExists: { _ in false }
    ) == true)
    #expect(shouldRunFirstTimeSetup(
        settingsPath: settingsPath,
        env: [:],
        fileExists: { _ in false }
    ) == false)
    #expect(shouldRunFirstTimeSetup(
        settingsPath: settingsPath,
        env: ["PI_EXPERIMENTAL": "1", ENV_AGENT_DIR: "/tmp/custom-agent"],
        fileExists: { _ in false }
    ) == false)
    #expect(shouldRunFirstTimeSetup(
        settingsPath: settingsPath,
        env: experimentalEnv,
        packageName: "fork",
        fileExists: { _ in false }
    ) == false)
    #expect(shouldRunFirstTimeSetup(
        settingsPath: settingsPath,
        env: experimentalEnv,
        fileExists: { _ in true }
    ) == false)
}

@Test func firstTimeSetupPersistsThemeAndAnalyticsSelection() async throws {
    await withFirstTimeSetupTempDirs { cwd, agentDir, settingsPath in
        let manager = SettingsManager.create(cwd, agentDir, projectTrusted: false)
        let shown = await runFirstTimeSetupIfNeeded(
            settingsManager: manager,
            settingsPath: settingsPath,
            env: ["PI_EXPERIMENTAL": "1"],
            isInteractive: true,
            presenter: { _ in
                FirstTimeSetupResult(themeName: "light", shareAnalytics: true)
            }
        )

        #expect(shown == true)
        let reloaded = SettingsManager.create(cwd, agentDir, projectTrusted: false)
        #expect(reloaded.getTheme() == "light")
        #expect(reloaded.getEnableAnalytics() == true)
        #expect(reloaded.getTrackingId() != nil)
    }
}

@Test func firstTimeSetupCancelDoesNotPersistSettings() async throws {
    await withFirstTimeSetupTempDirs { cwd, agentDir, settingsPath in
        let manager = SettingsManager.create(cwd, agentDir, projectTrusted: false)
        let shown = await runFirstTimeSetupIfNeeded(
            settingsManager: manager,
            settingsPath: settingsPath,
            env: ["PI_EXPERIMENTAL": "1"],
            isInteractive: true,
            presenter: { _ in nil }
        )

        #expect(shown == true)
        #expect(FileManager.default.fileExists(atPath: settingsPath) == false)
    }
}

@Test func firstTimeSetupSkippedWhenNonInteractive() async throws {
    await withFirstTimeSetupTempDirs { cwd, agentDir, settingsPath in
        let manager = SettingsManager.create(cwd, agentDir, projectTrusted: false)
        let shown = await runFirstTimeSetupIfNeeded(
            settingsManager: manager,
            settingsPath: settingsPath,
            env: ["PI_EXPERIMENTAL": "1"],
            isInteractive: false,
            presenter: { _ in
                FirstTimeSetupResult(themeName: "light", shareAnalytics: true)
            }
        )

        #expect(shown == false)
        #expect(FileManager.default.fileExists(atPath: settingsPath) == false)
    }
}
