import Testing
import PiSwiftAI
import PiSwiftChord
import Synchronization
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessRunControlValueTests {
    @Test func documentPoliciesMatchIdleAndRunningStates() throws {
        let info = CheckpointInfo(deltasSinceBase: 1)
        #expect(try InboxDoc.definition.checkpointWhen?(["items": []], [], info) == true)
        #expect(try InboxDoc.definition.checkpointWhen?(["items": [[:]]], [], info) == false)
        #expect(try UsageDoc.definition.checkpointWhen?(["models": [:], "tools": [:]], [], info) == true)
        #expect(try ProviderDoc.definition.checkpointWhen?(["sessionId": "id"], [], info) == true)
        #expect(try LiveDoc.definition.checkpointWhen?([:], [], info) == true)
        #expect(try LiveDoc.definition.checkpointWhen?(["generation": [:]], [], info) == false)
        #expect(try LiveDoc.definition.checkpointWhen?(["tools": [["status": "pending"]]], [], info) == true)
        #expect(try LiveDoc.definition.checkpointWhen?(["tools": [["status": "running"]]], [], info) == false)
        for definition in [LiveDoc.definition, InboxDoc.definition, UsageDoc.definition, ProviderDoc.definition] {
            #expect(definition.version == 1)
            if case .conversation(let history, let fork, _) = definition.semantics {
                #expect(history == .latest)
                #expect(fork == .initial)
            } else { Issue.record("Expected conversation document") }
        }
    }

    @Test func forkGetsFreshProviderAndEmptyRunDocuments() async throws {
        let setup = HarnessChatSetup()
        let held = HarnessUnanswered()
        setup.models.setResponses([held.step])
        let opened = try await openChat(setup: setup)
        _ = try await opened.root.submit(.input(content: .text("first")), context: .background)
        await held.reached.wait()
        _ = try await opened.root.submit(.input(content: .text("queued")), context: .background)
        let entry = try #require(try await allEntries(opened.root).last)
        let fork = try await opened.root.fork(at: entry.id, options: .init(ownership: .ownerless()), context: .background)
        #expect(try await opened.harness.snapshot(LiveDoc, conversationId: fork.id, context: .background) == LiveState())
        #expect(try await opened.harness.snapshot(InboxDoc, conversationId: fork.id, context: .background) == InboxState())
        let parent = try #require(try await opened.harness.snapshot(ProviderDoc, conversationId: opened.root.id, context: .background))
        let child = try #require(try await opened.harness.snapshot(ProviderDoc, conversationId: fork.id, context: .background))
        #expect(parent.sessionId != child.sessionId)
        #expect(child.sessionId.split(separator: "-")[2].first == "7")
        try await opened.root.abort(context: .background)
        try await opened.harness.close(context: .background)
    }

    @Test func publicRunControlExample() async throws {
        let models = FakeDurableModels()
        let held = HarnessGatedResponse(message: chatAssistant("first answer"))
        models.setResponses([held.step, .message(chatAssistant("steered answer"))])
        let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: models, registry: createRegistry()), context: .background)
        let root = try await harness.root(options: .init(agent: AgentChange(model: .set(ModelRef(provider: "faux", modelId: "faux-1")))), context: .background)
        let input = try await root.submit(.input(content: .text("Start"), requestId: "start"), context: .background)
        await held.reached.wait()
        let steer = try await root.submit(.input(content: .text("Use short text"), whenBusy: .steer), context: .background)
        held.release()
        #expect(try await input.wait(context: .background).status == "done")
        #expect(try await steer.wait(context: .background).status == "done")
        #expect(try await harness.usage(context: .background).models["faux/faux-1"] != nil)
        try await harness.close(context: .background)
    }

    @Test func draftAssignmentAppendsStringLeavesAndKeepsContainers() throws {
        let tracker = try Delta.track(["message": ["content": [["type": "text", "text": "a"]], "old": true]])
        let change = tracker.beginChange()
        try assignJSON(target: change.state, key: "message", value: ["content": [["type": "text", "text": "abc"], ["type": "text", "text": "new"]]])
        let prepared = try change.prepare()
        #expect(prepared.ops.contains(.append(["message", "content", 0, "text"], "bc")))
        #expect(prepared.ops.contains(.delete(["message", "old"])))
        #expect(!prepared.ops.contains { if case .set(["message"], _) = $0 { true } else { false } })
        #expect(try Delta.applyImmutable(tracker.value, prepared.ops) == prepared.value)
        prepared.abort()
    }

    @Test func shrinkingArrayUsesOneSet() throws {
        let tracker = try Delta.track(["items": ["a", "b"]])
        let change = tracker.beginChange()
        try assignJSON(target: change.state, key: "items", value: ["a"])
        let prepared = try change.prepare()
        #expect(prepared.ops == [.set(["items"], ["a"])])
        prepared.abort()
    }

    @Test func pinnedStreamOptionsRoundTripUsesUpstreamFields() throws {
        let value = ConversationStreamOptions(transport: .websocketCached, timeoutMs: 123, maxRetries: 2,
            maxRetryDelayMs: 500, headers: ["X-Test": "yes"], metadata: ["extra": .number(1)],
            cacheRetention: .long, deferred: DeferredRequest(window: .oneHour))
        let raw = try JSONValue(encoding: value)
        #expect(raw.objectValue?["transport"] == .string("websocket-cached"))
        #expect(raw.objectValue?["deferred"] == .object(["window": .string("1h")]))
        let decoded = try raw.decode(ConversationStreamOptions.self)
        #expect(try JSONValue(encoding: decoded) == raw)
        #expect(try JSONValue(encoding: ConversationStreamOptions()) == .object([:]))
    }

    @Test func usageWritesAccumulateOptionalCountersAndNamedBuckets() async throws {
        let session = try await Session.open(storage: MemoryStorage(), context: .background)
        try await session.commit({ tx in
            _ = try await tx.createRootConversation()
            let usage = Usage(input: 3, output: 4, cacheRead: 1, cacheWrite: 2, cacheWrite1h: 5,
                              reasoning: 6, totalTokens: 10,
                              cost: UsageCost(input: 1, output: 2, cacheRead: 3, cacheWrite: 4, total: 10))
            try await recordUsage(tx: tx, conversationId: rootConversationID, bucket: .models, key: "faux/test", usage: usage)
            try await recordUsage(tx: tx, conversationId: rootConversationID, bucket: .models, key: "faux/test", usage: usage)
            for key in ["toString", "constructor", "prototype", "__proto__"] {
                try await recordUsage(tx: tx, conversationId: rootConversationID, bucket: .tools, key: key, usage: usage)
            }
        }, context: .background)
        let state = try #require(try await session.snapshot(UsageDoc, conversationId: rootConversationID, context: .background))
        #expect(state.models["faux/test"]?.totalTokens == 20)
        #expect(state.models["faux/test"]?.reasoning == 12)
        #expect(state.models["faux/test"]?.cacheWrite1h == 10)
        #expect(state.models["faux/test"]?.cost.total == 20)
        for key in ["toString", "constructor", "prototype", "__proto__"] {
            #expect(state.tools[key]?.totalTokens == 10)
        }
        try await session.close(context: .background)
    }

    // upstream harness-inbox.test.ts:903; tool execution is supplied in H7.
    @Test func usagePublishesNumericSetsInTheAssistantEntryCommit() async throws {
        let session = try await Session.open(storage: MemoryStorage(), context: .background)
        try await session.commit({ tx in
            _ = try await tx.createRootConversation()
            _ = try await tx.doc(UsageDoc, conversationId: rootConversationID)
        }, context: .background)
        var response = chatAssistant("answer")
        response.usage = Usage(input: 3, output: 4, cacheRead: 1, cacheWrite: 2, totalTokens: 10)
        let message = response
        try await session.commit({ tx in
            _ = try await appendGenerationAssistant(tx: tx, conversationId: rootConversationID, message: message)
        }, context: .background)
        let publications = Mutex<[CommitPublication]>([])
        let listener = try session.subscribeCommits { publication, _ in publications.withLock { $0.append(publication) } }
        try await session.commit({ tx in
            _ = try await appendGenerationAssistant(tx: tx, conversationId: rootConversationID, message: message)
        }, context: .background)
        let publication = try #require(publications.withLock { $0.last })
        let usage = try #require(publication.changes.compactMap { change -> DocumentCommitChange? in
            if case .document(let document) = change, document.record.kind == "pi.usage" { return document }
            return nil
        }.first)
        #expect(usage.ops.contains(.set(["models", "faux/faux-1", "totalTokens"], .number(20))))
        #expect(usage.ops.allSatisfy { if case .set(_, .number) = $0 { true } else { false } })
        #expect(publication.changes.contains { if case .entry = $0 { true } else { false } })
        listener.cancel()
        try await session.close(context: .background)
    }

    // upstream harness-inbox.test.ts:773,853; no H7 execution is needed for ledger assertions.
    @Test func harnessUsageSumsOwnSpendAndForkStartsAtZero() async throws {
        let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: FakeDurableModels(), registry: createRegistry()), context: .background)
        let root = try await harness.root(context: .background)
        let first = try await root.commit({ tx in
            let entry = try await appendGenerationAssistant(tx: tx, conversationId: root.id, message: chatAssistant("answer"))
            try await recordUsage(tx: tx, conversationId: root.id, bucket: .tools, key: "__proto__", usage: Usage(input: 2, output: 3, cacheRead: 0, cacheWrite: 0, totalTokens: 5))
            return entry.id
        }, context: .background)
        let fork = try await root.fork(at: first, options: .init(ownership: .ownerless()), context: .background)
        let initial = try #require(try await harness.snapshot(UsageDoc, conversationId: fork.id, context: .background))
        #expect(initial.models.isEmpty && initial.tools.isEmpty)
        try await fork.commit({ tx in
            try await recordUsage(tx: tx, conversationId: fork.id, bucket: .tools, key: "__proto__", usage: Usage(input: 3, output: 4, cacheRead: 0, cacheWrite: 0, totalTokens: 7))
        }, context: .background)
        #expect(try await harness.usage(context: .background).tools["__proto__"]?.totalTokens == 12)
        try await harness.close(context: .background)
    }
}
