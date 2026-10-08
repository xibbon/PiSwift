import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftMCP
@testable import PiSwiftCodingAgent

private let c1ImagePNG = "iVBORw0KGgo="

private func c1ImageText(_ block: ContentBlock) -> String? {
    if case .text(let item) = block { return item.text }
    return nil
}

private func c1ImagePath(_ block: ContentBlock) throws -> String {
    let label = try #require(c1ImageText(block))
    #expect(label.hasPrefix("[Image saved to "))
    let end = try #require(label.range(of: " (", options: .backwards))
    return String(label.dropFirst("[Image saved to ".count).prefix(upTo: end.lowerBound))
}

private func c1ImageContext() -> CustomToolContext {
    CustomToolContext(sessionManager: .inMemory(), modelRegistry: ModelRegistry(AuthStorage(":memory:")), model: nil,
                      isIdle: { true }, hasPendingMessages: { false }, abort: {},
                      events: createEventBus(), sendMessage: { _, _ in })
}

// Upstream v1.0.3 #10310: keep explicit image order and save repeated data once.
@Test(.timeLimit(.minutes(1))) func c1CodemodeImageExplicitOrderAndDuplicateFile() async throws {
    let screenshot = AgentTool(label: "screenshot", name: "screenshot", description: "Screenshot", parameters: [:]) {
        _, _, _, _ in AgentToolResult(content: [])
    }
    var context = c1ImageContext()
    context.setNestedToolHost(tools: [screenshot]) { name, args, _ in
        let result = AgentToolResult(content: [.text(TextContent(text: "captured")),
                                              .image(ImageContent(data: c1ImagePNG, mimeType: "image/png"))])
        return AgentToolCallOutcome(toolCall: .init(id: "c1-image/1", name: name, arguments: args), result: result, isError: false)
    }
    let result = try await executeCodemode(toolCallId: "c1-image", params: ["code": AnyCodable("""
        text(await tools.screenshot({}));
        image('data:image/png;base64,\(c1ImagePNG)');
        image('data:image/png;base64,\(c1ImagePNG)');
        text('after');
        """)], context: context)
    // Upstream v1.1.0 agent-session-codemode.test.ts:382-393: join text and label.
    #expect(result.content.count == 6)
    let first = try #require(c1ImageText(result.content[1]))
    let label = try #require(first.components(separatedBy: "\n").last)
    #expect(first == "==> text 1/2 <==\ncaptured\n" + label)
    let path = try c1ImagePath(result.content[3])
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(label == c1ImageText(result.content[3]))
    #expect(try c1ImagePath(.text(TextContent(text: label))) == path)
    for index in [2, 4] {
        if case .image(let image) = result.content[index] { #expect(image.data == c1ImagePNG) }
        else { Issue.record("Missing image after path label") }
    }
    #expect(c1ImageText(result.content[5]) == "==> text 2/2 <==\nafter")
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data(base64Encoded: c1ImagePNG))
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test(.timeLimit(.minutes(1)), arguments: [
    ("iVBORw0KGgo=", "image/png", ".png"),
    ("/9j/4A==", "image/jpeg", ".jpg"),
    ("R0lGODlh", "image/gif", ".gif"),
    ("UklGRgAAAABXRUJQ", "image/webp", ".webp"),
]) func c1CodemodeImageFilesUseDetectedExtension(data: String, mime: String, fileExtension: String) async throws {
    let result = try await executeCodemode(toolCallId: "c1-extension", params: ["code": AnyCodable("image('data:image/png;base64,\(data)')")])
    #expect(result.content.count == 3)
    let path = try c1ImagePath(result.content[1])
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(path.range(of: "pi-codemode-[0-9a-f]{16}\\" + fileExtension + "$", options: .regularExpression) != nil)
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data(base64Encoded: data))
    #expect(c1ImageText(result.content[1])?.hasSuffix("(\(mime), \(formatSize(Data(base64Encoded: data)!.count)))]") == true)
    #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func c1CodemodeImageLabelsFollowTruncationAndPrivateTextSpill() throws {
    let text = String(repeating: "long output\n", count: 100)
    let result = try formatCodemodeResultForExecution(.init(output: [.text(TextContent(text: text)),
                      .image(ImageContent(data: c1ImagePNG, mimeType: "image/png"))]),
                      wallTimeSeconds: 1, maxOutputTokens: 10)
    let details = try #require(result.details?.value as? [String: Any])
    let textPath = try #require(details["fullOutputPath"] as? String)
    // Upstream v1.1.0 agent-session-codemode.test.ts:533-535: label joins truncated text.
    let label = try #require(c1ImageText(result.content[1])?.components(separatedBy: "\n").last)
    let imagePath = try c1ImagePath(.text(TextContent(text: label)))
    defer {
        try? FileManager.default.removeItem(atPath: textPath)
        try? FileManager.default.removeItem(atPath: imagePath)
    }
    #expect(result.content.count == 3)
    #expect(c1ImageText(result.content[1])?.contains("tokens truncated") == true)
    #expect(try String(contentsOfFile: textPath, encoding: .utf8) == text)
    #expect((try FileManager.default.attributesOfItem(atPath: textPath)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(textPath.range(of: #"pi-codemode-[0-9a-f]{16}\.txt$"#, options: .regularExpression) != nil)
    if case .image = result.content[2] {} else { Issue.record("Image must follow its untruncated label") }
}

private enum C1ImageWriteFailure: Error, LocalizedError {
    case unavailable
    var errorDescription: String? { "test output directory is unavailable" }
}

@Test func c1CodemodeImageWriteFailureKeepsResultAndReusesLabel() throws {
    var attempts = 0
    let image = ContentBlock.image(ImageContent(data: c1ImagePNG, mimeType: "image/png"))
    let result = try formatCodemodeResultForExecution(.init(output: [image, image], returnedValue: AnyCodable(42)),
                     wallTimeSeconds: 1, imageWriter: { _, _ in
        attempts += 1
        throw C1ImageWriteFailure.unavailable
    })
    #expect(attempts == 1)
    #expect(result.isError != true)
    #expect(result.content.count == 6)
    #expect(c1ImageText(result.content[1]) == "[Image (image/png, 8B) could not be saved: test output directory is unavailable]")
    #expect(c1ImageText(result.content[1]) == c1ImageText(result.content[3]))
    #expect(c1ImageText(result.content[5]) == "42")
    for index in [2, 4] {
        if case .image(let item) = result.content[index] { #expect(item.data == c1ImagePNG) }
        else { Issue.record("Write failure discarded image") }
    }
}

@Test func c1CodemodeImageDataOnlyDeduplicationAndPerResultScope() throws {
    var attempts = 0
    let images: [ContentBlock] = [
        .image(ImageContent(data: c1ImagePNG, mimeType: "image/png")),
        .image(ImageContent(data: c1ImagePNG, mimeType: "image/jpeg")),
        .image(ImageContent(data: c1ImagePNG, mimeType: "image/unknown")),
    ]
    let writer: CodemodeImageWriter = { _, fileExtension in
        attempts += 1
        #expect(fileExtension == ".png")
        return "/tmp/test-image.png"
    }
    for _ in 0..<2 {
        let result = try formatCodemodeResultForExecution(.init(output: images), wallTimeSeconds: 1, imageWriter: writer)
        #expect(c1ImageText(result.content[1]) == c1ImageText(result.content[3]))
        #expect(c1ImageText(result.content[1]) == c1ImageText(result.content[5]))
    }
    #expect(attempts == 2)
}

@Test func c1CodemodeImageUnknownMIMEThrowsInternallyAndKeepsPublicCompatibility() throws {
    let execution = CodemodeExecutionResult(output: [.image(ImageContent(data: c1ImagePNG, mimeType: "image/unknown"))])
    var attempts = 0
    #expect(throws: CodemodeImageError.unsupportedMIME("image/unknown")) {
        try formatCodemodeResultForExecution(execution, wallTimeSeconds: 1, imageWriter: { _, _ in
            attempts += 1
            return "/tmp/unexpected"
        })
    }
    #expect(attempts == 0)
    let result = formatCodemodeResult(execution, wallTimeSeconds: 1)
    #expect(result.content.count == 2)
    #expect(result.isError != true)
    if case .image(let image) = result.content[1] { #expect(image.mimeType == "image/unknown") }
    else { Issue.record("Public formatter discarded an unsupported image") }
}

@Test(arguments: [(1023, "1023B"), (1024, "1.0KB"), (1024 * 1024, "1.0MB")])
func c1CodemodeImageLabelUsesDecodedSize(count: Int, size: String) throws {
    let bytes = Data(repeating: 0, count: count)
    let result = try formatCodemodeResultForExecution(.init(output: [
        .image(ImageContent(data: bytes.base64EncodedString(), mimeType: "image/png"))
    ]), wallTimeSeconds: 1, imageWriter: { data, fileExtension in
        #expect(data == bytes)
        #expect(fileExtension == ".png")
        return "/tmp/test-size.png"
    })
    #expect(c1ImageText(result.content[1]) == "[Image saved to /tmp/test-size.png (image/png, \(size))]")
}

// Upstream v1.0.3 agent-session-mcp.test.ts:215–280: MCP images shown by image() gain a saved path.
@Test(.timeLimit(.minutes(1))) func c1CodemodeImageMCPResultHasSavedPathBeforeImageAndJSON() async throws {
    let tool = AgentTool(label: "MCP image", name: "mcp__test__image", description: "Image", parameters: [:],
                         execute: { _, _, _, _ in AgentToolResult(content: []) },
                         outputSchema: mcpResultSchema(nil))
    var context = c1ImageContext()
    context.setNestedToolHost(tools: [tool]) { name, args, _ in
        let result = await convertMcpResult(server: "test", tool: "image", result: McpToolResult(content: [
            .init(type: "image", data: c1ImagePNG, mimeType: "image/png")
        ], structuredContent: AnyCodable(["ok": true])))
        return AgentToolCallOutcome(toolCall: .init(id: "c1-mcp/1", name: name, arguments: args), result: result, isError: false)
    }
    let result = try await executeCodemode(toolCallId: "c1-mcp", params: ["code": AnyCodable("""
        const result = await tools.mcp__test__image({});
        image(result.content[0]);
        return result.structuredContent;
        """)], context: context)
    #expect(result.content.count == 4)
    let path = try c1ImagePath(result.content[1])
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data(base64Encoded: c1ImagePNG))
    if case .image(let image) = result.content[2] { #expect(image.mimeType == "image/png") }
    else { Issue.record("MCP image must follow saved path") }
    #expect(c1ImageText(result.content[3]) == "{\"ok\":true}")
}
