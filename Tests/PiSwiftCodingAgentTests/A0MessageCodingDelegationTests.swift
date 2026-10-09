import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

@Suite struct A0MessageCodingDelegationTests {
    @Test func builtInRolesUseTheSharedCoder() {
        let messages: [Message] = [
            .system(SystemMessage(content: .text("rules"), timestamp: 1)),
            .user(UserMessage(content: .text("question"), timestamp: 2)),
            .assistant(AssistantMessage(content: [.text(TextContent(text: "answer"))], api: .openAIResponses,
                provider: "openai", model: "test", usage: Usage(input: 1, output: 2, cacheRead: 0,
                cacheWrite: 0, totalTokens: 3), stopReason: .stop, timestamp: 3)),
            .toolResult(ToolResultMessage(toolCallId: "call", toolName: "read", content: [.text(TextContent(text: "done"))],
                details: AnyCodable(["ok": true]), isError: false, timestamp: 4, durationMs: 5)),
        ]
        for message in messages {
            let agentMessage = AgentMessage(message)
            #expect(encodeAgentMessageJSON(agentMessage).serialized() == messageToOrderedJSON(message).serialized())
            #expect(OrderedJSON.fromFoundation(encodeAgentMessageDict(agentMessage)).serialized()
                    == OrderedJSON.fromFoundation(messageToJSONObject(message)).serialized())
        }
    }

    @Test func customRolesKeepTheirExistingJSON() {
        let message = AgentMessage.custom(AgentCustomMessage(role: "branchSummary",
            payload: AnyCodable(["summary": "saved", "fromId": "branch"]), timestamp: 5))
        #expect(encodeAgentMessageJSON(message).serialized()
                == #"{"fromId":"branch","role":"branchSummary","summary":"saved","timestamp":5}"#)
    }
}
