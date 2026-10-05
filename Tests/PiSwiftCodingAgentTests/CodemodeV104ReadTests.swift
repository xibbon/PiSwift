import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private let v104ReadPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="

private func v104ReadText(_ block: ContentBlock) -> String? {
    if case .text(let value) = block { return value.text }
    return nil
}

private func v104ReadDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-v104-read-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

// Upstream v1.0.4 #10251, agent-session-codemode.test.ts:523–540.
@Test(.timeLimit(.minutes(1))) func codemodeV104ReadTextAndImage() async throws {
    let directory = try v104ReadDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try "hello".write(to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    try #require(Data(base64Encoded: v104ReadPNG)).write(to: directory.appendingPathComponent("pixel.png"))
    let read = createReadTool(cwd: directory.path)
    var context = CustomToolContext(
        sessionManager: .inMemory(), modelRegistry: ModelRegistry(AuthStorage(":memory:")), model: nil,
        isIdle: { true }, hasPendingMessages: { false }, abort: {},
        events: createEventBus(), sendMessage: { _, _ in })
    context.setNestedToolHost(tools: [read]) { name, arguments, options in
        let call = AgentToolCall(id: "v104-read/nested", name: name, arguments: arguments)
        do {
            let result = try await read.execute(call.id, arguments, options.signal, options.onUpdate)
            return AgentToolCallOutcome(toolCall: call, result: result, isError: false)
        } catch {
            return AgentToolCallOutcome(toolCall: call,
                result: AgentToolResult(content: [.text(TextContent(text: error.localizedDescription))]), isError: true)
        }
    }
    let result = try await executeCodemode(toolCallId: "v104-read", params: ["code": AnyCodable("""
        text(await tools.read({ path: "notes.txt" }));
        const shot = await tools.read({ path: "pixel.png" });
        text(shot.note);
        image(shot);
        """)], context: context)
    #expect(result.isError != true)
    try #require(result.content.count == 5)
    #expect(v104ReadText(result.content[1]) == "hello")
    #expect(v104ReadText(result.content[2]) == "Read image file [image/png]")
    let label = try #require(v104ReadText(result.content[3]))
    #expect(label.hasPrefix("[Image saved to "))
    #expect(label.hasSuffix("(image/png, 70B)]"))
    let labelEnd = try #require(label.range(of: " (", options: .backwards))
    let savedPath = String(label.dropFirst("[Image saved to ".count).prefix(upTo: labelEnd.lowerBound))
    defer { try? FileManager.default.removeItem(atPath: savedPath) }
    #expect(try Data(contentsOf: URL(fileURLWithPath: savedPath)) == Data(base64Encoded: v104ReadPNG))
    if case .image(let image) = result.content[4] {
        #expect(image.data == v104ReadPNG)
        #expect(image.mimeType == "image/png")
    } else {
        Issue.record("The read image must follow its saved-file label")
    }
}

// Upstream v1.0.4 #10251: all successful read branches set structuredContent.
@Test(arguments: ["text", "blocked", "omitted", "resized", "original"])
func codemodeV104ReadStructuredSuccessBranches(branch: String) async throws {
    let directory = try v104ReadDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let filename = branch == "text" ? "notes.txt" : "pixel.png"
    if branch == "text" {
        try "hello".write(to: directory.appendingPathComponent(filename), atomically: true, encoding: .utf8)
    } else {
        try #require(Data(base64Encoded: v104ReadPNG)).write(to: directory.appendingPathComponent(filename))
    }
    let options = ReadToolOptions(
        autoResizeImages: branch != "original", blockImages: branch == "blocked",
        resizeOptions: branch == "omitted" ? .init(maxBytes: 1) : nil)
    let tool = createReadTool(cwd: directory.path, options: options)
    let result = try await tool.execute("v104-read/branch", ["path": AnyCodable(filename)], nil, nil)
    let note = result.content.compactMap(v104ReadText).first ?? ""
    switch branch {
    case "text":
        #expect(note == "hello")
        #expect(result.structuredContent == AnyCodable(note))
    case "blocked":
        #expect(note == "[Image file detected: \(directory.appendingPathComponent(filename).path)]\nImage reading is disabled. The 'blockImages' setting is enabled.")
        #expect(result.structuredContent == AnyCodable(note))
    case "omitted":
        #expect(note == "Read image file [image/png]\n[Image omitted: could not be resized below the inline image size limit.]")
        #expect(result.structuredContent == AnyCodable(note))
    default:
        #expect(note == "Read image file [image/png]")
        #expect(result.structuredContent == AnyCodable([
            "type": "image", "data": v104ReadPNG, "mimeType": "image/png", "note": note,
        ]))
    }
    // The execution-context path uses the same structured-result helper.
    let executeWithContext = try #require(tool.executeWithContext)
    let contextual = try await executeWithContext("v104-read/context", ["path": AnyCodable(filename)], nil, nil,
                                                 AgentToolExecutionContext(cwd: directory.path))
    #expect(contextual.structuredContent == result.structuredContent)
}

// Upstream v1.0.4 #10251: read output is a one-line union in both codemode modes.
@Test func codemodeV104ReadDeclarations() throws {
    let read = createReadTool(cwd: "/")
    let output = #"string | { data: string; mimeType: string; note: string; type: "image"; }"#
    #expect(renderToolOutputType(CodemodeDeclaration(tool: read).outputSchema) == output)
    let loadout = ToolLoadout(declared: [read], callable: [read], registered: [read],
                              getExposure: { _ in .direct }, getNamespace: { _ in nil },
                              getPromptGuidelines: { _ in ["Use read to examine files instead of cat or sed."] })
    let on = prepareCodemodeLoadout(loadout, options: .init(getMode: { .on }))
    let onDescription = try #require(on.descriptions?["read"])
    #expect(onDescription == read.description + "\n\nCodemode: `tools.read(args)` resolves to `\(output)`.")
    let only = prepareCodemodeLoadout(loadout, options: .init(getMode: { .only }))
    let listing = try #require(only.descriptions?["codemode"])
    let signature = "declare const tools: { read(args: {\n  // Maximum number of lines to read\n  limit?: number;\n  // Line number to start reading from (1-indexed)\n  offset?: number;\n  // Path to the file to read (relative or absolute)\n  path?: string;\n}): Promise<\(output)>; };"
    #expect(listing.contains("### `read`\n" + read.description + "\n\n- Use read to examine files instead of cat or sed.\n\ncodemode tool declaration:\n```ts\n" + signature + "\n```"))
}
