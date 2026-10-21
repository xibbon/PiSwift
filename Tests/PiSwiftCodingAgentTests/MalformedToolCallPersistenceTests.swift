import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func malformedStoredAssistant() -> AssistantMessage {
    var call = ToolCall(id: "invalid-call", name: "optional", arguments: [:])
    call.finalizeArguments(from: #"{"value":1} trailing"#)
    return AssistantMessage(content: [
        .thinking(ThinkingContent(thinking: "", thinkingSignature: "redacted-data", redacted: true)),
        .toolCall(call),
    ], api: .openAIResponses, provider: "openai", model: "test",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse)
}

private func storedMalformedCall(_ message: AssistantMessage) throws -> ToolCall {
    let call = try #require(message.content.compactMap { block -> ToolCall? in
        if case .toolCall(let call) = block { return call }
        return nil
    }.first)
    #expect(call.arguments.isEmpty)
    #expect(call.argumentsError?.hasSuffix("\n\nReceived arguments:\n" + #"{"value":1} trailing"#) == true)
    return call
}

@Suite struct MalformedToolCallPersistenceTests {
    @Test func sessionFileKeepsMalformedArguments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("malformed-call-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let message = malformedStoredAssistant()
        let manager = SessionManager.create(directory.path, directory.path)
        manager.appendMessage(.user(UserMessage(content: .text("Run the tool"))))
        let id = manager.appendMessage(.assistant(message))
        let file = try #require(manager.getSessionFile())
        let restored = SessionManager.open(file)
        guard case .message(let entry) = restored.getEntry(id), case .assistant(let decoded) = entry.message else {
            Issue.record("The saved assistant message is absent")
            return
        }
        let call = try storedMalformedCall(decoded)
        #expect(try call.argumentsError == storedMalformedCall(message).argumentsError)
    }

    @Test func sessionEventsKeepMalformedFinalCall() throws {
        let message = malformedStoredAssistant()
        let call = try storedMalformedCall(message)
        let end = encodeSessionEventJSON(.agent(.messageEnd(message: .assistant(message))))
        let object = try #require(JSONSerialization.jsonObject(with: Data(end.utf8)) as? [String: Any])
        let encodedMessage = try #require(object["message"] as? [String: Any])
        let decoded = assistantMessageFromJSONObject(encodedMessage, ordered: try OrderedJSON.parse(end)["message"])
        #expect(try storedMalformedCall(decoded).argumentsError == call.argumentsError)

        let update = encodeSessionEventJSON(.agent(.messageUpdate(message: .assistant(message),
            assistantMessageEvent: .toolCallEnd(contentIndex: 1, toolCall: call, partial: message))))
        let updateObject = try #require(JSONSerialization.jsonObject(with: Data(update.utf8)) as? [String: Any])
        let delta = try #require(updateObject["assistantMessageEvent"] as? [String: Any])
        let encodedCall = try #require(delta["toolCall"] as? [String: Any])
        guard case .toolCall(let decodedCall) = contentBlockFromJSONObject(encodedCall) else {
            Issue.record("The final tool call is absent")
            return
        }
        #expect(decodedCall.argumentsError == call.argumentsError)
        #expect(decodedCall.arguments.isEmpty)
    }

    @Test func contextCopiesKeepArgumentErrorAndRedactedThinking() async throws {
        let message = malformedStoredAssistant()
        let originalCall = try storedMalformedCall(message)
        let api = HookAPI()
        api.on("context") { (event: ContextEvent, _: HookContext) async throws -> Any? in
            guard case .assistant(let copy) = event.messages.first else {
                Issue.record("The context has no assistant message")
                return nil
            }
            let copiedCall = try storedMalformedCall(copy)
            #expect(copiedCall.argumentsError == originalCall.argumentsError)
            guard case .thinking(let thinking) = copy.content.first else {
                Issue.record("The context has no thinking block")
                return nil
            }
            #expect(thinking.redacted == true)
            #expect(thinking.thinkingSignature == "redacted-data")
            return nil
        }
        let hook = LoadedHook(path: "malformed-test", resolvedPath: "malformed-test", handlers: api.handlers,
            currentHandlers: { api.handlers })
        let runner = HookRunner([hook], "/tmp", SessionManager.inMemory("/tmp"), ModelRegistry(AuthStorage(":memory:")))
        let result = await runner.emitContext([.assistant(message)])
        guard case .assistant(let copy) = result.first else {
            Issue.record("The copied assistant message is absent")
            return
        }
        #expect(try storedMalformedCall(copy).argumentsError == originalCall.argumentsError)
        guard case .thinking(let thinking) = copy.content.first else {
            Issue.record("The copied thinking block is absent")
            return
        }
        #expect(thinking.redacted == true)
    }
}
