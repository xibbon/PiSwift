import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

// v1.3.0: coding-agent/src/extensions/codemode/tool.ts getScriptReach.
@Test(arguments: ["searchTools", "describeNamespace", "describeTool", "ALL_TOOLS"])
func c4CodemodeDiscoveryReachesAllTools(_ name: String) throws {
    let reaches = try #require(createCodemodeToolDefinition().reachesTools)
    #expect(reaches(["code": AnyCodable("await \(name)('docs')")]) == .all)
    #expect(reaches(["code": AnyCodable("// \(name)")]) == .all)
    #expect(reaches(["code": AnyCodable("'\(name)'")]) == .all)
    #expect(reaches(["code": AnyCodable("é\(name)é")]) == .all)
    #expect(reaches(["code": AnyCodable("_\(name) \(name)2")]) == .words(["_" + name, name + "2"]))
}

@Test func c4CodemodeReachUsesSourceWords() throws {
    let reaches = try #require(createCodemodeToolDefinition().reachesTools)
    #expect(reaches(["code": AnyCodable("await tools.mcp__docs__search({}); tools[\"mcp__docs__\" + name];")]) ==
            .words(["await", "tools", "mcp__docs__search", "tools", "mcp__docs__", "name"]))
    #expect(reaches(["code": AnyCodable("éabc💡123_abc abc")]) == .words(["abc", "123_abc", "abc"]))
    #expect(reaches(["code": AnyCodable("?!")]) == .words([]))
    #expect(reaches([:]) == .words([]))
    for value in [AnyCodable(7), AnyCodable(true), AnyCodable(["searchTools"]), AnyCodable(NSNull())] {
        #expect(reaches(["code": value]) == .words([]))
    }
    let searchReach = try #require(createToolSearchToolDefinition().reachesTools)
    #expect(searchReach([:]) == .all)
    #expect(searchReach(["query": AnyCodable("docs")]) == .all)
}

@Test func c4NamespaceAliasesDecodeOldDataAndRoundTrip() throws {
    let old = Data(#"{"name":"mcp__docs","description":"Docs","version":"1","instructions":"Read first"}"#.utf8)
    let decoded = try JSONDecoder().decode(ToolNamespace.self, from: old)
    #expect(decoded.name == "mcp__docs")
    #expect(decoded.description == "Docs")
    #expect(decoded.version == "1")
    #expect(decoded.instructions == "Read first")
    #expect(decoded.aliases == nil)
    let namespace = ToolNamespace(name: "mcp__dev_radius", aliases: ["dev-radius", "guide"])
    let restored = try JSONDecoder().decode(ToolNamespace.self, from: JSONEncoder().encode(namespace))
    #expect(restored.aliases == ["dev-radius", "guide"])
    for query in ["mcp__dev-radius", "mcp__dev_radius", "dev-radius", "dev_radius", "guide"] {
        #expect(matchesToolNamespace(name: query, namespace: restored))
    }
    #expect(!matchesToolNamespace(name: "radius", namespace: restored))
    #expect(!matchesToolNamespace(name: "dev_radius", namespace: decoded))
    #expect(!matchesToolNamespace(name: "last", namespace: "outer__inner__last"))
}

private func c4Context() -> CustomToolContext {
    CustomToolContext(sessionManager: .inMemory(), modelRegistry: ModelRegistry(AuthStorage(":memory:")),
        model: nil, isIdle: { true }, hasPendingMessages: { false }, abort: {},
        events: createEventBus(), sendMessage: { _, _ in })
}

// v1.3.0: codemode/execute.ts isNamespaceName does not infer a suffix alias.
@Test(.timeLimit(.minutes(1)), arguments: ["dev-radius", "dev_radius"])
func c4CodemodeDiscoveryRequiresDeclaredAlias(_ query: String) async throws {
    let tool = AgentTool(label: "search", name: "mcp__dev_radius__search", description: "Search docs", parameters: [:]) { _, _, _, _ in
        AgentToolResult(content: [])
    }
    var context = c4Context()
    context.setNestedToolHost(tools: [tool]) { name, args, _ in
        AgentToolCallOutcome(toolCall: AgentToolCall(id: "unused", name: name, arguments: args),
            result: AgentToolResult(content: []), isError: false)
    }
    let result = try await executeCodemode(toolCallId: "c4", params: ["code": AnyCodable("""
    const ns=await describeNamespace('\(query)');
    const hits=await searchTools('docs',{namespace:'\(query)'});
    return {found:ns!==undefined,hits:hits.map(t=>t.name)};
    """)], context: context,
        options: CodemodeToolOptions(getToolNamespace: { _ in ToolNamespace(name: "mcp__dev_radius") }))
    #expect(result.isError != true)
    let output = result.content.compactMap { if case .text(let item) = $0 { return item.text }; return nil }
        .dropFirst().joined(separator: "\n")
    let object = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    #expect(object["found"] as? Bool == false)
    #expect(object["hits"] as? [String] == [])
}

// v1.3.0: core/agent-session.ts getAllTools forwards executable reach metadata.
@Test func c4SessionForwardsReachFromStoredDefinition() throws {
    let definition = CustomTool(name: "reach", label: "reach", description: "Reach another tool",
        execute: { _, _, _, _, _ in AgentToolResult(content: []) },
        reachesTools: { .words([$0["target"]?.value as? String ?? "missing"]) })
    let loaded = LoadedCustomTool(path: "test:reach", resolvedPath: "test:reach",
        tool: CustomToolDefinition(tool: definition).tool)
    let wrapped = wrapCustomTool(loaded.tool) { c4Context() }
    let agent = Agent(AgentOptions(initialState: AgentState(tools: [wrapped])))
    let session = AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: .inMemory(),
        settingsManager: .inMemory(), resourceLoader: TestResourceLoader(), customTools: [loaded],
        modelRegistry: ModelRegistry(AuthStorage(":memory:")), toolDefinitions: [definition.name: loaded.tool]))
    defer { session.dispose() }
    let info = try #require(session.getAllTools().first { $0.name == definition.name })
    let reaches = try #require(info.reachesTools)
    #expect(reaches(["target": AnyCodable("mcp__docs")]) == .words(["mcp__docs"]))
    #expect(reaches([:]) == .words(["missing"]))
    #expect(CustomTool(name: "plain", label: "plain", description: "Plain",
        execute: { _, _, _, _, _ in AgentToolResult(content: []) }).reachesTools == nil)
    #expect(ToolInfo(name: "plain", description: "Plain").reachesTools == nil)
}
