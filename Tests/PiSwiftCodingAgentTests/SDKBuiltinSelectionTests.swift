import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

private struct SDKBuiltinCase: Sendable {
    let global: [String]
    let project: [String]
    let trusted: Bool
    let enabled: Bool

    init(_ global: [String], _ project: [String], trusted: Bool = true, enabled: Bool) {
        self.global = global
        self.project = project
        self.trusted = trusted
        self.enabled = enabled
    }
}

private func sdkBuiltinSession(global: [String], project: [String], trusted: Bool = true,
                               noExtensions: Bool = false, explicit: [String] = [],
                               defaultLoader: Bool = false) async throws -> CreateAgentSessionResult {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-builtins-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var settings = Settings()
    settings.extensions = global
    let settingsManager = SettingsManager.inMemory(settings)
    settingsManager.setProjectExtensionPaths(project)
    let model = try #require(getModel(provider: .openai, modelId: "gpt-4o-mini"))
    let auth = AuthStorage.inMemory([model.provider: .apiKey(ApiKeyCredential(key: "test"))])
    // C1 U3: SDK tool-list validation now throws.
    return try await createAgentSession(CreateAgentSessionOptions(
        cwd: directory.path, agentDir: directory.appendingPathComponent("agent").path,
        authStorage: auth, model: model, projectTrusted: trusted, offline: true, noTools: .builtin,
        resourceLoader: defaultLoader ? nil : TestResourceLoader(), hooks: [],
        additionalExtensionPaths: explicit, inlineExtensions: builtInExtensions, noExtensions: noExtensions,
        sessionManager: .inMemory(), settingsManager: settingsManager))
}

// Upstream v0.99.1 package-manager.test.ts: user exclusions and project overrides.
// Also test reverse precedence, trust, ! patterns, and the last project match.
@Test(.timeLimit(.minutes(1)), arguments: [
    SDKBuiltinCase([], [], enabled: true),
    SDKBuiltinCase(["-builtin:mcp"], [], enabled: false),
    SDKBuiltinCase(["-builtin:mcp"], ["+builtin:mcp"], enabled: true),
    SDKBuiltinCase(["+builtin:mcp"], ["-builtin:mcp"], enabled: false),
    SDKBuiltinCase(["-builtin:mcp"], ["+builtin:mcp"], trusted: false, enabled: false),
    SDKBuiltinCase(["+builtin:mcp"], ["-builtin:mcp"], trusted: false, enabled: true),
    SDKBuiltinCase(["-builtin:mcp"], ["+builtin:codemode"], enabled: false),
    SDKBuiltinCase(["!builtin:*"], ["+builtin:mcp"], enabled: true),
    SDKBuiltinCase(["+builtin:mcp"], ["!builtin:*"], enabled: false),
    SDKBuiltinCase(["-builtin:mcp"], ["-builtin:mcp", "+builtin:mcp"], enabled: true),
    SDKBuiltinCase(["+builtin:mcp"], ["+builtin:mcp", "-builtin:mcp"], enabled: false)
])
private func sdkBuiltinMcpUsesProjectOverrides(_ test: SDKBuiltinCase) async throws {
    let result = try await sdkBuiltinSession(global: test.global, project: test.project, trusted: test.trusted)
    defer { result.session.dispose() }
    let command = result.session.hookRunner?.getRegisteredCommands().first { $0.name == "mcp" }
    #expect((command != nil) == test.enabled)
    if test.enabled {
        #expect(command?.sourceInfo?.path == "builtin:mcp")
        #expect(command?.sourceInfo?.source == "builtin")
    }
    #expect(result.diagnostics.filter { $0.type == "error" }.isEmpty)
}

@Test(.timeLimit(.minutes(1))) func sdkBuiltinMcpUsesProjectOverridesWithDefaultLoader() async throws {
    let result = try await sdkBuiltinSession(global: ["-builtin:mcp"], project: ["+builtin:mcp"],
                                            defaultLoader: true)
    defer { result.session.dispose() }
    #expect(result.session.hookRunner?.getRegisteredCommands().contains { $0.name == "mcp" } == true)
    #expect(result.diagnostics.filter { $0.type == "error" }.isEmpty)
}

// Upstream v0.99.1 resource-loader.test.ts: noExtensions requires an explicit built-in path.
@Test(.timeLimit(.minutes(1))) func sdkBuiltinMcpExplicitPathOverridesDisabledExtensions() async throws {
    let disabled = try await sdkBuiltinSession(global: [], project: ["+builtin:mcp"], noExtensions: true)
    defer { disabled.session.dispose() }
    #expect(disabled.session.hookRunner?.getRegisteredCommands().contains { $0.name == "mcp" } != true)

    let explicit = try await sdkBuiltinSession(global: ["-builtin:mcp"], project: ["-builtin:mcp"],
        noExtensions: true, explicit: ["builtin:mcp"])
    defer { explicit.session.dispose() }
    #expect(explicit.session.hookRunner?.getRegisteredCommands().contains { $0.name == "mcp" } == true)
}
