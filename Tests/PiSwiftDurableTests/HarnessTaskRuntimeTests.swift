import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private struct RuntimePing: Sendable { let call: @Sendable () throws -> Void }
private func runtimeTool(_ name: String) throws -> ToolRegistration {
    try ToolRegistration(name: name, description: name,
        parameters: ["type": .string("object")]) { _, _, _ in ToolExecutionResult(content: []) }
}
private func expectRuntimeEnded<Value>(_ operation: () async throws -> Value) async {
    do { _ = try await operation(); Issue.record("Ended invocation operation returned") }
    catch { #expect(String(describing: error).contains("invocation has ended")) }
}

@Suite struct HarnessTaskRuntimeTests {
    // upstream harness-tasks.test.ts:361,410
    @Test func phaseSnapshotsAndLazyAgentStayFixedUntilNextPhase() async throws {
        let beforeUse = SessionTestGate(), firstUse = SessionTestGate(), afterUse = SessionTestGate(), entered = SessionTestGate()
        let seen = SessionTestLog<String>(), pings = SessionTestLog<String>()
        let definition = harnessOneStep("test.runtime-phases") { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                entered.release(); await beforeUse.wait()
                let first = try await runtime.agent(context: context)
                try await runtime.hooks.each(RuntimePing.self, context: context) { try $0.call() }
                seen.append("first:\(first.thinkingLevel.rawValue):\(runtime.registry.tools().count)")
                firstUse.release(); await afterUse.wait()
                let second = try await runtime.agent(context: context)
                try await runtime.hooks.each(RuntimePing.self, context: context) { try $0.call() }
                seen.append("same:\(second.thinkingLevel.rawValue):\(runtime.registry.tools().count)")
                try await runtime.commit({ _, _ in .running(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined))) }, context: context)
            case .joined:
                let next = try await runtime.agent(context: context)
                try await runtime.hooks.each(RuntimePing.self, context: context) { try $0.call() }
                seen.append("next:\(next.thinkingLevel.rawValue):\(runtime.registry.tools().count)")
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
            }
        }
        let registry = Registry()
        try registry.install(Extension(name: "before", hooks: [hook(definition.name, handlers: RuntimePing(call: { pings.append("before") }))]))
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], registry: registry)
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, definition)
        try harness.resume(); await entered.wait()
        try await root.configure(change: AgentChange(thinkingLevel: .set(.low)), context: .background)
        beforeUse.release(); await firstUse.wait()
        try registry.install(Extension(name: "late", tools: [try runtimeTool("late")],
            hooks: [hook(definition.name, handlers: RuntimePing(call: { pings.append("late") }))]))
        try await root.configure(change: AgentChange(thinkingLevel: .set(.high)), context: .background)
        afterUse.release()
        _ = try await harness.waitForTask(id: id, context: .background)
        #expect(seen.values == ["first:low:0", "same:low:0", "next:high:1"])
        #expect(pings.values == ["before", "before", "before", "late"])
        try await harness.close(context: .background)
    }

    // upstream harness-tasks.test.ts:479
    @Test func cancelledAgentCallerDoesNotCancelPhaseResolution() async throws {
        let seen = SessionTestLog<String>()
        let definition = harnessOneStep("test.runtime-agent-cancel") { _, runtime, context in
            let caller = context.withCancel(); caller.cancel(TaskDefinitionError("caller gone"))
            do { _ = try await runtime.agent(context: caller.context); Issue.record("Cancelled agent returned") }
            catch { seen.append(String(describing: error)) }
            seen.append(try await runtime.agent(context: context).thinkingLevel.rawValue)
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)])
        let root = try await harness.root(context: .background)
        _ = try await harness.waitForTask(id: harnessStart(root, definition), context: .background)
        #expect(seen.values == ["caller gone", "off"])
        try await harness.close(context: .background)
    }

    // upstream harness-tasks.test.ts:496. A stored decode failure replaces its throwing JS settings getter.
    @Test func failedAgentResolutionRemainsObservedAfterCallerStopsWaiting() async throws {
        let seen = SessionTestLog<String>()
        let definition = harnessOneStep("test.runtime-agent-failure") { _, runtime, context in
            let caller = context.withCancel(); caller.cancel(TaskDefinitionError("caller gone"))
            do { _ = try await runtime.agent(context: caller.context) } catch { seen.append("caller") }
            do { _ = try await runtime.agent(context: context); Issue.record("Invalid agent returned") }
            catch { seen.append("resolution") }
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)])
        let root = try await harness.root(context: .background)
        try await root.commit({ tx in try await tx.doc(AgentDoc, conversationId: root.id).set("model", .number(1)) }, context: .background)
        _ = try await harness.waitForTask(id: harnessStart(root, definition), context: .background)
        #expect(seen.values == ["caller", "resolution"])
        try await harness.close(context: .background)
    }

    // upstream harness-tasks.test.ts:523,655; all D4 document token families are also checked.
    @Test func documentReadsAndWatchesAreBoundToInvocation() async throws {
        let tokens = try DefinitionTokens()
        let captured = Mutex<TaskRuntime?>(nil)
        let watches = SessionTestLog<CommittedWatch<DefinitionState?>>()
        let delivered = SessionTestLog<Int>()
        let definition = harnessOneStep("test.runtime-documents") { _, runtime, context in
            captured.withLock { $0 = runtime }
            try await runtime.commit({ tx, _ in
                _ = try await tx.doc(tokens.session)
                _ = try await tx.doc(tokens.sessionFamily, key: "k", seed: 7)
                _ = try await tx.doc(tokens.latest, conversationId: runtime.conversationId)
                _ = try await tx.doc(tokens.latestFamily, conversationId: runtime.conversationId, key: "k", seed: 7)
                _ = try await tx.doc(tokens.rewindable, conversationId: runtime.conversationId)
                _ = try await tx.doc(tokens.rewindableFamily, conversationId: runtime.conversationId, key: "k", seed: 7)
                _ = try await tx.doc(tokens.task, taskId: runtime.taskId)
                _ = try await tx.doc(tokens.taskFamily, taskId: runtime.taskId, key: "k", seed: 7)
                return nil
            }, context: context)
            #expect(try await runtime.snapshot(tokens.session, context: context)?.value == 0)
            #expect(try await runtime.snapshot(tokens.sessionFamily, key: "k", context: context)?.value == 7)
            #expect(try await runtime.snapshot(tokens.latest, conversationId: runtime.conversationId, context: context)?.value == 0)
            #expect(try await runtime.snapshot(tokens.latestFamily, conversationId: runtime.conversationId, key: "k", context: context)?.value == 7)
            #expect(try await runtime.snapshot(tokens.rewindable, conversationId: runtime.conversationId, context: context)?.value == 0)
            #expect(try await runtime.snapshot(tokens.rewindableFamily, conversationId: runtime.conversationId, key: "k", context: context)?.value == 7)
            #expect(try await runtime.snapshot(tokens.task, taskId: runtime.taskId, context: context)?.value == 0)
            #expect(try await runtime.snapshot(tokens.taskFamily, taskId: runtime.taskId, key: "k", context: context)?.value == 7)
            let acquired = try await [
                runtime.watchDoc(tokens.session, context: context),
                runtime.watchDoc(tokens.sessionFamily, key: "k", context: context),
                runtime.watchDoc(tokens.latest, conversationId: runtime.conversationId, context: context),
                runtime.watchDoc(tokens.latestFamily, conversationId: runtime.conversationId, key: "k", context: context),
                runtime.watchDoc(tokens.rewindable, conversationId: runtime.conversationId, context: context),
                runtime.watchDoc(tokens.rewindableFamily, conversationId: runtime.conversationId, key: "k", context: context),
                runtime.watchDoc(tokens.task, taskId: runtime.taskId, context: context),
                runtime.watchDoc(tokens.taskFamily, taskId: runtime.taskId, key: "k", context: context)
            ]
            for (index, watch) in acquired.enumerated() {
                let watch = try #require(watch)
                watches.append(watch)
                if index == 0 { try watch.start { value, _, _ in delivered.append(value?.value ?? -1) } }
            }
            let stopped = try #require(acquired[2])
            _ = await stopped.stop()
            try await harnessEventually { runtime.invocation.state.withLock { $0.watches.count == 7 } }
            let absent = try SessionDocToken<DefinitionState>(kind: "test.runtime-absent", version: 1, initial: { .init(value: 0) })
            #expect(try await runtime.watchDoc(absent, context: context) == nil)
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)])
        let root = try await harness.root(context: .background)
        _ = try await harness.waitForTask(id: harnessStart(root, definition), context: .background)
        let runtime = try #require(captured.withLock { $0 })
        try await harnessEventually { do { _ = try runtime.now(); return false } catch { return true } }
        for watch in watches.values {
            let end = await watch.closed
            switch end { case .stopped, .retired: break; default: Issue.record("Watch did not stop or retire") }
        }
        try await root.commit({ tx in try await tx.doc(tokens.session).set("value", .number(9)) }, context: .background)
        #expect(delivered.values.isEmpty)
        await expectRuntimeEnded { try await runtime.snapshot(tokens.session, context: .background) }
        await expectRuntimeEnded { try await runtime.watchDoc(tokens.session, context: .background) }
        await expectRuntimeEnded { try await runtime.agent(context: runtime.context) }
        #expect(throws: (any Error).self) { _ = try runtime.now() }
        #expect(throws: (any Error).self) { try runtime.report(TaskDefinitionError("late")) }
        try await harness.close(context: .background)
    }

    // upstream harness-tasks.test.ts:580
    @Test func readsHistoricalDocumentsAndContextAndForwardsClockAndReport() async throws {
        let notes = try RewindableConversationDocToken<DefinitionState>(kind: "test.runtime-history", version: 1, fork: .asOf, initial: { .init(value: 0) })
        let family = try RewindableConversationDocFamilyToken<DefinitionState, Int>(kind: "test.runtime-history-family", version: 1, fork: .asOf, initial: { .init(value: $0) })
        let seen = SessionTestLog<Int>(), reports = SessionTestLog<String>()
        let definition = harnessOneStep("test.runtime-reader") { _, runtime, context in
            let entries = try await runtime.context(runtime.conversationId, context: context).entries
            let first = try #require(entries.first?.id), second = try #require(entries.last?.id)
            let current = try await runtime.snapshot(notes, conversationId: runtime.conversationId, context: context)
            let historical = try await runtime.snapshotAsOf(notes, conversationId: runtime.conversationId, at: first, context: context)
            let historicalFamily = try await runtime.snapshotAsOf(family, conversationId: runtime.conversationId, key: "k", at: first, context: context)
            seen.append(try #require(current).value)
            seen.append(try #require(historical).value)
            seen.append(try #require(historicalFamily).value)
            seen.append(try await runtime.context(runtime.conversationId, at: first, context: context).entries.count)
            seen.append(try await runtime.context(runtime.conversationId, at: second, context: context).messages.count)
            seen.append(Int(try runtime.now())); try runtime.report(TaskDefinitionError("reported"))
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }
        let registry = Registry(); try registry.install(Extension(name: "task", tasks: [AnyTaskDefinition(definition)]))
        let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: FakeDurableModels(), registry: registry,
            now: { 1234 }, onReport: { reports.append(String(describing: $0)) }), context: .background)
        let root = try await harness.root(context: .background)
        for count in [1, 2] {
            try await root.commit({ tx in
                try await tx.doc(notes, conversationId: root.id).set("value", .number(Double(count)))
                try await tx.doc(family, conversationId: root.id, key: "k", seed: 0).set("value", .number(Double(count + 10)))
                let message = Message.user(UserMessage(content: .text("\(count)"), timestamp: 1))
                _ = try await tx.appendEntry(root.id, value: EntryDraft(kind: "message", model: EntryRecord.encodeMessages([message])))
            }, context: .background)
        }
        _ = try await harness.waitForTask(id: harnessStart(root, definition), context: .background)
        #expect(seen.values == [2, 1, 11, 1, 2, 1234])
        #expect(reports.values == ["reported"])
        try await harness.close(context: .background)
    }

    // upstream harness-tasks.test.ts:712
    @Test func sleepHonorsOwnContextCancellationAndInvocationAbort() async throws {
        let clock = TestClock(now: 1000), entered = SessionTestGate(), results = SessionTestLog<String>()
        let signalled = harnessOneStep("test.runtime-sleep-abort") { _, runtime, context in
            entered.release()
            do { try await runtime.sleep(until: 60_000, context: context); Issue.record("Sleep returned") }
            catch { results.append("signalled"); throw error }
        }
        let cancelled = harnessOneStep("test.runtime-sleep-cancel") { _, runtime, context in
            let caller = context.withCancel(); caller.cancel(TaskDefinitionError("stop sleeping"))
            do { try await runtime.sleep(until: 60_000, context: caller.context); Issue.record("Sleep returned") }
            catch { results.append(String(describing: error)) }
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }
        let harness = try await harnessOpen([AnyTaskDefinition(signalled), AnyTaskDefinition(cancelled)], clock: clock)
        let root = try await harness.root(context: .background)
        let a = try await harnessStart(root, signalled), b = try await harnessStart(root, cancelled)
        _ = try await harness.waitForTask(id: b, context: .background)
        await entered.wait()
        _ = try await harness.abortTask(id: a, context: .background)
        #expect(try await harness.waitForTask(id: a, context: .background).outcome == .aborted(reason: "test"))
        #expect(Set(results.values) == ["stop sleeping", "signalled"])
        try await harness.close(context: .background)
    }
    // upstream harness-tasks.test.ts:655. Hold acquisition and end the invocation explicitly to fix the race order.
    @Test func lateWatchAcquisitionStopsAndRejects() async throws {
        let storage = ControlledStorage(), entered = SessionTestGate(), release = SessionTestGate()
        let captured = Mutex<TaskRuntime?>(nil)
        let notes = try SessionDocToken<DefinitionState>(kind: "test.runtime-late-watch", version: 1, initial: { .init(value: 0) })
        let definition = harnessOneStep("test.runtime-late-watch") { _, runtime, _ in
            captured.withLock { $0 = runtime }; entered.release(); await release.wait()
        }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], storage: storage)
        let root = try await harness.root(context: .background)
        try await root.commit({ tx in _ = try await tx.doc(notes) }, context: .background)
        _ = try await harnessStart(root, definition)
        try harness.resume(); await entered.wait()
        let runtime = try #require(captured.withLock { $0 })
        try await harness.session.unloadDocuments()
        let held = await storage.holdFindDocument()
        let acquiring = Task { try await runtime.watchDoc(notes, context: .background) }
        await held.waitUntilEntered()
        runtime.scheduler.end(runtime.invocation)
        await held.release()
        do { _ = try await acquiring.value; Issue.record("Late acquisition returned") }
        catch { #expect(String(describing: error).contains("invocation has ended")) }
        let closing = Task { try await harness.close(context: .background) }
        try await harnessEventually { harness.tasks.closing }
        release.release()
        try await closing.value
    }

    // scheduler.ts:1241-1273 and spec §5: contextRetentionMs retention, range growth, and one expiry timer.
    @Test(arguments: [Int64(0), Int64(10)])
    func contextRangeGrowsAndExpiresAtOriginalIdleDeadline(retention: Int64) async throws {
        let clock = TestClock(now: 1000), entered = SessionTestGate(), release = SessionTestGate()
        let captured = Mutex<TaskRuntime?>(nil)
        let definition = harnessOneStep("test.runtime-context-cache") { _, runtime, context in
            captured.withLock { $0 = runtime }
            _ = try await runtime.context(runtime.conversationId, context: context)
            entered.release(); await release.wait()
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }
        let opened = try await openTasks(tasks: [AnyTaskDefinition(definition)],
            settings: HarnessSettingsProvider { HarnessSettings(contextRetentionMs: retention) }, clock: clock)
        let harness = opened.harness
        let root = try await harness.root(context: .background)
        let other = try await harness.createConversation(options: .init(ownership: .ownerless()), context: .background)
        for conversation in [root, other] {
            try await conversation.commit({ tx in _ = try await tx.appendEntry(conversation.id, value: .init(kind: "note")) }, context: .background)
        }
        let id = try await harnessStart(root, definition)
        try harness.resume(); await entered.wait()
        let runtime = try #require(captured.withLock { $0 })
        #expect(harness.tasks.state.withLock { $0.contexts[root.id]?.idleSince == nil && $0.contexts[root.id] != nil })
        #expect(try await runtime.context(other.id, context: .background).entries.count == 1)
        #expect(harness.tasks.state.withLock { $0.contexts[other.id] != nil } == (retention > 0))
        let latest = try await root.commit({ tx in try await tx.appendEntry(root.id, value: .init(kind: "note")) }, context: .background)
        #expect(try await runtime.context(root.id, context: .background).entries.count == 2)
        #expect(harness.tasks.state.withLock { $0.contexts[root.id]?.range.bounds.tail == latest.id })
        if retention > 0 {
            try await harnessEventually { clock.pendingSleeperCount == 1 }
            clock.advance(by: 9)
            _ = try await runtime.context(other.id, context: .background)
            #expect(harness.tasks.state.withLock { $0.contexts[other.id]?.idleSince == 1000 })
            clock.advance(by: 1)
            try await harnessEventually { harness.tasks.state.withLock { $0.contexts[other.id] == nil } }
            #expect(harness.tasks.state.withLock { $0.contexts[root.id] != nil })
        }
        release.release()
        _ = try await harness.waitForTask(id: id, context: .background)
        if retention > 0 {
            try await harnessEventually { harness.tasks.state.withLock { $0.contexts[root.id]?.idleSince == clock.now() } }
            try await harnessEventually { clock.pendingSleeperCount == 1 }
            clock.advance(by: retention)
        }
        try await harnessEventually { harness.tasks.state.withLock { $0.contexts.isEmpty } }
        try await harness.close(context: .background)
        #expect(harness.tasks.state.withLock { $0.expiry == nil && $0.contexts.isEmpty })
        try await harnessEventually { clock.pendingSleeperCount == 0 }
    }

}
