import Foundation
import Testing
import PiSwiftCodingAgent
import PiSwiftAI

@Test func settingsPreservesExternalEdits() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-settings-test-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let settingsPath = URL(fileURLWithPath: tempDir).appendingPathComponent("settings.json").path
    let initial = """
    {"theme":"dark","extra":{"foo":"bar"},"compaction":{"enabled":true,"reserveTokens":1234,"keepRecentTokens":5678}}
    """
    try initial.data(using: .utf8)?.write(to: URL(fileURLWithPath: settingsPath))

    let manager = SettingsManager.create(tempDir, tempDir)
    manager.setCompactionEnabled(false)

    let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

    let extra = json?["extra"] as? [String: Any]
    #expect(extra?["foo"] as? String == "bar")

    let compaction = json?["compaction"] as? [String: Any]
    #expect(compaction?["enabled"] as? Bool == false)
    #expect(compaction?["reserveTokens"] as? Int == 1234)
    #expect(compaction?["keepRecentTokens"] as? Int == 5678)
    #expect(json?["theme"] as? String == "dark")
}

@Test func settingsInvalidJsonDoesNotOverwrite() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-settings-bad-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let settingsPath = URL(fileURLWithPath: tempDir).appendingPathComponent("settings.json").path
    let invalid = "{"
    try invalid.data(using: .utf8)?.write(to: URL(fileURLWithPath: settingsPath))

    let manager = SettingsManager.create(tempDir, tempDir)
    manager.setTheme("light")

    let contents = try String(contentsOfFile: settingsPath, encoding: .utf8)
    #expect(contents == invalid)
}

@Test func settingsQuietStartupRoundTrip() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-settings-quiet-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let settingsPath = URL(fileURLWithPath: tempDir).appendingPathComponent("settings.json").path

    let manager = SettingsManager.create(tempDir, tempDir)
    manager.setQuietStartup(true)

    let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(json?["quietStartup"] as? Bool == true)

    let reloaded = SettingsManager.create(tempDir, tempDir)
    #expect(reloaded.getQuietStartup() == true)
}

@Test func settingsTransportRoundTrip() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-settings-transport-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let settingsPath = URL(fileURLWithPath: tempDir).appendingPathComponent("settings.json").path

    let manager = SettingsManager.create(tempDir, tempDir)
    manager.setTransport(.websocket)

    let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(json?["transport"] as? String == "websocket")

    let reloaded = SettingsManager.create(tempDir, tempDir)
    #expect(reloaded.getTransport() == .websocket)
}

@Test func settingsTransportDefaultsToAuto() throws {
    let manager = SettingsManager.inMemory()
    #expect(manager.getTransport() == .auto)
}

@Test func settingsMigratesLegacyWebsocketsFlagToTransport() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-settings-websockets-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let settingsPath = URL(fileURLWithPath: tempDir).appendingPathComponent("settings.json").path
    let initial = """
    {"websockets":true}
    """
    try initial.data(using: .utf8)?.write(to: URL(fileURLWithPath: settingsPath))

    let manager = SettingsManager.create(tempDir, tempDir)
    #expect(manager.getTransport() == .websocket)
}

@Test func settingsParityFieldsRoundTrip() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-settings-parity-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let settingsPath = URL(fileURLWithPath: tempDir).appendingPathComponent("settings.json").path
    let initial = """
    {
      "defaultProjectTrust":"never",
      "editorPaddingX":9,
      "showHardwareCursor":true,
      "markdown":{"codeBlockIndent":"    "},
      "httpIdleTimeoutMs":"disabled",
      "websocketConnectTimeoutMs":"1234"
    }
    """
    try initial.data(using: .utf8)?.write(to: URL(fileURLWithPath: settingsPath))

    let manager = SettingsManager.create(tempDir, tempDir)
    #expect(manager.getDefaultProjectTrust() == .never)
    #expect(manager.getEditorPaddingX() == 3)
    #expect(manager.getShowHardwareCursor() == true)
    #expect(manager.getCodeBlockIndent() == "    ")
    #expect(manager.getHttpIdleTimeoutMs() == 0)
    #expect(manager.getWebSocketConnectTimeoutMs() == 1234)

    manager.setDefaultProjectTrust(.always)
    manager.setEditorPaddingX(-4)
    manager.setShowHardwareCursor(false)
    manager.setHttpIdleTimeoutMs(60_000)
    manager.setWebSocketConnectTimeoutMs(nil)

    let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(json?["defaultProjectTrust"] as? String == "always")
    #expect(json?["editorPaddingX"] as? Int == 0)
    #expect(json?["showHardwareCursor"] as? Bool == false)
    #expect(json?["httpIdleTimeoutMs"] as? Int == 60_000)
    #expect(json?["websocketConnectTimeoutMs"] == nil)

    let markdown = json?["markdown"] as? [String: Any]
    #expect(markdown?["codeBlockIndent"] as? String == "    ")
}

@Test func settingsAnalyticsOptInGeneratesTrackingId() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-settings-analytics-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let manager = SettingsManager.create(tempDir, tempDir)
    #expect(manager.getEnableAnalytics() == false)
    #expect(manager.getTrackingId() == nil)

    manager.setEnableAnalytics(true)
    let trackingId = try #require(manager.getTrackingId())
    #expect(!trackingId.isEmpty)

    manager.setEnableAnalytics(false)
    #expect(manager.getEnableAnalytics() == false)
    #expect(manager.getTrackingId() == trackingId)

    let reloaded = SettingsManager.create(tempDir, tempDir)
    #expect(reloaded.getEnableAnalytics() == false)
    #expect(reloaded.getTrackingId() == trackingId)
}

@Test func settingsProjectOverridesParityFields() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-settings-parity-project-\(UUID().uuidString)")
        .path
    let projectDir = URL(fileURLWithPath: tempDir).appendingPathComponent("project").path
    let agentDir = URL(fileURLWithPath: tempDir).appendingPathComponent("agent").path
    try? FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let globalPath = URL(fileURLWithPath: agentDir).appendingPathComponent("settings.json").path
    let projectPath = URL(fileURLWithPath: projectDir).appendingPathComponent(".pi").appendingPathComponent("settings.json").path
    try? FileManager.default.createDirectory(
        atPath: URL(fileURLWithPath: projectPath).deletingLastPathComponent().path,
        withIntermediateDirectories: true
    )
    try #"{"editorPaddingX":1,"httpIdleTimeoutMs":300000,"websocketConnectTimeoutMs":2222}"#.write(
        toFile: globalPath,
        atomically: true,
        encoding: .utf8
    )
    try #"{"editorPaddingX":2,"websocketConnectTimeoutMs":3333}"#.write(
        toFile: projectPath,
        atomically: true,
        encoding: .utf8
    )

    let manager = SettingsManager.create(projectDir, agentDir)
    #expect(manager.getEditorPaddingX() == 2)
    #expect(manager.getHttpIdleTimeoutMs() == 300_000)
    #expect(manager.getWebSocketConnectTimeoutMs() == 3333)
}

// MARK: - Packages tests

@Test func settingsLocalExtensionsInExtensionPaths() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-settings-ext-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let settingsPath = URL(fileURLWithPath: tempDir).appendingPathComponent("settings.json").path
    let initial = """
    {"extensions":["/local/ext.swift","./relative/ext.swift"]}
    """
    try initial.data(using: .utf8)?.write(to: URL(fileURLWithPath: settingsPath))

    let manager = SettingsManager.create(tempDir, tempDir)

    #expect(manager.getPackages().isEmpty)
    #expect(manager.getExtensionPaths() == ["/local/ext.swift", "./relative/ext.swift"])
}

@Test func settingsPackagesWithFilteringObjects() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-settings-pkg-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let settingsPath = URL(fileURLWithPath: tempDir).appendingPathComponent("settings.json").path
    let initial = """
    {"packages":["npm:simple-pkg",{"source":"npm:filtered-pkg","extensions":["ext/one.swift"],"skills":[]}]}
    """
    try initial.data(using: .utf8)?.write(to: URL(fileURLWithPath: settingsPath))

    let manager = SettingsManager.create(tempDir, tempDir)

    let packages = manager.getPackages()
    #expect(packages.count == 2)

    if case .simple(let first) = packages[0] {
        #expect(first == "npm:simple-pkg")
    } else {
        #expect(Bool(false), "Expected first package to be a simple string")
    }

    if case .filtered(let filtered) = packages[1] {
        #expect(filtered.source == "npm:filtered-pkg")
        #expect(filtered.extensions == ["ext/one.swift"])
        #expect(filtered.skills?.isEmpty == true)
    } else {
        #expect(Bool(false), "Expected second package to be a filtered object")
    }
}

@Test func settingsPreservesEnableModelsOnThinkingLevelChange() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-settings-models-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let settingsPath = URL(fileURLWithPath: tempDir).appendingPathComponent("settings.json").path
    let initial = """
    {"theme":"dark","defaultModel":"claude-sonnet"}
    """
    try initial.data(using: .utf8)?.write(to: URL(fileURLWithPath: settingsPath))

    let manager = SettingsManager.create(tempDir, tempDir)

    // Simulate user editing settings.json externally to add enabledModels
    let updated = """
    {"theme":"dark","defaultModel":"claude-sonnet","enabledModels":["claude-opus-4-5","gpt-5.2-codex"]}
    """
    try updated.data(using: .utf8)?.write(to: URL(fileURLWithPath: settingsPath))

    // User changes thinking level
    manager.setDefaultThinkingLevel("high")

    let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

    let enabledModels = json?["enabledModels"] as? [String]
    #expect(enabledModels == ["claude-opus-4-5", "gpt-5.2-codex"])
    #expect(json?["defaultThinkingLevel"] as? String == "high")
    #expect(json?["theme"] as? String == "dark")
    #expect(json?["defaultModel"] as? String == "claude-sonnet")
}

@Test func settingsInMemoryOverridesFileChanges() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-settings-inmem-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let settingsPath = URL(fileURLWithPath: tempDir).appendingPathComponent("settings.json").path
    let initial = """
    {"theme":"dark"}
    """
    try initial.data(using: .utf8)?.write(to: URL(fileURLWithPath: settingsPath))

    let manager = SettingsManager.create(tempDir, tempDir)

    // User externally sets thinking level to "low"
    let external = """
    {"theme":"dark","defaultThinkingLevel":"low"}
    """
    try external.data(using: .utf8)?.write(to: URL(fileURLWithPath: settingsPath))

    // But then changes it via UI to "high"
    manager.setDefaultThinkingLevel("high")

    let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(json?["defaultThinkingLevel"] as? String == "high")
}

@Test func settingsShellCommandPrefix() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-settings-prefix-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let settingsPath = URL(fileURLWithPath: tempDir).appendingPathComponent("settings.json").path
    let initial = """
    {"shellCommandPrefix":"shopt -s expand_aliases"}
    """
    try initial.data(using: .utf8)?.write(to: URL(fileURLWithPath: settingsPath))

    let manager = SettingsManager.create(tempDir, tempDir)
    #expect(manager.getShellCommandPrefix() == "shopt -s expand_aliases")

    // Test setting a new prefix
    manager.setShellCommandPrefix("source ~/.bashrc")
    #expect(manager.getShellCommandPrefix() == "source ~/.bashrc")

    let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(json?["shellCommandPrefix"] as? String == "source ~/.bashrc")
}

@Test func settingsDrainErrorsIncludesGlobalAndProjectParseErrors() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-settings-errors-\(UUID().uuidString)")
        .path
    let projectDir = URL(fileURLWithPath: tempDir).appendingPathComponent("project").path
    let agentDir = URL(fileURLWithPath: tempDir).appendingPathComponent("agent").path
    try? FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let globalPath = URL(fileURLWithPath: agentDir).appendingPathComponent("settings.json").path
    let projectPath = URL(fileURLWithPath: projectDir).appendingPathComponent(".pi").appendingPathComponent("settings.json").path
    try? FileManager.default.createDirectory(
        atPath: URL(fileURLWithPath: projectPath).deletingLastPathComponent().path,
        withIntermediateDirectories: true
    )
    try "{invalid-global".write(toFile: globalPath, atomically: true, encoding: .utf8)
    try "{invalid-project".write(toFile: projectPath, atomically: true, encoding: .utf8)

    let manager = SettingsManager.create(projectDir, agentDir)
    let errors = manager.drainErrors()
    #expect(errors.count == 2)
    #expect(Set(errors.map { $0.scope }) == Set(["global", "project"]))
    #expect(manager.drainErrors().isEmpty)
}

@Test func settingsManagerSkipsProjectSettingsWhenUntrusted() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-settings-untrusted-\(UUID().uuidString)")
        .path
    let projectDir = URL(fileURLWithPath: tempDir).appendingPathComponent("project").path
    let agentDir = URL(fileURLWithPath: tempDir).appendingPathComponent("agent").path
    try? FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let globalPath = URL(fileURLWithPath: agentDir).appendingPathComponent("settings.json").path
    let projectPath = URL(fileURLWithPath: projectDir).appendingPathComponent(".pi").appendingPathComponent("settings.json").path
    try? FileManager.default.createDirectory(
        atPath: URL(fileURLWithPath: projectPath).deletingLastPathComponent().path,
        withIntermediateDirectories: true
    )
    try #"{"defaultModel":"global-model"}"#.write(toFile: globalPath, atomically: true, encoding: .utf8)
    try #"{"defaultModel":"project-model","extensions":["extensions/project.swift"]}"#.write(toFile: projectPath, atomically: true, encoding: .utf8)

    let manager = SettingsManager.create(projectDir, agentDir, projectTrusted: false)

    #expect(manager.getDefaultModel() == "global-model")
    #expect(manager.getProjectSettings().extensions == nil)
    #expect(manager.drainErrors().isEmpty)
}

@Test func projectTrustManagerPersistsDecisionInGlobalSettings() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-project-trust-\(UUID().uuidString)")
        .path
    let projectDir = URL(fileURLWithPath: tempDir).appendingPathComponent("project").path
    let agentDir = URL(fileURLWithPath: tempDir).appendingPathComponent("agent").path
    try? FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let manager = SettingsManager.create(projectDir, agentDir, projectTrusted: false)
    let trustManager = ProjectTrustManager(settingsManager: manager)
    let denied = trustManager.resolve(cwd: projectDir, choice: .untrusted, persistChoice: true)
    #expect(!denied.trusted)

    let reloaded = SettingsManager.create(projectDir, agentDir, projectTrusted: false)
    #expect(ProjectTrustManager(settingsManager: reloaded).resolve(cwd: projectDir).trusted == false)
}

@Test func projectTrustManagerCanPersistExtensionDecision() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-project-trust-extension-\(UUID().uuidString)")
        .path
    let projectDir = URL(fileURLWithPath: tempDir).appendingPathComponent("project").path
    let agentDir = URL(fileURLWithPath: tempDir).appendingPathComponent("agent").path
    try? FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let manager = SettingsManager.create(projectDir, agentDir, projectTrusted: false)
    let decision = ProjectTrustEventResult(trusted: .yes, remember: true)
    let resolved = ProjectTrustManager(settingsManager: manager).resolve(cwd: projectDir, extensionDecision: decision)

    #expect(resolved.trusted == true)
    #expect(resolved.source == "extension-saved")

    let reloaded = SettingsManager.create(projectDir, agentDir, projectTrusted: false)
    #expect(ProjectTrustManager(settingsManager: reloaded).resolve(cwd: projectDir).trusted == true)
}

@Test func hasTrustRequiringProjectResourcesDetectsPiResources() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-project-trust-resources-\(UUID().uuidString)")
        .path
    let projectDir = URL(fileURLWithPath: tempDir).appendingPathComponent("project").path
    let piDir = URL(fileURLWithPath: projectDir).appendingPathComponent(".pi").path
    try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    #expect(hasTrustRequiringProjectResources(projectDir) == false)

    try FileManager.default.createDirectory(atPath: piDir, withIntermediateDirectories: true)
    try "{}".write(
        toFile: URL(fileURLWithPath: piDir).appendingPathComponent("settings.json").path,
        atomically: true,
        encoding: .utf8
    )

    #expect(hasTrustRequiringProjectResources(projectDir) == true)
}

@Test func settingsPreserveExternalProjectEditWhenChangingUnrelatedProjectField() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-settings-project-preserve-\(UUID().uuidString)")
        .path
    let projectDir = URL(fileURLWithPath: tempDir).appendingPathComponent("project").path
    let agentDir = URL(fileURLWithPath: tempDir).appendingPathComponent("agent").path
    try? FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let projectSettingsPath = URL(fileURLWithPath: projectDir).appendingPathComponent(".pi").appendingPathComponent("settings.json").path
    try? FileManager.default.createDirectory(
        atPath: URL(fileURLWithPath: projectSettingsPath).deletingLastPathComponent().path,
        withIntermediateDirectories: true
    )
    let initial = """
    {"extensions":["./old-extension.ts"],"prompts":["./old-prompt.md"]}
    """
    try initial.write(toFile: projectSettingsPath, atomically: true, encoding: .utf8)

    let manager = SettingsManager.create(projectDir, agentDir)

    let external = """
    {"extensions":["./old-extension.ts"],"prompts":["./new-prompt.md"]}
    """
    try external.write(toFile: projectSettingsPath, atomically: true, encoding: .utf8)

    manager.setProjectExtensionPaths(["./updated-extension.ts"])
    await manager.flush()

    let data = try Data(contentsOf: URL(fileURLWithPath: projectSettingsPath))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(json?["prompts"] as? [String] == ["./new-prompt.md"])
    #expect(json?["extensions"] as? [String] == ["./updated-extension.ts"])
}

@Test func settingsProjectInMemoryChangeOverridesExternalChangeForSameField() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-settings-project-override-\(UUID().uuidString)")
        .path
    let projectDir = URL(fileURLWithPath: tempDir).appendingPathComponent("project").path
    let agentDir = URL(fileURLWithPath: tempDir).appendingPathComponent("agent").path
    try? FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let projectSettingsPath = URL(fileURLWithPath: projectDir).appendingPathComponent(".pi").appendingPathComponent("settings.json").path
    try? FileManager.default.createDirectory(
        atPath: URL(fileURLWithPath: projectSettingsPath).deletingLastPathComponent().path,
        withIntermediateDirectories: true
    )
    try #"{"extensions":["./initial-extension.ts"]}"#.write(
        toFile: projectSettingsPath,
        atomically: true,
        encoding: .utf8
    )

    let manager = SettingsManager.create(projectDir, agentDir)

    try #"{"extensions":["./external-extension.ts"]}"#.write(
        toFile: projectSettingsPath,
        atomically: true,
        encoding: .utf8
    )

    manager.setProjectExtensionPaths(["./in-memory-extension.ts"])
    await manager.flush()

    let data = try Data(contentsOf: URL(fileURLWithPath: projectSettingsPath))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(json?["extensions"] as? [String] == ["./in-memory-extension.ts"])
}
