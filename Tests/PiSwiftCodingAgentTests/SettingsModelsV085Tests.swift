import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func settings085Directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pi-settings085-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func settings085PerModelMergePersistenceAndRemoval() async throws {
    let dir = try settings085Directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let project = dir.appendingPathComponent(CONFIG_DIR_NAME)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try Data("\u{feff}{\"modelThinkingLevels\":{\"p/a\":\"high\",\"p/b\":\"low\"},\"defaultTools\":[],\"terminal\":{\"images\":\"kitty\",\"trueColor\":false}}".utf8).write(to: dir.appendingPathComponent("settings.json"))
    try Data("{\"modelThinkingLevels\":{\"p/a\":\"off\"},\"terminal\":{\"hyperlinks\":true}}".utf8).write(to: project.appendingPathComponent("settings.json"))
    let settings = SettingsManager.create(dir.path, dir.path)
    #expect(settings.getModelThinkingLevel("p", "a") == .off)
    #expect(settings.getModelThinkingLevel("p", "b") == .low)
    #expect(settings.getDefaultTools() == [])
    #expect(settings.getFullscreenExitOutput() == .transcript)
    #expect(settings.getFullscreenCopyOnSelect())
    #expect(settings.getTerminalCapabilityOverrides().images == .kitty)
    #expect(settings.getTerminalCapabilityOverrides().trueColor == false)
    #expect(settings.getTerminalCapabilityOverrides().hyperlinks == true)
    settings.setModelThinkingLevel("p", "c", .max)
    settings.setFullscreenExitOutput(.resumeHint)
    settings.setFullscreenCopyOnSelect(false)
    await settings.flush()
    let reloaded = SettingsManager.create(dir.path, dir.path)
    #expect(reloaded.getModelThinkingLevel("p", "c") == .max)
    #expect(reloaded.getFullscreenExitOutput() == .resumeHint)
    #expect(!reloaded.getFullscreenCopyOnSelect())
    for id in ["a", "b", "c"] { settings.removeModelThinkingLevel("p", id) }
    await settings.flush()
    let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("settings.json"))) as? [String: Any])
    #expect(json["modelThinkingLevels"] == nil)
    #expect(settings.getModelThinkingLevel("p", "a") == .off)
}

@Test func settings085TerminalAutoAndDisabled() {
    var value = Settings()
    value.terminal = TerminalSettings(hyperlinks: .auto, trueColor: .auto, images: .disabled)
    let manager = SettingsManager.inMemory(value)
    #expect(manager.getTerminalCapabilityOverrides().images == .disabled)
    #expect(manager.getTerminalCapabilityOverrides().hyperlinks == nil)
    #expect(manager.getTerminalCapabilityOverrides().trueColor == nil)
    value.terminal?.images = .auto
    manager.applyOverrides(value)
    #expect(manager.getTerminalCapabilityOverrides().images == nil)
}

@Test func settings085DiagnosticsPathsAndDeduplication() throws {
    let dir = try settings085Directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("{".utf8).write(to: dir.appendingPathComponent("settings.json"))
    let manager = SettingsManager.create(dir.path, dir.path)
    let errors = collectSettingsDiagnostics(manager)
    #expect(errors.count == 1)
    #expect(errors.first?.message.hasPrefix("Invalid settings file \(dir.appendingPathComponent("settings.json").path): ") == true)
    #expect(collectSettingsDiagnostics(manager).isEmpty)
    let sameMessage = ResourceDiagnostic(type: "error", message: errors[0].message)
    let result = deduplicateDiagnostics(errors + errors + [sameMessage])
    #expect(result.map(\.type) == ["warning", "error"])
}

@Test func settings085InitialThinkingPrecedence() async throws {
    let registry = ModelRegistry(AuthStorage.inMemory(["anthropic": .apiKey(ApiKeyCredential(key: "test"))]))
    let model = try #require(registry.find("anthropic", "claude-sonnet-4-6"))
    let key = "\(model.provider)/\(model.id)"
    let perModel: [String: PiSwiftAgent.ThinkingLevel] = [key: .high]
    let scoped = await findInitialModel(scopedModels: [ScopedModel(model: model)], defaultThinkingLevel: .low, modelThinkingLevels: perModel, modelRegistry: registry)
    #expect(scoped.thinkingLevel == .high)
    let explicit = await findInitialModel(scopedModels: [ScopedModel(model: model, thinkingLevel: .off)], defaultThinkingLevel: .low, modelThinkingLevels: perModel, modelRegistry: registry)
    #expect(explicit.thinkingLevel == .off)
    let saved = await findInitialModel(defaultProvider: model.provider, defaultModelId: model.id, defaultThinkingLevel: .low, modelThinkingLevels: perModel, modelRegistry: registry)
    #expect(saved.thinkingLevel == .high)
}

@Test func settings085ModelDefaultsPreferMatchingAPI() {
    func model(_ id: String, _ api: Api) -> Model {
        Model(id: id, name: id, api: api, provider: "p", baseUrl: "https://example.invalid/\(id)", reasoning: false, input: [.text], cost: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 100, maxTokens: 10)
    }
    let models = [model("responses", .openAIResponses), model("chat", .openAICompletions), model("anthropic", .anthropicMessages)]
    #expect(findModelDefaults(models, modelId: "new")?.id == "chat")
    #expect(findModelDefaults(models, modelId: "new", api: .anthropicMessages)?.id == "anthropic")
    #expect(findModelDefaults(models, modelId: "responses", api: .anthropicMessages)?.id == "responses")
    #expect(findModelDefaults(Array(models.prefix(1)), modelId: "new")?.id == "responses")
}

@Test func settings085CompatConfigAndProgrammaticMerge() throws {
    let dir = try settings085Directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let json = """
    {"providers":{"test":{"api":"openai-completions","baseUrl":"https://example.invalid","compat":{"supportsFinishReason":false,"vllmPriority":7,"supportsAdditionalTools":true,"supportsMaxOutputTokens":false,"supportsMidConvoEffort":true,"thinkingTokenBudgetField":"thinking_budget","allowedFallbackModels":[]},"models":[{"id":"model","compat":{"supportsStore":false}}]}}}
    """
    try Data(("\u{feff}" + json).utf8).write(to: dir.appendingPathComponent("models.json"))
    let registry = ModelRegistry(AuthStorage(":memory:"), dir.path)
    let compat = try #require(registry.find("test", "model")?.compat)
    #expect(compat.supportsFinishReason == false)
    #expect(compat.vllmPriority == 7)
    #expect(compat.supportsAdditionalTools == true)
    #expect(compat.supportsMaxOutputTokens == false)
    #expect(compat.supportsMidConvoEffort == true)
    #expect(compat.thinkingTokenBudgetField == .thinkingBudget)
    #expect(compat.allowedFallbackModels == nil)
    registry.registerProvider(HookProviderConfig(provider: "dynamic", api: .anthropicMessages, baseUrl: "https://example.invalid", compat: OpenAICompat(supportsMidConvoEffort: true, allowedFallbackModels: []), models: [HookProviderModel(id: "m", compat: OpenAICompat(supportsStrictTools: false))]), sourceId: "test")
    let dynamic = try #require(registry.find("dynamic", "m")?.compat)
    #expect(dynamic.supportsMidConvoEffort == true)
    #expect(dynamic.allowedFallbackModels == [])
    #expect(dynamic.supportsStrictTools == false)
}

@Test func settings085SDKToolAndThinkingDefaults() async throws {
    let dir = try settings085Directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = try #require(getModel(provider: "anthropic", modelId: "claude-sonnet-4-6"))
    var settings = Settings()
    settings.defaultTools = ["read", "grep"]
    settings.defaultThinkingLevel = "low"
    settings.modelThinkingLevels = ["\(model.provider)/\(model.id)": .high]
    for (tools, noTools, expected) in [([String]?.none, NoToolsMode?.none, ["read"]), (["write"], .builtin, ["write"]), (nil, .all, [])] {
        let result = await createAgentSession(CreateAgentSessionOptions(cwd: dir.path, agentDir: dir.path, model: model, offline: true, toolNames: tools, excludeTools: ["grep"], noTools: noTools, customTools: [], hooks: [], settingsManager: .inMemory(settings)))
        #expect(result.session.agent.state.tools.map(\.name).sorted() == expected)
        #expect(result.session.agent.state.thinkingLevel == .high)
        if noTools == .all { #expect(result.session.getAllToolNames().isEmpty) }
        result.session.dispose()
    }
}

@Test func settings085DefaultToolsKeepCustomAndExtensionTools() async throws {
    let dir = try settings085Directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var settings = Settings()
    settings.defaultTools = ["grep"]
    let custom = CustomTool(name: "sdk-tool", label: "SDK", description: "Test", parameters: [:]) { _, _, _, _, _ in
        CustomToolResult(content: [.text(TextContent(text: "ok"))])
    }
    let inline = InlineExtension(name: "test") { api in
        var extensionTool = custom
        extensionTool.name = "extension-tool"
        api.registerTool(extensionTool)
    }
    let result = await createAgentSession(CreateAgentSessionOptions(cwd: dir.path, agentDir: dir.path, model: getModel(provider: .anthropic, modelId: "claude-sonnet-4-6"), offline: true, customTools: [CustomToolDefinition(tool: custom)], hooks: [], inlineExtensions: [inline], sessionManager: .inMemory(), settingsManager: .inMemory(settings)))
    defer { result.session.dispose() }
    #expect(result.session.agent.state.tools.map(\.name).sorted() == ["extension-tool", "grep", "sdk-tool"])
}
