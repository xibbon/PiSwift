import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting

private enum HarnessModelFailure: Error, LocalizedError, Equatable {
    case failed
    var errorDescription: String? { "script failed" }
}

private func modelRequest(_ text: String = "hello") -> PiSwiftAI.Context {
    PiSwiftAI.Context(messages: [.user(UserMessage(content: .text(text), timestamp: 1))])
}

private func modelText(_ text: String, timestamp: Int64 = 1) -> AssistantMessage {
    fauxAssistantMessage(content: [.text(TextContent(text: text))], timestamp: timestamp)
}

private func responseText(_ message: AssistantMessage) -> String {
    message.content.compactMap {
        if case .text(let text) = $0 { return text.text }
        return nil
    }.joined()
}

@Suite("Harness model runtime")
struct HarnessModelsTests {
    @Test func scriptedQueuesArePerInstanceAndCountsAreExact() async throws {
        let first = FakeDurableModels(responses: [.message(modelText("first"))])
        let second = FakeDurableModels(responses: [.message(modelText("other"))])
        let model = try #require(first.getModel(provider: "faux", modelId: "faux-1"))
        first.appendResponses([.message(modelText("second"))])
        #expect(first.pendingResponseCount() == 2)
        #expect(responseText(await first.completeSimple(model: model, context: modelRequest(), options: .init())) == "first")
        #expect(responseText(await first.streamSimple(model: model, context: modelRequest(), options: .init()).result()) == "second")
        #expect(responseText(await second.completeSimple(model: model, context: modelRequest(), options: .init())) == "other")
        #expect(first.state().callCount == 2)
        #expect(second.state().callCount == 1)
        #expect(first.calls().getModel == 1)
        #expect(first.calls().completeSimple == 1)
        #expect(first.calls().streamSimple == 1)
        #expect(first.pendingResponseCount() == 0)
        let empty = await first.completeSimple(model: model, context: modelRequest(), options: .init())
        #expect(empty.stopReason == .error)
        #expect(empty.errorMessage == "No more faux responses queued")
        #expect(first.state().callCount == 3)
        first.setResponses([.message(modelText("replacement"))])
        #expect(first.pendingResponseCount() == 1)
    }

    @Test func factoriesSeeNormalizedContextOptionsAndStateAndThrowInBand() async throws {
        let fake = FakeDurableModels(options: .init(models: [FauxModelDefinition(id: "faux-1", contextWindow: 32_000)]), responses: [.factory { context, options, state, model in
            #expect(context.messages.count == 2)
            #expect(options?.apiKey == "test-key")
            #expect(state.callCount == 1)
            #expect(model.contextWindow == 32_000)
            throw HarnessModelFailure.failed
        }])
        var context = modelRequest()
        context.systemPrompt = "system"
        let stream = fake.streamSimple(model: fake.models[0], context: context, options: .init(apiKey: "test-key"))
        var eventCount = 0
        for await event in stream {
            eventCount += 1
            guard case .error = event else { Issue.record("A thrown factory must emit only an error"); continue }
        }
        #expect(eventCount == 1)
        let failed = await stream.result()
        #expect(failed.stopReason == .error)
        #expect(failed.errorMessage == "script failed")
    }

    @Test func exactModelLookupUsesPerModelLimits() throws {
        let fake = FakeDurableModels(options: .init(provider: "local", models: [
            FauxModelDefinition(id: "Small", contextWindow: 32_000, maxTokens: 1_000),
            FauxModelDefinition(id: "Large", contextWindow: 200_000, maxTokens: 8_000)
        ]))
        let small = try #require(fake.getModel(provider: "local", modelId: "Small"))
        #expect(small.contextWindow == 32_000)
        #expect(small.maxTokens == 1_000)
        #expect(fake.getModel(provider: "LOCAL", modelId: "Small") == nil)
        #expect(fake.getModel(provider: "local", modelId: "small") == nil)
        #expect(fake.calls().getModel == 3)
        let unicode = FakeDurableModels(options: .init(provider: "café", models: [FauxModelDefinition(id: "café")]))
        #expect(unicode.getModel(provider: "cafe\u{301}", modelId: "café") == nil)
        #expect(unicode.getModel(provider: "café", modelId: "cafe\u{301}") == nil)
    }

    @Test func deferredSubmitPollRedeemReplayAndCancel() async throws {
        let resolutions = Mutex(0)
        let fake = FakeDurableModels(options: .init(deferred: FauxDeferredOptions(pendingFetches: 1, pollAfterMs: 25)),
            responses: [.factory { _, options, _, _ in
                resolutions.withLock { $0 += 1 }
                #expect(options?.deferred == nil)
                #expect(options?.signal == nil)
                return modelText("ready")
            }, .message(modelText("cancel"))])
        let model = fake.models[0]
        let submitted = await fake.completeSimple(model: model, context: modelRequest(), options: .init(deferred: DeferredRequest()))
        #expect(submitted.stopReason == .deferred)
        #expect(submitted.content.isEmpty)
        #expect(submitted.usage.totalTokens == 0)
        let handle = try #require(submitted.deferred)
        #expect(handle.pollAfterMs == 25)
        #expect(resolutions.withLock { $0 } == 0)
        let pending = await fake.fetchDeferred(model: model, handle: handle, options: .init())
        #expect(pending.deferred == handle)
        let ready = await fake.fetchDeferred(model: model, handle: handle, options: .init())
        let replay = await fake.fetchDeferred(model: model, handle: handle, options: .init())
        #expect(responseText(ready) == "ready")
        #expect(messageToOrderedJSON(.assistant(ready)).serialized() == messageToOrderedJSON(.assistant(replay)).serialized())
        #expect(resolutions.withLock { $0 } == 1)
        let other = await fake.completeSimple(model: model, context: modelRequest(), options: .init(deferred: DeferredRequest()))
        let cancel = try #require(other.deferred)
        try await fake.cancelDeferred(model: model, handle: cancel, options: .init())
        let cancelled = await fake.fetchDeferred(model: model, handle: cancel, options: .init())
        #expect(cancelled.stopReason == .error)
        #expect(cancelled.errorMessage?.contains("was cancelled") == true)
        #expect(fake.state().callCount == 2)
        #expect(fake.state().deferredFetchCount == 4)
        #expect(fake.state().cancelledDeferred == [cancel])
        #expect(fake.calls().fetchDeferred == 4)
        #expect(fake.calls().cancelDeferred == 1)
    }

    @Test func concurrentDeferredRedemptionExecutesFactoryOnce() async throws {
        let resolutions = Mutex(0)
        let fake = FakeDurableModels(responses: [.factory { _, _, _, _ in
            resolutions.withLock { $0 += 1 }
            try await Task.sleep(for: .milliseconds(5))
            return modelText("once")
        }])
        let model = fake.models[0]
        let submitted = await fake.completeSimple(model: model, context: modelRequest(), options: .init(deferred: DeferredRequest()))
        let handle = try #require(submitted.deferred)
        async let first = fake.fetchDeferred(model: model, handle: handle, options: .init())
        async let second = fake.fetchDeferred(model: model, handle: handle, options: .init())
        let responses = await [first, second]
        #expect(responses.map(responseText) == ["once", "once"])
        #expect(resolutions.withLock { $0 } == 1)
        #expect(fake.state().deferredFetchCount == 2)
    }

    @Test func unknownAndMismatchedHandlesFailInBand() async throws {
        let fake = FakeDurableModels(responses: [.message(modelText("ready"))])
        let model = fake.models[0]
        var handle = DeferredHandle(provider: model.provider, modelId: model.id, api: model.api.rawValue, id: "missing")
        #expect(await fake.fetchDeferred(model: model, handle: handle, options: .init()).stopReason == .error)
        let submitted = await fake.completeSimple(model: model, context: modelRequest(), options: .init(deferred: DeferredRequest()))
        handle = try #require(submitted.deferred)
        for field in 0..<3 {
            var mismatch = handle
            switch field {
            case 0: mismatch.provider = "other"
            case 1: mismatch.modelId = "other"
            default: mismatch.api = "other"
            }
            #expect(await fake.fetchDeferred(model: model, handle: mismatch, options: .init()).stopReason == .error)
        }
        #expect(fake.state().deferredFetchCount == 4)
    }

    @Test func textThinkingAndToolCallsEmitDeltasAndFinalContent() async throws {
        let content: [ContentBlock] = [.thinking(ThinkingContent(thinking: "think")), .text(TextContent(text: "abcdefgh🙂")),
            .toolCall(ToolCall(id: "call", name: "read", arguments: ["path": AnyCodable("a")]))]
        let fake = FakeDurableModels(options: .init(minTokenSize: 1, maxTokenSize: 1),
            responses: [.message(fauxAssistantMessage(content: content, stopReason: .toolUse, timestamp: 1))])
        let stream = fake.streamSimple(model: fake.models[0], context: modelRequest(), options: .init())
        var text = ""
        var thinking = ""
        var tool = ""
        var done = 0
        for await event in stream {
            switch event {
            case .textDelta(_, let delta, _): text += delta
            case .thinkingDelta(_, let delta, _): thinking += delta
            case .toolCallDelta(_, let delta, _): tool += delta
            case .done: done += 1
            default: break
            }
        }
        #expect(text == "abcdefgh🙂")
        #expect(thinking == "think")
        #expect(tool == "{\"path\":\"a\"}")
        #expect(done == 1)
        #expect(await stream.result().stopReason == .toolUse)
    }

    @Test func outputUsageAndCacheUseUTF16AndNilCacheRetentionIsOn() async {
        let fake = FakeDurableModels(responses: [.message(modelText("🙂")), .message(modelText("🙂"))])
        let options = SimpleStreamOptions(sessionId: "session")
        let first = await fake.completeSimple(model: fake.models[0], context: modelRequest("hi🙂"), options: options)
        let second = await fake.completeSimple(model: fake.models[0], context: modelRequest("hi🙂"), options: options)
        #expect(first.usage.input == 3)
        #expect(first.usage.output == 1)
        #expect(first.usage.cacheWrite == 3)
        #expect(second.usage.input == 0)
        #expect(second.usage.cacheRead == 3)
        #expect(second.usage.cacheWrite == 0)
    }

    @Test func cancelledModelStreamIsAborted() async {
        let token = CancellationToken()
        token.cancel()
        let fake = FakeDurableModels(responses: [.message(modelText("unseen"))])
        let result = await fake.completeSimple(model: fake.models[0], context: modelRequest(), options: .init(signal: token))
        #expect(result.stopReason == .aborted)
        #expect(result.content.isEmpty)
        #expect(result.errorMessage == "Request was aborted")
    }

    @Test func midStreamCancellationKeepsTheDeliveredPartial() async {
        let token = CancellationToken()
        let fake = FakeDurableModels(options: .init(tokensPerSecond: 10, minTokenSize: 1, maxTokenSize: 1),
            responses: [.message(modelText("abcdefghijkl"))])
        let stream = fake.streamSimple(model: fake.models[0], context: modelRequest(), options: .init(signal: token))
        var delivered = ""
        for await event in stream {
            if case .textDelta(_, let delta, _) = event {
                delivered += delta
                token.cancel()
            }
        }
        let result = await stream.result()
        #expect(delivered == "abcd")
        #expect(result.stopReason == .aborted)
        #expect(responseText(result) == delivered)
    }

    @Test func contextBridgeHandlesBeforeAndAfterAbortAndIsOneWay() {
        let cancellable = ChordContext.background.withCancel()
        let bridge = ContextCancellationBridge(context: cancellable.context)
        #expect(!bridge.token.isCancelled)
        cancellable.cancel()
        #expect(bridge.token.isCancelled)
        #expect(ContextCancellationBridge(context: cancellable.context).token.isCancelled)
        let other = ChordContext.background.withCancel()
        let reverse = ContextCancellationBridge(context: other.context)
        reverse.token.cancel()
        #expect(other.context.abortSignal?.aborted == false)
        #expect(!ContextCancellationBridge(context: .background).token.isCancelled)
    }

    @Test func releasedContextBridgeRemovesItsListener() {
        let cancellable = ChordContext.background.withCancel()
        let token = CancellationToken()
        do {
            let bridge = ContextCancellationBridge(context: cancellable.context, token: token)
            #expect(bridge.token === token)
        }
        cancellable.cancel()
        #expect(!token.isCancelled)
    }

    @Test func contextCancellationHelperKeepsListenerAcrossSuspension() async throws {
        let cancellable = ChordContext.background.withCancel()
        await withContextCancellation(cancellable.context) { token in
            await Task.yield()
            cancellable.cancel()
            #expect(token.isCancelled)
            let fake = FakeDurableModels(responses: [.message(modelText("unseen"))])
            let result = await fake.completeSimple(model: fake.models[0], context: modelRequest(), options: .init(signal: token))
            #expect(result.stopReason == .aborted)
        }
    }
}

/// The one required global faux round trip is isolated from all per-instance fake tests.
@Suite("PiSwiftAI durable adapter", .serialized)
struct PiSwiftAIDurableAdapterTests {
    @Test func fauxRoundTripResolvesAPIKeyAndExplicitKeyWins() async throws {
        let registration = registerFauxProvider(.init(api: Api.piVirtual.rawValue))
        defer { registration.unregister() }
        let resolutions = Mutex(0)
        let keys = Mutex<[String?]>([])
        registration.setResponses([.factory { _, options, _, _ in
            keys.withLock { $0.append(options?.apiKey) }
            return modelText("round trip")
        }, .factory { _, options, _, _ in
            keys.withLock { $0.append(options?.apiKey) }
            return modelText("explicit")
        }])
        let adapter = PiSwiftAIDurableModels { _ in
            resolutions.withLock { $0 += 1 }
            await Task.yield()
            return "resolved-key"
        }
        let model = try #require(registration.getModel())
        let result = await adapter.completeSimple(model: model, context: modelRequest(), options: .init())
        #expect(responseText(result) == "round trip")
        #expect(result.stopReason == .stop)
        #expect(result.provider == "faux")
        let explicit = await adapter.completeSimple(model: model, context: modelRequest(), options: .init(apiKey: "explicit-key"))
        #expect(responseText(explicit) == "explicit")
        #expect(keys.withLock { $0 } == ["resolved-key", "explicit-key"])
        #expect(resolutions.withLock { $0 } == 1)
    }

    @Test func catalogLookupAndCredentialFailureUseUpstreamSemantics() async throws {
        let adapter = PiSwiftAIDurableModels { _ in throw HarnessModelFailure.failed }
        #expect(adapter.getModel(provider: "unknown", modelId: "unknown") == nil)
        let model = try #require(getModels(provider: .anthropic).first)
        #expect(adapter.getModel(provider: model.provider, modelId: model.id)?.id == model.id)
        #expect(adapter.getModel(provider: model.provider.uppercased(), modelId: model.id) == nil)
        let failed = await adapter.completeSimple(model: model, context: modelRequest(), options: .init())
        #expect(failed.stopReason == .error)
        let handle = DeferredHandle(provider: model.provider, modelId: model.id, api: model.api.rawValue, id: "missing")
        #expect(await adapter.fetchDeferred(model: model, handle: handle, options: .init()).stopReason == .error)
        await #expect(throws: HarnessModelFailure.failed) {
            try await adapter.cancelDeferred(model: model, handle: handle, options: .init())
        }
    }
}
