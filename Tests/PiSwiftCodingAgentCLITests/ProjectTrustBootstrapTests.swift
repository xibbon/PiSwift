import Foundation
import Testing
@testable import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentCLI

private func withTrustBootstrapTempDirs(_ body: (String, String) async throws -> Void) async rethrows {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pi-cli-trust-bootstrap-\(UUID().uuidString)")
        .path
    let cwd = URL(fileURLWithPath: tempDir).appendingPathComponent("project").path
    let agentDir = URL(fileURLWithPath: tempDir).appendingPathComponent("agent").path
    try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    try await body(cwd, agentDir)
}

private func writeProjectSettings(_ cwd: String, _ json: String) throws {
    let settingsPath = URL(fileURLWithPath: cwd)
        .appendingPathComponent(CONFIG_DIR_NAME)
        .appendingPathComponent("settings.json")
    try FileManager.default.createDirectory(
        at: settingsPath.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try json.write(to: settingsPath, atomically: true, encoding: .utf8)
}

private func writeGlobalSettings(_ agentDir: String, _ json: String) throws {
    let settingsPath = URL(fileURLWithPath: agentDir).appendingPathComponent("settings.json")
    try FileManager.default.createDirectory(
        at: settingsPath.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try json.write(to: settingsPath, atomically: true, encoding: .utf8)
}

@Test func cliProjectTrustBootstrapSkipsProjectSettingsWhenUntrusted() async throws {
    try await withTrustBootstrapTempDirs { cwd, agentDir in
        try writeProjectSettings(cwd, #"{"packages":["project-pkg"]}"#)

        let result = await resolveProjectTrustForCLI(
            cwd: cwd,
            agentDir: agentDir,
            modelRegistry: ModelRegistry(AuthStorage(":memory:"), agentDir),
            eventBus: createEventBus(),
            choice: .untrusted,
            persistChoice: true,
            noExtensions: true,
            mode: .print,
            hasUI: false
        )

        #expect(result.trust.trusted == false)
        #expect((result.settingsManager.getProjectSettings().packages ?? []).isEmpty)
    }
}

@Test func cliProjectTrustBootstrapUsesDefaultProjectTrustAlways() async throws {
    try await withTrustBootstrapTempDirs { cwd, agentDir in
        try writeGlobalSettings(agentDir, #"{"defaultProjectTrust":"always"}"#)
        try writeProjectSettings(cwd, #"{"packages":["project-pkg"]}"#)

        let result = await resolveProjectTrustForCLI(
            cwd: cwd,
            agentDir: agentDir,
            modelRegistry: ModelRegistry(AuthStorage(":memory:"), agentDir),
            eventBus: createEventBus(),
            choice: nil,
            persistChoice: false,
            noExtensions: true,
            mode: .print,
            hasUI: false
        )

        #expect(result.trust.trusted == true)
        #expect(result.trust.source == "default-always")
        #expect((result.settingsManager.getProjectSettings().packages ?? []).count == 1)
    }
}

@Test func cliProjectTrustBootstrapUsesDefaultProjectTrustNever() async throws {
    try await withTrustBootstrapTempDirs { cwd, agentDir in
        try writeGlobalSettings(agentDir, #"{"defaultProjectTrust":"never"}"#)
        try writeProjectSettings(cwd, #"{"packages":["project-pkg"]}"#)

        let result = await resolveProjectTrustForCLI(
            cwd: cwd,
            agentDir: agentDir,
            modelRegistry: ModelRegistry(AuthStorage(":memory:"), agentDir),
            eventBus: createEventBus(),
            choice: nil,
            persistChoice: false,
            noExtensions: true,
            mode: .print,
            hasUI: false
        )

        #expect(result.trust.trusted == false)
        #expect(result.trust.source == "default-never")
        #expect((result.settingsManager.getProjectSettings().packages ?? []).isEmpty)
    }
}

@Test func cliProjectTrustBootstrapAskWithoutUiDeniesTrustRequiringProject() async throws {
    try await withTrustBootstrapTempDirs { cwd, agentDir in
        try writeGlobalSettings(agentDir, #"{"defaultProjectTrust":"ask"}"#)
        try writeProjectSettings(cwd, #"{"packages":["project-pkg"]}"#)

        let result = await resolveProjectTrustForCLI(
            cwd: cwd,
            agentDir: agentDir,
            modelRegistry: ModelRegistry(AuthStorage(":memory:"), agentDir),
            eventBus: createEventBus(),
            choice: nil,
            persistChoice: false,
            noExtensions: true,
            mode: .print,
            hasUI: false
        )

        #expect(result.trust.trusted == false)
        #expect(result.trust.source == "ask-no-ui")
        #expect((result.settingsManager.getProjectSettings().packages ?? []).isEmpty)
    }
}

@Test func cliProjectTrustBootstrapAskWithUiPersistsSelectedTrustOption() async throws {
    try await withTrustBootstrapTempDirs { cwd, agentDir in
        try writeGlobalSettings(agentDir, #"{"defaultProjectTrust":"ask"}"#)
        try writeProjectSettings(cwd, #"{"packages":["project-pkg"]}"#)

        let result = await resolveProjectTrustForCLI(
            cwd: cwd,
            agentDir: agentDir,
            modelRegistry: ModelRegistry(AuthStorage(":memory:"), agentDir),
            eventBus: createEventBus(),
            choice: nil,
            persistChoice: false,
            noExtensions: true,
            mode: .tui,
            hasUI: true,
            selectTrustOption: { cwd, _ in
                getProjectTrustOptions(cwd, includeSessionOnly: true)[0]
            }
        )

        #expect(result.trust.trusted == true)
        #expect(result.trust.source == "prompt-saved")
        #expect(result.trustSettingsManager.getProjectTrust(cwd) == true)
        #expect((result.settingsManager.getProjectSettings().packages ?? []).count == 1)
    }
}

@Test func cliProjectTrustBootstrapAskWithUiUsesSessionOnlySelection() async throws {
    try await withTrustBootstrapTempDirs { cwd, agentDir in
        try writeGlobalSettings(agentDir, #"{"defaultProjectTrust":"ask"}"#)
        try writeProjectSettings(cwd, #"{"packages":["project-pkg"]}"#)

        let result = await resolveProjectTrustForCLI(
            cwd: cwd,
            agentDir: agentDir,
            modelRegistry: ModelRegistry(AuthStorage(":memory:"), agentDir),
            eventBus: createEventBus(),
            choice: nil,
            persistChoice: false,
            noExtensions: true,
            mode: .tui,
            hasUI: true,
            selectTrustOption: { cwd, _ in
                getProjectTrustOptions(cwd, includeSessionOnly: true).first {
                    $0.trusted && $0.updates.isEmpty
                }
            }
        )

        #expect(result.trust.trusted == true)
        #expect(result.trust.source == "prompt-session")
        #expect(result.trustSettingsManager.getProjectTrust(cwd) == nil)
        #expect((result.settingsManager.getProjectSettings().packages ?? []).count == 1)
    }
}

@Test func cliProjectTrustBootstrapAskWithUiCancelDeniesProject() async throws {
    try await withTrustBootstrapTempDirs { cwd, agentDir in
        try writeGlobalSettings(agentDir, #"{"defaultProjectTrust":"ask"}"#)
        try writeProjectSettings(cwd, #"{"packages":["project-pkg"]}"#)

        let result = await resolveProjectTrustForCLI(
            cwd: cwd,
            agentDir: agentDir,
            modelRegistry: ModelRegistry(AuthStorage(":memory:"), agentDir),
            eventBus: createEventBus(),
            choice: nil,
            persistChoice: false,
            noExtensions: true,
            mode: .tui,
            hasUI: true,
            selectTrustOption: { _, _ in nil }
        )

        #expect(result.trust.trusted == false)
        #expect(result.trust.source == "ask-cancelled")
        #expect((result.settingsManager.getProjectSettings().packages ?? []).isEmpty)
    }
}

@Test func cliProjectTrustBootstrapTrustsProjectWithoutTrustRequiringResources() async throws {
    try await withTrustBootstrapTempDirs { cwd, agentDir in
        try writeGlobalSettings(agentDir, #"{"defaultProjectTrust":"never"}"#)

        let result = await resolveProjectTrustForCLI(
            cwd: cwd,
            agentDir: agentDir,
            modelRegistry: ModelRegistry(AuthStorage(":memory:"), agentDir),
            eventBus: createEventBus(),
            choice: nil,
            persistChoice: false,
            noExtensions: true,
            mode: .print,
            hasUI: false
        )

        #expect(result.trust.trusted == true)
        #expect(result.trust.source == "no-project-resources")
    }
}

@Test func cliProjectTrustBootstrapLoadsProjectSettingsWhenTrusted() async throws {
    try await withTrustBootstrapTempDirs { cwd, agentDir in
        try writeProjectSettings(cwd, #"{"packages":["project-pkg"]}"#)

        let result = await resolveProjectTrustForCLI(
            cwd: cwd,
            agentDir: agentDir,
            modelRegistry: ModelRegistry(AuthStorage(":memory:"), agentDir),
            eventBus: createEventBus(),
            choice: .trusted,
            persistChoice: true,
            noExtensions: true,
            mode: .print,
            hasUI: false
        )

        #expect(result.trust.trusted == true)
        let packages = result.settingsManager.getProjectSettings().packages ?? []
        #expect(packages.count == 1)
        if case .simple(let source)? = packages.first {
            #expect(source == "project-pkg")
        } else {
            Issue.record("Expected simple project package source")
        }
    }
}
