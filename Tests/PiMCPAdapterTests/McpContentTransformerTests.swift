import Testing
import Foundation
import PiSwiftAI
@testable import PiMCPAdapter

@Suite("Content Transformer")
struct ContentTransformerTests {
    @Test("Text content")
    func textContent() {
        let content = [McpContent(type: "text", text: "Hello world")]
        let blocks = transformMcpContent(content)
        #expect(blocks.count == 1)
        if case .text(let tc) = blocks[0] {
            #expect(tc.text == "Hello world")
        } else {
            Issue.record("Expected text block")
        }
    }

    @Test("Text content with nil text")
    func textNilContent() {
        let content = [McpContent(type: "text")]
        let blocks = transformMcpContent(content)
        if case .text(let tc) = blocks[0] {
            #expect(tc.text == "")
        } else {
            Issue.record("Expected text block")
        }
    }

    @Test("Image content")
    func imageContent() {
        let content = [McpContent(type: "image", data: "base64data", mimeType: "image/jpeg")]
        let blocks = transformMcpContent(content)
        if case .image(let ic) = blocks[0] {
            #expect(ic.data == "base64data")
            #expect(ic.mimeType == "image/jpeg")
        } else {
            Issue.record("Expected image block")
        }
    }

    @Test("Image content defaults to image/png")
    func imageDefaultMime() {
        let content = [McpContent(type: "image", data: "abc")]
        let blocks = transformMcpContent(content)
        if case .image(let ic) = blocks[0] {
            #expect(ic.mimeType == "image/png")
        } else {
            Issue.record("Expected image block")
        }
    }

    @Test("Resource content")
    func resourceContent() {
        let resource = McpResourceContent(uri: "file:///test.txt", text: "file contents")
        let content = [McpContent(type: "resource", resource: resource, uri: "file:///test.txt")]
        let blocks = transformMcpContent(content)
        if case .text(let tc) = blocks[0] {
            #expect(tc.text.contains("[Resource: file:///test.txt]"))
            #expect(tc.text.contains("file contents"))
        } else {
            Issue.record("Expected text block")
        }
    }

    @Test("Resource link content")
    func resourceLinkContent() {
        let content = [McpContent(type: "resource_link", uri: "https://example.com", name: "Example")]
        let blocks = transformMcpContent(content)
        if case .text(let tc) = blocks[0] {
            #expect(tc.text.contains("[Resource Link: Example]"))
            #expect(tc.text.contains("URI: https://example.com"))
        } else {
            Issue.record("Expected text block")
        }
    }

    @Test("Audio content")
    func audioContent() {
        let content = [McpContent(type: "audio", mimeType: "audio/mp3")]
        let blocks = transformMcpContent(content)
        if case .text(let tc) = blocks[0] {
            #expect(tc.text.contains("audio/mp3"))
        } else {
            Issue.record("Expected text block")
        }
    }

    @Test("Unknown content type")
    func unknownContent() {
        let content = [McpContent(type: "custom_widget")]
        let blocks = transformMcpContent(content)
        #expect(blocks.count == 1)
        if case .text(let tc) = blocks[0] {
            #expect(tc.text.contains("custom_widget"))
        } else {
            Issue.record("Expected text block")
        }
    }

    @Test("Multiple content items")
    func multipleContent() {
        let content = [
            McpContent(type: "text", text: "first"),
            McpContent(type: "text", text: "second"),
            McpContent(type: "image", data: "img", mimeType: "image/png"),
        ]
        let blocks = transformMcpContent(content)
        #expect(blocks.count == 3)
    }

    @Test("Empty content array")
    func emptyContent() {
        let blocks = transformMcpContent([])
        #expect(blocks.isEmpty)
    }

    @Test("Structured content is used when a tool result has no content blocks")
    func structuredContentFallback() {
        let blocks = resolveMcpResultContent(McpToolResult(
            content: [],
            structuredContent: AnyCodable(["answer": 42] as [String: Any])
        ))
        guard case .text(let text) = blocks.first else {
            Issue.record("Expected structured content text")
            return
        }
        #expect(text.text.contains("answer"))
        #expect(text.text.contains("42"))
    }
}
