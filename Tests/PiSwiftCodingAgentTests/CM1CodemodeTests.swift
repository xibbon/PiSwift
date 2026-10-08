import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func cm1Text(_ block: ContentBlock) -> String? {
    if case .text(let value) = block { return value.text }
    return nil
}

// Upstream v1.1.0 sandbox.test.ts:54-85: only console calls carry the console flag.
@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func codemodeCM1ConsoleFlags(forceWatchdog: Bool) async throws {
    let result = await CodemodeSandbox.execute(code: """
        console.log('hello', 1, {a:1});
        console.info('info'); console.warn('warn'); console.debug('debug');
        console.error(new Error('bad'));
        try { throw new TypeError('caught'); } catch (error) { console.error(error); }
        text({json:true}); text(undefined); text(7); text('');
        """, tools: [], timeoutMs: 3_000, forceWatchdog: forceWatchdog,
        onCall: { _ in .init(ok: false, payloadJSON: "unexpected call") })
    #expect(result.execution.failure == nil)
    #expect(result.usedWatchdog == !CodemodeSandbox.usesTimeLimit(forceWatchdog: forceWatchdog))
    let items = result.execution.output.compactMap { item -> (String, Bool)? in
        guard case .text(let text, let console) = item else { return nil }
        return (text, console)
    }
    try #require(items.count == 10)
    #expect(items.map { $0.1 } == [true, true, true, true, true, true, false, false, false, false])
    #expect(items.prefix(4).map { $0.0 } == ["hello 1 {\"a\":1}", "info", "warn", "debug"])
    #expect(items[4].0.hasPrefix("Error: bad"))
    #expect(items[5].0.hasPrefix("TypeError: caught"))
    #expect(items.suffix(4).map { $0.0 } == ["{\"json\":true}", "undefined", "7", ""])
}

// Upstream v1.1.0 agent-session-codemode.test.ts:396-418.
@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func codemodeCM1OutputLayout(forceWatchdog: Bool) async throws {
    let result = try await executeCodemode(toolCallId: "cm1-layout", params: ["code": AnyCodable("""
        text("one\\ntwo");
        console.log("a");
        console.log("b");
        text("three\\n");
        return 4;
        """)], forceWatchdog: forceWatchdog)
    #expect(result.isError != true)
    try #require(result.content.count == 2)
    #expect(cm1Text(result.content[0])?.hasPrefix("Script completed\nWall time ") == true)
    #expect(cm1Text(result.content[1]) == "==> text 1/3 <==\none\ntwo\n==> text 2/3 <==\nthree\n==> text 3/3 <==\n4\n<console_output>\na\nb\n</console_output>")
}

// Upstream execute.ts:287-300: empty text and a final newline need no separator.
@Test func codemodeCM1JoinAdjacentText() throws {
    let image = ImageContent(data: "aW1hZ2U=", mimeType: "image/png")
    let output = joinAdjacentCodemodeText([
        .text(TextContent(text: "")), .text(TextContent(text: "first\n")),
        .text(TextContent(text: "second")), .text(TextContent(text: "third")),
        .image(image), .text(TextContent(text: "")), .text(TextContent(text: "last")),
    ])
    try #require(output.count == 3)
    #expect(cm1Text(output[0]) == "first\nsecond\nthird")
    if case .image(let value) = output[1] { #expect(value.data == image.data) }
    else { Issue.record("Missing image between text blocks") }
    #expect(cm1Text(output[2]) == "last")
}

// Upstream execute.ts:502-526: errors and the unshown-image note follow console output.
@Test func codemodeCM1FailureAndNoteLayout() throws {
    let result = formatCodemodeResult(.init(output: [
        .text("a", console: true), .text("partial", console: false), .text("b", console: true)
    ], returnedValue: AnyCodable("unused"), failure: .init(kind: .script, message: "boom", name: "Error")),
        wallTimeSeconds: 1, outputNote: "image note")
    try #require(result.content.count == 2)
    #expect(cm1Text(result.content[1]) == "partial\n<console_output>\na\nb\n</console_output>\nScript error:\nError: boom\n\nNo tool calls were made.\nimage note")
    let consoleOnly = formatCodemodeResult(.init(output: [.text("", console: true)]), wallTimeSeconds: 1)
    #expect(consoleOnly.content.count == 2)
    #expect(cm1Text(consoleOnly.content[1]) == "<console_output>\n\n</console_output>")
}

private func cm1Registry(_ seen: LockedState<[[ImageContent]?]>) -> ModelRegistry {
    let registry = ModelRegistry(AuthStorage(":memory:"))
    registry.registerProvider(HookProviderConfig(provider: "scorer", api: .openAICompletions,
        baseUrl: "https://classifier.test/v1", apiKey: "test-key", classifiers: [.typesafeSystemOne: { model, context, _ in
            seen.withLock { $0.append(context.images) }
            return ClassifierResult(api: model.api, provider: model.provider, model: model.id, stopReason: .stop)
        }], models: [
            .classifier(.init(id: "judge", api: .typesafeSystemOne, contextWindow: 512)),
            .classifier(.init(id: "vision", api: .typesafeSystemOne, input: [.text, .image], contextWindow: 512)),
        ]), sourceId: "cm1")
    return registry
}

private func cm1Classify(_ code: String, registry: ModelRegistry) async throws -> AgentToolResult {
    try await executeCodemode(toolCallId: "cm1-classify", params: ["code": AnyCodable(code)],
                             options: .init(models: true, modelRuntime: registry))
}

private let cm1Questions = "{q:{type:'bool',instructions:'Broken?',criteria:{true:'yes',false:'no'}}}"

// Upstream v1.1.0 agent-session-codemode.test.ts:910-967: a text-only model returns an error row.
@Test(.timeLimit(.minutes(1))) func codemodeCM1ClassifierImagesTextOnlyAndBadBlock() async throws {
    let seen = LockedState<[[ImageContent]?]>([])
    let result = try await cm1Classify("""
        const model = await models.getModelOfType('classifier','scorer','judge');
        const textOnly = await models.classify(model, {state:{text:'good'},
          images:[{type:'image',data:'aW1hZ2U=',mimeType:'image/png'}],questions:\(cm1Questions)});
        let badClassifierImage;
        try { await models.classify(model, {state:{},images:[{data:'aW1hZ2U='}],questions:\(cm1Questions)}); }
        catch(error) { badClassifierImage = error.message; }
        return {textOnly:[textOnly.stopReason,textOnly.errorMessage],badClassifierImage};
        """, registry: cm1Registry(seen))
    #expect(result.isError != true)
    let body = try #require(result.content.last.flatMap(cm1Text))
    let value = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    #expect(value["textOnly"] as? [String] == ["error", "Model scorer/judge does not accept image input"])
    let message = try #require(value["badClassifierImage"] as? String)
    #expect(message.contains("models.classify() context.images[0] must be an image block, got { data }."))
    #expect(message.contains(#"images?: [{ type: "image", data: <base64>, mimeType }]"#))
    let rows = try #require((result.details?.value as? [String: Any])?["calls"] as? [[String: Any]])
    try #require(rows.count == 1)
    #expect(rows[0]["name"] as? String == "models.classify")
    #expect(rows[0]["status"] as? String == "error")
    #expect(rows[0]["error"] as? String == "Model scorer/judge does not accept image input")
    #expect(seen.withLock { $0.isEmpty })
    #expect(result.usage == nil)
}

// Upstream execute.ts:129-143: validate image shape before questions and before the provider call.
@Test(.timeLimit(.minutes(1)), arguments: [
    ("null", "context.images must be an array, got null"),
    ("{}", "context.images must be an array, got {}"),
    ("'x'", "context.images must be an array, got a string"),
    ("[null]", "context.images[0] must be an image block, got null"),
    ("[[]]", "context.images[0] must be an image block, got an empty array"),
    ("[{type:'text',data:'x',mimeType:'image/png'}]", "context.images[0] must be an image block, got { type, data, mimeType }"),
    ("[{type:'image',data:1,mimeType:'image/png'}]", "context.images[0] must be an image block, got { type, data, mimeType }"),
    ("[{type:'image',data:'x',mimeType:1}]", "context.images[0] must be an image block, got { type, data, mimeType }"),
    ("[{type:'image',data:'x',mimeType:'image/png'},{data:'x'}]", "context.images[1] must be an image block, got { data }"),
]) func codemodeCM1InvalidClassifierImages(images: String, expected: String) async throws {
    let seen = LockedState<[[ImageContent]?]>([])
    let result = try await cm1Classify("""
        try { await models.classify({provider:'scorer',id:'vision'}, {state:{},images:\(images),questions:{}}); }
        catch(error) { return error.message; }
        """, registry: cm1Registry(seen))
    #expect(result.isError != true)
    let body = try #require(result.content.last.flatMap(cm1Text))
    #expect(body.contains("models.classify() " + expected + ". Expected context:"))
    #expect(body.contains(CODEMODE_DOCS_PATH))
    #expect(((result.details?.value as? [String: Any])?["calls"] as? [[String: Any]])?.isEmpty == true)
    #expect(seen.withLock { $0.isEmpty })
}

// Upstream execute.ts:129-143: image blocks pass through without base64 or MIME validation.
@Test(.timeLimit(.minutes(1))) func codemodeCM1ClassifierImagesReachProvider() async throws {
    let seen = LockedState<[[ImageContent]?]>([])
    let result = try await cm1Classify("""
        const model = {provider:'scorer',id:'vision'};
        const context = {state:{},questions:\(cm1Questions)};
        await models.classify(model, context);
        await models.classify(model, {...context,images:[]});
        await models.classify(model, {...context,images:[
          {type:'image',data:'aW1hZ2U=',mimeType:'image/png'}, {type:'image',data:'',mimeType:''}]});
        return 'done';
        """, registry: cm1Registry(seen))
    #expect(result.isError != true)
    #expect(result.content.last.flatMap(cm1Text) == "done")
    let contexts = seen.withLock { $0 }
    try #require(contexts.count == 3)
    #expect(contexts[0] == nil)
    #expect(contexts[1]?.isEmpty == true)
    #expect(contexts[2]?.map(\.data) == ["aW1hZ2U=", ""])
    #expect(contexts[2]?.map(\.mimeType) == ["image/png", ""])
}

// Upstream tool-search.test.ts:84-87 and docs/codemode.md v1.1.0.
@Test func codemodeCM1DescriptionAndBundledDocs() throws {
    let description = createCodemodeDescription([])
    for helper in ["await searchTools(query, { limit?, namespace? })", "await describeTool(name)", "await describeNamespace(name)"] {
        #expect(description.contains("`" + helper + "`"))
    }
    #expect(description.contains("With several text items, each starts with a `==> text N/M <==` line, and `console` lines follow the other output in one `<console_output>` block."))
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/PiSwiftCodingAgent/Resources/codemode.md")
    let docs = try String(contentsOf: path, encoding: .utf8)
    #expect(docs.contains("==> text N/M <=="))
    #expect(docs.contains("images?:"))
    #expect(docs.contains("gpt-6-luna"))
    let links = docs.components(separatedBy: "https://github.com/").dropFirst()
    #expect(links.count == 5)
    #expect(links.allSatisfy { $0.hasPrefix("earendil-works/pi/blob/v1.1.0/") })
    #expect(docs.contains("JavaScriptCore"))
    #expect(docs.contains("On iOS, a timed-out script is abandoned"))
    #expect(!docs.contains("256 MB"))
}
