import PiSwiftChord
import Testing
@testable import PiSwiftDurable

struct ObservationStateDelivery: Sendable, Equatable { let value: ObservationValue?; let sequence: Int }

@Suite struct SessionStateTests {
    @Test("never creates an absent document") func absent() async throws {
        let harness = try await openTestSession(); let token = try observationToken(); let family = try SessionDocFamilyToken<JSONObject, String>(kind: "state.family", version: 1, initial: { ["value": .number(Double($0.count))] })
        #expect(try await harness.session.documentState(token, context: .background) == nil)
        #expect(try await harness.session.documentState(family, key: "missing", context: .background) == nil)
        #expect(await harness.storage.commits.isEmpty); #expect(await harness.storage.mintCount == 0)
    }

    @Test("returns an immediately hydrated read-only state with contiguous Chord deliveries") func hydratedAndContiguous() async throws {
        let (harness, token) = try await createObservationState(); let baseline = try await harness.session.snapshot(token, context: .background)
        let state = try #require(try await harness.session.documentState(token, context: .background)); let log = SessionTestLog<ObservationStateDelivery>()
        state.subscribe { value, _, delivery in log.append(.init(value: value, sequence: delivery.sequence)) }
        #expect(state.value == baseline); await state.waitUntilIdle()
        try await setObservation(1, harness, token); try await setObservation(2, harness, token); await state.waitUntilIdle()
        #expect(log.values.map(\.sequence) == [0, 1, 2]); #expect(log.values.map { $0.value?.value } == [0, 1, 2])
        #expect(state.value == (try await harness.session.snapshot(token, context: .background))); state.dispose()
    }

    @Test("creates independent disposable states for one incarnation") func independentDisposal() async throws {
        let (harness, token) = try await createObservationState(); let first = try #require(try await harness.session.documentState(token, context: .background)); let second = try #require(try await harness.session.documentState(token, context: .background))
        #expect(first !== second); try await setObservation(1, harness, token); await first.waitUntilIdle(); await second.waitUntilIdle()
        #expect(first.value?.value == 1); #expect(second.value?.value == 1)
        first.dispose(); try await setObservation(2, harness, token); await second.waitUntilIdle()
        #expect(first.value?.value == 1); #expect(second.value?.value == 2); second.dispose()
    }

    @Test("shares exact committed value and operation references with Chord") func exactCommittedOps() async throws {
        let (harness, token) = try await createObservationState(); let state = try #require(try await harness.session.documentState(token, context: .background)); let batches = SessionTestLog<[Delta.Op]>()
        state.subscribeOperations { ops, _, _ in batches.append(ops) }
        try await setObservation(4, harness, token); await state.waitUntilIdle()
        let published = documentChanges(harness.publications.values.last!)[0]
        #expect(state.value?.value == 4); #expect(batches.values == [published.ops]); #expect(state.value?.retained == (try await harness.session.snapshot(token, context: .background))?.retained); state.dispose()
    }

    @Test("captures a late baseline without redelivering an already covered commit") func lateBaseline() async throws {
        let (harness, token) = try await createObservationState(); try await setObservation(1, harness, token)
        let state = try #require(try await harness.session.documentState(token, context: .background)); let deliveries = SessionTestLog<Int>()
        state.subscribe { _, _, delivery in deliveries.append(delivery.sequence) }; await state.waitUntilIdle()
        #expect(state.value?.value == 1); #expect(deliveries.values == [0]); state.dispose()
    }

    @Test("publishes null retirement and never follows a replacement incarnation") func retirementAndReplacement() async throws {
        let (harness, token) = try await createObservationState(); let old = try #require(try await harness.session.documentState(token, context: .background)); let batches = SessionTestLog<[Delta.Op]>()
        old.subscribeOperations { ops, _, _ in batches.append(ops) }
        try await harness.session.commit({ tx in try await tx.retireDoc(token); try await tx.doc(token).set("value", 10) }, context: .background); await old.waitUntilIdle()
        #expect(old.value == nil); #expect(batches.values == [[.replace(nil)]])
        let replacement = try #require(try await harness.session.documentState(token, context: .background)); #expect(replacement.value?.value == 10)
        try await setObservation(11, harness, token); await replacement.waitUntilIdle()
        #expect(old.value == nil); #expect(replacement.value?.value == 11); old.dispose(); replacement.dispose()
    }

    @Test("cold-loads a definition-free fork copy") func coldForkCopy() async throws {
        let harness = try await openTestSession(); let token = try ConversationDocToken<DefinitionState>(kind: "state.copied", version: 1, fork: .current, initial: { .init(value: 0) }); let parent = try await createConversation(harness.session)
        let entry = try await harness.session.commit({ tx in let entry = try await tx.appendEntry(parent, value: EntryDraft(kind: "point")); try await tx.doc(token, conversationId: parent).set("value", 7); return entry.id }, context: .background)
        let child = try await harness.session.commit({ tx in try await tx.forkConversation(parent, at: entry, ownership: .ownerless()).id }, context: .background)
        let reads = await harness.storage.documentReadCount; let state = try #require(try await harness.session.documentState(token, conversationId: child, context: .background))
        #expect(state.value == .init(value: 7)); #expect(await harness.storage.documentReadCount > reads); state.dispose()
    }

    @Test("hydrates a migrated tracker without writing and skips an equal version-base update") func migration() async throws {
        let harness = try await openTestSession(); let old = try SessionDocToken<JSONObject>(kind: "state.migration", version: 1, initial: { ["value": 3] }); let current = try SessionDocToken<JSONObject>(kind: "state.migration", version: 2, initial: { ["value": 0, "migrated": false] }, migrate: { value, _ in ["value": value["value"]!, "migrated": true] })
        try await harness.session.commit({ tx in _ = try await tx.doc(old) }, context: .background); try await harness.session.unloadDocuments(); let commits = await harness.storage.commits.count
        let state = try #require(try await harness.session.documentState(current, context: .background)); #expect(state.value == ["value": 3, "migrated": true]); #expect(await harness.storage.commits.count == commits)
        let batches = SessionTestLog<[Delta.Op]>(); state.subscribeOperations { ops, _, _ in batches.append(ops) }
        try await harness.session.commit({ tx in _ = try await tx.doc(current) }, context: .background); await state.waitUntilIdle()
        #expect(await harness.storage.commits.count == commits + 1); #expect(state.value == ["value": 3, "migrated": true]); #expect(batches.count == 0)
        try await harness.session.commit({ tx in try await tx.doc(current).set("value", 4) }, context: .background); await state.waitUntilIdle()
        #expect(state.value == ["value": 4, "migrated": true]); #expect(batches.count == 1); state.dispose()
    }

    @Test("continues from exact committed values after the tracker cache unloads") func cacheUnload() async throws {
        let (harness, token) = try await createObservationState(); let state = try #require(try await harness.session.documentState(token, context: .background)); let baseline = state.value; let reads = await harness.storage.documentReadCount
        try await harness.session.unloadDocuments(); #expect(try await harness.session.snapshot(token, context: .background) == baseline); #expect(await harness.storage.documentReadCount > reads)
        try await setObservation(6, harness, token); await state.waitUntilIdle(); #expect(state.value?.value == 6); state.dispose()
    }

    @Test("exposes trusted shared immutable values without freezing") func immutableValues() async throws {
        let (harness, token) = try await createObservationState(); let snapshot = try await harness.session.snapshot(token, context: .background); let state = try #require(try await harness.session.documentState(token, context: .background))
        #expect(state.value == snapshot); #expect(state.value?.retained.label == "stable"); state.dispose()
        // JavaScript object identity and Object.isFrozen have no Swift value-type equivalent.
    }

    @Test("observes all typed scopes and families") func scopeAndFamilyOverloads() async throws {
        let harness = try await openTestSession(); let tokens = try DefinitionTokens(); let conversation = try await createConversation(harness.session)
        let kind = TaskKind<JSONObject, JSONObject>(name: "observation-scopes", version: 1, initial: { $0 })
        let task = try await harness.session.commit({ tx in try await tx.createTask(kind, input: [:], options: TaskOptions(ownership: .conversation(), conversationId: conversation)) }, context: .background)
        try await harness.session.commit({ tx in
            _ = try await tx.doc(tokens.session); _ = try await tx.doc(tokens.latest, conversationId: conversation); _ = try await tx.doc(tokens.rewindable, conversationId: conversation); _ = try await tx.doc(tokens.task, taskId: task)
            _ = try await tx.doc(tokens.sessionFamily, key: "k", seed: 0); _ = try await tx.doc(tokens.latestFamily, conversationId: conversation, key: "k", seed: 0); _ = try await tx.doc(tokens.rewindableFamily, conversationId: conversation, key: "k", seed: 0); _ = try await tx.doc(tokens.taskFamily, taskId: task, key: "k", seed: 0)
        }, context: .background)
        let watches = try await [
            harness.session.watchDoc(tokens.session, context: .background), harness.session.watchDoc(tokens.latest, conversationId: conversation, context: .background), harness.session.watchDoc(tokens.rewindable, conversationId: conversation, context: .background), harness.session.watchDoc(tokens.task, taskId: task, context: .background),
            harness.session.watchDoc(tokens.sessionFamily, key: "k", context: .background), harness.session.watchDoc(tokens.latestFamily, conversationId: conversation, key: "k", context: .background), harness.session.watchDoc(tokens.rewindableFamily, conversationId: conversation, key: "k", context: .background), harness.session.watchDoc(tokens.taskFamily, taskId: task, key: "k", context: .background)
        ].compactMap { $0 }
        let states = try await [
            harness.session.documentState(tokens.session, context: .background), harness.session.documentState(tokens.latest, conversationId: conversation, context: .background), harness.session.documentState(tokens.rewindable, conversationId: conversation, context: .background), harness.session.documentState(tokens.task, taskId: task, context: .background),
            harness.session.documentState(tokens.sessionFamily, key: "k", context: .background), harness.session.documentState(tokens.latestFamily, conversationId: conversation, key: "k", context: .background), harness.session.documentState(tokens.rewindableFamily, conversationId: conversation, key: "k", context: .background), harness.session.documentState(tokens.taskFamily, taskId: task, key: "k", context: .background)
        ].compactMap { $0 }
        #expect(watches.count == 8); #expect(states.count == 8)
        for watch in watches { try watch.start { _, _, _ in } }
        try await harness.session.commit({ tx in
            try await tx.doc(tokens.session).set("value", 9); try await tx.doc(tokens.latest, conversationId: conversation).set("value", 9); try await tx.doc(tokens.rewindable, conversationId: conversation).set("value", 9); try await tx.doc(tokens.task, taskId: task).set("value", 9)
            try await tx.doc(tokens.sessionFamily, key: "k", seed: 0).set("value", 9); try await tx.doc(tokens.latestFamily, conversationId: conversation, key: "k", seed: 0).set("value", 9); try await tx.doc(tokens.rewindableFamily, conversationId: conversation, key: "k", seed: 0).set("value", 9); try await tx.doc(tokens.taskFamily, taskId: task, key: "k", seed: 0).set("value", 9)
        }, context: .background)
        for watch in watches { await watch.waitUntilIdle(); #expect(watch.value?.value == 9); _ = await watch.stop() }
        for state in states { await state.waitUntilIdle(); #expect(state.value?.value == 9); state.dispose() }
    }
}
