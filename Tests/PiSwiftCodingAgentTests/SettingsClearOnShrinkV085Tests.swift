import Foundation
import Testing
@testable import PiSwiftCodingAgent

@Test func settings085ClearOnShrinkSettingWinsOverEnvironment() {
    for setting in [true, false] {
        for environment in [[:], ["PI_CLEAR_ON_SHRINK": "1"], ["PI_CLEAR_ON_SHRINK": "0"]] {
            #expect(SettingsManager.resolveClearOnShrink(setting, environment: environment) == setting)
        }
        var settings = Settings()
        settings.terminal = TerminalSettings(clearOnShrink: setting)
        #expect(SettingsManager.inMemory(settings).getClearOnShrink() == setting)
    }
}

@Test func settings085ClearOnShrinkEnvironmentRequiresOne() {
    #expect(SettingsManager.resolveClearOnShrink(nil, environment: ["PI_CLEAR_ON_SHRINK": "1"]))
    for value in ["0", "true", "", "01"] {
        #expect(!SettingsManager.resolveClearOnShrink(nil, environment: ["PI_CLEAR_ON_SHRINK": value]))
    }
}

@Test func settings085ClearOnShrinkDefaultsToFalse() {
    #expect(TerminalSettings().clearOnShrink == nil)
    #expect(!SettingsManager.resolveClearOnShrink(nil, environment: [:]))
}

@Test func settings085ClearOnShrinkGetterReadsEnvironment() {
    let expected = ProcessInfo.processInfo.environment["PI_CLEAR_ON_SHRINK"] == "1"
    #expect(SettingsManager.inMemory().getClearOnShrink() == expected)
}

@Test func settings085ClearOnShrinkSetterPersistsAndDecodes() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-clear-on-shrink-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settingsFile = directory.appendingPathComponent("settings.json")
    let manager = SettingsManager.create(directory.path, directory.path)

    for enabled in [true, false] {
        manager.setClearOnShrink(enabled)
        await manager.flush()
        #expect(manager.getClearOnShrink() == enabled)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settingsFile)) as? [String: Any])
        let terminal = try #require(json["terminal"] as? [String: Any])
        #expect(terminal["clearOnShrink"] as? Bool == enabled)
        let reloaded = SettingsManager.create(directory.path, directory.path)
        #expect(reloaded.getTerminalSettings().clearOnShrink == enabled)
        #expect(reloaded.getClearOnShrink() == enabled)
        #expect(manager.drainErrors().isEmpty)
    }
}

@Test func settings085ClearOnShrinkProjectMergeKeepsOtherTerminalFields() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-clear-on-shrink-merge-\(UUID().uuidString)")
    let projectSettingsDirectory = directory.appendingPathComponent(CONFIG_DIR_NAME)
    try FileManager.default.createDirectory(at: projectSettingsDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("""
    {"terminal":{"showTerminalProgress":true,"showImages":false,"imageWidthCells":88,"hyperlinks":true,"trueColor":false,"images":"kitty"}}
    """.utf8).write(to: directory.appendingPathComponent("settings.json"))
    try Data("""
    {"terminal":{"clearOnShrink":true}}
    """.utf8).write(to: projectSettingsDirectory.appendingPathComponent("settings.json"))

    let manager = SettingsManager.create(directory.path, directory.path)
    #expect(manager.getClearOnShrink())
    #expect(manager.getShowTerminalProgress())
    #expect(!manager.getShowImages())
    #expect(manager.getImageWidthCells() == 88)
    #expect(manager.getTerminalCapabilityOverrides().hyperlinks == true)
    #expect(manager.getTerminalCapabilityOverrides().trueColor == false)
    #expect(manager.getTerminalCapabilityOverrides().images == .kitty)
    #expect(manager.drainErrors().isEmpty)
}

@Test func settings085ClearOnShrinkMergeKeepsBaseAndAcceptsFalse() {
    var settings = Settings()
    settings.terminal = TerminalSettings(clearOnShrink: true)
    let manager = SettingsManager.inMemory(settings)
    var overrides = Settings()
    overrides.terminal = TerminalSettings(showTerminalProgress: true)
    manager.applyOverrides(overrides)
    #expect(manager.getClearOnShrink())
    #expect(manager.getShowTerminalProgress())

    overrides.terminal = TerminalSettings(clearOnShrink: false)
    manager.applyOverrides(overrides)
    #expect(!manager.getClearOnShrink())
    #expect(manager.getShowTerminalProgress())
}
