import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftAgent

@Test func proxyFinalToolCallKeepsArgumentError() throws {
    var call = ToolCall(id: "invalid-call", name: "optional", arguments: [:])
    call.finalizeArguments(from: #"{"value":1} trailing"#)
    let error = try #require(call.argumentsError)
    let object: [String: Any] = ["type": "toolcall_end", "contentIndex": 0,
        "toolCall": contentBlockToJSONObject(.toolCall(call))]
    let data = try JSONSerialization.data(withJSONObject: object)
    guard case .toolCallEnd(let index, let restored?) = try decodeProxyAssistantMessageEventJSON(data) else {
        Issue.record("The proxy final tool call is absent")
        return
    }
    #expect(index == 0)
    #expect(restored.id == call.id)
    #expect(restored.arguments.isEmpty)
    #expect(restored.argumentsError == error)
}
