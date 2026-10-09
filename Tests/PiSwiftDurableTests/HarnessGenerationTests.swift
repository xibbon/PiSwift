import Testing
import Synchronization
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

struct HarnessGenerationTests {
    @Test func answersAndSettlesSubmission() async throws {
        let setup = HarnessChatSetup()
        try setup.registry.install(Extension(name: "prompt", sections: [section("preamble", tag: false) { _, _ in "You are helpful." }]))
        setup.models.setResponses([.message(chatAssistant("Hello there"))])
        let opened = try await openChat(setup: setup)
        let settled = try await generationSubmit(opened).wait(context: .background)
        #expect(settled.status == "done")
        let entries = try await allEntries(opened.root)
        #expect(entries.map(\.kind) == ["pi.user", "pi.system", "pi.assistant"])
        #expect(try textOf(entries.last?.messages()?.first) == "Hello there")
        #expect(entries[0].byTaskId == nil)
        #expect(entries[1].byTaskId == entries[2].byTaskId)
        #expect(try await generationLive(opened) == LiveState())
        let usage = try await opened.harness.usage(context: .background)
        #expect(usage.models["faux/faux-1"]?.totalTokens ?? 0 > 0)
        try await opened.harness.close(context: .background)
    }
    @Test func endsRunWhoseInputWasAlreadySettled() async throws {
        let setup = HarnessChatSetup(), models = HarnessManualModels(base: FakeDurableModels())
        let opened = try await openChat(setup: setup, models: models), submission = try await generationSubmit(opened)
        try await eventually { models.seen.withLock { !$0.isEmpty } }
        try await opened.root.commit({ tx in try tx.settleSubmission(submission.id, settlement: .unanswered(reason: "withdrawn")) }, context: .background)
        let id = try #require(await generationLive(opened)?.run?.taskId)
        _ = try await opened.harness.abortTask(id: id, context: .background)
        _ = try await opened.harness.waitForTask(id: id, context: .background)
        #expect(try await submission.wait(context: .background).reason == "withdrawn")
        #expect(try await generationLive(opened) == LiveState())
        try await opened.harness.close(context: .background)
    }
    @Test(arguments: [false, true]) func noModel(unset: Bool) async throws {
        let opened = try await openChat(setup: HarnessChatSetup())
        try await opened.root.configure(change: AgentChange(model: unset ? .clear : .set(ModelRef(provider: "faux", modelId: "missing"))), context: .background)
        let settled = try await generationSubmit(opened).wait(context: .background)
        #expect(settled.reason == "no_model")
        #expect(try await allEntries(opened.root).map(\.kind) == ["pi.user"])
        #expect(try await generationLive(opened) == LiveState())
        try await opened.harness.close(context: .background)
    }
    @Test func retryBackoffThenAnswerReadsNewSettings() async throws {
        let clock = TestClock(now: 10)
        let setup = HarnessChatSetup(settings: .init(stream: .init(timeoutMs: 111), retry: .init(baseDelayMs: 20)), clock: clock)
        let seen = Mutex<[Int?]>([])
        setup.models.setResponses([
            .factory { _, options, _, _ in
                seen.withLock { $0.append(options?.timeoutMs) }; setup.updateSettings { $0.stream = .init(timeoutMs: 222) }
                return chatAssistant("", reason: .error, error: "503 Service Unavailable")
            }, .factory { _, options, _, _ in seen.withLock { $0.append(options?.timeoutMs) }; return chatAssistant("ok") }
        ])
        let opened = try await openChat(setup: setup), submission = try await generationSubmit(opened)
        try await eventually { try await generationLive(opened)?.generation?.retry?.at == 30 && clock.pendingSleeperCount > 0 }
        #expect(setup.models.state().callCount == 1)
        clock.advance(by: 19); #expect(setup.models.state().callCount == 1)
        clock.advance(by: 1)
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(seen.withLock { $0 } == [111, 222])
        #expect(try await allEntries(opened.root).filter { $0.kind == assistantEntry.kind }.count == 2)
        try await opened.harness.close(context: .background)
    }
    @Test(arguments: ["exhausted", "disabled", "nonretryable"]) func modelErrorPolicies(mode: String) async throws {
        let retry = RetryPolicyOverrides(enabled: mode != "disabled", maxRetries: mode == "exhausted" ? 0 : 3, baseDelayMs: 0)
        let setup = HarnessChatSetup(settings: .init(retry: retry))
        setup.models.setResponses([.message(chatAssistant("", reason: .error, error: mode == "nonretryable" ? "Invalid API key" : "503 Service Unavailable"))])
        let opened = try await openChat(setup: setup)
        #expect(try await generationSubmit(opened).wait(context: .background).reason == "model_error")
        #expect(setup.models.state().callCount == 1)
        #expect(try await generationLive(opened) == LiveState())
        try await opened.harness.close(context: .background)
    }
    @Test func sectionWrapperFailureIsReported() async throws {
        let setup = HarnessChatSetup()
        try setup.registry.install(Extension(name: "prompt", sections: [section("preamble") { _, _ in "hi" }],
            wraps: [wrapSection("preamble") { _ in throw TaskDefinitionError("wrapper failed") }]))
        setup.models.setResponses([.message(chatAssistant("ok"))])
        let opened = try await openChat(setup: setup)
        #expect(try await generationSubmit(opened).wait(context: .background).status == "done")
        #expect(setup.reports.count > 0)
        try await opened.harness.close(context: .background)
    }
    @Test func deferredPollsUntilReady() async throws {
        let clock = TestClock(now: 10)
        let setup = HarnessChatSetup(options: .init(deferred: .init(pendingFetches: 1, pollAfterMs: 20)),
            settings: .init(stream: .init(deferred: DeferredRequest())), clock: clock)
        setup.models.setResponses([.message(chatAssistant("ready"))])
        let opened = try await openChat(setup: setup), submission = try await generationSubmit(opened)
        try await eventually { try await generationLive(opened)?.generation?.deferred?.pollAt == 30 && clock.pendingSleeperCount > 0 }
        clock.advance(by: 20)
        try await eventually { try await generationLive(opened)?.generation?.deferred?.pollAt == 50 && clock.pendingSleeperCount > 0 }
        clock.advance(by: 20)
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(setup.models.state().deferredFetchCount == 2)
        #expect(try await allEntries(opened.root).filter { $0.kind == assistantEntry.kind }.count == 1)
        try await opened.harness.close(context: .background)
    }
    @Test func abortCancelsDeferred() async throws {
        let clock = TestClock()
        let setup = HarnessChatSetup(settings: .init(stream: .init(deferred: DeferredRequest())), clock: clock)
        setup.models.setResponses([.message(chatAssistant("ready"))])
        let opened = try await openChat(setup: setup), submission = try await generationSubmit(opened)
        try await eventually { try await generationLive(opened)?.generation?.deferred != nil && clock.pendingSleeperCount > 0 }
        try await opened.root.abort(context: .background)
        #expect(try await submission.wait(context: .background).reason == "aborted")
        #expect(setup.models.state().cancelledDeferred.count == 1)
        try await opened.harness.close(context: .background)
    }
    @Test func failedDeferredCancellationIsReported() async throws {
        let clock = TestClock()
        let setup = HarnessChatSetup(clock: clock)
        let models = HarnessManualModels(base: setup.models, cancelFails: true)
        let opened = try await openChat(setup: setup, models: models)
        let submission = try await generationSubmit(opened)
        try await eventually { models.seen.withLock { !$0.isEmpty } }
        var deferred = chatAssistant("", reason: .deferred)
        deferred.content = []; deferred.deferred = DeferredHandle(provider: "faux", modelId: "faux-1", api: "openai-completions", id: "test")
        models.stream.push(.done(reason: .deferred, message: deferred))
        try await eventually { try await generationLive(opened)?.generation?.deferred != nil }
        try await opened.root.abort(context: .background)
        #expect(try await submission.wait(context: .background).reason == "aborted")
        #expect(setup.reports.count == 1)
        try await opened.harness.close(context: .background)
    }
    @Test func streamOptionsAndThinkingLevelAreForwarded() async throws {
        let seen = Mutex<[SimpleStreamOptions]>([])
        let setup = HarnessChatSetup(settings: .init(stream: .init(timeoutMs: 1234, headers: ["x-test": "1"])))
        let step = FakeDurableResponseStep.factory { _, options, _, _ in if let options { seen.withLock { $0.append(options) } }; return chatAssistant("ok") }
        setup.models.setResponses([step, step])
        let opened = try await openChat(setup: setup)
        try await opened.root.configure(change: .init(thinkingLevel: .set(.high)), context: .background)
        _ = try await generationSubmit(opened).wait(context: .background)
        try await opened.root.configure(change: .init(thinkingLevel: .clear), context: .background)
        setup.updateSettings { $0.stream = .init(timeoutMs: 99) }
        _ = try await generationSubmit(opened, "two").wait(context: .background)
        let options = seen.withLock { $0 }, provider = try #require(await opened.harness.snapshot(ProviderDoc, conversationId: opened.root.id, context: .background))
        #expect(options[0].timeoutMs == 1234 && options[0].reasoning == .high && options[0].headers?["x-test"] == "1")
        #expect(options[1].timeoutMs == 99 && options[1].reasoning == nil && options[1].headers == nil)
        #expect(options.allSatisfy { $0.sessionId == provider.sessionId && $0.signal != nil })
        try await opened.harness.close(context: .background)
    }
    @Test func providerSessionIdsStayLocalToConcurrentConversations() async throws {
        let seen = Mutex<[String: String]>([:]), setup = HarnessChatSetup()
        let step = FakeDurableResponseStep.factory { request, options, _, _ in
            let text = request.messages.reversed().compactMap { textOf($0) }.first ?? ""
            seen.withLock { $0[text] = options?.sessionId }; return chatAssistant("ok")
        }
        setup.models.setResponses([step, step, step, step])
        let opened = try await openChat(setup: setup)
        let child = try await opened.harness.createConversation(options: .init(ownership: .ownerless(), agent: .init(model: .set(ModelRef(provider: "faux", modelId: "faux-1")))), context: .background)
        for round in 1...2 {
            async let root = opened.root.submit(.input(content: .text("root-\(round)")), context: .background).wait(context: .background)
            async let other = child.submit(.input(content: .text("child-\(round)")), context: .background).wait(context: .background)
            _ = try await (root, other)
        }
        let ids = seen.withLock { $0 }
        #expect(ids["root-1"] == ids["root-2"] && ids["child-1"] == ids["child-2"])
        #expect(ids["root-1"] != ids["child-1"])
        try await opened.harness.close(context: .background)
    }
    @Test func legacyProviderIdentityIsPersistedBeforeRequest() async throws {
        let setup = HarnessChatSetup(), seen = Mutex<String?>(nil)
        setup.models.setResponses([.factory { _, options, _, _ in seen.withLock { $0 = options?.sessionId }; return chatAssistant("ok") }])
        let opened = try await openChat(setup: setup)
        try await opened.root.commit({ tx in try await tx.retireDoc(ProviderDoc, conversationId: opened.root.id) }, context: .background)
        #expect(try await opened.harness.snapshot(ProviderDoc, conversationId: opened.root.id, context: .background) == nil)
        _ = try await generationSubmit(opened).wait(context: .background)
        let provider = try #require(await opened.harness.snapshot(ProviderDoc, conversationId: opened.root.id, context: .background))
        #expect(seen.withLock { $0 } == provider.sessionId)
        #expect(provider.sessionId.split(separator: "-")[2].first == "7")
        try await opened.harness.close(context: .background)
    }
    @Test func settingsResolveOverDefaults() {
        let value = resolveSettings()
        #expect(value.retry == defaultRetryPolicy && value.compaction == defaultCompactionPolicy && value.progress == defaultProgressPolicy)
        #expect(value.toolExecution == .parallel && value.steeringMode == .oneAtATime && value.followUpMode == .oneAtATime)
        #expect(value.contextRetentionMs == 600000)
        let changed = resolveSettings(.init(retry: .init(enabled: false), compaction: .init(backgroundTokens: 0), progress: .init(outputIntervalMs: 500)))
        #expect(!changed.retry.enabled && changed.retry.maxRetries == 3 && changed.compaction.backgroundTokens == 0)
        #expect(changed.progress == .init(partialIntervalMs: 100, outputIntervalMs: 500))
    }
}
