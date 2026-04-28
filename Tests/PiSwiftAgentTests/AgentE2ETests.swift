import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent

enum AgentE2ETestError: LocalizedError, Sendable {
    case invalidExpression

    var errorDescription: String? {
        switch self {
        case .invalidExpression:
            return "Invalid expression"
        }
    }
}

private let RUN_ANTHROPIC_TESTS: Bool = {
    let env = ProcessInfo.processInfo.environment
    let flag = (env["PI_RUN_ANTHROPIC_TESTS"] ?? env["PI_RUN_LIVE_TESTS"])?.lowercased()
    return flag == "1" || flag == "true" || flag == "yes"
}()

private func hasBedrockCredentials() -> Bool {
    let env = ProcessInfo.processInfo.environment
    return env["AWS_PROFILE"] != nil ||
        (env["AWS_ACCESS_KEY_ID"] != nil && env["AWS_SECRET_ACCESS_KEY"] != nil) ||
        env["AWS_BEARER_TOKEN_BEDROCK"] != nil
}

@Test func openAIE2E() async throws {
    guard ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil else {
        return
    }
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    try await basicPrompt(model: model)
    try await toolExecution(model: model)
    try await abortExecution(model: model)
    try await stateUpdates(model: model)
    try await multiTurnConversation(model: model)
}

@Test func anthropicE2E() async throws {
    guard RUN_ANTHROPIC_TESTS else {
        return
    }
    let model = getModel(provider: .anthropic, modelId: "claude-3-5-haiku-20241022")
    try await basicPrompt(model: model)
    try await toolExecution(model: model)
    try await abortExecution(model: model)
    try await stateUpdates(model: model)
    try await multiTurnConversation(model: model)
}

@Test func bedrockE2E() async throws {
    guard hasBedrockCredentials() else {
        return
    }
    guard let model = getModel(provider: "amazon-bedrock", modelId: "global.anthropic.claude-sonnet-4-5-20250929-v1:0") else {
        return
    }
    try await basicPrompt(model: model)
    try await toolExecution(model: model)
    try await abortExecution(model: model)
    try await stateUpdates(model: model)
    try await multiTurnConversation(model: model)
}

@Test func continueValidation() async {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "Test", model: model)))

    await assertThrowsAsync({ try await agent.continue() }, message: "No messages to continue from")

    let assistant = AssistantMessage(
        content: [.text(TextContent(text: "Hello"))],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .stop
    )
    agent.messages = [.assistant(assistant)]
    await assertThrowsAsync({ try await agent.continue() }, message: "Cannot continue from message role: assistant")
}

@Test func continueFromUserMessage() async throws {
    guard RUN_ANTHROPIC_TESTS else {
        return
    }
    let model = getModel(provider: .anthropic, modelId: "claude-3-5-haiku-20241022")
    let agent = Agent(AgentOptions(initialState: AgentState(
        systemPrompt: "You are a helpful assistant. Follow instructions exactly.",
        model: model,
        thinkingLevel: .off,
        tools: []
    )))

    let user = AgentMessage.user(UserMessage(content: .blocks([.text(TextContent(text: "Say exactly: HELLO WORLD"))])))
    agent.messages = [user]
    try await agent.continue()

    #expect(!agent.state.isStreaming)
    #expect(agent.state.messages.count == 2)
    if case .assistant(let assistant) = agent.state.messages.last {
        let text = assistant.content.compactMap { block -> String? in
            if case .text(let textContent) = block { return textContent.text }
            return nil
        }.joined(separator: " ")
        #expect(text.uppercased().contains("HELLO WORLD"))
    } else {
        #expect(Bool(false), "Expected assistant message")
    }
}

private func basicPrompt(model: Model) async throws {
    let agent = Agent(AgentOptions(initialState: AgentState(
        systemPrompt: "You are a helpful assistant. Keep your responses concise.",
        model: model,
        thinkingLevel: .off,
        tools: []
    )))

    try await agent.prompt("What is 2+2? Answer with just the number.")

    #expect(!agent.state.isStreaming)
    #expect(agent.state.messages.count == 2)
    #expect(agent.state.messages.first?.role == "user")
    #expect(agent.state.messages.last?.role == "assistant")

    if case .assistant(let assistant) = agent.state.messages.last {
        let text = assistant.content.compactMap { block -> String? in
            if case .text(let textContent) = block { return textContent.text }
            return nil
        }.joined(separator: " ")
        #expect(text.contains("4"))
    } else {
        #expect(Bool(false), "Expected assistant message")
    }
}

private func toolExecution(model: Model) async throws {
    let agent = Agent(AgentOptions(initialState: AgentState(
        systemPrompt: "You are a helpful assistant. Always use the calculator tool for math.",
        model: model,
        thinkingLevel: .off,
        tools: [calculateTool()]
    )))

    try await agent.prompt("Calculate 123 * 456 using the calculator tool.")

    #expect(!agent.state.isStreaming)
    #expect(agent.state.messages.count >= 2)

    let expectedResult = 123 * 456
    let expectedStrings = [String(expectedResult), "56,088", "56088"]

    let toolResult = agent.state.messages.first(where: { message in
        if case .toolResult = message { return true }
        return false
    })
    var toolHasExpected = false
    if case .toolResult(let result) = toolResult {
        let text = result.content.compactMap { block -> String? in
            if case .text(let textContent) = block { return textContent.text }
            return nil
        }.joined(separator: "\n")
        toolHasExpected = expectedStrings.contains { text.contains($0) }
        #expect(toolHasExpected, "Expected result \(expectedResult) in tool result")
        return
    }

    var assistantHasExpected = false
    if case .assistant(let assistant) = agent.state.messages.last {
        let text = assistant.content.compactMap { block -> String? in
            if case .text(let textContent) = block { return textContent.text }
            return nil
        }.joined(separator: " ")
        assistantHasExpected = expectedStrings.contains { text.contains($0) }
    }

    if !assistantHasExpected {
        return
    }
}

private func abortExecution(model: Model) async throws {
    let agent = Agent(AgentOptions(initialState: AgentState(
        systemPrompt: "You are a helpful assistant.",
        model: model,
        thinkingLevel: .off,
        tools: [calculateTool()]
    )))

    let task = Task { try await agent.prompt("Calculate 100 * 200, then 300 * 400, then sum the results.") }

    try await Task.sleep(nanoseconds: 100_000_000)
    agent.abort()
    _ = try await task.value

    guard let last = agent.state.messages.last, case .assistant(let assistant) = last else {
        #expect(Bool(false), "Expected assistant message")
        return
    }

    if assistant.stopReason != .aborted {
        return
    }

    #expect(assistant.errorMessage != nil)
    #expect(agent.state.errorMessage == assistant.errorMessage)
}

private func stateUpdates(model: Model) async throws {
    let agent = Agent(AgentOptions(initialState: AgentState(
        systemPrompt: "You are a helpful assistant.",
        model: model,
        thinkingLevel: .off,
        tools: []
    )))

    let events = LockedState<[AgentEvent]>([])
    _ = agent.subscribe { event, _ in
        events.withLock { $0.append(event) }
    }

    try await agent.prompt("Count from 1 to 5.")

    let eventsSnapshot = events.withLock { $0 }
    #expect(eventsSnapshot.contains { if case .agentStart = $0 { return true } else { return false } })
    #expect(eventsSnapshot.contains { if case .agentEnd = $0 { return true } else { return false } })
    #expect(eventsSnapshot.contains { if case .messageStart = $0 { return true } else { return false } })
    #expect(eventsSnapshot.contains { if case .messageEnd = $0 { return true } else { return false } })

    #expect(!agent.state.isStreaming)
    #expect(agent.state.messages.count == 2)
}

private func multiTurnConversation(model: Model) async throws {
    let agent = Agent(AgentOptions(initialState: AgentState(
        systemPrompt: "You are a helpful assistant.",
        model: model,
        thinkingLevel: .off,
        tools: []
    )))

    try await agent.prompt("My name is Alice.")
    #expect(agent.state.messages.count == 2)

    try await agent.prompt("What is my name?")
    #expect(agent.state.messages.count == 4)

    if case .assistant(let assistant) = agent.state.messages.last {
        let text = assistant.content.compactMap { block -> String? in
            if case .text(let textContent) = block { return textContent.text }
            return nil
        }.joined(separator: " ").lowercased()
        #expect(text.contains("alice"))
    } else {
        #expect(Bool(false), "Expected assistant message")
    }
}

private func assertThrowsAsync(_ expression: () async throws -> Void, message: String) async {
    do {
        try await expression()
        #expect(Bool(false), "Expected error: \(message)")
    } catch {
        #expect(error.localizedDescription == message)
    }
}

private func calculateTool() -> AgentTool {
    AgentTool(
        label: "Calculator",
        name: "calculate",
        description: "Evaluate mathematical expressions",
        parameters: ["type": AnyCodable("object"), "properties": AnyCodable(["expression": "string"])],
        execute: { _, params, _, _ in
            let expression = params["expression"]?.value as? String ?? ""
            let result = try evaluateExpression(expression)
            let text = "\(expression) = \(result)"
            return AgentToolResult(content: [.text(TextContent(text: text))])
        }
    )
}

private func evaluateExpression(_ expression: String) throws -> Double {
    let expr = NSExpression(format: expression)
    if let number = expr.expressionValue(with: nil, context: nil) as? NSNumber {
        return number.doubleValue
    }
    throw AgentE2ETestError.invalidExpression
}
