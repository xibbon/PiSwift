import Foundation
import Testing
@testable import PiSwiftCodingAgent

@Suite(.serialized)
struct ThemeV99Tests {
    @Test func colorFgBgUsesLastFieldAndVimClassification() {
        for index in 0...15 {
            #expect(detectColorFgBgTheme(env: ["COLORFGBG": "15;default;\(index)"]) == (index <= 6 || index == 8 ? .dark : .light))
        }
        for value in ["", "default", "16", "-1", "1.2", "123"] {
            #expect(detectColorFgBgTheme(env: ["COLORFGBG": value]) == nil)
        }
        #expect(detectColorFgBgTheme(env: ["COLORFGBG": "0; 7 "]) == .light)
    }

    @Test func terminalDetectionOrder() throws {
        let black = colorToRgb(try parseColor("#000"))
        let white = colorToRgb(try parseColor("#fff"))
        #expect(detectTerminalTheme(colors: TerminalColors(background: black), reportedScheme: .light, env: ["COLORFGBG": "0;7"]) == .dark)
        #expect(detectTerminalTheme(colors: TerminalColors(background: white), reportedScheme: .dark) == .light)
        #expect(detectTerminalTheme(reportedScheme: .light, env: ["COLORFGBG": "0;0"]) == .light)
        #expect(detectTerminalTheme(env: ["COLORFGBG": "0;7"]) == .light)
        #expect(detectTerminalTheme(env: [:]) == .dark)
    }

    @Test func builtinsUseDeclaredAppearanceAndNewColors() throws {
        let dark = try loadTheme("dark", mode: .truecolor)
        let light = try loadTheme("light", mode: .color256)
        #expect(dark.appearance == .dark)
        #expect(light.appearance == .light)
        #expect(dark.colors.count == ThemeColor.allCases.count + ThemeBg.allCases.count)
        #expect(dark.getFgAnsi(.accent).contains("38;2;"))
        #expect(light.getFgAnsi(.accent).contains("38;5;"))
        #expect(getThemeExportColors("dark").pageBg?.hasPrefix("#") == true)
    }

    @Test func systemReservedFirstAndFallback() throws {
        defer { setTerminalColors(TerminalColors()); setTerminalColorScheme(nil) }
        setTerminalColors(TerminalColors())
        #expect(getAvailableThemes().first == "system")
        #expect(getAvailableThemesWithPaths().first?.name == "system")
        #expect(try loadTheme("system").name == "system")
        initTheme()
        #expect(theme.name == "system")
        #expect(!setTheme("missing-\(UUID().uuidString)").success)
        #expect(theme.name == "system")
        #expect(getThemeExportColors("system").pageBg == nil)
    }

    @Test func terminalDefaultsAndDimTokensFollowGeneration() throws {
        defer { setTerminalColors(TerminalColors()); setTerminalColorScheme(nil) }
        setTerminalColors(TerminalColors())
        let system = try loadTheme("system", mode: .truecolor)
        let before = try #require(system.colors["text"])
        let foreground = colorToRgb(try parseColor("#abcdef"))
        let background = colorToRgb(try parseColor("#123456"))
        setTerminalColors(TerminalColors(foreground: foreground, background: background))
        #expect(colorToHex(try #require(system.colors["text"])) == "#abcdef")
        #expect(before != system.colors["text"])
        let dim = try #require(system.colors["muted"])
        #expect(dim == (try mixColors(.rgb(foreground), .rgb(background), amount: 0.4)))
        #expect(system.fg(.muted, "x").hasSuffix("\u{001B}[22;39m"))
        #expect(system.style("x", options: ThemeStyle(fg: .token(.muted))).contains("\u{001B}[2m"))
    }

    @Test func hostModeAppliesToAllThemes() throws {
        setTerminalColorMode(.color256)
        #expect(try loadTheme("dark").colorMode == .color256)
        #expect(try loadTheme("system").colorMode == .color256)
        setTerminalColorMode(.truecolor)
        #expect(try loadTheme("light").colorMode == .truecolor)
    }

    @Test func jsonAcceptsColorFormsAndSwiftVariables() throws {
        let builtin = URL(fileURLWithPath: "Sources/PiSwiftCodingAgent/Resources/theme/dark.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: builtin)) as? [String: Any])
        var colors = try #require(json["colors"] as? [String: Any])
        colors["accent"] = "$short"; colors["border"] = "oklch(60% 0.1 120deg)"; colors["text"] = "okhsl(240 50% 70%)"
        json["colors"] = colors
        var vars = try #require(json["vars"] as? [String: Any])
        vars["short"] = "#abc"; json["vars"] = vars
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("theme-v99-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: path) }
        try JSONSerialization.data(withJSONObject: json).write(to: path)
        let loaded = try loadThemeFromPath(path.path, mode: .truecolor)
        #expect(colorToHex(try #require(loaded.colors["accent"])) == "#aabbcc")
        #expect(loaded.appearance == .dark)
    }
    private func withThemeJson(base: String = "dark", edit: (inout [String: Any]) throws -> Void, verify: (Theme, String) throws -> Void) throws {
        let source = URL(fileURLWithPath: "Sources/PiSwiftCodingAgent/Resources/theme/\(base).json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
        let name = "test-v99-\(UUID().uuidString)"
        json["name"] = name
        try edit(&json)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).json")
        defer { setRegisteredThemes([]); try? FileManager.default.removeItem(at: path) }
        try JSONSerialization.data(withJSONObject: json).write(to: path)
        setRegisteredThemes([HookThemeInfo(name: name, path: path.path)])
        try verify(loadThemeFromPath(path.path, mode: .truecolor), name)
    }

    @Test func stylesMatchGenericStylerAndRetainOklch() throws {
        try withThemeJson { json in
            var colors = try #require(json["colors"] as? [String: Any])
            colors["accent"] = "oklch(62% 0.1 200)"; json["colors"] = colors
        } verify: { loaded, _ in
            let expectedAccent = try oklchColor(0.62, 0.1, 200)
            #expect(loaded.colors["accent"] == expectedAccent)
            #expect(loaded.style("Ready", options: ThemeStyle(fg: .token(.success), bg: .token(.toolSuccessBg), attributes: TextAttributes(bold: true))) == styleText("Ready", options: TextStyle(fg: loaded.colors["success"], bg: loaded.colors["toolSuccessBg"], bold: true), mode: .truecolor))
            let customColor = try parseColor("#abc")
            #expect(loaded.style("Color", options: ThemeStyle(fg: .color(customColor))) == styleText("Color", options: TextStyle(fg: customColor), mode: .truecolor))
        }
    }

    @Test func appearanceDetectionAndPaletteOnlyFollowTerminal() throws {
        defer { setTerminalColors(TerminalColors()); setTerminalColorScheme(nil) }
        setTerminalColors(TerminalColors()); setTerminalColorScheme(nil)
        for base in ["dark", "light"] {
            try withThemeJson(base: base, edit: { $0.removeValue(forKey: "appearance") }) { loaded, _ in
                #expect(loaded.appearance.rawValue == base)
            }
        }
        try withThemeJson(edit: { $0["appearance"] = "light" }) { loaded, _ in #expect(loaded.appearance == .light) }
        try withThemeJson { json in
            json.removeValue(forKey: "appearance")
            let original = try #require(json["colors"] as? [String: Any])
            json["colors"] = original.mapValues { _ in 7 }
        } verify: { loaded, _ in
            #expect(loaded.appearance == .dark)
            setTerminalColors(TerminalColors(background: colorToRgb(try parseColor("#fafafa"))))
            #expect(loaded.appearance == .light)
        }
    }

    @Test func emptyTokensRenderDefaultAndResolveReportedColors() throws {
        defer { setTerminalColors(TerminalColors()) }
        setTerminalColors(TerminalColors())
        try withThemeJson { json in
            var colors = try #require(json["colors"] as? [String: Any])
            colors["text"] = ""; colors["userMessageBg"] = ""; json["colors"] = colors
        } verify: { loaded, _ in
            #expect(loaded.fg(.text, "x") == "\u{001B}[39mx\u{001B}[39m")
            #expect(loaded.bg(.userMessageBg, "x") == "\u{001B}[49mx\u{001B}[49m")
            #expect(colorToHex(try #require(loaded.colors["text"])) == "#e5e5e7")
            #expect(colorToHex(try #require(loaded.colors["userMessageBg"])) == "#000000")
            setTerminalColors(TerminalColors(foreground: colorToRgb(try parseColor("#c8d2dc")), background: colorToRgb(try parseColor("#0a141e"))))
            #expect(colorToHex(try #require(loaded.colors["text"])) == "#c8d2dc")
            #expect(colorToHex(try #require(loaded.colors["userMessageBg"])) == "#0a141e")
        }
    }

    @Test func exportResolvesRecursiveVariablesAndCssForms() throws {
        let cases: [([String: Any], [String: Any], String?, String?, String?)] = [
            (["page": "#112233", "alias": "page", "card": "#223344", "info": "#445566"], ["pageBg": "alias", "cardBg": "card", "infoBg": "info"], "#112233", "#223344", "#445566"),
            (["card": "okhsl(250 20% 20%)"], ["pageBg": "okhsl(250 20% 15%)", "cardBg": "card", "infoBg": "oklch(30% 0.05 80)"], colorToHex(try okhslColor(250, 0.2, 0.15)), colorToHex(try okhslColor(250, 0.2, 0.2)), "oklch(30% 0.05 80)"),
            (["deep": "#abcdef", "alias": "$deep", "card": 24], ["pageBg": "alias", "cardBg": "card", "infoBg": ""], "#abcdef", "#005f87", nil)
        ]
        for (added, exports, page, card, info) in cases {
            try withThemeJson { json in
                var vars = try #require(json["vars"] as? [String: Any]); vars.merge(added) { _, value in value }
                json["vars"] = vars; json["export"] = exports
            } verify: { _, name in
                let result = getThemeExportColors(name)
                #expect(result.pageBg == page); #expect(result.cardBg == card); #expect(result.infoBg == info)
            }
        }
    }

    @Test func missingOrInvalidExportReturnsNoColors() throws {
        #expect(getThemeExportColors("missing-v99").pageBg == nil)
        try withThemeJson(edit: { $0.removeValue(forKey: "export") }) { _, name in
            #expect(getThemeExportColors(name).pageBg == nil)
        }
        try withThemeJson(edit: { $0["export"] = ["pageBg": "#123456", "cardBg": "missingVariable"] }) { _, name in
            let result = getThemeExportColors(name)
            #expect(result.pageBg == nil); #expect(result.cardBg == nil); #expect(result.infoBg == nil)
        }
    }

    @Test func jsonRejectsCyclesAndInvalidRanges() throws {
        for value in ["cycle", "oklch(120% 0.1 200)", "okhsl(20 150% 60%)", "#ggg"] {
            let source = URL(fileURLWithPath: "Sources/PiSwiftCodingAgent/Resources/theme/dark.json")
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
            var colors = try #require(json["colors"] as? [String: Any]); colors["accent"] = value; json["colors"] = colors
            var vars = try #require(json["vars"] as? [String: Any]); vars["cycle"] = "$cycle"; json["vars"] = vars
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-v99-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: path) }
            try JSONSerialization.data(withJSONObject: json).write(to: path)
            #expect(throws: (any Error).self) { try loadThemeFromPath(path.path) }
        }
    }

}
