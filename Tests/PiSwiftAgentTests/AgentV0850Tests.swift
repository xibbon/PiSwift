import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftAgent

private let portModel = Model(id: "port", name: "port", api: .openAIResponses, provider: "openai", baseUrl: "https://example.invalid", reasoning: true, input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 10000, maxTokens: 1000)
private func portResponse(_ content: [ContentBlock], _ reason: StopReason = .stop) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()
    let message = AssistantMessage(content: content, api: portModel.api, provider: portModel.provider, model: portModel.id, usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: reason)
    stream.push(.done(reason: reason, message: message))
    stream.end(message)
    return stream
}

@Test func prepareNextTurnRunsOnlyBeforeContinuationAndAfterStopCheck() async {
    let calls = LockedState(0)
    let prepared = LockedState(0)
    let order = LockedState<[String]>([])
    let tool = AgentTool(label: "test", name: "test", description: "test", parameters: ["type": AnyCodable("object")]) { _, _, _, _ in
        AgentToolResult(content: [.text(TextContent(text: "result"))])
    }
    let config = AgentLoopConfig(model: portModel, convertToLlm: { $0.compactMap(\.asMessage) }, shouldStopAfterTurn: { _ in
        order.withLock { $0.append("stop") }
        return false
    }, prepareNextTurn: { turn in
        prepared.withLock { $0 += 1 }
        order.withLock { $0.append("prepare") }
        var context = turn.context
        context.systemPrompt = "updated"
        return AgentLoopTurnUpdate(context: context)
    })
    _ = await runAgentLoop(prompts: [.user(UserMessage(content: .text("go")))], context: AgentContext(systemPrompt: "first", messages: [], tools: [tool]), config: config, emit: { event in
        if case .turnStart = event { order.withLock { $0.append("start") } }
    }, streamFn: { _, context, _ in
        let count = calls.withLock { $0 += 1; return $0 }
        if count == 1 { return portResponse([.toolCall(ToolCall(id: "1", name: "test", arguments: [:]))], .toolUse) }
        #expect(context.systemPrompt == "updated")
        return portResponse([.text(TextContent(text: "done"))])
    })
    #expect(calls.withLock { $0 } == 2)
    #expect(prepared.withLock { $0 } == 1)
    #expect(order.withLock { $0 } == ["start", "stop", "prepare", "start", "stop"])
}

@Test func parallelPreflightAbortDoesNotExecuteEarlierPreparedCall() async {
    let signal = CancellationToken()
    let executions = LockedState(0)
    let ends = LockedState<[String]>([])
    let tool = AgentTool(label: "test", name: "test", description: "test", parameters: ["type": AnyCodable("object")]) { _, _, _, _ in
        executions.withLock { $0 += 1 }
        return AgentToolResult(content: [])
    }
    let config = AgentLoopConfig(model: portModel, toolExecution: .parallel, beforeToolCall: { context, _ in
        if context.toolCall.id == "2" { signal.cancel() }
        return nil
    }, convertToLlm: { $0.compactMap(\.asMessage) }, shouldStopAfterTurn: { _ in true })
    _ = await runAgentLoop(prompts: [.user(UserMessage(content: .text("go")))], context: AgentContext(systemPrompt: "", messages: [], tools: [tool]), config: config, emit: { event in
        if case .toolExecutionEnd(let id, _, let result, let isError) = event {
            #expect(isError)
            #expect(result.content.contains { if case .text(let text) = $0 { return text.text == "Operation aborted" }; return false })
            ends.withLock { $0.append(id) }
        }
    }, signal: signal, streamFn: { _, _, _ in portResponse([.toolCall(ToolCall(id: "1", name: "test", arguments: [:])), .toolCall(ToolCall(id: "2", name: "test", arguments: [:]))], .toolUse) })
    #expect(executions.withLock { $0 } == 0)
    #expect(ends.withLock { $0.sorted() } == ["1", "2"])
}

private final class ProxyPortURLProtocol: URLProtocol {
    static let bodies = LockedState<[String: String]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = Self.bodies.withLock { $0[request.url!.host!] ?? "" }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test(arguments: ["metadata", "residual", "eof"])
func proxyV085TerminalCases(_ scenario: String) async throws {
    let usage = #""usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}}"#
    var body = "data: {\"type\":\"start\"}\n\n"
    if scenario == "metadata" {
        body += #"data: {"type":"toolcall_start","contentIndex":0,"id":"call","toolName":"lookup"}"# + "\n\n"
        body += #"data: {"type":"toolcall_end","contentIndex":0,"toolCall":{"type":"toolCall","id":"call","name":"lookup","arguments":{"value":"hello"},"namespace":"dynamic_tools"}}"# + "\n\n"
    }
    if scenario != "eof" { body += "data: {\"type\":\"done\",\"reason\":\"stop\",\"providerThinkingLevel\":\"high\",\(usage)}" }
    let host = "\(scenario).invalid"
    ProxyPortURLProtocol.bodies.withLock { $0[host] = body }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ProxyPortURLProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let stream = streamProxy(model: portModel, context: Context(messages: []), options: ProxyStreamOptions(authToken: "token", proxyUrl: "https://\(host)"), session: session)
    var events: [AssistantMessageEvent] = []
    for await event in stream { events.append(event) }
    let result = await stream.result()
    if scenario == "eof" {
        #expect(result.stopReason == .error)
        #expect(result.errorMessage == "Connection closed by proxy server before the response completed")
    } else {
        #expect(result.providerThinkingLevel == "high")
        #expect(result.stopReason == .stop)
    }
    if scenario == "metadata" {
        guard case .toolCall(let call) = result.content.first else { Issue.record("Missing tool call"); return }
        #expect(call.namespace == "dynamic_tools")
        #expect(call.arguments["value"]?.value as? String == "hello")
    }
}
