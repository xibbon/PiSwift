import Foundation
import Testing
@testable import PiSwiftAI

private enum A0DeferredFailure: LocalizedError {
    case failed
    var errorDescription: String? { "deferred failed" }
}

private func a0DeferredContext() -> Context {
    Context(messages: [.user(UserMessage(content: .text("hello"), timestamp: 1))])
}

// Use the existing serialized registry suite. Its other tests also reset the registry.
extension ApiRegistryTests {
    @Test func a0SubmitsPollsAndRedeemsDeferredResponses() async throws {
        let faux = registerFauxProvider(FauxRegistrationOptions(api: Api.piVirtual.rawValue,
            deferred: FauxDeferredOptions(pendingFetches: 1, pollAfterMs: 25)))
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage(content: [fauxText("ready")], timestamp: 1))])
        let model = try #require(faux.getModel())
        let submission = try streamSimple(model: model, context: a0DeferredContext(),
            options: SimpleStreamOptions(deferred: DeferredRequest(window: .oneHour)))
        var eventTypes: [String] = []
        for await event in submission {
            switch event {
            case .start: eventTypes.append("start")
            case .done: eventTypes.append("done")
            default: eventTypes.append("unexpected")
            }
        }
        let deferred = await submission.result()
        #expect(eventTypes == ["start", "done"])
        #expect(deferred.stopReason == .deferred)
        #expect(deferred.content.isEmpty)
        #expect(deferred.usage.totalTokens == 0)
        let handle = try #require(deferred.deferred)
        #expect(handle.provider == model.provider)
        #expect(handle.modelId == model.id)
        #expect(handle.api == model.api.rawValue)
        #expect(handle.id.hasPrefix("deferred-"))
        #expect(handle.pollAfterMs == 25)
        let pending = try await fetchDeferred(model: model, handle: handle)
        #expect(pending.stopReason == .deferred)
        #expect(pending.deferred == handle)
        let ready = try await fetchDeferred(model: model, handle: handle, options: DeferredFetchOptions(wait: 0))
        #expect(ready.stopReason == .stop)
        #expect(ready.content.count == 1)
        guard case .text(let text) = ready.content.first else { Issue.record("Missing ready text"); return }
        #expect(text.text == "ready")
        #expect(ready.usage.totalTokens > 0)
        #expect(faux.state().callCount == 1)
        #expect(faux.state().deferredFetchCount == 2)
        let repeated = try await fetchDeferred(model: model, handle: handle)
        #expect(messageToOrderedJSON(.assistant(repeated)).serialized() == messageToOrderedJSON(.assistant(ready)).serialized())
    }

    @Test func a0RecordsCancellationAndFetchFailuresInBand() async throws {
        let faux = registerFauxProvider(FauxRegistrationOptions(api: Api.piVirtual.rawValue))
        defer { faux.unregister() }
        faux.setResponses([.factory { _, _, _, _ in throw A0DeferredFailure.failed },
            .message(fauxAssistantMessage(content: [fauxText("cancelled")]))])
        let model = try #require(faux.getModel())
        let first = try await completeSimple(model: model, context: a0DeferredContext(),
            options: SimpleStreamOptions(deferred: DeferredRequest()))
        let failedHandle = try #require(first.deferred)
        let failed = try await fetchDeferred(model: model, handle: failedHandle)
        #expect(failed.stopReason == .error)
        #expect(failed.errorMessage == "deferred failed")
        let second = try await completeSimple(model: model, context: a0DeferredContext(),
            options: SimpleStreamOptions(deferred: DeferredRequest()))
        let cancelledHandle = try #require(second.deferred)
        try await cancelDeferred(model: model, handle: cancelledHandle)
        #expect(faux.state().cancelledDeferred == [cancelledHandle])
        let cancelled = try await fetchDeferred(model: model, handle: cancelledHandle)
        #expect(cancelled.stopReason == .error)
        #expect(cancelled.errorMessage?.contains("was cancelled") == true)
    }

    @Test func a0UnknownAndMismatchedDeferredHandles() async throws {
        let faux = registerFauxProvider(FauxRegistrationOptions(api: Api.piVirtual.rawValue))
        defer { faux.unregister() }
        let model = try #require(faux.getModel())
        let unknown = DeferredHandle(provider: model.provider, modelId: model.id, api: model.api.rawValue, id: "missing")
        let result = try await fetchDeferred(model: model, handle: unknown)
        #expect(result.stopReason == .error)
        #expect(result.errorMessage == "Unknown faux deferred response: missing")
        try await cancelDeferred(model: model, handle: unknown)
        #expect(faux.state().cancelledDeferred == [unknown])
        faux.setResponses([.message(fauxAssistantMessage(content: [fauxText("ready")]))])
        let submitted = try await completeSimple(model: model, context: a0DeferredContext(), options: SimpleStreamOptions(deferred: DeferredRequest()))
        let handle = try #require(submitted.deferred)
        for field in ["provider", "modelId", "api"] {
            var mismatch = handle
            switch field {
            case "provider": mismatch.provider = "other"
            case "modelId": mismatch.modelId = "other"
            default: mismatch.api = "other"
            }
            let failed = try await fetchDeferred(model: model, handle: mismatch)
            #expect(failed.errorMessage == "Unknown faux deferred response: \(handle.id)")
        }
    }

    @Test func a0ProviderWithoutDeferredClosuresThrows() async throws {
        resetApiProviders()
        let model = Model(id: "plain", name: "Plain", api: .openAICompletions, provider: "plain", baseUrl: "", reasoning: false,
            input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 100, maxTokens: 10)
        let handle = DeferredHandle(provider: model.provider, modelId: model.id, api: model.api.rawValue, id: "id")
        do {
            _ = try streamDeferred(model: model, handle: handle)
            Issue.record("Expected unsupported fetch")
        } catch StreamError.deferredUnsupported(let provider) {
            #expect(provider == "plain")
            #expect(StreamError.deferredUnsupported(provider: provider).errorDescription == "Provider plain does not support deferred responses")
        }
        do {
            try await cancelDeferred(model: model, handle: handle)
            Issue.record("Expected unsupported cancellation")
        } catch StreamError.deferredUnsupported(let provider) {
            #expect(provider == "plain")
            #expect(StreamError.deferredUnsupported(provider: provider).errorDescription == "Provider plain does not support deferred responses")
        }
    }
}

@Suite struct A0DeferredPrivateTests {
    @Test func resolvesFactoryOnceForConcurrentFetchesAndStripsSubmissionCallbacks() async throws {
        let model = Model(id: "private", name: "Private", api: .openAICompletions, provider: "faux", baseUrl: "", reasoning: false,
            input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 128_000, maxTokens: 100)
        let faux = FauxProviderRegistration(api: model.api, provider: model.provider, models: [model], sourceId: "private",
            minTokenSize: 3, maxTokenSize: 5, tokensPerSecond: nil)
        let calls = LockedState(0)
        faux.setResponses([.factory { _, options, _, _ in
            calls.withLock { $0 += 1 }
            #expect(options?.deferred == nil)
            #expect(options?.signal == nil)
            #expect(options?.onResponse == nil)
            #expect(options?.temperature == 0.5)
            await Task.yield()
            return fauxAssistantMessage(content: [fauxText("ready")], timestamp: 1)
        }])
        let context = normalizeContext(a0DeferredContext())
        let signal = CancellationToken()
        let callbacks = LockedState(0)
        let submitted = await fauxStream(model: model, context: context, registration: faux,
            simpleOptions: SimpleStreamOptions(temperature: 0.5, signal: signal,
                onResponse: { _ in callbacks.withLock { $0 += 1 } }, deferred: DeferredRequest())).result()
        let handle = try #require(submitted.deferred)
        signal.cancel()
        let one = fauxFetchDeferred(model: model, handle: handle, registration: faux, options: nil)
        let two = fauxFetchDeferred(model: model, handle: handle, registration: faux, options: nil)
        async let first = one.result()
        async let second = two.result()
        let results = await [first, second]
        #expect(results.allSatisfy { $0.stopReason == .stop })
        #expect(calls.withLock { $0 } == 1)
        #expect(callbacks.withLock { $0 } == 1)
        #expect(faux.state().deferredFetchCount == 2)
    }

    @Test func responseCallbackCanCancelBeforeTheEntryCheck() async throws {
        let model = Model(id: "private", name: "Private", api: .openAICompletions, provider: "faux", baseUrl: "", reasoning: false,
            input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 128_000, maxTokens: 100)
        let faux = FauxProviderRegistration(api: model.api, provider: model.provider, models: [model], sourceId: "private",
            minTokenSize: 3, maxTokenSize: 5, tokensPerSecond: nil, deferred: FauxDeferredOptions(pendingFetches: 1))
        faux.setResponses([.message(fauxAssistantMessage(content: [fauxText("ready")]))])
        let submitted = await fauxStream(model: model, context: normalizeContext(a0DeferredContext()), registration: faux,
            simpleOptions: SimpleStreamOptions(deferred: DeferredRequest())).result()
        let handle = try #require(submitted.deferred)
        let result = await fauxFetchDeferred(model: model, handle: handle, registration: faux,
            options: DeferredFetchOptions(onResponse: { response in
                #expect(response.statusCode == 200)
                #expect(faux.state().deferredFetchCount == 1)
                faux.cancelDeferred(handle)
            })).result()
        #expect(result.stopReason == .error)
        #expect(result.errorMessage == "Faux deferred response was cancelled: \(handle.id)")
    }

    @Test(arguments: [StopReason.stop, .pending, .error])
    func repeatedFetchKeepsTheFirstFinalDuration(reason: StopReason) async throws {
        let model = Model(id: "private", name: "Private", api: .openAICompletions, provider: "faux", baseUrl: "", reasoning: false,
            input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 128_000, maxTokens: 100)
        let faux = FauxProviderRegistration(api: model.api, provider: model.provider, models: [model], sourceId: "private",
            minTokenSize: 3, maxTokenSize: 5, tokensPerSecond: nil)
        faux.setResponses([.factory { _, _, _, _ in
            try await Task.sleep(for: .milliseconds(20))
            return fauxAssistantMessage(content: [fauxText("ready")], stopReason: reason, timestamp: Int64.max)
        }])
        let submitted = await fauxStream(model: model, context: normalizeContext(a0DeferredContext()), registration: faux,
            simpleOptions: SimpleStreamOptions(deferred: DeferredRequest())).result()
        let handle = try #require(submitted.deferred)
        let first = await fauxFetchDeferred(model: model, handle: handle, registration: faux, options: nil).result()
        #expect(try #require(first.durationMs) >= 20)
        let repeated = await fauxFetchDeferred(model: model, handle: handle, registration: faux, options: nil).result()
        #expect(repeated.durationMs == first.durationMs)
        #expect(messageToOrderedJSON(.assistant(repeated)).serialized() == messageToOrderedJSON(.assistant(first)).serialized())
    }

    @Test func immediateFactoryFailureIsInBandAndEmptyQueueKeepsItsError() async {
        let model = Model(id: "private", name: "Private", api: .openAICompletions, provider: "faux", baseUrl: "", reasoning: false,
            input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 128_000, maxTokens: 100)
        let faux = FauxProviderRegistration(api: model.api, provider: model.provider, models: [model], sourceId: "private",
            minTokenSize: 3, maxTokenSize: 5, tokensPerSecond: nil)
        faux.setResponses([.factory { _, _, _, _ in throw A0DeferredFailure.failed }])
        let context = normalizeContext(a0DeferredContext())
        let failure = await fauxStream(model: model, context: context, registration: faux, simpleOptions: nil).result()
        #expect(failure.stopReason == .error)
        #expect(failure.errorMessage == "deferred failed")
        let empty = await fauxStream(model: model, context: context, registration: faux, simpleOptions: SimpleStreamOptions(deferred: DeferredRequest())).result()
        #expect(empty.stopReason == .error)
        #expect(empty.errorMessage == "No more faux responses queued")
        #expect(empty.deferred == nil)
    }
}
