import Testing
import Synchronization
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private final class HarnessObserverLog<Value: Sendable>: Sendable {
    let calls = SessionTestLog<WatchCall<Value>>()
    let ends = SessionTestLog<WatchEnd>()
    var observer: Observer<Value> {
        Observer(advance: { [self] call, context in
            #expect(context.abortSignal == nil)
            guard case .value = call else { Issue.record("Unexpected failure call"); return }
            calls.append(call)
        }, end: { [self] in ends.append($0) })
    }
}
private final class HarnessObserverProbe: Sendable {}
private struct HarnessObserverReferences: Sendable {
    weak var view: HarnessObserverProbe?
    weak var graph: HarnessObserverProbe?
}

// v1.5.2 CH3: harness-observers.test.ts, conversation and graph observers.
@Suite struct HarnessObserverTests {
    @Test(.timeLimit(.minutes(1))) func publicationIsSynchronousAndMatchesTheWatch() async throws {
        let opened = try await openTasks(tasks: []), harness = opened.harness
        let root = try await harness.root(context: .background)
        let view = HarnessObserverLog<ConversationView>(), graph = HarnessObserverLog<TaskGraph>()
        let observedView = try await harness.observeConversation(root.id, observer: view.observer, context: .background)
        let observedGraph = try await harness.observeTaskGraph(graph.observer, context: .background)
        #expect(observedView.value.conversation.id == root.id)
        #expect(observedGraph.value == TaskGraph())
        let watch = try await root.watch(context: .background), watched = SessionTestLog<WatchCall<ConversationView>>()
        try watch.start { call, _ in watched.append(call) }
        let entry = try await failureNote(root)
        #expect(view.calls.count == 1)
        guard case .value(let value, _, let retired) = try #require(view.calls.values.first) else { return }
        #expect(!retired && value.entries.last?.id == entry.id)
        await watch.waitUntilIdle()
        #expect(watched.values == view.calls.values)
        #expect(graph.calls.values.isEmpty)
        observedView.detach(); observedView.detach()
        _ = try await failureNote(root)
        #expect(view.calls.count == 1)
        _ = await watch.stop()
        let graphWatch = try await harness.watchTaskGraph(context: .background)
        try await harness.close(context: .background)
        #expect(graph.ends.values == [.failed(.message("session closed"))])
        #expect(await graphWatch.closed == .ended)
        #expect(view.ends.values.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func storageFailureEndsBothObserversWithTheFailure() async throws {
        let storage = ControlledStorage(), opened = try await openTasks(storage: storage, tasks: [])
        let harness = opened.harness, root = try await harness.root(context: .background)
        let view = HarnessObserverLog<ConversationView>(), graph = HarnessObserverLog<TaskGraph>()
        _ = try await harness.observeConversation(root.id, observer: view.observer, context: .background)
        _ = try await harness.observeTaskGraph(graph.observer, context: .background)
        let failure = HarnessStorageFailure("observer disk gone")
        await storage.failNextCommit(failure)
        await expectStorageFailure(failure) { try await failureNote(root) }
        _ = await harness.closed
        let expected = WatchEnd.failed(.message(String(describing: failure)))
        #expect(view.ends.values == [expected] && graph.ends.values == [expected])
        #expect(view.calls.values.isEmpty && graph.calls.values.isEmpty)
        try await harness.close(context: .background)
    }

    @Test(.timeLimit(.minutes(1))) func throwingObserverDetachesAndLeavesHealthyObserversActive() async throws {
        let opened = try await openTasks(tasks: []), harness = opened.harness
        let root = try await harness.root(context: .background)
        let bug = HarnessStorageFailure("observer bug"), ends = SessionTestLog<WatchEnd>()
        _ = try await harness.observeConversation(root.id, observer: Observer(advance: { _, _ in throw bug },
            end: { ends.append($0) }), context: .background)
        let healthy = HarnessObserverLog<ConversationView>()
        _ = try await harness.observeConversation(root.id, observer: healthy.observer, context: .background)
        _ = try await failureNote(root); _ = try await failureNote(root)
        #expect(opened.reports.count == 1)
        #expect((opened.reports.values.first as? HarnessStorageFailure) === bug)
        #expect(opened.reports.infos == [.listenerError])
        #expect(ends.values == [.listenerError(String(describing: bug))])
        #expect(healthy.calls.count == 2)
        try await harness.close(context: .background)
        #expect(ends.count == 1)
        #expect(harness.failure == nil)
    }

    @Test(.timeLimit(.minutes(1))) func closedHarnessRejectsAttachments() async throws {
        let opened = try await openTasks(tasks: []), harness = opened.harness
        let root = try await harness.root(context: .background)
        try await harness.close(context: .background)
        await #expect(throws: HarnessClosedError.self) {
            _ = try await harness.observeConversation(root.id, observer: HarnessObserverLog<ConversationView>().observer, context: .background)
        }
        await #expect(throws: HarnessClosedError.self) {
            _ = try await harness.observeTaskGraph(HarnessObserverLog<TaskGraph>().observer, context: .background)
        }
    }

    @Test(.timeLimit(.minutes(1))) func cancelledQueuedAttachmentsRegisterNothing() async throws {
        let storage = ControlledStorage(), opened = try await openTasks(storage: storage, tasks: [])
        let harness = opened.harness, root = try await harness.root(context: .background)
        let view = HarnessObserverLog<ConversationView>(), graph = HarnessObserverLog<TaskGraph>()
        // v1.5.2 D3a harness-tasks.test.ts:87–101: hold the callback on the line.
        let held = holdSessionLine(harness.session) { tx in _ = try await tx.appendEntry(root.id, value: .init(kind: "note")) }
        let controller = AbortController()
        await held.waitUntilEntered()
        let context = ChordContext.background.withAbortSignal(controller.signal)
        let attachingView = Task { try await harness.observeConversation(root.id, observer: view.observer, context: context) }
        let attachingGraph = Task { try await harness.observeTaskGraph(graph.observer, context: context) }
        try await eventually { harness.session.line.queuedCount >= 2 }
        controller.abort(TaskDefinitionError("gone"))
        held.release(); try await held.finish()
        await #expect(throws: TaskDefinitionError("gone")) { _ = try await attachingView.value }
        await #expect(throws: TaskDefinitionError("gone")) { _ = try await attachingGraph.value }
        _ = try await failureNote(root)
        try await harness.close(context: .background)
        #expect(view.calls.values.isEmpty && view.ends.values.isEmpty)
        #expect(graph.calls.values.isEmpty && graph.ends.values.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func registryRefreshAdvancesGraphWithoutACommit() async throws {
        let missing = harnessOneStep("test.observer-missing") { _, runtime, context in
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }
        let storage = ControlledStorage(), opened = try await openTasks(storage: storage, tasks: [])
        let harness = opened.harness, root = try await harness.root(context: .background)
        let graph = HarnessObserverLog<TaskGraph>()
        let observation = try await harness.observeTaskGraph(graph.observer, context: .background)
        let id = try await harnessStart(root, missing), key = String(id.rawValue)
        #expect(graph.calls.count == 1)
        guard case .value(let initial, _, let retired) = try #require(graph.calls.values.first) else { return }
        #expect(initial.tasks[key]?.blocked == .missingTask && !retired)
        let writes = await storage.admittedCommits.count
        try opened.registry.install(Extension(name: "late", tasks: [AnyTaskDefinition(missing)]))
        try await eventually { graph.calls.count == 2 }
        guard case .value(let current, let ops, _) = graph.calls.values[1] else { return }
        #expect(current.tasks[key]?.blocked == nil)
        #expect(ops == [.delete(["tasks", .key(key), "blocked"])])
        #expect(await storage.admittedCommits.count == writes)
        try harness.resume(); _ = try await harness.waitForTask(id: id, context: .background)
        observation.detach(); try await harness.close(context: .background)
    }

    @Test(.timeLimit(.minutes(1))) func detachReleasesObserverClosures() async throws {
        let opened = try await openTasks(tasks: []), harness = opened.harness
        let root = try await harness.root(context: .background)
        func attach() async throws -> (Observation<ConversationView>, Observation<TaskGraph>, HarnessObserverReferences) {
            let view = HarnessObserverProbe(), graph = HarnessObserverProbe()
            let observedView = try await harness.observeConversation(root.id, observer: Observer(
                advance: { [view] _, _ in withExtendedLifetime(view) {} }, end: { _ in }), context: .background)
            let observedGraph = try await harness.observeTaskGraph(Observer(
                advance: { [graph] _, _ in withExtendedLifetime(graph) {} }, end: { _ in }), context: .background)
            return (observedView, observedGraph, HarnessObserverReferences(view: view, graph: graph))
        }
        let (view, graph, references) = try await attach()
        #expect(references.view != nil && references.graph != nil)
        view.detach(); graph.detach()
        #expect(references.view == nil && references.graph == nil)
        try await harness.close(context: .background)
    }

    @Test(.timeLimit(.minutes(1))) func cancellationAfterAttachmentDoesNotDetachHostObservers() async throws {
        let opened = try await openTasks(tasks: []), harness = opened.harness
        let root = try await harness.root(context: .background), controller = AbortController()
        let view = HarnessObserverLog<ConversationView>()
        let observation = try await harness.observeConversation(root.id, observer: view.observer,
            context: .background.withAbortSignal(controller.signal))
        controller.abort()
        _ = try await failureNote(root)
        #expect(view.calls.count == 1 && view.ends.values.isEmpty)
        observation.detach(); try await harness.close(context: .background)
    }
}
