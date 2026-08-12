import Foundation
import Testing
import PiSwiftCodingAgent

@Suite(.serialized)
struct ThemeTests {
    @Test func themeResolvesThinkingMaxFallbackToXhigh() throws {
        try withRegisteredTheme(name: "legacy-thinking") { dark in
            dark.replacingOccurrences(of: "\n\t\t\"thinkingMax\": \"#ff5fff\",", with: "")
        } verify: { name in
            let theme = try #require(getThemeByName(name))
            #expect(theme.getFgAnsi(.thinkingMax) == theme.getFgAnsi(.thinkingXhigh))
        }
    }

    @Test func themeWithoutScrollbarThumbFallsBackToSelectedBackground() throws {
        try withRegisteredTheme(name: "legacy-scrollbar") { dark in
            dark.replacingOccurrences(of: ",\n\t\t\"scrollbarThumb\": \"selectedBg\"", with: "")
        } verify: { name in
            _ = try #require(getThemeByName(name))
            #expect(getResolvedThemeColors(name)["scrollbarThumb"] == "#3a3a4a")
        }
    }

    @Test func explicitScrollbarThumbWinsOverFallback() throws {
        try withRegisteredTheme(name: "explicit-scrollbar") { dark in
            dark.replacingOccurrences(
                of: "\"scrollbarThumb\": \"selectedBg\"",
                with: "\"scrollbarThumb\": \"#123456\""
            )
        } verify: { name in
            _ = try #require(getThemeByName(name))
            #expect(getResolvedThemeColors(name)["scrollbarThumb"] == "#123456")
        }
    }

    private func withRegisteredTheme(
        name: String,
        transform: (String) -> String,
        verify: (String) throws -> Void
    ) throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-theme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            setRegisteredThemes([])
            try? FileManager.default.removeItem(at: tempDir)
        }

        let darkPath = Bundle.module.url(forResource: "dark", withExtension: "json", subdirectory: "theme")
            ?? URL(fileURLWithPath: "Sources/PiSwiftCodingAgent/Resources/theme/dark.json")
        let dark = try String(contentsOf: darkPath, encoding: .utf8)
        let themePath = tempDir.appendingPathComponent("\(name).json")
        try transform(dark)
            .replacingOccurrences(of: "\"name\": \"dark\"", with: "\"name\": \"\(name)\"")
            .write(to: themePath, atomically: true, encoding: .utf8)
        setRegisteredThemes([HookThemeInfo(name: name, path: themePath.path)])

        try verify(name)
    }
}
