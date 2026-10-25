import Foundation
import Testing
@testable import PiSwiftCodingAgent

@Suite("H1 deferred tool settings")
struct H1DeferredToolsSettingsTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-h1-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ json: String, to path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: path)
    }

    @Test func defaultsAndInMemorySetter() {
        let manager = SettingsManager.inMemory()
        #expect(manager.getDurableDeferredTools().isEmpty)
        #expect(manager.getGlobalSettings().durableDeferredTools == nil)

        manager.setDurableDeferredTools(["read", "custom-tool"])
        #expect(manager.getDurableDeferredTools() == ["read", "custom-tool"])
        #expect(manager.getGlobalSettings().durableDeferredTools == ["read", "custom-tool"])
        manager.setDurableDeferredTools([])
        #expect(manager.getDurableDeferredTools().isEmpty)
        #expect(manager.getGlobalSettings().durableDeferredTools == [])
    }

    @Test func overridesReplaceListsAndPreserveOtherFields() {
        var base = Settings()
        base.durableDeferredTools = ["read", "write"]
        base.defaultTools = ["read", "bash"]
        base.theme = "dark"
        let manager = SettingsManager.inMemory(base)
        #expect(manager.getDurableDeferredTools() == ["read", "write"])

        manager.applyOverrides(Settings())
        #expect(manager.getDurableDeferredTools() == ["read", "write"])
        var override = Settings()
        override.durableDeferredTools = ["custom-tool"]
        manager.applyOverrides(override)
        #expect(manager.getDurableDeferredTools() == ["custom-tool"])
        override.durableDeferredTools = []
        manager.applyOverrides(override)
        #expect(manager.getDurableDeferredTools().isEmpty)
        #expect(manager.getDefaultTools() == ["read", "bash"])
        #expect(manager.getTheme() == "dark")
        #expect(manager.getGlobalSettings().durableDeferredTools == ["read", "write"])
    }

    @Test(arguments: [#"{}"#, #"{"durableDeferredTools":null}"#,
                      #"{"durableDeferredTools":"read"}"#, #"{"durableDeferredTools":["read",1]}"#])
    func missingOrInvalidJSONUsesDefault(_ json: String) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(json, to: directory.appendingPathComponent("settings.json"))
        let manager = SettingsManager.create(directory.path, directory.path)
        #expect(manager.getDurableDeferredTools().isEmpty)
        #expect(manager.getGlobalSettings().durableDeferredTools == nil)
        #expect(manager.drainErrors().isEmpty)
    }

    @Test(arguments: [["read", "custom-tool"], []])
    func fileRoundTripPreservesOtherFields(_ names: [String]) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("settings.json")
        try write(#"{"theme":"dark","defaultTools":["read"],"futureSetting":{"enabled":true}}"#, to: path)
        let manager = SettingsManager.create(directory.path, directory.path)
        manager.setDurableDeferredTools(names)

        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        #expect(saved["durableDeferredTools"] as? [String] == names)
        #expect(saved["theme"] as? String == "dark")
        #expect(saved["defaultTools"] as? [String] == ["read"])
        #expect((saved["futureSetting"] as? [String: Bool])?["enabled"] == true)
        let reloaded = SettingsManager.create(directory.path, directory.path)
        #expect(reloaded.getDurableDeferredTools() == names)
        #expect(reloaded.getGlobalSettings().durableDeferredTools == names)
        #expect(reloaded.drainErrors().isEmpty)
    }

    @Test func setterPreservesExternalChanges() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("settings.json")
        try write(#"{"theme":"dark","durableDeferredTools":["read"]}"#, to: path)
        let manager = SettingsManager.create(directory.path, directory.path)
        try write(#"{"theme":"light","defaultModel":"updated","durableDeferredTools":["write"]}"#, to: path)
        manager.setDurableDeferredTools(["custom-tool"])
        #expect(manager.getDurableDeferredTools() == ["custom-tool"])
        #expect(manager.getTheme() == "light")
        #expect(manager.getGlobalSettings().defaultModel == "updated")
        #expect(SettingsManager.create(directory.path, directory.path).getDurableDeferredTools() == ["custom-tool"])
    }

    @Test(arguments: [["project-tool"], []])
    func projectOverridesGlobalAndSurvivesOtherProjectWrites(_ names: [String]) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let globalPath = directory.appendingPathComponent("settings.json")
        let projectPath = directory.appendingPathComponent(CONFIG_DIR_NAME).appendingPathComponent("settings.json")
        try write(#"{"durableDeferredTools":["global-tool"],"theme":"dark"}"#, to: globalPath)
        let projectData = try JSONSerialization.data(withJSONObject: ["durableDeferredTools": names])
        try write(String(decoding: projectData, as: UTF8.self), to: projectPath)
        let manager = SettingsManager.create(directory.path, directory.path)
        #expect(manager.getDurableDeferredTools() == names)
        #expect(manager.getProjectSettings().durableDeferredTools == names)
        manager.setProjectExtensionPaths(["./extension.swift"])
        manager.setDurableDeferredTools(["new-global-tool"])
        #expect(manager.getDurableDeferredTools() == names)
        #expect(manager.getGlobalSettings().durableDeferredTools == ["new-global-tool"])
        let savedProject = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: projectPath)) as? [String: Any])
        #expect(savedProject["durableDeferredTools"] as? [String] == names)
        #expect(SettingsManager.create(directory.path, directory.path).getDurableDeferredTools() == names)
        #expect(SettingsManager.create(directory.path, directory.path, projectTrusted: false).getDurableDeferredTools() == ["new-global-tool"])
    }

    @Test func projectWithoutDeferredToolsKeepsGlobalValue() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(#"{"durableDeferredTools":["global-tool"]}"#, to: directory.appendingPathComponent("settings.json"))
        try write(#"{"theme":"light"}"#, to: directory.appendingPathComponent(CONFIG_DIR_NAME).appendingPathComponent("settings.json"))
        let manager = SettingsManager.create(directory.path, directory.path)
        #expect(manager.getDurableDeferredTools() == ["global-tool"])
        #expect(manager.getTheme() == "light")
    }

    @Test(.timeLimit(.minutes(1))) func reloadReadsGlobalAndProjectChanges() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let globalPath = directory.appendingPathComponent("settings.json")
        let projectPath = directory.appendingPathComponent(CONFIG_DIR_NAME).appendingPathComponent("settings.json")
        try write(#"{"durableDeferredTools":["read"]}"#, to: globalPath)
        let manager = SettingsManager.create(directory.path, directory.path)
        var override = Settings()
        override.durableDeferredTools = ["temporary"]
        manager.applyOverrides(override)
        try write(#"{"durableDeferredTools":["write"],"theme":"light"}"#, to: globalPath)
        await manager.reload()
        #expect(manager.getDurableDeferredTools() == ["write"])
        #expect(manager.getTheme() == "light")
        try write(#"{"durableDeferredTools":[]}"#, to: projectPath)
        await manager.reload()
        #expect(manager.getDurableDeferredTools().isEmpty)
        try write(#"{"durableDeferredTools":["project-tool"]}"#, to: projectPath)
        await manager.reload()
        #expect(manager.getDurableDeferredTools() == ["project-tool"])
        try write("{}", to: projectPath)
        await manager.reload()
        #expect(manager.getDurableDeferredTools() == ["write"])
        #expect(manager.drainErrors().isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func inMemoryReloadKeepsStoredValue() async {
        let manager = SettingsManager.inMemory()
        manager.setDurableDeferredTools(["read"])
        var override = Settings()
        override.durableDeferredTools = []
        manager.applyOverrides(override)
        #expect(manager.getDurableDeferredTools().isEmpty)
        await manager.reload()
        #expect(manager.getDurableDeferredTools() == ["read"])
    }
}
