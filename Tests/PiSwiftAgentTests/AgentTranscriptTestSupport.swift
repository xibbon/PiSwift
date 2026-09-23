import PiSwiftAI
import PiSwiftAgent

/// Seed the transcript for tests written before AgentContext lost its prompt field.
func testAgentContext(systemPrompt: String, messages: [AgentMessage], tools: [AgentTool]? = nil) -> AgentContext {
    var transcript = messages
    if let initial = createInitialSystemMessage(systemPrompt, tools?.map { toToolDeclaration($0.aiTool) }) {
        transcript.insert(.system(initial), at: 0)
    }
    return AgentContext(messages: transcript, tools: tools)
}
