import Synchronization
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting

final class HarnessManualModels: DurableModels {
    let base: FakeDurableModels
    let stream = AssistantMessageEventStream()
    let seen = Mutex<[SimpleStreamOptions]>([])
    let cancelFails: Bool
    init(base: FakeDurableModels, cancelFails: Bool = false) { self.base = base; self.cancelFails = cancelFails }
    func getModel(provider: String, modelId: String) -> Model? { base.getModel(provider: provider, modelId: modelId) }
    func streamSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) -> AssistantMessageEventStream {
        seen.withLock { $0.append(options) }
        let stream = stream
        _ = options.signal?.onCancel { stream.push(.error(reason: .aborted, error: chatAssistant("", reason: .aborted))) }
        return stream
    }
    func fetchDeferred(model: Model, handle: DeferredHandle, options: DeferredFetchOptions) async -> AssistantMessage {
        await base.fetchDeferred(model: model, handle: handle, options: options)
    }
    func cancelDeferred(model: Model, handle: DeferredHandle, options: DeferredCancelOptions) async throws {
        if cancelFails { throw TaskDefinitionError("cancel failed") }
        try await base.cancelDeferred(model: model, handle: handle, options: options)
    }
}
func generationLive(_ opened: OpenChatResult) async throws -> LiveState? {
    try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background)
}
func generationSubmit(_ opened: OpenChatResult, _ text: String = "hi") async throws -> Submission {
    try await opened.root.submit(.input(content: .text(text)), context: .background)
}
func generationPartial(_ models: HarnessManualModels, text: String = "partial") {
    models.stream.push(.textDelta(contentIndex: 0, delta: text, partial: chatAssistant(text, reason: .pending)))
}
func generationFinal(_ models: HarnessManualModels, text: String = "final") {
    models.stream.push(.done(reason: .stop, message: chatAssistant(text)))
}
