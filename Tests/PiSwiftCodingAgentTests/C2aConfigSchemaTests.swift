import CryptoKit
import Foundation
import Testing
import TestEnvironmentSupport
import PiSwiftAI
@testable import PiSwiftCodingAgent

func c2aValidTheme(name: String = "custom") throws -> [String: Any] {
    let url = try #require(BundledConfigSchema.theme.url?.deletingLastPathComponent().appendingPathComponent("dark.json"))
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    json["name"] = name
    return json
}

func c2aThemeText(name: String) throws -> String {
    try #require(String(data: JSONSerialization.data(withJSONObject: c2aValidTheme(name: name)), encoding: .utf8))
}

private func c2aTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("c2a-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct C2aConfigSchemaTests {
    @Test func bundledArtifactsMatchV140() throws {
        // Upstream 8efd314fa, v1.4.0: pin the published schema bytes.
        let expected: [BundledConfigSchema: String] = [
            .settings: "d4b19b0e492cb887a23c50034f00213c476048956fa92c5cce2f1536ef50b9b0",
            .models: "86ade9716724902bdfe91347a728980ad7242a76d0773dbc7217ce4584d696ea",
            .keybindings: "46d494b2493cd9fcf957d352aac653fe6f04121254f34033a5664e7c8f9928aa",
            .theme: "f526a690b63c6303296f683c9df6077ddc290ee9acb1bc27eedef169c0caad59",
        ]
        for schema in BundledConfigSchema.allCases {
            let url = try #require(schema.url)
            let data = try Data(contentsOf: url)
            #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == expected[schema])
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["$id"] as? String == "https://pi.dev/schemas/\(schema.rawValue).schema.json")
        }
        let legacy = try #require(BundledConfigSchema.theme.url?.deletingLastPathComponent().appendingPathComponent("theme-schema.json"))
        #expect(try Data(contentsOf: legacy) == Data(contentsOf: #require(BundledConfigSchema.theme.url)))
        for name in ["dark", "light"] {
            let url = try #require(BundledConfigSchema.theme.url?.deletingLastPathComponent().appendingPathComponent("\(name).json"))
            let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            #expect(json["$schema"] as? String == "https://pi.dev/schemas/theme.schema.json")
        }
    }

    @Test func bundledSchemasKeepEditorAndMigrationGuidance() throws {
        func schema(_ name: BundledConfigSchema) throws -> [String: Any] {
            let url = try #require(name.url)
            return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        }
        let theme = try schema(.theme)
        #expect(theme["title"] as? String == "Pi Coding Agent Theme")
        #expect(theme["description"] as? String == "Theme schema for Pi coding agent")
        let properties = try #require(theme["properties"] as? [String: [String: Any]])
        let colors = try #require(properties["colors"])
        #expect((colors["description"] as? String)?.contains("use compatible fallbacks") == true)
        let tokens = try #require(colors["properties"] as? [String: [String: Any]])
        #expect(tokens["accent"]?["description"] as? String == "Primary accent color (logo, selected items, cursor)")
        #expect((tokens["scrollbarTrack"]?["description"] as? String)?.contains("falls back to muted") == true)
        #expect((properties["export"]?["description"] as? String)?.contains("defaults derived from userMessageBg") == true)
        let definitions = try #require(schema(.models)["$defs"] as? [String: [String: Any]])
        // Upstream 8efd314fa: retain the models reference guidance in the published schema.
        let models = try schema(.models)
        let rootProperties = try #require(models["properties"] as? [String: [String: Any]])
        let providerPatterns = try #require(rootProperties["providers"]?["patternProperties"] as? [String: [String: Any]])
        let provider = try #require(providerPatterns["^.*$"]?["properties"] as? [String: [String: Any]])
        #expect(provider["baseUrl"]?["description"] as? String == "API base URL. Also applies to the provider's built-in models.")
        #expect(provider["authHeader"]?["default"] as? Bool == false)
        let modelItems = try #require(provider["models"]?["items"] as? [String: Any])
        let modelFields = try #require(modelItems["properties"] as? [String: [String: Any]])
        #expect(modelFields["id"]?["description"] as? String == "Model ID sent to the API.")
        let overrides = try #require(provider["modelOverrides"]?["patternProperties"] as? [String: [String: Any]])
        let overrideFields = try #require(overrides["^.*$"]?["properties"] as? [String: [String: Any]])
        #expect(overrideFields["name"]?["description"] as? String == "Display name, also matched by --model patterns.")
        let compat = try #require(definitions["ProviderCompat"]?["properties"] as? [String: [String: Any]])
        #expect((compat["imageInput"]?["description"] as? String)?.contains("Classifier models read it from the provider-level compat; models and modelOverrides entries apply to chat models only.") == true)
        #expect((compat["sendImageOptInHeader"]?["description"] as? String)?.contains("TypeSafe-Danger-Zone-Images: true") == true)
        let cost = try #require(definitions["ModelCost"]?["properties"] as? [String: [String: Any]])
        #expect((cost["input"]?["description"] as? String)?.contains("USD per million tokens") == true)
        #expect((cost["tiers"]?["description"] as? String)?.contains("highest matching input threshold") == true)
        let limits = try #require(definitions["ModelInputLimits"]?["properties"] as? [String: [String: Any]])
        #expect((limits["maxRequestBytes"]?["description"] as? String)?.contains("serialized provider request size") == true)
        let settings = try #require(schema(.settings)["properties"] as? [String: [String: Any]])
        for (key, text) in [("quietStartup", "hide all startup output"), ("defaultTools", "+name and -name"), ("fullscreenWheelScrollLines", "1 to 100")] {
            #expect((settings[key]?["description"] as? String)?.contains(text) == true)
        }
        #expect(settings["queueMode"]?["description"] as? String == "Legacy setting migrated to steeringMode.")
        let retry = try #require(settings["retry"]?["properties"] as? [String: [String: Any]])
        #expect((retry["maxDelayMs"]?["description"] as? String)?.contains("provider.maxRetryDelayMs") == true)
    }

    @Test func modelSchemaReferenceAndRepresentativeDocument() throws {
        try withRegistry([
            "$schema": "https://pi.dev/schemas/models.schema.json",
            "providers": ["local": [
                "api": "openai-completions", "baseUrl": "https://example.invalid/v1",
                "compat": ["zaiToolStream": true, "thinkingTokenBudgetField": "thinking_budget", "chatTemplateKwargs": ["budget": ["$var": "thinking.budget"]], "supportsMidConvoSystemMessages": true, "supportsExplicitPromptCacheMode": true],
                "models": [["id": "model", "inputLimits": ["maxRequestBytes": 1024, "images": ["maxPerRequest": 2]], "promptCache": ["short": 300], "contextWindow": 1, "maxTokens": 1]],
                "modelOverrides": ["model": ["contextWindow": 1, "maxTokens": 1]]
            ]]
        ]) { registry, _ in
            #expect(registry.getError() == nil)
            let model = try #require(registry.find("local", "model"))
            #expect(model.contextWindow == 1)
            #expect(model.maxTokens == 1)
            #expect(model.compat?.zaiToolStream == nil)
            #expect(model.compat?.supportsExplicitPromptCacheMode == nil)
            let compat = try #require(registry.getConfiguredCompatibility(provider: "local", modelId: "model"))
            #expect(compat["zaiToolStream"] == AnyCodable(true))
            #expect(compat["supportsExplicitPromptCacheMode"] == AnyCodable(true))
            #expect(model.inputLimits?.maxRequestBytes == 1024)
            #expect(model.promptCache?.short == 300)
        }
        for schema in [AnyCodable(42), AnyCodable(NSNull()), AnyCodable(false)] {
            try withRegistry(["$schema": schema.value, "providers": [:]]) { registry, path in
                #expect(registry.getError() == "Invalid models.json schema:\n  - $schema: must be string\n\nFile: \(path)")
            }
        }
        try withRegistry(["$schema": "https://pi.dev/schemas/models.schema.json", "providers": ["demo": ["models": [["id": ""]]]]]) { registry, _ in
            #expect(registry.getError()?.contains("Invalid models.json schema") == true)
        }
    }

    @Test func modelLimitsRejectNonpositiveAndMalformedValues() throws {
        for field in ["contextWindow", "maxTokens"] {
            for value in [AnyCodable(0), AnyCodable(-1), AnyCodable(false), AnyCodable("100"), AnyCodable(NSNull())] {
                for override in [false, true] {
                    let provider: [String: Any] = override
                        ? ["modelOverrides": ["model": [field: value.value]]]
                        : ["models": [["id": "model", field: value.value]]]
                    try withRegistry(["providers": ["local": provider]]) { registry, _ in
                        #expect(registry.getError()?.contains("Invalid models.json schema") == true)
                        #expect(registry.getError()?.contains(field) == true)
                    }
                }
            }
        }
    }

    @Test func legacyModelLimitsRejectNonpositiveValues() throws {
        for field in ["contextWindow", "maxTokens"] {
            for value in [0, -1] {
                var model: [String: Any] = ["provider": "local", "id": "model", "name": "Model", "api": "openai-completions", "baseUrl": "https://example.invalid/v1", "reasoning": false, "input": ["text"], "contextWindow": 1, "maxTokens": 1, "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0]]
                model[field] = value
                try withRegistry([model]) { registry, _ in
                    #expect(registry.getError()?.contains("models.0.\(field): must be > 0") == true)
                    #expect(registry.find("local", "model") == nil)
                }
            }
        }
    }

    @Test func malformedKnownModelFieldsAreRejected() throws {
        for definition in [
            ["id": ""], ["id": "model", "reasoning": "yes"],
            ["id": "model", "input": ["bogus"]], ["id": "model", "cost": ["input": 1]],
            ["id": "model", "promptCache": ["short": 0]], ["id": "model", "inputLimits": ["images": ["resize": ["jpegQuality": 101]]]],
            ["id": "model", "samplingParams": NSNull()],
            ["id": "model", "thinkingLevelMap": ["high": 42]]
        ] as [[String: Any]] {
            try withRegistry(["providers": ["local": ["models": [definition]]]]) { registry, _ in
                #expect(registry.getError()?.contains("Invalid models.json schema") == true)
            }
        }
    }

    @Test func customCompatibilityIsRetainedAndMalformedFieldsRemainTolerant() throws {
        let compat: [String: Any] = ["customOption": "value", "supportsStore": true, "supportsAdditionalTools": true, "vercelGatewayRouting": ["sort": 42, "allow_fallbacks": "custom", "ignore": 42]]
        try withRegistry(["providers": ["demo": ["api": "custom-api", "compat": compat, "models": [["id": "model", "compat": ["nestedCustom": ["enabled": true]]]], "modelOverrides": ["model": ["compat": ["overrideCustom": 42]]]]]]) { registry, _ in
            #expect(registry.getError() == nil)
            let retained = try #require(registry.getConfiguredCompatibility(provider: "demo", modelId: "model"))
            #expect(retained["customOption"] == AnyCodable("value"))
            #expect(retained["supportsStore"] == AnyCodable(true))
            #expect(retained["vercelGatewayRouting"] == AnyCodable(["sort": 42, "allow_fallbacks": "custom", "ignore": 42]))
            #expect(retained["nestedCustom"] == AnyCodable(["enabled": true]))
            #expect(retained["overrideCustom"] == AnyCodable(42))
        }
        for compat in [
            ["supportsLongCacheRetention": "yes"], ["supportsStore": 1], ["supportsAdditionalTools": NSNull()],
            ["thinkingTokenBudgetField": "bogus"], ["openRouterRouting": ["only": 42]],
            ["chatTemplateKwargs": ["budget": ["$var": "bogus"]]], ["allowedFallbackModels": [[:]]]
        ] as [[String: Any]] {
            for location in [0, 1, 2] {
                var provider: [String: Any] = ["api": "openai-completions", "baseUrl": "https://example.invalid/v1", "models": [["id": "model"]]]
                if location == 0 { provider["compat"] = compat }
                if location == 1 { provider["models"] = [["id": "model", "compat": compat]] }
                if location == 2 { provider["modelOverrides"] = ["model": ["compat": compat]] }
                try withRegistry(["providers": ["demo": provider]]) { registry, _ in
                    #expect(registry.getError() == nil)
                    _ = try #require(registry.find("demo", "model"))
                    #expect(registry.getConfiguredCompatibility(provider: "demo", modelId: "model") == compat.mapValues(AnyCodable.init))
                }
            }
        }
    }

    @Test func headersAndSamplingLevelsKeepTolerantParsing() throws {
        try withRegistry(["providers": ["local": [
            "api": "openai-completions", "baseUrl": "https://example.invalid/v1",
            "headers": ["Authorization": "provider-value"],
            "models": [["id": "model", "headers": ["Authorization": NSNull(), "X-Test": 42, "X-Empty": ""],
                        "samplingParamsByThinkingLevel": ["low": ["temperature": 0.6], "high": false, "unknown": ["top_k": 2]]]],
            "modelOverrides": ["model": ["samplingParamsByThinkingLevel": ["low": "invalid", "medium": ["top_k": 64]]]]
        ]]]) { registry, _ in
            #expect(registry.getError() == nil)
            let model = try #require(registry.find("local", "model"))
            let headers = try #require(model.headers)
            #expect(providerHeadersContain(headers, name: "Authorization"))
            #expect(providerHeaderValue(headers, name: "Authorization") == nil)
            #expect(!providerHeadersContain(headers, name: "X-Test"))
            #expect(providerHeaderValue(headers, name: "X-Empty") == "")
            #expect(model.samplingParamsByThinkingLevel == [.low: ["temperature": AnyCodable(0.6)], .medium: ["top_k": AnyCodable(64)]])
        }
    }

    @Test func costTierExtensionFieldsRemainValid() throws {
        let rates: [String: Any] = ["input": 1, "output": 2, "cacheRead": 0, "cacheWrite": 0]
        var tier = rates; tier["inputTokensAbove"] = 100; tier["tiers"] = "metadata"
        var cost = rates; cost["tiers"] = [tier]
        try withRegistry(["providers": ["local": ["api": "openai-completions", "baseUrl": "https://example.invalid/v1", "models": [["id": "model", "cost": cost]]]]]) { registry, _ in
            #expect(registry.getError() == nil)
            #expect(registry.find("local", "model")?.cost.tiers?.first?.inputTokensAbove == 100)
        }
    }

    @Test func settingsSchemaAndExtensionFieldsSurviveSaveAndReload() throws {
        let dir = try c2aTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: ["$schema": "https://pi.dev/schemas/settings.schema.json", "theme": "light", "extensionSetting": ["enabled": true], "queueMode": "all", "websockets": true, "skills": ["enableSkillCommands": true, "customDirectories": ["./skills"]], "retry": ["maxDelayMs": 1000]]).write(to: path)
        let manager = SettingsManager.create(dir.path, dir.path)
        #expect(manager.getTheme() == "light")
        manager.setTheme("dark")
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        #expect(saved["$schema"] as? String == "https://pi.dev/schemas/settings.schema.json")
        #expect((saved["extensionSetting"] as? [String: Bool])?["enabled"] == true)
        #expect(SettingsManager.create(dir.path, dir.path).getTheme() == "dark")
    }

    private func withRegistry(_ json: Any, verify: (ModelRegistry, String) throws -> Void) throws {
        let dir = try c2aTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("models.json")
        try JSONSerialization.data(withJSONObject: json).write(to: path)
        let registry = ModelRegistry(AuthStorage(":memory:"), dir.path, modelsStore: FileModelsStore(dir.appendingPathComponent("store.json").path), networkEnabled: false)
        try verify(registry, path.path)
    }
}

@Suite(.serialized) struct C2aThemeValidationTests {
    @Test func rawThemesRejectUnknownKeysNullsAndInvalidValues() throws {
        let dir = try c2aTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("invalid.json")
        let valid = try c2aValidTheme()
        var variants: [([String: Any], String)] = []
        for key in ["$schema", "appearance", "vars", "export"] {
            var json = valid; json[key] = NSNull(); variants.append((json, "/\(key)"))
        }
        for (key, value) in [("$schema", 42 as Any), ("name", ""), ("name", NSNull()), ("appearance", "auto"), ("vars", []), ("colors", NSNull()), ("export", [])] {
            var json = valid; json[key] = value; variants.append((json, "/\(key)"))
        }
        var extra = valid; extra["unexpected"] = true; variants.append((extra, "/unexpected"))
        extra = valid; extra["vars"] = ["unused/key~name": 256]; variants.append((extra, "/vars/unused/key~name"))
        var colors = try #require(valid["colors"] as? [String: Any])
        colors["scrollbarThmb"] = ""; extra = valid; extra["colors"] = colors; variants.append((extra, "/colors/scrollbarThmb"))
        extra = valid; extra["export"] = ["unexpected": ""]; variants.append((extra, "/export/unexpected"))
        for value in [AnyCodable(-1), AnyCodable(256), AnyCodable(1.5), AnyCodable(true), AnyCodable(NSNull()), AnyCodable([]), AnyCodable([:])] {
            extra = valid; extra["vars"] = ["unused": value.value]; variants.append((extra, "/vars/unused"))
            colors = try #require(valid["colors"] as? [String: Any]); colors["accent"] = value.value
            extra = valid; extra["colors"] = colors; variants.append((extra, "/colors/accent"))
            for key in ["pageBg", "cardBg", "infoBg"] {
                extra = valid; extra["export"] = [key: value.value]; variants.append((extra, "/export/\(key)"))
            }
        }
        for (json, pointer) in variants {
            try JSONSerialization.data(withJSONObject: json).write(to: path)
            do {
                _ = try loadThemeFromPath(path.path)
                Issue.record("Accepted invalid theme at \(pointer)")
            } catch {
                let message = String(describing: error)
                #expect(message.hasPrefix("Invalid theme \"\(path.path)\":\n"))
                #expect(message.contains("Other errors:\n"))
                #expect(message.contains(pointer))
            }
        }
        for raw in ["null", "[]", "42", "{}"] {
            try raw.write(to: path, atomically: true, encoding: .utf8)
            #expect(throws: (any Error).self) { try loadThemeFromPath(path.path) }
        }
    }

    @Test func slashNameHasPriorityAndMissingTokensKeepGuidance() throws {
        let dir = try c2aTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("invalid.json")
        try JSONSerialization.data(withJSONObject: ["name": "invalid/name", "colors": NSNull(), "extra": true]).write(to: path)
        do { _ = try loadThemeFromPath(path.path); Issue.record("Accepted slash name") }
        catch { #expect(String(describing: error) == "Invalid theme name \"invalid/name\": theme names cannot contain \"/\" because it is reserved for automatic light/dark theme settings.") }
        try JSONSerialization.data(withJSONObject: ["name": "missing", "colors": [:]]).write(to: path)
        do { _ = try loadThemeFromPath(path.path); Issue.record("Accepted missing tokens") }
        catch {
            // Use the hashed upstream artifact as the independent token contract.
            let schemaURL = try #require(BundledConfigSchema.theme.url)
            let schema = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL)) as? [String: Any])
            let properties = try #require(schema["properties"] as? [String: [String: Any]])
            let missing = try #require(properties["colors"]?["required"] as? [String]).sorted()
            let expected = "Invalid theme \"\(path.path)\":\n\nMissing required color tokens:\n" + missing.map { "  - \($0)" }.joined(separator: "\n") + "\n\nPlease add these colors to your theme's \"colors\" object.\nSee the built-in themes (dark.json, light.json) for reference values."
            #expect(String(describing: error) == expected)
        }
    }

    @Test func schemaStringsVarsAndAllFiveFallbacksRemainValid() throws {
        let dir = try c2aTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("custom.json")
        var json = try c2aValidTheme()
        json["$schema"] = "https://pi.dev/schemas/theme.schema.json"
        json.removeValue(forKey: "appearance")
        json["vars"] = ["first": 0, "last": 255, "unusedString": "$missing", "primary": "#123456", "alias": "$primary"]
        json["export"] = [:]
        var colors = try #require(json["colors"] as? [String: Any])
        // Replace all vars from the built-in document with concrete values.
        colors = Dictionary(uniqueKeysWithValues: colors.keys.map { ($0, "#abcdef" as Any) })
        colors["accent"] = "$alias"
        for key in ["thinkingMax", "scrollbarTrack", "scrollbarThumb", "searchMatchBg", "searchMatchText"] { colors.removeValue(forKey: key) }
        json["colors"] = colors
        try JSONSerialization.data(withJSONObject: json).write(to: path)
        let loaded = try loadThemeFromPath(path.path, mode: .truecolor)
        #expect(loaded.name == "custom")
        #expect(loaded.fg(.accent, "x").contains("18;52;86"))
        for (key, fallback) in [("thinkingMax", "thinkingXhigh"), ("scrollbarTrack", "muted"), ("scrollbarThumb", "text"), ("searchMatchBg", "selectedBg"), ("searchMatchText", "text")] {
            #expect(loaded.colors[key] == loaded.colors[fallback])
        }
        json.removeValue(forKey: "vars"); json.removeValue(forKey: "export"); colors["accent"] = "#123456"; json["colors"] = colors
        try JSONSerialization.data(withJSONObject: json).write(to: path)
        _ = try loadThemeFromPath(path.path)
    }

    @Test func registeredThemeAndExportUseTheRawValidator() throws {
        let dir = try c2aTemporaryDirectory()
        let previous = theme
        defer { setRegisteredThemes([]); setThemeInstance(previous); try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("registered.json")
        var json = try c2aValidTheme(name: "registered")
        json["export"] = ["pageBg": "#123456"]
        try JSONSerialization.data(withJSONObject: json).write(to: path)
        setRegisteredThemes([HookThemeInfo(name: "registered", path: path.path)])
        #expect(try loadTheme("registered").name == "registered")
        #expect(getThemeExportColors("registered").pageBg == "#123456")
        json["extra"] = true
        try JSONSerialization.data(withJSONObject: json).write(to: path)
        #expect(throws: (any Error).self) { try loadTheme("registered") }
        #expect(getThemeByName("registered") == nil)
        #expect(setTheme("registered").success == false)
        #expect(getThemeExportColors("registered").pageBg == nil)
        #expect(getResolvedThemeColors("registered").isEmpty)
    }

    @Test func discoveryValidatesDirectoryAndFileCandidatesOnInitialLoadAndReload() async throws {
        let dir = try c2aTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let themesDir = dir.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
        let path = themesDir.appendingPathComponent("file-name.json")
        for candidate in [themesDir, path] {
            var json = try c2aValidTheme(name: "document-name")
            json["unsupported"] = true
            try JSONSerialization.data(withJSONObject: json).write(to: path)
            let loader = DefaultResourceLoader(DefaultResourceLoaderOptions(cwd: dir.path, agentDir: dir.appendingPathComponent("agent").path, settingsManager: SettingsManager.inMemory(), additionalThemePaths: [candidate.path], noExtensions: true, noSkills: true, noPromptTemplates: true, noContextFiles: true, offline: true))
            await loader.reload()
            let initial = loader.getThemes()
            #expect(initial.themes.isEmpty)
            let warning = try #require(initial.diagnostics.first)
            #expect(initial.diagnostics.count == 1)
            #expect(warning.type == "warning")
            #expect(warning.path == path.path)
            #expect(warning.message.contains("/unsupported"))
            json.removeValue(forKey: "unsupported")
            try JSONSerialization.data(withJSONObject: json).write(to: path)
            await loader.reload()
            #expect(loader.getThemes().diagnostics.isEmpty)
            #expect(loader.getThemes().themes.contains { $0.name == "document-name" && $0.path == path.path })
            json["unsupported"] = true
            try JSONSerialization.data(withJSONObject: json).write(to: path)
            await loader.reload()
            #expect(loader.getThemes().themes.isEmpty)
            #expect(loader.getThemes().diagnostics.first?.message == warning.message)
        }
    }
}

extension C2aThemeValidationTests {
    @Test(.processEnvironment, .timeLimit(.minutes(1))) func customThemeWatcherKeepsTheLastValidTheme() async throws {
        let dir = try c2aTemporaryDirectory()
        let previousDir = ProcessInfo.processInfo.environment[ENV_AGENT_DIR]
        let previousTheme = theme
        setenv(ENV_AGENT_DIR, dir.path, 1)
        defer {
            stopThemeWatcher()
            setThemeInstance(previousTheme)
            if let previousDir { setenv(ENV_AGENT_DIR, previousDir, 1) } else { unsetenv(ENV_AGENT_DIR) }
            try? FileManager.default.removeItem(at: dir)
        }
        let themes = dir.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        let path = themes.appendingPathComponent("watched.json")
        var json = try c2aValidTheme(name: "watched")
        try JSONSerialization.data(withJSONObject: json).write(to: path)
        #expect(try loadTheme("watched").name == "watched")
        #expect(setTheme("watched", enableWatcher: true).success)
        let before = theme.getFgAnsi(.accent)
        json["unexpected"] = true
        var colors = try #require(json["colors"] as? [String: Any])
        colors["accent"] = "#123456"; json["colors"] = colors
        // Write to the same inode so this test exercises reload, not file removal.
        try JSONSerialization.data(withJSONObject: json).write(to: path)
        try await Task.sleep(for: .milliseconds(350))
        #expect(theme.getFgAnsi(.accent) == before)
        #expect(throws: (any Error).self) { try loadTheme("watched") }
        #expect(getThemeExportColors("watched").pageBg == nil)
        json.removeValue(forKey: "unexpected")
        try JSONSerialization.data(withJSONObject: json).write(to: path)
        for _ in 0..<100 {
            if theme.getFgAnsi(.accent) != before { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(theme.getFgAnsi(.accent) == (try loadThemeFromPath(path.path)).getFgAnsi(.accent))
        #expect(theme.getFgAnsi(.accent) != before)
    }
}
