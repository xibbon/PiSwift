import Testing
import Synchronization
import PiSwiftAI
import PiSwiftChord
import PiSwiftTelemetry
@testable import PiSwiftDurable
import PiSwiftDurableTesting

struct DurableTelemetryOptionsTests {
    @Test(arguments: [false, true])
    func generationAndCompactionKeepContextSpan(useDefault: Bool) async throws {
        let span: any TelemetrySpan = useDefault ? noopTelemetryContext : DurableTestSpan()
        let context = useDefault ? ChordContext.background : ChordContext.background.withTelemetry(span)
        let setup = HarnessChatSetup(options: .init(models: [.init(id: "faux-1", contextWindow: 100_000, maxTokens: 900)]),
            settings: .init(compaction: compactionOverrides(compactionManualPolicy)))
        let script = CompactionScript(setup: setup)
        let opened = try await openChat(setup: setup, context: context)
        let chat = CompactionChat(harness: opened.harness, root: opened.root, setup: setup, script: script)
        try await compactionHistory(chat)
        script.appendSummary([.message(chatAssistant("SUMMARY"))])
        let outcome = try await compactionOutcome(chat, chat.root.compact(context: .background))
        #expect(outcome.status == "completed")
        #expect(script.agentRequests.count == 3)
        #expect(script.summaryRequests.count == 1)
        for request in script.agentRequests + script.summaryRequests {
            #expect(request.options?.telemetry === span)
        }
        let messages = try await opened.root.context(context: .background).messages
        #expect(compactionFirstUser(messages).contains("<summary>\nSUMMARY\n</summary>"))
        #expect(try await generationLive(opened)?.run == nil)
        #expect(setup.reports.count == 0)
        try await opened.harness.close(context: .background)
    }

    @Test(arguments: [false, true])
    func deferredPollAndCancelKeepContextSpan(abort: Bool) async throws {
        let span = DurableTestSpan(), clock = TestClock(now: 10)
        let setup = HarnessChatSetup(options: .init(deferred: .init(pendingFetches: 1, pollAfterMs: 20)),
            settings: .init(stream: .init(deferred: DeferredRequest())), clock: clock)
        setup.models.setResponses([.message(chatAssistant("ready"))])
        let models = DurableTelemetryModels(base: setup.models)
        let opened = try await openChat(setup: setup, models: models, context: ChordContext.background.withTelemetry(span))
        let submission = try await generationSubmit(opened)
        try await eventually {
            try await generationLive(opened)?.generation?.deferred?.pollAt == 30 && clock.pendingSleeperCount > 0
        }
        #expect(models.streamSpans.withLock { $0.count == 1 && $0[0] === span })
        if abort {
            try await opened.root.abort(context: .background)
            #expect(try await submission.wait(context: .background).reason == "aborted")
            #expect(models.cancelSpans.withLock { $0.count == 1 && $0[0] === span })
        } else {
            clock.advance(by: 20)
            try await eventually {
                try await generationLive(opened)?.generation?.deferred?.pollAt == 50 && clock.pendingSleeperCount > 0
            }
            clock.advance(by: 20)
            #expect(try await submission.wait(context: .background).status == "done")
            #expect(models.fetchSpans.withLock { $0.count == 2 && $0.allSatisfy { $0 === span } })
        }
        #expect(setup.reports.count == 0)
        try await opened.harness.close(context: .background)
    }
}

private final class DurableTestSpan: TelemetrySpan {
    func startSpan<Result>(_ options: SpanOptions, body: (any TelemetrySpan) throws -> Result) rethrows -> Result {
        try body(self)
    }
    func startSpan<Result: Sendable>(_ options: SpanOptions,
                                    body: @Sendable (any TelemetrySpan) async throws -> Result) async rethrows -> Result {
        try await body(self)
    }
    func addLink(_ link: SpanLink) {}
    func addEvent(_ name: String, attributes: SpanAttributes?) {}
    func setAttributes(_ attributes: SpanAttributes) {}
    func setStatus(_ status: SpanStatus) {}
}

private final class DurableTelemetryModels: DurableModels {
    let base: FakeDurableModels
    let streamSpans = Mutex<[(any TelemetrySpan)?]>([])
    let fetchSpans = Mutex<[(any TelemetrySpan)?]>([])
    let cancelSpans = Mutex<[(any TelemetrySpan)?]>([])

    init(base: FakeDurableModels) { self.base = base }
    func getModel(provider: String, modelId: String) -> Model? {
        base.getModel(provider: provider, modelId: modelId)
    }
    func streamSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) -> AssistantMessageEventStream {
        streamSpans.withLock { $0.append(options.telemetry) }
        return base.streamSimple(model: model, context: context, options: options)
    }
    func fetchDeferred(model: Model, handle: DeferredHandle, options: DeferredFetchOptions) async -> AssistantMessage {
        fetchSpans.withLock { $0.append(options.telemetry) }
        return await base.fetchDeferred(model: model, handle: handle, options: options)
    }
    func cancelDeferred(model: Model, handle: DeferredHandle, options: DeferredCancelOptions) async throws {
        cancelSpans.withLock { $0.append(options.telemetry) }
        try await base.cancelDeferred(model: model, handle: handle, options: options)
    }
}
