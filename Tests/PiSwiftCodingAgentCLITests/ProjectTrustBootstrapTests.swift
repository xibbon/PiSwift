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

