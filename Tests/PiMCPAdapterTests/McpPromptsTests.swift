import Testing
@testable import PiMCPAdapter

@Suite("MCP Prompts")
struct McpPromptsTests {
    @Test("parses quoted positional and named prompt arguments")
    func parsesArguments() {
        let parsed = parsePromptArguments("today topic=\"important tasks\" 'personal notes'")
        #expect(parsed.positional == ["today", "personal notes"])
        #expect(parsed.named == ["topic": "important tasks"])
    }

    @Test("requires declared prompt arguments")
    func requiresArguments() {
        let metadata = PromptMetadata(
            serverName: "demo",
            originalName: "brief",
            commandName: "mcp__demo__brief",
            description: "Brief",
            arguments: [McpPromptArgument(name: "day", required: true)]
        )
        switch resolvePromptArguments(parsePromptArguments(""), metadata: metadata) {
        case .success:
            Issue.record("Expected missing argument failure")
        case .failure(let message):
            #expect(message.contains("day"))
        }
    }

    @Test("formats multiple MCP prompt messages with roles")
    func formatsMessages() {
        let text = formatPromptResult(McpPromptResult(messages: [
            McpPromptMessage(role: "user", content: [McpContent(type: "text", text: "Question")]),
            McpPromptMessage(role: "assistant", content: [McpContent(type: "text", text: "Answer")]),
        ]))
        #expect(text == "[user] Question\n\n[assistant] Answer")
    }
}
