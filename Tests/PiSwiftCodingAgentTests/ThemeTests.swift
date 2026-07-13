import Foundation
import Testing
import PiSwiftCodingAgent

@Test func themesResolveThinkingMaxAndFallbackToXhigh() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pi-theme-max-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer {
        setRegisteredThemes([])
        try? FileManager.default.removeItem(at: tempDir)
    }

    let legacyPath = tempDir.appendingPathComponent("legacy.json")
    let explicitPath = tempDir.appendingPathComponent("explicit.json")
    let darkPath = Bundle.module.url(forResource: "dark", withExtension: "json", subdirectory: "theme")
        ?? URL(fileURLWithPath: "Sources/PiSwiftCodingAgent/Resources/theme/dark.json")
    let dark = try String(contentsOf: darkPath, encoding: .utf8)
    try dark
        .replacingOccurrences(of: "\"name\": \"dark\"", with: "\"name\": \"legacy\"")
        .replacingOccurrences(of: "\n\t\t\"thinkingMax\": \"#ff5fff\",", with: "")
        .write(to: legacyPath, atomically: true, encoding: .utf8)
    try dark
        .replacingOccurrences(of: "\"name\": \"dark\"", with: "\"name\": \"explicit\"")
        .write(to: explicitPath, atomically: true, encoding: .utf8)

    setRegisteredThemes([
        HookThemeInfo(name: "legacy", path: legacyPath.path),
        HookThemeInfo(name: "explicit", path: explicitPath.path),
    ])

    let legacy = try #require(getThemeByName("legacy"))
    #expect(legacy.getFgAnsi(.thinkingMax) == legacy.getFgAnsi(.thinkingXhigh))
    #expect(getResolvedThemeColors("explicit")["thinkingMax"] == "#ff5fff")
}
