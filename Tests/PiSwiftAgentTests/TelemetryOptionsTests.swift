import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftTelemetry

@Test(.timeLimit(.minutes(1)))
func agentLoopPassesRequestSpanToStreamFunction() async {
    let span = noopTelemetryContext
    let model = Model(id: "telemetry-agent", name: "Telemetry agent", api: .openAICompletions,
        provider: "telemetry-test", baseUrl: "https://example.invalid", reasoning: false, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 128_000, maxTokens: 100)
    let observed = LockedState<[(any TelemetrySpan)?]>([])
    let config = AgentLoopConfig(model: model, telemetry: span,
        convertToLlm: { $0.compactMap(\.asMessage) })
    let stream = agentLoop(
        prompts: [.user(UserMessage(content: .text("hello")))],
        context: testAgentContext(systemPrompt: "", messages: [], tools: []),
        config: config,
        streamFn: { model, _, options in
            observed.withLock { $0.append(options.telemetry) }
            let message = AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                stopReason: .stop, timestamp: 0)
            let stream = AssistantMessageEventStream()
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
            return stream
        })
    _ = await stream.result()
    let spans = observed.withLock { $0 }
    #expect(spans.count == 1)
    #expect(spans.first.flatMap { $0 } === span)
    #expect(AgentLoopConfig(model: model, convertToLlm: { $0.compactMap(\.asMessage) }).telemetry == nil)
}
