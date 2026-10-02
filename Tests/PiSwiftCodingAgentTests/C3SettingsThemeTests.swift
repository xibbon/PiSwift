import Foundation
import Testing
@testable import PiSwiftCodingAgent

@Suite("C3 settings and system theme")
struct C3SettingsThemeTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-c3-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test(.timeLimit(.minutes(1))) func reloadReadsGlobalAndProjectSettings() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent(CONFIG_DIR_NAME)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let globalPath = directory.appendingPathComponent("settings.json")
        let projectPath = project.appendingPathComponent("settings.json")
        try #"{"defaultTools":["read"],"theme":"dark"}"#.write(to: globalPath, atomically: true, encoding: .utf8)
        let manager = SettingsManager.create(directory.path, directory.path)
        try #"{"defaultTools":["read","bash"],"theme":"light"}"#.write(to: globalPath, atomically: true, encoding: .utf8)
        try #"{"quietStartup":"header"}"#.write(to: projectPath, atomically: true, encoding: .utf8)
        await manager.reload()
        #expect(manager.getDefaultTools() == ["read", "bash"])
        #expect(manager.getTheme() == "light")
        #expect(manager.getQuietStartup() == .header)
    }

    @Test(.timeLimit(.minutes(1))) func reloadPreservesFailedScopeAndHonorsProjectTrust() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent(CONFIG_DIR_NAME)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("settings.json")
        try #"{"theme":"light"}"#.write(to: path, atomically: true, encoding: .utf8)
        try #"{"quietStartup":true}"#.write(to: project.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let manager = SettingsManager.create(directory.path, directory.path, projectTrusted: false)
        try "{".write(to: path, atomically: true, encoding: .utf8)
        await manager.reload()
        #expect(manager.getTheme() == "light")
        #expect(manager.getQuietStartup() == .off)
        #expect(manager.drainErrors().map(\.scope) == ["global"])
        try #"{"theme":"dark"}"#.write(to: path, atomically: true, encoding: .utf8)
        await manager.reload()
        manager.setTheme("light")
        #expect(SettingsManager.create(directory.path, directory.path).getTheme() == "light")
    }

    // v1.0.0 settings-manager.ts loads an empty project scope when it is untrusted.
    @Test(.timeLimit(.minutes(1))) func reloadClearsAppliedUntrustedProjectSettings() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SettingsManager.create(directory.path, directory.path, projectTrusted: false)
        manager.setProjectExtensionPaths(["./project-extension.swift"])
        #expect(manager.getExtensionPaths() == ["./project-extension.swift"])
        await manager.reload()
        #expect(manager.getProjectSettings().extensions == nil)
        #expect(manager.getExtensionPaths().isEmpty)
        #expect(manager.drainErrors().isEmpty)
    }

    @Test func quietStartupJSONAndVisibility() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("settings.json")
        for (json, expected) in [("false", QuietStartup.off), ("true", .on), (#""header""#, .header), (#""other""#, .off), ("1", .off), ("null", .off), ("{}", .off)] {
            try "{\"quietStartup\":\(json)}".write(to: path, atomically: true, encoding: .utf8)
            #expect(SettingsManager.create(directory.path, directory.path).getQuietStartup() == expected)
            #expect(try JSONDecoder().decode(QuietStartup.self, from: Data(json.utf8)) == expected)
        }
        for value in [QuietStartup.off, .on, .header] {
            let manager = SettingsManager.create(directory.path, directory.path)
            manager.setQuietStartup(value)
            #expect(SettingsManager.create(directory.path, directory.path).getQuietStartup() == value)
            #expect(try JSONDecoder().decode(QuietStartup.self, from: JSONEncoder().encode(value)) == value)
            #expect(value.showsStartupHeader() == (value != .on))
            #expect(value.showsStartupDetails() == (value == .off))
            #expect(value.showsStartupHeader(verbose: true))
            #expect(value.showsStartupDetails(verbose: true))
        }
    }

    @Test func oldUIModeIsIgnored() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try #"{"uiMode":"regular"}"#.write(to: directory.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        #expect(SettingsManager.create(directory.path, directory.path).getTuiMode() == "fullscreen")
    }

    // Port of v1.0.0 system-theme.test.ts, issue #10255.
    @Test func catppuccinFrappeKeepsPastelChroma() throws {
        func rgb(_ hex: String) throws -> RgbColorValue { colorToRgb(try parseColor(hex)) }
        let palette = try ["#51576d", "#e78284", "#a6d189", "#e5c890", "#8caaee", "#f4b8e4", "#81c8be", "#b5bfe2",
                           "#626880", "#e67172", "#8ec772", "#d9ba73", "#7b9ef0", "#f2a4db", "#5abfb5", "#a5adce"].map(rgb)
        let input = try SystemThemeInput(foreground: rgb("#c6d0f5"), background: rgb("#303446"), palette: palette)
        let colors = generateSystemThemeColors(input).colors
        func resolved(_ token: String) throws -> RgbColorValue {
            guard case .string(let hex) = colors[token] else { throw C3ThemeTestError.missingColor }
            return try rgb(hex)
        }
        let pink = colorToOklch(.rgb(palette[5]))
        let accent = colorToOklch(.rgb(try resolved("accent")))
        #expect(accent.l < pink.l - 0.05)
        #expect(accent.c <= pink.c * 1.03)
        for panel in ["userMessageBg", "customMessageBg"] {
            #expect(colorToOklch(.rgb(try resolved(panel))).c <= 0.1)
        }
    }
}

private enum C3ThemeTestError: Error { case missingColor }
