import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

private func schema(_ value: Any) -> AnyCodable { AnyCodable(value) }

private func codemodeText(_ block: ContentBlock) -> String? {
    if case .text(let value) = block { return value.text }
    return nil
}

private func codemodeTestTool(_ name: String, _ description: String, properties: [String: Any] = [:],
                              outputSchema: [String: AnyCodable]? = nil) -> AgentTool {
    AgentTool(label: name, name: name, description: description,
              parameters: ["type": AnyCodable("object"), "properties": AnyCodable(properties)],
              execute: { _, _, _, _ in AgentToolResult(content: []) }, outputSchema: outputSchema)
}

@Test func codemodeIdentifiersMatchUpstream() {
    #expect(toCodemodeIdentifier("mcp__docs__search") == "mcp__docs__search")
    #expect(toCodemodeIdentifier("my-tool") == "my_tool")
    #expect(toCodemodeIdentifier("1🙂-x") == "___x")
    #expect(toCodemodeIdentifier("") == "_")
    #expect(toCodemodeIdentifier("$a_1") == "$a_1")
}

@Test func codemodeSchemaPrimitivesAndUnionsMatchUpstream() {
    #expect(schemaToType(schema(["type": "string"])) == "string")
    #expect(schemaToType(schema(["type": "integer"])) == "number")
    #expect(schemaToType(schema(["type": ["string", "null"]])) == "string | null")
    #expect(schemaToType(schema(["const": "a"])) == "\"a\"")
    #expect(schemaToType(schema(["enum": ["a", 1, NSNull()] as [Any]])) == "\"a\" | 1 | null")
    #expect(schemaToType(schema(["anyOf": [["type": "string"], ["type": "number"]]])) == "string | number")
    #expect(schemaToType(schema(["anyOf": [["type": "string"], [:]]])) == "unknown")
    #expect(schemaToType(schema(["allOf": [["anyOf": [["type": "string"], ["type": "number"]]], ["const": 1]]])) == "(string | number) & 1")
    #expect(schemaToType(schema(["$ref": "#/defs/x"])) == "unknown")
    #expect(schemaToType(schema(true)) == "unknown")
    #expect(schemaToType(schema(false)) == "never")
}

@Test func codemodeSchemaObjectsCommentsAndTuplesMatchUpstream() {
    let simple: [String: Any] = [
        "type": "object", "properties": ["city": ["type": "string"], "max-lines": ["type": "number"]],
        "required": ["city"], "additionalProperties": false
    ]
    #expect(schemaToType(schema(simple)) == #"{ city: string; "max-lines"?: number; }"#)
    #expect(schemaToType(schema(["type": "object", "additionalProperties": ["type": "number"]])) == "{ [key: string]: number; }")
    #expect(schemaToType(schema(["type": "object"])) == "{ [key: string]: unknown; }")
    #expect(schemaToType(schema(["type": "object", "properties": [:], "additionalProperties": false])) == "{}")
    let described: [String: Any] = ["type": "object", "properties": [
        "weather": ["type": "array", "description": "look up weather for a given list of locations",
                    "items": ["type": "object", "properties": ["location": ["type": "string"]], "required": ["location"]]]
    ], "required": ["weather"]]
    #expect(schemaToType(schema(described)) == "{\n  // look up weather for a given list of locations\n  weather: Array<{ location: string; }>;\n}")
    let nested: [String: Any] = ["type": "object", "properties": [
        "outer": ["type": "object", "description": "Outer", "properties": [
            "inner": ["type": "string", "description": "Inner"]]]
    ]]
    #expect(schemaToType(schema(nested)) == "{\n  // Outer\n  outer?: {\n    // Inner\n    inner?: string;\n  };\n}")
    #expect(schemaToType(schema(["type": "array", "items": ["type": "string"]])) == "Array<string>")
    #expect(schemaToType(schema(["type": "array", "prefixItems": [["type": "string"], ["type": "number"]]])) == "[string, number]")
    #expect(schemaToType(schema(["type": "array"])) == "unknown[]")
}

@Test func codemodeReferencesAndSizeGuardMatchUpstream() {
    let root: [String: Any] = ["type": "object", "properties": [
        "item": ["$ref": "#/$defs/Item"], "legacy": ["$ref": "#/definitions/Legacy"],
        "remote": ["$ref": "https://example.com/schema.json"]
    ], "required": ["item"], "$defs": ["Item": ["type": "object", "properties": [
        "id": ["type": "string"], "parent": ["$ref": "#/$defs/Item"]], "required": ["id"]]],
        "definitions": ["Legacy": ["enum": ["a", "b"]]]]
    #expect(schemaToType(schema(root)) == #"{ item: { id: string; parent?: unknown; }; legacy?: "a" | "b"; remote?: unknown; }"#)
    let fields = Dictionary(uniqueKeysWithValues: (0..<50).map { ("field\($0)", ["type": "string"]) })
    let many = schema(["type": "object", "properties": fields])
    #expect(schemaToType(many, maxChars: 100) == "unknown")
    #expect(schemaToType(many).contains("field49?: string;"))
    let chain: [String: Any] = ["$ref": "#/$defs/A", "$defs": ["A": ["type": "string"]]]
    #expect(schemaToType(schema(chain)) == "string")
    var definitions: [String: Any] = [:]
    for index in 0..<33 {
        definitions["item\(index)"] = index == 32 ? ["type": "string"] : ["$ref": "#/$defs/item\(index + 1)"]
    }
    #expect(schemaToType(schema(["$ref": "#/$defs/item0", "$defs": definitions])) == "unknown")
    let large = Dictionary(uniqueKeysWithValues: (0..<1_000).map { ("field\($0)", ["type": "string"]) })
    #expect(renderToolSignature(.init(name: "large", inputSchema: schema(["type": "object", "properties": large]))) ==
            "large(args: unknown): Promise<unknown>;")
}

@Test func codemodeDeclarationsMatchUpstream() {
    let input = schema(["type": "object", "properties": ["city": ["type": "string"]],
                        "required": ["city"], "additionalProperties": false])
    let output = schema(["type": "object", "properties": ["ok": ["type": "boolean"]], "required": ["ok"]])
    #expect(renderToolSignature(.init(name: "hidden-dynamic-tool", inputSchema: input, outputSchema: output)) ==
            "hidden_dynamic_tool(args: { city: string; }): Promise<{ ok: boolean; }>;")
    #expect(renderToolSignature(.init(name: "free")) == "free(args: unknown): Promise<unknown>;")
    #expect(renderToolSample(.init(name: "foo", description: "bar", inputSchema: schema(["type": "string"]))) ==
            "bar\n\ncodemode tool declaration:\n```ts\ndeclare const tools: { foo(args: string): Promise<unknown>; };\n```")
    let declarations = renderDeclarations(tools: [
        .init(name: "read", description: "Read a file.\nSecond line.",
              inputSchema: schema(["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]]),
              outputSchema: schema(["type": "string"])),
        .init(name: "remote-api")
    ], globals: [.init(name: "attach", description: "Attach it.", inputSchema: schema(["type": "string"]))])
    #expect(declarations == "declare const tools: {\n  /**\n   * Read a file.\n   * Second line.\n   */\n  read(args: { path: string; }): Promise<string>;\n  remote_api(args: unknown): Promise<unknown>;\n};\n\n/** Attach it. */\ndeclare function attach(args: string): Promise<unknown>;")
    #expect(renderDeclarations(tools: [.init(name: "x", description: "a */ b")]).contains("/** a *\\/ b */"))
    #expect(renderDeclarations(globals: [
        .init(name: "models.list", description: "List models.", signature: "(type: string): Promise<string[]>"),
        .init(name: "models.get", inputSchema: schema(["type": "string"])),
        .init(name: "plain", signature: "(): void")
    ]) == "declare function plain(): void;\n\ndeclare const models: {\n  /** List models. */\n  list(type: string): Promise<string[]>;\n  get(args: string): Promise<unknown>;\n};")
}

@Test func codemodeMcpResultMatchesUpstream() {
    let result: [String: Any] = ["type": "object", "properties": [
        "content": ["type": "array", "items": ["type": "object"]],
        "isError": ["type": "boolean"], "_meta": ["type": "object"],
        "structuredContent": ["type": "object", "properties": ["results": ["type": "array", "items": ["type": "string"]]],
                              "required": ["results"]]
    ]]
    #expect(mcpStructuredContentSchema(schema(result)) != nil)
    #expect(renderToolSignature(.init(name: "mcp__sample__search", inputSchema: schema(["type": "object", "properties": [:], "additionalProperties": false]),
                                     outputSchema: schema(result))) ==
            "mcp__sample__search(args: {}): Promise<CallToolResult<{ results: Array<string>; }>>;")
    #expect(mcpTypescriptPreamble.contains("type CallToolResult<TStructured"))
    let refResult: [String: Any] = ["type": "object", "properties": [
        "content": ["type": "array", "items": ["type": "object"]],
        "isError": ["type": "boolean"], "_meta": ["type": "object"],
        "structuredContent": ["type": "object", "properties": ["results": ["type": "array", "items": ["$ref": "#/definitions/Result~1item~0v1"]]],
                              "required": ["results"], "additionalProperties": false,
                              "definitions": ["Result/item~v1": ["type": "object", "properties": [
                                  "id": ["type": "string"], "score": ["type": "number"]],
                                  "required": ["id", "score"], "additionalProperties": false]]]
    ]]
    #expect(renderToolSignature(.init(name: "mcp__sample__search", inputSchema: schema(["type": "object", "properties": [:], "additionalProperties": false]),
                                     outputSchema: schema(refResult))) ==
            "mcp__sample__search(args: {}): Promise<CallToolResult<{ results: Array<{ id: string; score: number; }>; }>>;")
}

@Test func codemodeSourceVectorsMatchUpstream() throws {
    #expect(try parseCodemodeSource("text('hi')") == .init(code: "text('hi')", options: .init()))
    #expect(try parseCodemodeSource("// just a comment\nreturn 1").code == "// just a comment\nreturn 1")
    #expect(try parseCodemodeSource("// @options: {\"timeout_ms\": 10}\nconst a = 1;\ntext(a)") ==
            .init(code: "\nconst a = 1;\ntext(a)", options: .init(timeoutMs: 10)))
    #expect(try parseCodemodeSource("  // @options:{\"max_output_tokens\":0,\"timeout_ms\":1500}\r\ntext(1)").options ==
            .init(maxOutputTokens: 0, timeoutMs: 1500))
    #expect(try parseCodemodeSource("// @options: {}\ntext(1)").code == "\ntext(1)")
    #expect(try parseCodemodeSource("text(1)\n// @options: {\"timeout_ms\": 1}").options == .init())
    #expect(codemodeSourceGrammar == "\nstart: options_source | plain_source\noptions_source: OPTIONS_LINE NEWLINE SOURCE\nplain_source: SOURCE\n\nOPTIONS_LINE: /[ \\t]*\\/\\/ @options:[^\\r\\n]*/\nNEWLINE: /\\r?\\n/\nSOURCE: /[\\s\\S]+/\n")
    let invalid = ["", "  \n", "// @options:\ntext(1)", "// @options: [1]\ntext(1)",
                   "// @options: {\"yield\":1}\ntext(1)", "// @options: {\"max_output_tokens\":1.5}\ntext(1)",
                   "// @options: {\"timeout_ms\":0}\ntext(1)", "// @options: {\"timeout_ms\":1}"]
    for input in invalid { #expect(throws: CodemodeSourceError.self) { try parseCodemodeSource(input) } }
}

@Test func codemodeDescriptionCatalogMatchesUpstream() {
    let plain = codemodeTestTool("read_notes", "Read notes.")
    let github = ["a", "b", "c"].map { codemodeTestTool("mcp__github__\($0)", "GitHub \($0).") }
    let docs = [codemodeTestTool("mcp__docs__search", "Search docs."),
                codemodeTestTool("mcp__docs__long", String(repeating: "Long ", count: 200))]
    let all = [plain] + github + docs
    var namespaces: [String: ToolNamespace] = [:]
    for tool in github { namespaces[tool.name] = ToolNamespace(name: "mcp__github", description: "GitHub server") }
    for tool in docs { namespaces[tool.name] = ToolNamespace(name: "mcp__docs") }
    let complete = createCodemodeDescription(all, options: .init(namespaces: namespaces, inlineBudget: nil))
    // Upstream CM6: lean catalog, no counts, no deferred namespace sections.
    #expect(complete.contains("Nested tools:"))
    #expect(complete.contains("## mcp__github\nGitHub server"))
    let partial = createCodemodeDescription(all, options: .init(namespaces: namespaces, inlineBudget: 170))
    #expect(partial.contains("Nested tools:"))
    #expect(partial.contains("## mcp__docs (some tools not listed)"))
    #expect(partial.contains("## mcp__github (some tools not listed)"))
    #expect(!partial.contains("### `mcp__docs__long`"))
    let deferred = createCodemodeDescription(all, options: .init(namespaces: namespaces,
        deferred: Set(github.map(\.name)), inlineBudget: nil))
    #expect(deferred.contains("Nested tools:"))
    #expect(!deferred.contains("## mcp__github"))
    let zero = createCodemodeDescription(all, options: .init(namespaces: namespaces, inlineBudget: 0))
    #expect(zero.contains("Nested tools:"))
    #expect(!zero.contains("codemode tool declaration:"))
    #expect(!complete.contains("256 MB memory limit"))
    #expect(createCodemodeDescription([]).contains("JavaScriptCore sandbox"))
    let mcp = codemodeTestTool("mcp__x__call", "Call MCP.", outputSchema: [
        "type": AnyCodable("object"), "properties": AnyCodable([
            "content": ["type": "array", "items": ["type": "object"]],
            "isError": ["type": "boolean"], "_meta": ["type": "object"]] as [String: Any])])
    let withAPIs = createCodemodeDescription([mcp], options: .init(models: true))
    #expect(withAPIs.contains("Shared MCP Types:\n```ts\n\(mcpTypescriptPreamble)\n```"))
    #expect(withAPIs.contains("- `models`: classifiers and image generation. Read \(CODEMODE_DOCS_PATH) first."))
    #expect(!withAPIs.contains("declare const models: {"))
}

@Test func codemodeSettingsAndResultsMatchUpstream() throws {
    let manager = SettingsManager.inMemory()
    #expect(manager.getCodemodeMode() == .on)
    #expect(manager.getCodemodeInlineBudget() == 3_000)
    manager.setCodemodeMode(.only)
    manager.setCodemodeInlineBudget(0)
    #expect(manager.getCodemodeMode() == .only)
    #expect(manager.getCodemodeInlineBudget() == 0)
    manager.setCodemodeInlineBudget(-1)
    manager.setCodemodeInlineBudget(.infinity)
    #expect(manager.getCodemodeInlineBudget() == 0)
    var overrides = Settings()
    overrides.codemode = CodemodeSettings(mode: .on, inlineBudget: 170)
    manager.applyOverrides(overrides)
    #expect(manager.getCodemodeMode() == .on)
    #expect(manager.getCodemodeInlineBudget() == 170)

    let call = CodemodeNestedCall(id: "outer/1", name: "echo", args: String(repeating: "x", count: 220), status: .ok,
                                  durationMs: 12, error: String(repeating: "e", count: 510))
    #expect(call.args.count == 200)
    #expect(call.error?.count == 500)
    let failure = formatCodemodeResult(.init(output: [.text(TextContent(text: "partial"))],
                                              failure: .init(kind: .script, message: "boom", name: "Error")),
                                       calls: [call], wallTimeSeconds: 0.25)
    #expect(codemodeText(failure.content[0]) == "Script failed\nWall time 0.2 seconds\nOutput:\n")
    #expect(codemodeText(failure.content[2]) == "Script error:\nError: boom\n\nTool calls made before the failure (they are not undone): echo (ok)")
    #expect(failure.isError == true)

    let rows = (0..<100).map { ContentBlock.text(TextContent(text: "row \($0)")) }
    let long = formatCodemodeResult(.init(output: rows + [.image(ImageContent(data: "AAAA", mimeType: "image/png"))]),
                                    wallTimeSeconds: 1, maxOutputTokens: 10)
    guard let details = long.details?.value as? [String: Any], let path = details["fullOutputPath"] as? String else {
        Issue.record("Missing spill file")
        return
    }
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(path.range(of: #"pi-codemode-[0-9a-f]{16}\.txt$"#, options: .regularExpression) != nil)
    #expect(try String(contentsOfFile: path, encoding: .utf8) == (0..<100).map { "row \($0)" }.joined(separator: "\n"))
    #expect(codemodeText(long.content[1])?.contains("tokens truncated") == true)
    #expect(codemodeText(long.content[1])?.contains("[Full output: \(path) (read with offset/limit)]") == true)
    if case .image(let image) = long.content.last { #expect(image.data == "AAAA") }
    else { Issue.record("Image did not follow truncated text") }
}

@Test func codemodeSettingsPersistAndRejectInvalidBudget() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-codemode-settings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = SettingsManager.create(directory.path, directory.path)
    manager.setCodemodeMode(.only)
    manager.setCodemodeInlineBudget(75)
    let path = directory.appendingPathComponent("settings.json")
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
    let codemode = json?["codemode"] as? [String: Any]
    #expect(codemode?["mode"] as? String == "only")
    #expect(codemode?["inlineBudget"] as? Double == 75)
    let reloaded = SettingsManager.create(directory.path, directory.path)
    #expect(reloaded.getCodemodeMode() == .only)
    #expect(reloaded.getCodemodeInlineBudget() == 75)
    try #"{"codemode":{"mode":"only","inlineBudget":-1}}"#.write(to: path, atomically: true, encoding: .utf8)
    #expect(SettingsManager.create(directory.path, directory.path).getCodemodeInlineBudget() == 3_000)
}
