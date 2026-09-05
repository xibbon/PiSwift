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

    @Test func themeWithoutScrollbarThumbFallsBackToText() throws {
        try withRegisteredTheme(name: "legacy-scrollbar") { dark in
            dark.replacingOccurrences(of: "\n\t\t\"scrollbarThumb\": \"text\",", with: "")
        } verify: { name in
            _ = try #require(getThemeByName(name))
            #expect(getResolvedThemeColors(name)["scrollbarThumb"] == getResolvedThemeColors(name)["text"])
        }
    }

    @Test func explicitScrollbarThumbWinsOverFallback() throws {
        try withRegisteredTheme(name: "explicit-scrollbar") { dark in
            dark.replacingOccurrences(
                of: "\"scrollbarThumb\": \"text\"",
                with: "\"scrollbarThumb\": \"#123456\""
            )
        } verify: { name in
            _ = try #require(getThemeByName(name))
            #expect(getResolvedThemeColors(name)["scrollbarThumb"] == "#123456")
        }
    }

    @Test func legacyThemeResolvesSearchAndTrackFallbacks() throws {
        try withRegisteredTheme(name: "legacy-search") { dark in
            var json = try #require(JSONSerialization.jsonObject(with: Data(dark.utf8)) as? [String: Any])
            var colors = try #require(json["colors"] as? [String: Any])
            for key in ["scrollbarTrack", "scrollbarThumb", "searchMatchBg", "searchMatchText"] {
                colors.removeValue(forKey: key)
            }
            json["colors"] = colors
            return try #require(String(data: JSONSerialization.data(withJSONObject: json), encoding: .utf8))
        } verify: { name in
            _ = try #require(getThemeByName(name))
            let colors = getResolvedThemeColors(name)
            #expect(colors["scrollbarTrack"] == colors["muted"])
            #expect(colors["scrollbarThumb"] == colors["text"])
            #expect(colors["searchMatchBg"] == colors["selectedBg"])
            #expect(colors["searchMatchText"] == colors["text"])
        }
    }

    @Test func themeNameRejectsSlashReservedForAutomaticThemePairs() throws {
        try withRegisteredTheme(name: "invalid-theme-name") { dark in
            dark.replacingOccurrences(of: "\"name\": \"dark\"", with: "\"name\": \"light/dark\"")
        } verify: { name in
            #expect(getThemeByName(name) == nil)
            let result = setTheme(name)
            #expect(!result.success)
            #expect(result.error == "Invalid theme name \"light/dark\": theme names cannot contain \"/\" because it is reserved for automatic light/dark theme settings.")
        }
    }

    private func withRegisteredTheme(
        name: String,
        transform: (String) throws -> String,
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
