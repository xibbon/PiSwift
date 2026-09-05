import Foundation
import Testing
import PiSwiftCodingAgent

@Test func toolRenderShellJSONDefinitionSelectsSelf() throws {
    let data = Data(#"{"name":"test","label":"Test","description":"Test tool","parameters":{"type":"object"},"renderShell":"self"}"#.utf8)
    let definition = try JSONDecoder().decode(ToolDefinition.self, from: data)
    #expect(definition.renderShell == .self)
    #expect(definition.name == "test")
    #expect(definition.parameters?["type"]?.value as? String == "object")
    #expect(definition.renderCall == nil)
    #expect(definition.renderResult == nil)
}

@Test func toolRenderShellJSONDefinitionDefaults() throws {
    for field in ["", #", "renderShell":"default""#, #", "renderShell":"unknown""#, #", "renderShell":null"#] {
        let data = Data("{\"name\":\"test\",\"label\":\"Test\",\"description\":\"Test tool\"\(field)}".utf8)
        let definition = try JSONDecoder().decode(ToolDefinition.self, from: data)
        #expect(definition.renderShell == .default)
    }
}

@Test func toolRenderShellEnumCodableRoundTrip() throws {
    for shell in [ToolRenderShell.default, .self] {
        let data = try JSONEncoder().encode(shell)
        #expect(String(decoding: data, as: UTF8.self) == "\"\(shell.rawValue)\"")
        #expect(try JSONDecoder().decode(ToolRenderShell.self, from: data) == shell)
    }
}

@Test func toolRenderShellNativeDefinitionsDefaultAndAllowSelf() {
    var custom = CustomTool(name: "test", label: "Test", description: "Test tool", parameters: [:], execute: { _, _, _, _, _ in
        CustomToolResult(content: [])
    })
    var definition = ToolDefinition(name: "test", label: "Test", description: "Test tool")
    #expect(custom.renderShell == .default)
    #expect(definition.renderShell == .default)
    custom.renderShell = .self
    definition.renderShell = .self
    #expect(custom.renderShell == .self)
    #expect(definition.renderShell == .self)
    #expect(ToolDefinition(name: "test", label: "Test", description: "Test tool", renderShell: .self).renderShell == .self)
}

@Test func toolRenderShellSurvivesNativeExtensionLoading() throws {
    let result = ExtensionLoader.load(
        InlineExtension(name: "render-shell") { api in
            api.registerTool(CustomTool(
                name: "test", label: "Test", description: "Test tool", parameters: [:],
                execute: { _, _, _, _, _ in CustomToolResult(content: []) },
                renderShell: .self
            ))
        },
        cwd: FileManager.default.temporaryDirectory.path,
        eventBus: createEventBus()
    )
    #expect(result.error == nil)
    let hook = try #require(result.hook)
    defer { hook.dispose() }
    #expect(hook.tools["test"]?.renderShell == .self)
    #expect(hook.currentTools()["test"]?.renderShell == .self)
}

@Test func toolRenderShellSurvivesCustomPluginRegistration() {
    let api = CustomToolAPI(cwd: FileManager.default.temporaryDirectory.path, events: createEventBus())
    api.register(CustomTool(
        name: "test", label: "Test", description: "Test tool", parameters: [:],
        execute: { _, _, _, _, _ in CustomToolResult(content: []) },
        renderShell: .self
    ))
    #expect(api.toolsSnapshot().first?.renderShell == .self)
}
