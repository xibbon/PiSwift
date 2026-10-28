import Foundation
import Testing
@testable import PiSwiftCodingAgent

private func h2SettingsDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("h2-settings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent(CONFIG_DIR_NAME), withIntermediateDirectories: true)
    return root
}

private func h2SettingsJSON(_ field: String, _ value: String) -> String {
    field.split(separator: ".").reversed().reduce(value) { "{\"\($1)\":\($0)}" }
}

private func h2WriteSettings(_ json: String, root: URL, project: Bool = false) throws {
    let directory = project ? root.appendingPathComponent(CONFIG_DIR_NAME) : root
    try Data(json.utf8).write(to: directory.appendingPathComponent("settings.json"))
}

private enum H2StrictBooleanField: String, CaseIterable, Sendable {
    case websockets
    case hyperlinks = "terminal.hyperlinks"
    case trueColor = "terminal.trueColor"
    case images = "terminal.images"
    case warning = "warnings.anthropicExtraUsage"

    func check(_ manager: SettingsManager, token: String, project: Bool) {
        let capabilities = manager.getTerminalCapabilityOverrides()
        switch self {
        case .websockets:
            if token == "true" {
                #expect(manager.getTransport() == .websocket)
            } else if token == "false" || project {
                #expect(manager.getTransport() == .sse)
            } else {
                #expect(manager.getTransport() == .auto)
            }
            let layer = project ? manager.getProjectSettings() : manager.getGlobalSettings()
            if token != "true" && token != "false" { #expect(layer.transport == nil) }
        case .hyperlinks, .trueColor:
            let actual = self == .hyperlinks ? capabilities.hyperlinks : capabilities.trueColor
            let expected: Bool? = token == "true" ? true : token == "false" ? false : nil
            #expect(actual == expected)
        case .images:
            #expect(capabilities.images == (token == "false" ? .disabled : nil))
        case .warning:
            #expect(manager.getAnthropicExtraUsageWarning() == (token != "false"))
        }
    }
}

@Test(arguments: H2StrictBooleanField.allCases)
private func h2StrictBooleanSettings(_ field: H2StrictBooleanField) async throws {
    let root = try h2SettingsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    for project in [false, true] {
        for token in ["true", "false", "0", "1", "2"] {
            try h2WriteSettings("{}", root: root, project: true)
            if project {
                let base = field == .websockets ? #"{"transport":"sse"}"# : h2SettingsJSON(field.rawValue, "false")
                try h2WriteSettings(base, root: root)
            }
            try h2WriteSettings(h2SettingsJSON(field.rawValue, token), root: root, project: project)
            let manager = SettingsManager.create(root.path, root.path)
            field.check(manager, token: token, project: project)
            // Both save paths decode the raw JSON merge again.
            if project { manager.setProjectExtensionPaths(["./h2-extension"]) }
            else { manager.setDefaultModel("h2-model") }
            await manager.flush()
            field.check(manager, token: token, project: project)
            await manager.reload()
            field.check(manager, token: token, project: project)
            #expect(manager.drainErrors().isEmpty)
        }
    }
}

private enum H2TruthyBooleanField: String, CaseIterable, Sendable {
    case fullscreenCopyOnSelect, hideThinkingBlock, showCacheMissNotices, collapseChangelog
    case enableSkillCommands, showHardwareCursor, enableInstallTelemetry, enableAnalytics
    case compaction = "compaction.enabled"
    case branch = "branchSummary.skipPrompt"
    case retry = "retry.enabled"
    case legacySkillCommands = "skills.enableSkillCommands"
    case showImages = "terminal.showImages"
    case showTerminalProgress = "terminal.showTerminalProgress"
    case clearOnShrink = "terminal.clearOnShrink"
    case autoResize = "images.autoResize"
    case blockImages = "images.blockImages"

    func value(_ manager: SettingsManager) -> Bool? {
        let settings = manager.getSettings()
        switch self {
        case .fullscreenCopyOnSelect: return settings.fullscreenCopyOnSelect
        case .hideThinkingBlock: return settings.hideThinkingBlock
        case .showCacheMissNotices: return settings.showCacheMissNotices
        case .collapseChangelog: return settings.collapseChangelog
        case .enableSkillCommands: return manager.getEnableSkillCommands()
        case .showHardwareCursor: return manager.getShowHardwareCursor()
        case .enableInstallTelemetry: return settings.enableInstallTelemetry
        case .enableAnalytics: return manager.getEnableAnalytics()
        case .compaction: return settings.compaction?.enabled
        case .branch: return settings.branchSummary?.skipPrompt
        case .retry: return settings.retry?.enabled
        case .legacySkillCommands: return manager.getEnableSkillCommands()
        case .showImages: return settings.terminal?.showImages
        case .showTerminalProgress: return settings.terminal?.showTerminalProgress
        case .clearOnShrink: return manager.getClearOnShrink()
        case .autoResize: return settings.images?.autoResize
        case .blockImages: return settings.images?.blockImages
        }
    }
}

@Test(arguments: H2TruthyBooleanField.allCases)
private func h2TruthyBooleanSettings(_ field: H2TruthyBooleanField) async throws {
    let root = try h2SettingsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    for project in [false, true] {
        for token in ["true", "false", "0", "1", "2", "-2", "0.5", "-0"] {
            let expected = !["false", "0", "-0"].contains(token)
            try h2WriteSettings("{}", root: root, project: true)
            if project { try h2WriteSettings(h2SettingsJSON(field.rawValue, "false"), root: root) }
            try h2WriteSettings(h2SettingsJSON(field.rawValue, token), root: root, project: project)
            let manager = SettingsManager.create(root.path, root.path)
            #expect(field.value(manager) == expected)
            if project { manager.setProjectExtensionPaths(["./h2-extension"]) }
            else { manager.setDefaultModel("h2-model") }
            await manager.flush()
            #expect(field.value(manager) == expected)
            await manager.reload()
            #expect(field.value(manager) == expected)
            #expect(manager.drainErrors().isEmpty)
        }
    }
}

@Test private func h2QuietStartupKeepsStrictBooleanRule() throws {
    let root = try h2SettingsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    for token in ["true", "false", "0", "1", "2"] {
        try h2WriteSettings(h2SettingsJSON("quietStartup", token), root: root)
        let manager = SettingsManager.create(root.path, root.path)
        #expect(manager.getQuietStartup() == (token == "true" ? .on : .off))
        #expect(manager.drainErrors().isEmpty)
    }
}
