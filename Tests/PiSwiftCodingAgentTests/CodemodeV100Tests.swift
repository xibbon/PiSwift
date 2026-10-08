import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private let v100PNG = "iVBORw0KGgo="

private func v100Text(_ result: AgentToolResult) -> String {
    result.content.compactMap { if case .text(let text) = $0 { return text.text }; return nil }
        .dropFirst().joined(separator: "\n")
}

private func v100Context(_ registry: ModelRegistry = ModelRegistry(AuthStorage(":memory:"))) -> CustomToolContext {
    CustomToolContext(sessionManager: .inMemory(), modelRegistry: registry, model: nil,
        isIdle: { true }, hasPendingMessages: { false }, abort: {}, events: createEventBus(), sendMessage: { _, _ in })
}

private func v100Run(_ code: String, context: CustomToolContext? = nil,
                     options: CodemodeToolOptions = .init()) async throws -> AgentToolResult {
    try await executeCodemode(toolCallId: "v100", params: ["code": AnyCodable(code)],
                              context: context, options: options)
}

private func v100Sandbox(code: String, tools: [CodemodeRuntimeTool] = [],
                         globals: [CodemodeRuntimeGlobal] = []) async -> CodemodeRuntimeResult {
    await CodemodeSandbox.execute(code: code, tools: tools, globals: globals,
        onCall: { _ in CodemodeRuntimeReply(ok: true) })
}

// Ported from v1.0.0 codemode/test/sandbox.test.ts (#10215).
@Test(.timeLimit(.minutes(1)), arguments: [
    ("image('data:image/png;base64,AAAA!')", "not valid base64"),
    ("image('data:image/png;base64,AAAAA')", "not valid base64"),
    ("image('data:image/png;base64,AA=A')", "not valid base64"),
    ("image('data:image/png;base64,')", "not valid base64"),
    ("image('data:image/png;base64,AAAA\\n[Output truncated]')", "not valid base64"),
    ("image({type:'image',data:'AAAA!',mimeType:'image/png'})", "not valid base64"),
    ("image('data:image/png;base64,AAAA')", "not a PNG, JPEG, GIF, or WebP image"),
    ("image('data:image/png;base64,QUJD')", "not a PNG, JPEG, GIF, or WebP image"),
    ("image('data:image/jpeg;base64,/9j/9w==')", "not a PNG, JPEG, GIF, or WebP image"),
]) func codemodeV100RejectsInvalidImage(script: String, problem: String) async {
    let result = await v100Sandbox(code: script)
    #expect(result.execution.failure?.name == "TypeError")
    #expect(result.execution.failure?.message == "invalid image output. The image data is \(problem)\(problem == "not valid base64" ? " (truncated or corrupted?)" : "")")
    #expect(result.execution.output.isEmpty)
}

@Test(.timeLimit(.minutes(1))) func codemodeV100DetectsImageFormats() async {
    let result = await v100Sandbox(code: """
    image('data:image/jpeg;base64,iVBORw0KGgo=');
    image({image_url:'data:image/png;base64,/9j/4A=='});
    image({type:'image',data:'R0lGODlh',mimeType:'image/png'});
    image('data:image/png;base64,UklGRgAAAABXRUJQ');
    image({type:'image',data:'iVBORw0KGgo='});
    """)
    #expect(result.execution.failure == nil)
    let images = result.execution.output.compactMap { if case .image(let item) = $0 { return item }; return nil }
    #expect(images.map(\.mimeType) == ["image/png", "image/jpeg", "image/gif", "image/webp", "image/png"])
    #expect(images.map(\.data) == [v100PNG, "/9j/4A==", "R0lGODlh", "UklGRgAAAABXRUJQ", v100PNG])
}

@Test(.timeLimit(.minutes(1))) func codemodeV100AcceptsWrappedAndLargeImages() async {
    let large = "iVBORw0KGgoA" + String(repeating: "QUJD", count: 256 * 1024)
    let result = await v100Sandbox(code: "image('data:image/png;base64,iVBORw0K\\r\\nGgo=\\n'); image('data:image/png;base64,\(large)')")
    #expect(result.execution.failure == nil)
    let images = result.execution.output.compactMap { if case .image(let image) = $0 { return image }; return nil }
    #expect(images.map(\.data) == [v100PNG, large])
    #expect(images.allSatisfy { $0.mimeType == "image/png" })
}

@Test(.timeLimit(.minutes(1)), arguments: [
    ("tools.Echo", "tools.Echo does not exist. Did you mean tools.echo? ALL_TOOLS lists every tool; searchTools(query) finds tools by topic. Check for a member with \"Echo\" in tools."),
    ("tools.Bash", "Did you mean tools.bash?"),
    ("tools.websearch", "Did you mean tools.web_search?"),
    ("tools.nothing", "Available: echo, bash, web_search."),
]) func codemodeV100MissingToolsSuggestMatches(expression: String, expected: String) async {
    let result = await v100Sandbox(code: "return \(expression)",
        tools: [CodemodeRuntimeTool(name: "echo"), .init(name: "bash"), .init(name: "web-search")])
    #expect(result.execution.failure?.name == "TypeError")
    #expect(result.execution.failure?.message.contains(expected) == true)
}

@Test(.timeLimit(.minutes(1))) func codemodeV100ToolsSupportMembershipAndSerialization() async {
    let result = await v100Sandbox(code: "return ['echo' in tools, 'nothing' in tools, String(tools.toString), JSON.stringify(tools), tools.then, tools.toJSON]",
        tools: [.init(name: "echo")])
    #expect(result.execution.failure == nil)
    #expect((try? JSONEncoder().encode(result.execution.returnedValue)) == Data(#"[true,false,"undefined","{}",null,null]"#.utf8))
}

@Test(.timeLimit(.minutes(1))) func codemodeV100MissingNamespaceMemberSuggestsMatch() async {
    let result = await v100Sandbox(code: "await models.generateImage()",
        globals: [.init(name: "models.classify"), .init(name: "models.generateImages")])
    #expect(result.execution.failure?.message == "models.generateImage does not exist. Did you mean models.generateImages? Check for a member with \"generateImage\" in models.")
}

@Test(.timeLimit(.minutes(1))) func codemodeV100ExplainsStoreLimits() async {
    let result = await v100Sandbox(code: "store('img', 'x'.repeat(300 * 1024))")
    #expect(result.execution.failure?.name == "RangeError")
    #expect(result.execution.failure?.message == "store(\"img\") value has 307202 characters of JSON, more than the limit of 262144. store() is for small state such as IDs or summaries. Show images with image(), keep large data in variables, or write it to a file with a tool.")
    let full = await v100Sandbox(code: "for (let i=0;i<5;i++) store(String(i), 'x'.repeat(250000))")
    #expect(full.execution.failure?.message == "store is full: stored values would exceed 1048576 characters of JSON. Delete keys with store(key, undefined). store() is for small state such as IDs or summaries. Show images with image(), keep large data in variables, or write it to a file with a tool.")
}

private func v100Tool(_ name: String, schema: [String: AnyCodable]? = nil) -> AgentTool {
    AgentTool(label: name, name: name, description: "Search docs", parameters: [:],
        execute: { _, _, _, _ in AgentToolResult(content: []) }, outputSchema: schema)
}

@Test func codemodeV100DeferredToolsDoNotChangeDescription() {
    let direct = v100Tool("read")
    let deferred = v100Tool("mcp__docs__search", schema: ["type": AnyCodable("object"), "properties": AnyCodable([
        "content": ["type": "array", "items": ["type": "object"]], "isError": ["type": "boolean"], "_meta": ["type": "object"]])])
    let options = CodemodeDescriptionOptions(namespaces: [deferred.name: .init(name: "mcp__docs", description: "Docs", instructions: "Private guidance")], deferred: [deferred.name])
    let withDeferred = createCodemodeDescription([direct, deferred], options: options)
    #expect(withDeferred == createCodemodeDescription([direct]))
    #expect(!withDeferred.contains("Shared MCP Types"))
    #expect(withDeferred.contains("find unlisted tools, such as MCP tools"))
    let listed = createCodemodeDescription([deferred], options: .init(namespaces: options.namespaces))
    #expect(listed.contains("## mcp__docs\nDocs"))
    #expect(!listed.contains("Private guidance"))
    let zero = createCodemodeDescription([deferred], options: .init(namespaces: options.namespaces, inlineBudget: 0))
    #expect(zero.contains("## mcp__docs (tools not listed)"))
    #expect(!zero.contains("Shared MCP Types"))
}

@Test func codemodeV100DescriptionAndOutputNotes() throws {
    #expect(renderToolOutputType(AnyCodable(["type": "string"])) == "string")
    #expect(renderToolOutputType(nil) == "unknown")
    let description = createCodemodeDescription([], options: .init(models: true))
    // Upstream v1.0.3 #10310: the globals description names the saved image path.
    #expect(description == codemodeDescriptionIntro + "\n\nGlobals:\n- `text(value)`, `image(dataUrlOrImageBlock)`, `console.log(...)`, and top-level `return` add output; `exit()` ends the script. `image()` also saves the image to a temp file and the result names its path.\n- `store(key, value)` and `load(key)` keep JSON values across codemode calls.\n- `ALL_TOOLS`, `searchTools(query, { limit?, namespace? })`, `describeTool(name)`, `describeNamespace(name)`: find unlisted tools, such as MCP tools.\n- `models`: classifiers and image generation. Read \(CODEMODE_DOCS_PATH) first.")
    #expect(!createCodemodeDescription([]).contains("- `models`"))
    let text = try String(contentsOfFile: CODEMODE_DOCS_PATH, encoding: .utf8)
    #expect(text.contains("JavaScriptCore"))
    #expect(text.contains("On iOS, a timed-out script is abandoned"))
    #expect(!text.contains("256 MB"))
    let tool = v100Tool("stats", schema: ["type": AnyCodable("object"), "properties": AnyCodable(["output": ["type": "string"], "path": ["type": "string"]]), "required": AnyCodable(["output"])])
    let loadout = ToolLoadout(declared: [tool], callable: [tool], registered: [tool], getExposure: { _ in .direct }, getNamespace: { _ in nil })
    #expect(prepareCodemodeLoadout(loadout).descriptions?["stats"] == "Search docs\n\nCodemode: `tools.stats(args)` resolves to `{ output, path? }`.")
    let bash = createBashTool(cwd: "/tmp")
    let fields = bash.outputSchema?["properties"]?.value as? [String: [String: Any]]
    #expect(fields?["output"]?["description"] as? String == "Combined stdout and stderr, possibly truncated")
    #expect(fields?["truncated"]?["description"] == nil)
    #expect(fields?["full_output_path"]?["description"] as? String == "Full output, when truncated")
}

@Test(.timeLimit(.minutes(1)), arguments: ["mcp__dev-radius", "mcp__dev_radius", "dev-radius", "dev_radius"])
func codemodeV100NamespaceLookupAndSearch(name: String) async throws {
    let tool = v100Tool("mcp__dev_radius__search")
    var context = v100Context()
    context.setNestedToolHost(tools: [tool]) { name, args, _ in
        AgentToolCallOutcome(toolCall: AgentToolCall(id: "unused", name: name, arguments: args), result: AgentToolResult(content: []), isError: false)
    }
    let options = CodemodeToolOptions(getToolNamespace: { _ in .init(name: "mcp__dev_radius", description: "Docs", instructions: "Search the guide") })
    let result = try await v100Run("const ns=await describeNamespace('\(name)'); const hits=await searchTools('docs',{namespace:'\(name)'}); return {ns,hits:hits.map(t=>t.name),missing:await describeNamespace('absent')}", context: context, options: options)
    #expect(result.isError != true)
    let object = try #require(JSONSerialization.jsonObject(with: Data(v100Text(result).utf8)) as? [String: Any])
    let ns = try #require(object["ns"] as? [String: Any])
    #expect(ns["name"] as? String == "mcp__dev_radius")
    #expect(ns["description"] as? String == "Docs")
    #expect(ns["instructions"] as? String == "Search the guide")
    #expect(ns["tools"] as? [String] == [tool.name])
    #expect(object["hits"] as? [String] == [tool.name])
    #expect(object["missing"] == nil)
}

private struct V100Observation: Sendable {
    var baseURLs: [String] = []
    var keys: [String] = []
    var inputs: [[ContentBlock]] = []
    var active = 0
    var maximum = 0
}

private func v100Registry(_ observed: LockedState<V100Observation>, auth: AuthStorage = AuthStorage(":memory:")) -> ModelRegistry {
    let registry = ModelRegistry(auth)
    registry.registerProvider(HookProviderConfig(provider: "scorer", api: .openAICompletions,
        baseUrl: "https://images.test/v1", apiKey: "secret-key",
        images: [.openrouterImages: { model, context, options in
            observed.withLock { value in
                value.baseURLs.append(model.baseUrl); value.keys.append(options?.apiKey ?? "")
                value.inputs.append(context.input); value.active += 1; value.maximum = max(value.maximum, value.active)
            }
            try? await Task.sleep(for: .milliseconds(20))
            observed.withLock { $0.active -= 1 }
            let prompt = context.input.compactMap { if case .text(let text) = $0 { return text.text }; return nil }.first ?? ""
            if prompt == "explode" { return AssistantImages(api: model.api, provider: model.provider, model: model.id, stopReason: .error, errorMessage: "painter exploded") }
            return AssistantImages(api: model.api, provider: model.provider, model: model.id,
                output: [.text(TextContent(text: "painted \(prompt)")), .image(ImageContent(data: v100PNG, mimeType: "image/png"))],
                usage: Usage(input: 100, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 100, cost: UsageCost(total: 0.04)), stopReason: .stop)
        }], classifiers: [.typesafeSystemOne: { model, _, _ in
            observed.withLock { $0.active += 1; $0.maximum = max($0.maximum, $0.active) }
            try? await Task.sleep(for: .milliseconds(20))
            observed.withLock { $0.active -= 1 }
            return ClassifierResult(api: model.api, provider: model.provider, model: model.id, stopReason: .error, errorMessage: "classifier exploded")
        }], models: [
            .image(HookProviderImageModel(id: "painter", api: .openrouterImages, headers: ["X-Secret": "hunter2"])),
            .classifier(HookProviderClassifierModel(id: "judge", api: .typesafeSystemOne, contextWindow: 512)),
            .chat(HookProviderModel(id: "chat")),
        ]), sourceId: "v100")
    return registry
}

private let v100ImageScript = """
const [model] = await models.getAvailableOfType('image','scorer');
const generated = await models.generateImages({...model, baseUrl:'https://evil.test',headers:{Authorization:'evil'}},
    {input:[{type:'text',text:'a fox'},{type:'image',data:'iVBORw0KGgo=',mimeType:'image/png'}]});
for (const block of generated.output) { if (block.type === 'image') image(block); else text(block.text); }
const failed = await models.generateImages(model,{input:[{type:'text',text:'explode'}]});
return {id:model.id,headers:'headers' in model,stopReason:generated.stopReason,failed:[failed.stopReason,failed.errorMessage]};
"""

@Test(.timeLimit(.minutes(1))) func codemodeV100ImagesUseCatalogAuthRowsAndCost() async throws {
    let observed = LockedState(V100Observation())
    let registry = v100Registry(observed)
    let result = try await v100Run(v100ImageScript, context: v100Context(registry), options: .init(models: true))
    #expect(result.isError != true)
    #expect(v100Text(result).hasPrefix("painted a fox\n"))
    #expect(!v100Text(result).contains("script did not show"))
    let images = result.content.compactMap { if case .image(let image) = $0 { return image }; return nil }
    #expect(images.map(\.data) == [v100PNG])
    #expect(images.map(\.mimeType) == ["image/png"])
    #expect(observed.withLock { $0.baseURLs } == ["https://images.test/v1", "https://images.test/v1"])
    #expect(observed.withLock { $0.keys } == ["secret-key", "secret-key"])
    let inputs = observed.withLock { $0.inputs }
    #expect(inputs.first?.count == 2)
    if case .image(let reference)? = inputs.first?.last { #expect(reference.data == v100PNG) } else { Issue.record("Missing reference image") }
    let object = try #require(JSONSerialization.jsonObject(with: Data(v100Text(result).split(separator: "\n").last!.utf8)) as? [String: Any])
    #expect(object["id"] as? String == "painter")
    #expect(object["headers"] as? Bool == false)
    #expect(object["stopReason"] as? String == "stop")
    #expect(object["failed"] as? [String] == ["error", "painter exploded"])
    let rows = try #require((result.details?.value as? [String: Any])?["calls"] as? [[String: Any]])
    #expect(rows.map { $0["id"] as? String } == ["v100/models.generateImages/1", "v100/models.generateImages/2"])
    #expect(rows.map { $0["name"] as? String } == ["models.generateImages", "models.generateImages"])
    #expect(rows.map { $0["args"] as? String } == ["scorer/painter", "scorer/painter"])
    #expect(rows.map { $0["status"] as? String } == ["ok", "error"])
    #expect(rows[0]["cost"] as? Double == 0.04)
    #expect(rows[1]["error"] as? String == "painter exploded")
    #expect(rows.allSatisfy { ($0["durationMs"] as? Double ?? 0) > 0 })
    #expect(result.usage?.input == 100)
    #expect(result.usage?.cost.total == 0.04)
}

@Test(.timeLimit(.minutes(1))) func codemodeV100NotesUnshownImages() async throws {
    let registry = v100Registry(LockedState(V100Observation()))
    let result = try await v100Run("const m=await models.getModelOfType('image','scorer','painter'); const r=await models.generateImages(m,{input:[{type:'text',text:'a fox'}]}); return r.stopReason", context: v100Context(registry), options: .init(models: true))
    #expect(v100Text(result) == "stop\nNote: models.generateImages() returned 1 image that the script did not show. Show each image block of result.output with image(block).")
}

@Test(.timeLimit(.minutes(1))) func codemodeV100SharesModelCallLimit() async throws {
    let observed = LockedState(V100Observation())
    let registry = v100Registry(observed)
    let result = try await v100Run("""
    const imageModel=await models.getModelOfType('image','scorer','painter');
    const classifier=await models.getModelOfType('classifier','scorer','judge');
    await Promise.all(Array.from({length:8},(_,i)=>i%2
        ? models.classify(classifier,{state:{},questions:{q:{type:'bool',instructions:'Yes?',criteria:{true:'yes',false:'no'}}}})
        : models.generateImages(imageModel,{input:[{type:'text',text:'a fox'}]})));
    """, context: v100Context(registry), options: .init(models: true))
    #expect(result.isError != true)
    #expect(observed.withLock { $0.maximum } == 4)
    #expect(result.usage?.input == 400)
    #expect(result.usage?.cost.total == 0.16)
    #expect(v100Text(result).contains("returned 4 images"))
}

@Test(.timeLimit(.minutes(1)), arguments: [
    ("models.getModelsOfType('video')", "Unknown model type \"video\""),
    ("models.getModelsOfType('image',42)", "provider must be a string"),
    ("models.classify({provider:'scorer',id:'nope'},{})", "Unknown classifier model \"scorer/nope\". List the classifier models you can use with models.getAvailableOfType(\"classifier\")."),
    ("models.classify('judge',{})", "models.classify() expects a classifier model as its first argument, got a string."),
    ("models.classify(undefined,{})", "models.getModelOfType() returns undefined for an unknown provider or id."),
    ("models.classify({provider:'scorer',id:'judge'}, {questions:{}})", "models.classify() context.state must be an object, got undefined."),
    ("models.classify({provider:'scorer',id:'judge'}, {state:{},questions:{kind:{type:'choice',instructions:'Kind?',criteria:['a','b']}}})", "context.questions.kind is a \"choice\" question, so criteria must map each label to its meaning."),
    ("models.generateImages({provider:'scorer',id:'painter'}, {prompt:'a fox'})", "models.generateImages() context.input must be a non-empty array of blocks, got undefined."),
    ("models.getModelOfType('classifier','scorer/judge')", "The provider and the id are separate arguments"),
    ("models.generateImages({provider:'scorer',id:'judge'},{input:[]})", "\"scorer/judge\" is a classifier model, not an image model. List the image models you can use with models.getAvailableOfType(\"image\")."),
    ("models.classify({provider:'scorer',id:'painter'}, {})", "\"scorer/painter\" is an image model, not a classifier model."),
    ("models.generateImages({provider:'scorer',id:'chat'}, {})", "\"scorer/chat\" is a chat model, not an image model."),
    ("models.generateImages({provider:'scorer',id:'painter'}, {input:[{type:'image',data:'x'}]})", "context.input[0] must be a text or image block, got { type, data }"),
    ("models.classify({provider:'scorer',id:'judge'}, {state:{},questions:{}})", "context.questions must map question IDs to questions, got {}"),
    ("describeNamespace(42)", "describeNamespace() expects a namespace name"),
    ("searchTools('x',{namespace:42})", "searchTools() namespace must be a string"),
]) func codemodeV100ArgumentErrors(expression: String, expected: String) async throws {
    let registry = v100Registry(LockedState(V100Observation()))
    let result = try await v100Run("try { await \(expression); return 'no error' } catch(e) { return e.message }", context: v100Context(registry), options: .init(models: true))
    #expect(result.isError != true)
    #expect(v100Text(result).contains(expected))
    if expected.contains("context.") {
        #expect(v100Text(result).contains("Expected context:"))
        #expect(v100Text(result).contains(CODEMODE_DOCS_PATH))
    }
    #expect(((result.details?.value as? [String: Any])?["calls"] as? [[String: Any]])?.isEmpty == true)
}

private func v100Response(_ model: Model, script: String? = nil) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()
    let content: [ContentBlock] = script.map { [.toolCall(ToolCall(id: "images", name: "codemode", arguments: ["code": AnyCodable($0)]))] } ?? [.text(TextContent(text: "ok"))]
    let message = AssistantMessage(content: content, api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: script == nil ? .stop : .toolUse)
    stream.push(.done(reason: message.stopReason, message: message)); stream.end(message)
    return stream
}

@Test(.timeLimit(.minutes(1))) func codemodeV100SessionCostAndOnlyPrompt() async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let auth = AuthStorage(":memory:"); auth.setRuntimeApiKey(model.provider, "test")
    let registry = v100Registry(LockedState(V100Observation()), auth: auth)
    let settings = SettingsManager.inMemory()
    // C1 U3: SDK tool-list validation now throws.
    let created = try await createAgentSession(CreateAgentSessionOptions(authStorage: auth, modelRegistry: registry,
        model: model, offline: true, toolNames: ["read", "bash", "edit", "write", "codemode"], resourceLoader: TestResourceLoader(),
        inlineExtensions: [createCodemodeExtension()], sessionManager: .inMemory(), settingsManager: settings))
    let session = created.session
    defer { session.dispose() }
    let count = LockedState(0)
    let requests = LockedState<[TranscriptContext]>([])
    session.agent.streamFn = { model, context, _ in
        requests.withLock { $0.append(context) }
        let n = count.withLock { $0 += 1; return $0 }
        return v100Response(model, script: n == 1 ? v100ImageScript : nil)
    }
    try await session.prompt("make an image")
    #expect(abs(session.getSessionStats().cost - 0.04) < 0.000_001)
    let first = try #require(requests.withLock { $0.first })
    #expect(getCurrentSystemPrompt(first.messages).contains("\n- read: "))
    settings.setCodemodeMode(.only)
    session.setActiveToolsByName(["read", "bash", "edit", "write", "codemode"])
    try await session.prompt("only mode")
    let last = try #require(requests.withLock { $0.last })
    let prompt = getCurrentSystemPrompt(last.messages)
    for name in ["read", "bash", "edit", "write"] {
        #expect(!prompt.contains("\n- \(name): "))
        #expect(!getCurrentTools(last.messages).contains { $0.name == name })
    }
    // v1.0.4 #10343: hidden tool rules move to the codemode declaration.
    #expect(!prompt.contains("Use read to examine files"))
    #expect(session.agent.tools.first { $0.name == "codemode" }?.description.contains("- Use read to examine files instead of cat or sed.") == true)
    #expect(prompt.contains("\n- codemode: "))
    #expect(prompt.contains("codemode scripts and non-LLM models such as classifiers and image models (docs/codemode.md)"))
    #expect(prompt.contains("Codemode script reference: \(CODEMODE_DOCS_PATH)"))
}
