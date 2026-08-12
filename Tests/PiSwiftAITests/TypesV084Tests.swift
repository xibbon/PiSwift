import Testing
@testable import PiSwiftAI

@Test func stopReasonPendingAndDeferredRawValuesRoundTrip() {
    #expect(StopReason.pending.rawValue == "pending")
    #expect(StopReason(rawValue: "pending") == .pending)
    #expect(StopReason.deferred.rawValue == "deferred")
    #expect(StopReason(rawValue: "deferred") == .deferred)
}

@Test func deferredHandleConstructionPreservesFields() {
    let data = AnyCodable(["rowId": "row-7"] as [String: Any])
    let handle = DeferredHandle(
        provider: "example",
        modelId: "example-model",
        api: "openai-responses",
        id: "response-1:row-7",
        expiresAt: 1_800_000_000_000,
        pollAfterMs: 2_500,
        data: data
    )

    #expect(handle.provider == "example")
    #expect(handle.modelId == "example-model")
    #expect(handle.api == "openai-responses")
    #expect(handle.id == "response-1:row-7")
    #expect(handle.expiresAt == 1_800_000_000_000)
    #expect(handle.pollAfterMs == 2_500)
    #expect(handle.data == data)
}

@Test func constrainedSamplingPreservesAllFourStates() {
    let parameters = ["type": AnyCodable("object")]
    let unspecified = AITool(name: "unspecified", description: "", parameters: parameters)
    let disabled = AITool(
        name: "disabled",
        description: "",
        parameters: parameters,
        constrainedSampling: .disabled
    )
    let jsonSchema = AITool(
        name: "json-schema",
        description: "",
        parameters: parameters,
        constrainedSampling: .jsonSchema(strict: .require)
    )
    let grammar = AITool(
        name: "grammar",
        description: "",
        parameters: parameters,
        constrainedSampling: .grammar(variants: [.openAILark: "start: WORD"])
    )

    if case nil = unspecified.constrainedSampling {
        // The omitted parameter stays distinct from `.disabled`.
    } else {
        Issue.record("Expected constrained sampling to be unspecified")
    }

    if case .disabled? = disabled.constrainedSampling {
        // Explicit opt-out remains present.
    } else {
        Issue.record("Expected constrained sampling to be disabled")
    }

    if case .jsonSchema(let strictness)? = jsonSchema.constrainedSampling {
        #expect(strictness.rawValue == "require")
    } else {
        Issue.record("Expected required JSON-schema constrained sampling")
    }

    if case .grammar(let variants)? = grammar.constrainedSampling {
        #expect(variants == [.openAILark: "start: WORD"])
    } else {
        Issue.record("Expected grammar constrained sampling")
    }
}

@Test func newTypeParametersCanBeOmitted() {
    let usage = Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0)
    let tool = AITool(name: "tool", description: "", parameters: [:])
    let model = Model(
        id: "model",
        name: "Model",
        api: .openAICompletions,
        provider: "provider",
        baseUrl: "https://example.com",
        reasoning: false,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 1_024,
        maxTokens: 256
    )
    let streamOptions = StreamOptions()
    let assistant = AssistantMessage(
        content: [],
        api: .openAICompletions,
        provider: "provider",
        model: "model",
        usage: usage,
        stopReason: .stop
    )
    let toolResult = ToolResultMessage(
        toolCallId: "call-1",
        toolName: "tool",
        content: [],
        isError: false
    )

    if case nil = tool.constrainedSampling {
        // The legacy initializer omits constrained sampling.
    } else {
        Issue.record("Expected omitted constrained sampling to be nil")
    }
    #expect(model.samplingParams == nil)
    #expect(streamOptions.samplingParams == nil)
    #expect(assistant.deferred == nil)
    #expect(assistant.rawStopReason == nil)
    #expect(toolResult.usage == nil)
}
