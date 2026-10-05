import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func codemodeBlocks(_ result: AgentToolResult) -> [String] {
    result.content.compactMap { block in
        if case .text(let value) = block { return value.text }
        return nil
    }
}

private func codemodeValue(_ result: AgentToolResult) -> String {
    codemodeBlocks(result).dropFirst().joined(separator: "\n")
}

private func codemodeContext(session: SessionManager = .inMemory(),
                             signal: CancellationToken? = nil) -> CustomToolContext {
    CustomToolContext(sessionManager: session, modelRegistry: ModelRegistry(AuthStorage(":memory:")), model: nil,
                      isIdle: { true }, hasPendingMessages: { false }, abort: {},
                      events: createEventBus(), sendMessage: { _, _ in }, signal: signal)
}

private func codemodeRun(_ code: String, session: SessionManager = .inMemory(),
                         context: CustomToolContext? = nil, signal: CancellationToken? = nil,
                         options: CodemodeToolOptions = .init()) async throws -> AgentToolResult {
    let tool = createCodemodeToolDefinition(options: options)
    return try await tool.execute("codemode-test", ["code": AnyCodable(code)], nil,
                                  context ?? codemodeContext(session: session, signal: signal), signal)
}

@Test(.timeLimit(.minutes(1))) func codemodeRunsScriptOutputExitAndErrors() async throws {
    // Upstream #10215: image() validates the image signature.
    let output = try await codemodeRun("console.log('hello', 1); text({a: 2}); image('data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jOZkAAAAASUVORK5CYII='); return 42")
    #expect(output.isError != true)
    #expect(codemodeBlocks(output).first?.hasPrefix("Script completed\nWall time ") == true)
    // Upstream v1.0.3 #10310: each image follows a saved-path text block.
    let label = try #require(codemodeBlocks(output).dropFirst().dropFirst(2).first)
    #expect(codemodeBlocks(output).dropFirst() == ["hello 1", "{\"a\":2}", label, "42"])
    #expect(label.hasPrefix("[Image saved to "))
    let pathEnd = try #require(label.range(of: " (", options: .backwards))
    let path = String(label.dropFirst("[Image saved to ".count).prefix(upTo: pathEnd.lowerBound))
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jOZkAAAAASUVORK5CYII="))
    if case .text(let item) = output.content[3] { #expect(item.text == label) }
    else { Issue.record("Missing saved path before image") }
    if case .image = output.content[4] {} else { Issue.record("Missing image after saved path") }
    #expect(output.content.contains { if case .image(let item) = $0 { return item.data == "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jOZkAAAAASUVORK5CYII=" }; return false })

    let exited = try await codemodeRun("text('before'); try { exit(); } catch {} text('after')")
    #expect(codemodeValue(exited) == "before")

    let failed = try await codemodeRun("text('partial');\nthrow new TypeError('boom')")
    #expect(failed.isError == true)
    #expect(codemodeValue(failed).contains("partial\nScript error:\nTypeError: boom"))
    #expect(codemodeValue(failed).contains("codemode.js:2"))
    #expect(!codemodeValue(failed).contains("codemode-prelude.js"))

    let syntax = try await codemodeRun("const a = 1;\nconst b = ;")
    #expect(syntax.isError == true)
    #expect(codemodeValue(syntax).contains("SyntaxError"))
}

@Test(.timeLimit(.minutes(1))) func codemodeStoreReplaysBranchAndCommitsOnlySuccess() async throws {
    let session = SessionManager.inMemory()
    let options = CodemodeToolOptions(appendEntry: { type, data in
        session.appendCustomEntry(type, ["set": data.set.mapValues(\.value), "delete": data.delete])
    })
    let increment = "const n = (load('count') ?? 0) + 1; store('count', n); return n"
    #expect(codemodeValue(try await codemodeRun(increment, session: session, options: options)) == "1")
    #expect(codemodeValue(try await codemodeRun(increment, session: session, options: options)) == "2")
    let entries = session.getBranch().compactMap { entry -> CustomEntry? in
        if case .custom(let value) = entry, value.customType == CODEMODE_STORE_ENTRY_TYPE { return value }
        return nil
    }
    #expect(entries.count == 2)
    #expect(readCodemodeStore(session.getBranch())["count"]?.value as? Int == 2)
    _ = try await codemodeRun("store('count', 9); throw new Error('bad')", session: session, options: options)
    #expect(readCodemodeStore(session.getBranch())["count"]?.value as? Int == 2)
    #expect(session.getBranch().filter { if case .custom(let value) = $0 { return value.customType == CODEMODE_STORE_ENTRY_TYPE }; return false }.count == 2)

    #expect(codemodeValue(try await codemodeRun(increment, session: session, options: options)) == "3")
    try session.branch(entries[0].id)
    #expect(codemodeValue(try await codemodeRun(increment, session: session, options: options)) == "2")
}

@Test(.timeLimit(.minutes(1))) func codemodeToolBridgeRunsParallelCallsAndUsesStructuredContent() async throws {
    let seen = LockedState<[String]>([])
    let echo = AgentTool(label: "echo", name: "echo", description: "Echo", parameters: [:]) { _, _, _, _ in
        AgentToolResult(content: [])
    }
    let stats = AgentTool(label: "stats", name: "stats", description: "Stats", parameters: [:],
                          execute: { _, _, _, _ in AgentToolResult(content: []) },
                          outputSchema: ["type": AnyCodable("object")])
    var context = codemodeContext()
    context.setNestedToolHost(tools: [echo, stats]) { name, args, _ in
        seen.withLock { $0.append(name) }
        let result: AgentToolResult
        if name == "stats" {
            result = AgentToolResult(content: [.text(TextContent(text: "plain"))],
                                     structuredContent: AnyCodable(["files": 2]))
        } else {
            let value = args["text"]?.value as? String ?? ""
            result = AgentToolResult(content: [.text(TextContent(text: "echo: \(value)"))])
        }
        return AgentToolCallOutcome(toolCall: AgentToolCall(id: "codemode-test/\(seen.withLock { $0.count })",
                                                             name: name, arguments: args), result: result, isError: false)
    }
    let result = try await codemodeRun("const [a,b,s] = await Promise.all([tools.echo({text:'one'}), tools.echo({text:'two'}), tools.stats({})]); return [a,b,s.files]", context: context)
    #expect(result.isError != true)
    #expect(codemodeValue(result) == "[\"echo: one\",\"echo: two\",2]")
    #expect(seen.withLock { $0.sorted() } == ["echo", "echo", "stats"])
    let details = result.details?.value as? [String: Any]
    let calls = details?["calls"] as? [[String: Any]]
    #expect(calls?.count == 3)
    #expect(calls?.allSatisfy { $0["status"] as? String == "ok" } == true)
}

@Test(.timeLimit(.minutes(1))) func codemodeSourceTimeoutAndInvalidOptions() async throws {
    let timeout = try await codemodeRun("// @options: {\"timeout_ms\": 150}\nwhile (true) {}")
    #expect(timeout.isError == true)
    #expect(codemodeValue(timeout).contains("Script timed out"))
    await #expect(throws: CodemodeSourceError.self) {
        try await codemodeRun("// @options: {\"other\": 1}\ntext(1)")
    }
}

@Test(.timeLimit(.minutes(1))) func codemodeNestedErrorsRejectAndUnawaitedCallsAreCancelled() async throws {
    let echo = AgentTool(label: "echo", name: "echo", description: "Echo", parameters: [:]) {
        _, _, _, _ in AgentToolResult(content: [])
    }
    var context = codemodeContext()
    context.setNestedToolHost(tools: [echo]) { name, args, options in
        let value = args["text"]?.value as? String ?? ""
        if value == "slow" {
            try? await Task.sleep(for: .milliseconds(500))
        }
        let error = value == "fail"
        return AgentToolCallOutcome(toolCall: AgentToolCall(id: "nested/\(value)", name: name, arguments: args),
            result: AgentToolResult(content: [.text(TextContent(text: error ? "tool exploded" : value))], isError: error),
            isError: error)
    }
    let rejected = try await codemodeRun("try { await tools.echo({text:'fail'}) } catch(e) { return e.message }",
                                         context: context)
    #expect(codemodeValue(rejected) == "tool exploded")
    let errorRows = (rejected.details?.value as? [String: Any])?["calls"] as? [[String: Any]]
    #expect(errorRows?.first?["status"] as? String == "error")

    let updates = LockedState<[String]>([])
    let tool = createCodemodeToolDefinition()
    let early = try await tool.execute("early", ["code": AnyCodable("tools.echo({text:'slow'}); return 'early'")],
        { result in
            let rows = (result.details?.value as? [String: Any])?["calls"] as? [[String: Any]]
            if let status = rows?.first?["status"] as? String { updates.withLock { $0.append(status) } }
        }, context, nil)
    #expect(codemodeValue(early) == "early")
    let rows = (early.details?.value as? [String: Any])?["calls"] as? [[String: Any]]
    #expect(rows?.first?["status"] as? String == "cancelled")
    #expect(updates.withLock { $0 }.contains("running"))
}

@Test(.timeLimit(.minutes(1))) func codemodeBuiltinIsHiddenReplaceableAndInactive() async throws {
    let builtin = ExtensionLoader.load(createCodemodeExtension(), cwd: "/tmp", eventBus: createEventBus())
    #expect(builtin.hook?.path == "builtin:codemode")
    #expect(builtin.hook?.hidden == true)
    #expect(builtin.hook?.replaceable == true)
    #expect(builtInExtensions.map(\.name).contains("codemode"))

    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey(model.provider, "test")
    let created = await createAgentSession(CreateAgentSessionOptions(authStorage: auth, model: model,
        offline: true, noTools: .builtin, resourceLoader: TestResourceLoader(),
        inlineExtensions: builtInExtensions, sessionManager: .inMemory(), settingsManager: .inMemory()))
    defer { created.session.dispose() }
    #expect(created.session.getAllTools().contains { $0.name == CODEMODE_TOOL_NAME })
    #expect(!created.session.getActiveToolNames().contains(CODEMODE_TOOL_NAME))

    var settings = Settings()
    settings.defaultTools = ["+codemode"]
    // v1.0.4 C2 (upstream sdk.ts:274-276, unchanged since v0.99.1): `noTools` ignores `defaultTools`,
    // and codemode is not default-active, so only the default selection activates it.
    let enabled = await createAgentSession(CreateAgentSessionOptions(authStorage: auth, model: model,
        offline: true, resourceLoader: TestResourceLoader(),
        inlineExtensions: builtInExtensions, sessionManager: .inMemory(), settingsManager: .inMemory(settings)))
    defer { enabled.session.dispose() }
    #expect(enabled.session.getActiveToolNames().contains(CODEMODE_TOOL_NAME))
    let noBuiltins = await createAgentSession(CreateAgentSessionOptions(authStorage: auth, model: model,
        offline: true, noTools: .builtin, resourceLoader: TestResourceLoader(),
        inlineExtensions: builtInExtensions, sessionManager: .inMemory(), settingsManager: .inMemory(settings)))
    defer { noBuiltins.session.dispose() }
    #expect(!noBuiltins.session.getActiveToolNames().contains(CODEMODE_TOOL_NAME))

    settings.extensions = ["-builtin:codemode"]
    let disabled = await createAgentSession(CreateAgentSessionOptions(authStorage: auth, model: model,
        offline: true, noTools: .builtin, resourceLoader: TestResourceLoader(),
        inlineExtensions: builtInExtensions, sessionManager: .inMemory(), settingsManager: .inMemory(settings)))
    defer { disabled.session.dispose() }
    #expect(!disabled.session.getAllTools().contains { $0.name == CODEMODE_TOOL_NAME })

    let explicit = await createAgentSession(CreateAgentSessionOptions(authStorage: auth, model: model,
        offline: true, toolNames: [CODEMODE_TOOL_NAME], resourceLoader: TestResourceLoader(),
        inlineExtensions: builtInExtensions, sessionManager: .inMemory(), settingsManager: .inMemory()))
    defer { explicit.session.dispose() }
    #expect(explicit.session.getActiveToolNames() == [CODEMODE_TOOL_NAME])
}

@Test(.timeLimit(.minutes(1))) func codemodeLoadoutModesMatchUpstream() {
    func tool(_ name: String) -> AgentTool {
        AgentTool(label: name, name: name, description: "Description of \(name)", parameters: [:]) {
            _, _, _, _ in AgentToolResult(content: [])
        }
    }
    let direct = tool("direct")
    let code = tool("code")
    let deferred = tool("deferred")
    let codemode = tool(CODEMODE_TOOL_NAME)
    let loadout = ToolLoadout(declared: [direct, codemode],
                              callable: [direct, code, deferred],
                              registered: [direct, code, deferred, codemode],
                              getExposure: { name in
        switch name {
        case "code": .codemode
        case "deferred": .deferred
        case CODEMODE_TOOL_NAME: .modelOnly
        default: .direct
        }
    }, getNamespace: { _ in nil })
    let on = prepareCodemodeLoadout(loadout, options: .init(getMode: { .on }))
    // Upstream CM7: declared tools use a one-line script call note.
    #expect(on.descriptions?["direct"]?.contains("Codemode: `tools.direct(args)` resolves to") == true)
    #expect(on.descriptions?[CODEMODE_TOOL_NAME]?.contains("### `code`") == true)
    #expect(on.descriptions?[CODEMODE_TOOL_NAME]?.contains("### `direct`") == false)
    #expect(on.hiddenDeclarations?.isEmpty == true)

    let only = prepareCodemodeLoadout(loadout, options: .init(getMode: { .only }))
    #expect(only.descriptions?["direct"] == nil)
    #expect(only.descriptions?[CODEMODE_TOOL_NAME]?.contains("### `direct`") == true)
    #expect(only.hiddenDeclarations == ["direct"])
}

private final class FauxCodemodeModels: CodemodeModelRuntime, Sendable {
    private struct Counts: Sendable { var active = 0; var maxActive = 0; var seenBaseURLs: [String] = [] }
    private let counts = LockedState(Counts())
    let model = ClassifierModel(id: "judge", name: "Judge", api: .typesafeSystemOne,
        provider: "scorer", baseUrl: "https://classifier.test/v1", input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 1000, headers: ["X-Secret": "hunter2"])

    var maxActive: Int { counts.withLock { $0.maxActive } }
    var seenBaseURLs: [String] { counts.withLock { $0.seenBaseURLs } }

    func getModelsOfType(_ type: ModelType, provider: String?) -> [AnyModel] {
        type == .classifier && (provider == nil || provider == model.provider) ? [.classifier(model)] : []
    }
    func getAvailableOfType(_ type: ModelType, provider: String?) async -> [AnyModel] {
        getModelsOfType(type, provider: provider)
    }
    func getModelOfType(_ type: ModelType, provider: String, modelId: String) -> AnyModel? {
        type == .classifier && provider == model.provider && modelId == model.id ? .classifier(model) : nil
    }
    func classify(_ model: ClassifierModel, context: ClassifierContext,
                  options: ClassifierOptions?) async -> ClassifierResult {
        counts.withLock { value in
            value.active += 1
            value.maxActive = max(value.maxActive, value.active)
            value.seenBaseURLs.append(model.baseUrl)
        }
        try? await Task.sleep(for: .milliseconds(20))
        counts.withLock { $0.active -= 1 }
        let text = context.state["text"]?.value as? String
        let probability = text == "good" ? 0.9 : 0.1
        return ClassifierResult(api: model.api, provider: model.provider, model: model.id,
            answers: ["approved": .bool(probability: probability)],
            usage: Usage(input: 300, output: 0, cacheRead: 0, cacheWrite: 0,
                         totalTokens: 300, cost: UsageCost(input: 0.001, total: 0.001)))
    }
}

@Test(.timeLimit(.minutes(1))) func codemodeModelsUseResolvedClassifierAndAggregateUsage() async throws {
    let models = FauxCodemodeModels()
    let options = CodemodeToolOptions(models: true, modelRuntime: models)
    let questions = #"{approved:{type:'bool',instructions:'Approval?',criteria:{true:'yes',false:'no'}}}"#
    let script = """
    const model = await models.getModelOfType('classifier', 'scorer', 'judge');
    const listed = await models.getModelsOfType('classifier');
    const available = await models.getAvailableOfType('classifier', 'scorer');
    const texts = ['good','bad','good','bad','good','bad'];
    const results = await Promise.all(texts.map(text => models.classify({...model, baseUrl:'https://evil.test'}, {state:{text},questions:\(questions)})));
    return {headers: 'headers' in model, listed: listed.length, available: available.length,
            probabilities: results.map(r => r.answers.approved.probability), cost: results[0].usage.cost.total};
    """
    let result = try await codemodeRun(script, options: options)
    #expect(result.isError != true)
    let object = try #require(JSONSerialization.jsonObject(with: Data(codemodeValue(result).utf8)) as? [String: Any])
    #expect(object["headers"] as? Bool == false)
    #expect(object["listed"] as? Int == 1)
    #expect(object["available"] as? Int == 1)
    #expect(object["probabilities"] as? [Double] == [0.9, 0.1, 0.9, 0.1, 0.9, 0.1])
    #expect(models.maxActive == 4)
    #expect(models.seenBaseURLs == Array(repeating: "https://classifier.test/v1", count: 6))
    #expect(result.usage?.input == 1_800)
    #expect(abs((result.usage?.cost.total ?? 0) - 0.006) < 0.000_001)
    let details = result.details?.value as? [String: Any]
    let calls = details?["calls"] as? [[String: Any]]
    #expect(calls?.count == 6)
    #expect(calls?.allSatisfy { $0["name"] as? String == "models.classify" && $0["status"] as? String == "ok" } == true)
}

@Test(.timeLimit(.minutes(1))) func codemodeSearchAndDescribeToolsUseBm25() async throws {
    func tool(_ name: String, _ description: String) -> AgentTool {
        AgentTool(label: name, name: name, description: description, parameters: [:]) {
            _, _, _, _ in AgentToolResult(content: [])
        }
    }
    let docs = tool("mcp__docs__search", "Search the documentation")
    let issues = tool("mcp__github__list_issues", "List repository issues")
    var context = codemodeContext()
    context.setNestedToolHost(tools: [docs, issues]) { name, args, _ in
        AgentToolCallOutcome(toolCall: AgentToolCall(id: "unused", name: name, arguments: args),
                             result: AgentToolResult(content: []), isError: false)
    }
    let options = CodemodeToolOptions(getToolNamespace: { name in
        name == docs.name ? ToolNamespace(name: "mcp__docs") : ToolNamespace(name: "mcp__github")
    })
    let result = try await codemodeRun("const hits=await searchTools('documentation',{namespace:'mcp__docs'}); const desc=await describeTool(hits[0].name); return {names:hits.map(x=>x.name),hasSignature:desc.includes('codemode tool declaration:'),missing:await describeTool('missing')};",
                                       context: context, options: options)
    #expect(result.isError != true)
    let object = try #require(JSONSerialization.jsonObject(with: Data(codemodeValue(result).utf8)) as? [String: Any])
    #expect(object["names"] as? [String] == ["mcp__docs__search"])
    #expect(object["hasSignature"] as? Bool == true)
    #expect(object["missing"] == nil)
}
