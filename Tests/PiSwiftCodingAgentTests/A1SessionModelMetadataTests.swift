import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

@Test func sessionRoundTripsThinkingLevelAndNestedToolCalls() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("a1-session-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let manager = SessionManager.create(directory.path, directory.path)
    let usage = Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0)
    manager.appendMessage(.user(UserMessage(content: .text("start"))))
    manager.appendMessage(.assistant(AssistantMessage(content: [], api: .openAIResponses,
        provider: "openai", model: "gpt-test", usage: usage, stopReason: .toolUse,
        thinkingLevel: .high)))
    manager.appendMessage(.toolResult(ToolResultMessage(toolCallId: "outer", toolName: "script",
        content: [.text(TextContent(text: "done"))],
        nestedCalls: NestedToolCalls(calls: [NestedToolCallRecord(
            id: "inner", name: "read", argumentsBytes: 2000, status: .ok,
            durationMs: 3.5)], complete: false), isError: false)))

    let file = try #require(manager.getSessionFile())
    let messages = loadEntriesFromFile(file).compactMap { entry -> AgentMessage? in
        guard case .entry(.message(let message)) = entry else { return nil }
        return message.message
    }
    let assistant = try #require(messages.compactMap { message -> AssistantMessage? in
        guard case .assistant(let value) = message else { return nil }
        return value
    }.first)
    let tool = try #require(messages.compactMap { message -> ToolResultMessage? in
        guard case .toolResult(let value) = message else { return nil }
        return value
    }.first)
    #expect(assistant.thinkingLevel == .high)
    #expect(tool.nestedCalls?.calls.first?.argumentsBytes == 2000)
    #expect(tool.nestedCalls?.calls.first?.durationMs == 3.5)
    #expect(tool.nestedCalls?.complete == false)
}
