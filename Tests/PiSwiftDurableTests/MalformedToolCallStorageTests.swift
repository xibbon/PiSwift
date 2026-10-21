import Testing
import PiSwiftAI
import PiSwiftDurable

@Test func durableStorageKeepsMalformedToolCall() async throws {
    var call = ToolCall(id: "invalid-call", name: "optional", arguments: [:])
    call.finalizeArguments(from: #"{"value":1} trailing"#)
    let error = try #require(call.argumentsError)
    let message = AssistantMessage(content: [.toolCall(call)], api: .openAIResponses,
        provider: "openai", model: "test",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse)
    try await jsonlWithStorage { storage, directory, _ in
        try await jsonlRoot(storage)
        let id: EntryID = try await storage.mintId()
        let record = try EntryRecord.withMessages(id: id, conversationId: rootConversationID,
            kind: "pi.assistant", messages: [.assistant(message)])
        _ = try await storage.commit([.entry(value: record)], context: .background)
        let reopened = try await jsonlOpen(directory)
        let stored = try #require(try await reopened.entry(id, context: .background))
        guard case .assistant(let decoded) = try stored.entry.messages()?.first,
              case .toolCall(let restored) = decoded.content.first else {
            Issue.record("The stored tool call is absent")
            try await reopened.close(context: .background)
            return
        }
        #expect(restored.arguments.isEmpty)
        #expect(restored.argumentsError == error)
        let tool = AITool(name: "optional", description: "Optional arguments", parameters: [:])
        do {
            _ = try validateToolArguments(tool: tool, toolCall: restored)
            Issue.record("The saved malformed call passed validation")
        } catch ValidationError.invalidArguments(let toolName, let message) {
            #expect(toolName == call.name)
            #expect(message == error)
        }
        try await reopened.close(context: .background)
    }
}
