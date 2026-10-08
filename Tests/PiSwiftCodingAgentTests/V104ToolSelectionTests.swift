import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

private struct V104MatcherCase: Sendable {
    let entries: [String]
    let name: String
    let expected: Bool

    init(_ entries: [String], _ name: String, _ expected: Bool) {
        self.entries = entries
        self.name = name
        self.expected = expected
    }
}

@Test(arguments: [
    V104MatcherCase(["read"], "read", true),
    V104MatcherCase(["read"], "reader", false),
    V104MatcherCase(["re*"], "read", true),
    V104MatcherCase(["re*"], "re", true),
    V104MatcherCase(["*read"], "threadread", true),
    V104MatcherCase(["*read"], "reader", false),
    V104MatcherCase(["mcp__*__search"], "mcp__docs__search", true),
    V104MatcherCase(["a*b*c"], "abxc", true),
    V104MatcherCase(["a*b*c"], "abxcbc", true),
    V104MatcherCase(["a*b*c"], "abxcd", false),
    V104MatcherCase(["a**b"], "ab", true),
    V104MatcherCase(["**"], "", true),
    V104MatcherCase(["a.b?+[x]*"], "a.b?+[x]suffix", true),
    V104MatcherCase(["a.b?+[x]*"], "axbqxxsuffix", false),
    V104MatcherCase(["*"], "line\nbreak", true),
    V104MatcherCase([], "read", false),
    V104MatcherCase([], "", false),
    V104MatcherCase([""], "", true),
    V104MatcherCase(["é*雪"], "é中雪", true),
    V104MatcherCase(["a*\u{0301}b"], "aXYZ\u{0301}b", true),
    V104MatcherCase(["a*\u{0301}b"], "aXYZb", false)
])
private func v104ToolNameMatcherMatchesWholeLiteralName(_ test: V104MatcherCase) {
    #expect(ToolNameMatcher(test.entries).matches(test.name) == test.expected)
}

@Test func v104ToolNameMatcherEqualityIgnoresEntryOrderAndDuplicates() {
    #expect(ToolNameMatcher(["read", "mcp__*", "read"]) == ToolNameMatcher(["mcp__*", "read"]))
}

@Test func v104ToolNameMatcherKeepsDistinctLiteralUnicodePatterns() {
    let composed = "\u{00E9}*"
    let decomposed = "e\u{0301}*"
    let matcher = ToolNameMatcher([composed, decomposed])
    #expect(matcher.matches("\u{00E9}suffix"))
    #expect(matcher.matches("e\u{0301}suffix"))
    #expect(matcher == ToolNameMatcher([decomposed, composed]))
    #expect(!ToolNameMatcher([composed]).matches("e\u{0301}suffix"))
}

@Test func v104McpNameRecognitionIncludesResources() {
    for name in ["mcp__", "mcp__docs__search", LIST_MCP_RESOURCES_TOOL,
                 LIST_MCP_RESOURCE_TEMPLATES_TOOL, READ_MCP_RESOURCE_TOOL] {
        #expect(isMcpToolName(name))
    }
    for name in ["mcp", "mcp_docs_search", "list_mcp_resources_extra", "read"] {
        #expect(!isMcpToolName(name))
    }
}

@Test func v104McpToolExposureKeepsExactThenPatternOrder() {
    let config = McpServerConfig(exposure: .codemode,
        toolExposure: ["search": .direct, "s*": .hidden, "*": .deferred],
        toolExposureOrder: ["*", "s*"])
    #expect(getMcpToolExposure(config, toolName: "search") == .direct)
    #expect(getMcpToolExposure(config, toolName: "shot") == .deferred)
    var reversed = config
    reversed.toolExposureOrder = ["s*", "*"]
    #expect(getMcpToolExposure(reversed, toolName: "shot") == .hidden)
    #expect(getMcpToolExposure(McpServerConfig(exposure: .direct), toolName: "search") == .direct)
    let combining = McpServerConfig(exposure: .codemode, toolExposure: ["a*\u{0301}b": .direct])
    #expect(getMcpToolExposure(combining, toolName: "aXYZ\u{0301}b") == .direct)
}

private let v104RegisteredTools = [
    InitialToolRegistration(name: "read", isBuiltin: true),
    InitialToolRegistration(name: "bash", isBuiltin: true),
    InitialToolRegistration(name: "write", isBuiltin: true),
    InitialToolRegistration(name: "codemode", defaultActive: false),
    InitialToolRegistration(name: "ask_question"),
    InitialToolRegistration(name: "dynamic_tool", exposure: .modelOnly, defaultActive: false),
    InitialToolRegistration(name: "indirect_tool", exposure: .deferred),
    InitialToolRegistration(name: "hidden_tool", exposure: .hidden),
    InitialToolRegistration(name: "mcp__docs__search", exposure: .deferred),
    InitialToolRegistration(name: "mcp__docs__shot"),
    InitialToolRegistration(name: LIST_MCP_RESOURCES_TOOL, exposure: .deferred)
]

@Test func v104InitialSelectionExpandsPatternsAndAppliesExclusionsLast() {
    let result = selectInitialTools(registeredTools: v104RegisteredTools,
        toolNames: ["*_tool", "ask_*", "re*"], excludeTools: ["ask*"], defaultToolNames: ["read", "bash"])
    #expect(result.activeToolNames == ["read", "dynamic_tool"])
    #expect(result.registeredToolNames == ["read", "dynamic_tool", "indirect_tool", "hidden_tool",
        "mcp__docs__search", "mcp__docs__shot", LIST_MCP_RESOURCES_TOOL])
}

@Test func v104InitialSelectionKeepsUnnamedMcpRegisteredAndInactive() {
    let result = selectInitialTools(registeredTools: v104RegisteredTools,
        toolNames: ["codemode", "read"], defaultToolNames: ["read", "bash"])
    #expect(result.activeToolNames == ["codemode", "read"])
    #expect(result.registeredToolNames == ["read", "codemode", "mcp__docs__search", "mcp__docs__shot",
        LIST_MCP_RESOURCES_TOOL])
}

@Test func v104InitialSelectionFiltersMcpWithPrefixEntriesAndExclusions() {
    let result = selectInitialTools(registeredTools: v104RegisteredTools,
        toolNames: ["codemode", "mcp__docs__s*"], excludeTools: ["mcp__*__search"],
        defaultToolNames: ["read", "bash"])
    #expect(result.registeredToolNames == ["codemode", "mcp__docs__shot"])
    #expect(result.activeToolNames == ["codemode", "mcp__docs__shot"])
}

@Test func v104InitialSelectionNoToolsAndExplicitOverride() {
    let none = selectInitialTools(registeredTools: v104RegisteredTools,
        noTools: .all, defaultToolNames: ["read", "bash"])
    #expect(none.registeredToolNames.isEmpty)
    #expect(none.activeToolNames.isEmpty)
    let empty = selectInitialTools(registeredTools: v104RegisteredTools,
        toolNames: [], defaultToolNames: ["read", "bash"])
    #expect(empty == none)
    let builtin = selectInitialTools(registeredTools: v104RegisteredTools,
        noTools: .builtin, defaultToolNames: ["read", "bash"])
    #expect(builtin.activeToolNames == ["ask_question", "mcp__docs__shot"])
    let override = selectInitialTools(registeredTools: v104RegisteredTools,
        toolNames: ["read"], noTools: .all, defaultToolNames: ["read", "bash"])
    #expect(override.activeToolNames == ["read"])
    #expect(override.registeredToolNames.contains("mcp__docs__search"))
}

@Test func v104InitialSelectionKeepsDefaultOrderAndExactIndirectSelection() {
    let defaults = selectInitialTools(registeredTools: v104RegisteredTools,
        defaultToolNames: ["write", "read", "indirect_tool"])
    #expect(defaults.activeToolNames == ["write", "read", "indirect_tool", "ask_question", "mcp__docs__shot"])
    let explicit = selectInitialTools(registeredTools: v104RegisteredTools,
        toolNames: ["write", "read", "indirect_tool", "hidden_tool", "*_tool"], defaultToolNames: [])
    #expect(explicit.activeToolNames == ["write", "read", "indirect_tool", "dynamic_tool"])
}

@Test func v104ArgsAcceptsNamesAndPatternsAndNoMcpDefaultsFalse() {
    var args = Args()
    #expect(!args.noMcp)
    args.tools = ["read", "codemode", "mcp__docs__*"]
    args.noMcp = true
    #expect(args.tools == ["read", "codemode", "mcp__docs__*"])
    #expect(args.noMcp)
}

@Test func v104LoaderDisabledBuiltinsOverrideSettingsAndExplicitPaths() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("v104-loader-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var settings = Settings()
    settings.extensions = ["+builtin:mcp"]
    let loader = DefaultResourceLoader(DefaultResourceLoaderOptions(
        cwd: directory.path, agentDir: directory.path, settingsManager: .inMemory(settings),
        additionalExtensionPaths: ["builtin:mcp"], builtinExtensions: ["mcp", "llama"],
        disabledBuiltinExtensions: ["mcp"], offline: true))
    await loader.reload()
    #expect(loader.getExtensions().paths == ["builtin:llama"])
    #expect(loader.getExtensions().diagnostics.isEmpty)
    await loader.reload()
    #expect(loader.getExtensions().paths == ["builtin:llama"])
}

@Test(arguments: [false, true])
private func v104SdkDisabledBuiltinsOverrideSettingsAndExplicitPaths(_ noExtensions: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("v104-sdk-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var settings = Settings()
    settings.extensions = ["+builtin:mcp"]
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let auth = AuthStorage.inMemory([model.provider: .apiKey(ApiKeyCredential(key: "test"))])
    // C1 U3: SDK tool-list validation now throws.
    let result = try await createAgentSession(CreateAgentSessionOptions(
        cwd: directory.path, agentDir: directory.path, authStorage: auth, model: model,
        offline: true, noTools: .all, hooks: [], additionalExtensionPaths: ["builtin:mcp"],
        inlineExtensions: [
            InlineExtension(name: "mcp", builtin: true) { api in api.registerCommand("mcp") { _, _ in } },
            InlineExtension(name: "llama", builtin: true) { api in api.registerCommand("llama") { _, _ in } }
        ], noExtensions: noExtensions, disabledBuiltinExtensions: ["mcp"],
        sessionManager: .inMemory(), settingsManager: .inMemory(settings)))
    defer { result.session.dispose() }
    #expect(result.session.hookRunner?.getRegisteredCommands().contains { $0.name == "mcp" } != true)
    #expect(result.diagnostics.filter { $0.type == "error" }.isEmpty)
    #expect(result.session.hookRunner?.getRegisteredCommands().contains { $0.name == "llama" } == !noExtensions)
}

@Test func v104SdkDisabledBuiltinPathNeedsNoFactory() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("v104-disabled-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    // C1 U3: SDK tool-list validation now throws.
    let result = try await createAgentSession(CreateAgentSessionOptions(
        cwd: directory.path, agentDir: directory.path,
        authStorage: AuthStorage.inMemory([model.provider: .apiKey(ApiKeyCredential(key: "test"))]),
        model: model, offline: true, noTools: .all, hooks: [],
        additionalExtensionPaths: ["builtin:mcp"], inlineExtensions: [],
        disabledBuiltinExtensions: ["mcp"], sessionManager: .inMemory(), settingsManager: .inMemory()))
    defer { result.session.dispose() }
    #expect(result.session.hookRunner?.getRegisteredCommands().contains { $0.name == "mcp" } != true)
    #expect(result.diagnostics.filter { $0.type == "error" }.isEmpty)
}
