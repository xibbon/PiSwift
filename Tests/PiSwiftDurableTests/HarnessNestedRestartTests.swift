import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private func nestedRestartTool(_ name: String, replay: ToolReplay? = nil,
    execute: @escaping @Sendable (JSONValue, ToolExecutionApi, ChordContext) async throws -> ToolExecutionResult
) throws -> ToolRegistration {
    try ToolRegistration(name: name, description: name,
        parameters: ["type": "object", "properties": ["text": ["type": "string"]]], replay: replay, execute: execute)
}

private func nestedRestartInstall(_ setup: HarnessChatSetup, _ tool: ToolRegistration) throws {
    try setup.registry.install(Extension(name: "nested-restart:\(tool.name)", tools: [tool]))
}

private func nestedRestartResponses(_ setup: HarnessChatSetup, caller: String = "batch") throws {
    setup.models.setResponses([.message(try toolCalls([(caller, [:], "c1")])), .message(chatAssistant("done"))])
}

private func nestedRestartOpen(_ path: String, _ setup: HarnessChatSetup, resume: Bool = false) async throws -> OpenChatResult {
    let opened = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
    if resume { try opened.harness.resume() }
    return opened
}

private func nestedRestartTasks(_ opened: OpenChatResult) async throws -> [TaskRecord] {
    let records = try await opened.harness.commit({ tx in
        try await tx.scanTasks(.init(conversationId: opened.root.id, kind: "pi.tool"), limit: 100).items
    }, context: .background)
    return records.filter { $0.input["kind"] == "nested" }
}

private func nestedRestartWait(_ opened: OpenChatResult, _ id: SubmissionID) async throws -> SettledSubmission {
    let submission = try #require(try await opened.harness.submission(id: id, context: .background))
    return try await submission.wait(context: .background)
}

private func nestedRestartResults(_ opened: OpenChatResult) async throws -> [ToolResultMessage] {
    try harnessToolResults(await allEntries(opened.root))
}

private func nestedRestartWorker(_ name: String, started: HarnessChatSignal,
    phases: SessionTestLog<String>, aborts: SessionTestLog<TaskAbortReason?>
) -> HarnessTestTask {
    harnessOneStep(name, run: { _, _, context in
        phases.append("work"); started.signal(); try await harnessToolAwaitAbort(context)
    }, abort: { task, runtime, context in
        aborts.append(task.record.abortReason)
        try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
    })
}

@Suite struct HarnessNestedRestartTests {
    // v1.3.0 harness-nested-tools-restart.test.ts:93. A safe leaf cannot replay an unsafe caller's abandoned work.
    @Test func unsafeCallerAbandonsRunningAndBeforeIntentNestedCalls() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("unsafe-nested.sqlite").path
        let setup = HarnessChatSetup(), started = HarnessChatSignal(), gated = HarnessChatSignal()
        let runs = SessionTestLog<String>()
        try nestedRestartInstall(setup, nestedRestartTool("started", replay: .safe) { _, api, context in
            runs.append("started"); try api.output(.text("partial\n"), nil)
            try await api.details(["step": 1], context); started.signal()
            try await harnessToolAwaitAbort(context); return .init()
        })
        try nestedRestartInstall(setup, nestedRestartTool("gated") { _, _, _ in runs.append("gated"); return .init() })
        try setup.registry.install(Extension(name: "nested-restart-gate", hooks: [hook(ToolHooks(beforeTool: { call, _, context in
            if call.name == "gated" { gated.signal(); try await harnessToolAwaitAbort(context) }
            return nil
        }))]))
        try nestedRestartInstall(setup, nestedRestartTool("batch") { _, api, context in
            async let first = api.executeTool("started", arguments: [:], context: context)
            await started.wait()
            _ = try await api.executeTool("gated", arguments: [:], context: context)
            _ = try await first; return .init()
        })
        try nestedRestartResponses(setup)
        let first = try await nestedRestartOpen(path, setup)
        let id = try await generationSubmit(first, "go").id
        await started.wait(); await gated.wait()
        try await first.harness.close(context: .background)
        let second = try await nestedRestartOpen(path, setup)
        let (stream, log) = try await eventListen(second)
        try second.harness.resume()
        #expect(try await nestedRestartWait(second, id).status == "done")
        try await second.harness.waitForIdle(context: .background)
        _ = await stream.stop()
        #expect(runs.values == ["started"])
        let nested = try await nestedRestartTasks(second)
        #expect(nested.count == 2)
        for task in nested {
            #expect(task.abandonOnRestart == true && task.abortRequested && task.abortReason == .restart)
            guard case .terminal(let outcome, _) = task.state else { Issue.record("Expected terminal nested call"); continue }
            #expect(outcome.status == "aborted")
        }
        let ends = log.events.filter { $0["type"] == "tool_execution_end" }
        let interrupted = try #require(ends.first { $0["toolCallId"] == "c1/1" }?["result"])
        #expect(interrupted["diagnostics"]?[0]?["code"] == "interrupted")
        #expect(interrupted["isError"] == true && interrupted["details"] == ["step": 1])
        #expect(interrupted["structuredOutput"] == nil)
        #expect(ends.first { $0["toolCallId"] == "c1/2" }?["result"]?["diagnostics"]?[0]?["code"] == "abandoned")
        let results = try await nestedRestartResults(second)
        #expect(results.count == 1 && results[0].toolCallId == "c1" && results[0].isError)
        #expect(try await second.harness.snapshot(LiveDoc, conversationId: second.root.id, context: .background) == LiveState())
        try await second.harness.close(context: .background)
    }

    // :168. Restart cancellation reaches the work owned by an abandoned nested tool.
    @Test func abandonedNestedCallRunsOwnedTaskAbortWithoutAnotherPhase() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("owned-nested.sqlite").path
        let setup = HarnessChatSetup(), started = HarnessChatSignal()
        let phases = SessionTestLog<String>(), aborts = SessionTestLog<TaskAbortReason?>(), workerID = Mutex<TaskID?>(nil)
        let worker = nestedRestartWorker("test.nested-owned", started: started, phases: phases, aborts: aborts)
        try setup.registry.install(Extension(name: "nested-worker", tasks: [AnyTaskDefinition(worker)]))
        try nestedRestartInstall(setup, nestedRestartTool("spawn") { _, api, context in
            let id = try await api.createTask(worker, input: 0, options: .init(ownership: .task(taskId: api.taskId)), context: context)
            workerID.withLock { $0 = id }; _ = try await api.waitForTask(id: id, context: context); return .init()
        })
        try nestedRestartInstall(setup, nestedRestartTool("batch") { _, api, context in
            _ = try await api.executeTool("spawn", arguments: [:], context: context); return .init()
        })
        try nestedRestartResponses(setup)
        let first = try await nestedRestartOpen(path, setup), id = try await generationSubmit(first, "go").id
        await started.wait(); try await first.harness.close(context: .background)
        let second = try await nestedRestartOpen(path, setup, resume: true)
        #expect(try await nestedRestartWait(second, id).status == "done")
        try await second.harness.waitForIdle(context: .background)
        #expect(phases.values == ["work"] && aborts.values == [.restart])
        #expect(try await w3Terminal(second.harness, #require(workerID.withLock { $0 })).outcome.status == "aborted")
        try await second.harness.close(context: .background)
    }

    private func missingDefinition(requestAbort: Bool) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("missing-nested.sqlite").path
        let setup = HarnessChatSetup(), started = HarnessChatSignal(), workerID = Mutex<TaskID?>(nil)
        let phases = SessionTestLog<String>(), aborts = SessionTestLog<TaskAbortReason?>()
        let worker = nestedRestartWorker("test.nested-missing", started: started, phases: phases, aborts: aborts)
        let installed = Extension(name: "nested-late-worker", tasks: [AnyTaskDefinition(worker)])
        try setup.registry.install(installed)
        try nestedRestartInstall(setup, nestedRestartTool("spawn") { _, api, context in
            let id = try await api.createTask(worker, input: 0, options: .init(ownership: .task(taskId: api.taskId)), context: context)
            workerID.withLock { $0 = id }; _ = try await api.waitForTask(id: id, context: context); return .init()
        })
        try nestedRestartInstall(setup, nestedRestartTool("batch") { _, api, context in
            _ = try await api.executeTool("spawn", arguments: [:], context: context); return .init()
        })
        try nestedRestartResponses(setup)
        let first = try await nestedRestartOpen(path, setup), id = try await generationSubmit(first, "go").id
        await started.wait(); try await first.harness.close(context: .background)
        setup.registry.uninstall(installed)
        let second = try await nestedRestartOpen(path, setup, resume: true)
        let child = try #require(workerID.withLock { $0 })
        try await harnessEventually {
            let inspected = try await second.harness.inspect(context: .background).tasks.first { $0.record.id == child }
            guard let inspected, case .blocked = inspected.state else { return false }
            return inspected.record.abortReason == .restart
        }
        #expect(try await second.harness.getTask(id: child, context: .background)?.state.status != "terminal")
        #expect(aborts.values.isEmpty)
        if requestAbort {
            try await second.root.abort(context: .background)
            #expect(try await w3Terminal(second.harness, child).outcome == .orphaned(reason: "missing_task"))
            #expect(try await nestedRestartWait(second, id).status == "unanswered")
        } else {
            try setup.registry.install(installed)
            #expect(try await nestedRestartWait(second, id).status == "done")
            #expect(aborts.values == [.restart])
            #expect(try await w3Terminal(second.harness, child).outcome.status == "aborted")
        }
        #expect(phases.values == ["work"])
        try await second.harness.close(context: .background)
    }

    // :232. Installing a missing definition permits its restart abort handler to run.
    @Test func missingOwnedTaskWaitsForDefinitionThenRunsRestartAbort() async throws {
        try await missingDefinition(requestAbort: false)
    }

    // :300. A user abort replaces restart waiting with the missing-task orphan outcome.
    @Test func userAbortOrphansMissingTaskUnderAbandonedNestedCall() async throws {
        try await missingDefinition(requestAbort: true)
    }

    // :363. An inspection-only reopen does not mark nested work for restart.
    @Test func pausedReopenDoesNotMarkNestedCalls() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("paused-nested.sqlite").path
        let setup = HarnessChatSetup(), started = HarnessChatSignal()
        try nestedRestartInstall(setup, nestedRestartTool("hang") { _, _, context in
            started.signal(); try await harnessToolAwaitAbort(context); return .init()
        })
        try nestedRestartInstall(setup, nestedRestartTool("batch") { _, api, context in
            _ = try await api.executeTool("hang", arguments: [:], context: context); return .init()
        })
        try nestedRestartResponses(setup)
        let first = try await nestedRestartOpen(path, setup)
        _ = try await generationSubmit(first, "go")
        await started.wait(); try await first.harness.close(context: .background)
        let inspected = try await nestedRestartOpen(path, setup)
        #expect(try await inspected.harness.inspect(context: .background).scheduling == .paused)
        try await inspected.harness.close(context: .background)
        let second = try await nestedRestartOpen(path, setup)
        let task = try #require(try await nestedRestartTasks(second).first)
        #expect(task.abandonOnRestart == true && !task.abortRequested && task.abortReason == nil)
        #expect(task.state.status == "pending")
        try await second.harness.close(context: .background)
    }

    // :400. A replay-safe caller reattaches by default keys; each nested tool uses its own replay rule.
    @Test func safeCallerReattachesSafeAndUnsafeNestedCalls() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("safe-nested.sqlite").path
        let setup = HarnessChatSetup(), safeStarted = HarnessChatSignal(), unsafeStarted = HarnessChatSignal()
        let safeRuns = Mutex(0), unsafeRuns = Mutex(0), callerRuns = Mutex(0), results = SessionTestLog<NestedToolExecutionResult>()
        try nestedRestartInstall(setup, nestedRestartTool("safe", replay: .safe) { _, _, context in
            let run = safeRuns.withLock { $0 += 1; return $0 }
            if run == 1 { safeStarted.signal(); try await harnessToolAwaitAbort(context) }
            return .init(output: [.text(.init(text: "safe run \(run)"))])
        })
        try nestedRestartInstall(setup, nestedRestartTool("unsafe") { _, _, context in
            unsafeRuns.withLock { $0 += 1 }; unsafeStarted.signal(); try await harnessToolAwaitAbort(context); return .init()
        })
        try nestedRestartInstall(setup, nestedRestartTool("batch", replay: .safe) { _, api, context in
            let attempt = callerRuns.withLock { $0 += 1; return $0 }
            if attempt == 1 {
                async let safe = api.executeTool("safe", arguments: [:], context: context)
                await safeStarted.wait()
                let unsafe = try await api.executeTool("unsafe", arguments: [:], context: context)
                results.append(try await safe); results.append(unsafe)
            } else {
                results.append(try await api.executeTool("safe", arguments: [:], context: context))
                results.append(try await api.executeTool("unsafe", arguments: [:], context: context))
            }
            return .init()
        })
        try nestedRestartResponses(setup)
        let first = try await nestedRestartOpen(path, setup), id = try await generationSubmit(first, "go").id
        await safeStarted.wait(); await unsafeStarted.wait(); try await first.harness.close(context: .background)
        let second = try await nestedRestartOpen(path, setup, resume: true)
        #expect(try await nestedRestartWait(second, id).status == "done")
        #expect(safeRuns.withLock { $0 } == 2 && unsafeRuns.withLock { $0 } == 1 && callerRuns.withLock { $0 } == 2)
        let tasks = try await nestedRestartTasks(second)
        #expect(tasks.count == 2)
        for task in tasks { #expect(task.abandonOnRestart == nil && task.abortReason == nil) }
        #expect(results.values.count == 2)
        #expect(results.values.first?.structuredOutput == "safe run 2")
        #expect(results.values.last?.diagnostics.compactMap(\.code) == ["interrupted"])
        try await second.harness.close(context: .background)
    }

    // :465. A caller's terminal commit removes finished slots from all of its attempts.
    @Test func rerunWithNoNestedCallsRemovesEarlierFinishedSlotsAtParentTerminalCommit() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("finished-nested.sqlite").path
        let setup = HarnessChatSetup(), finished = HarnessChatSignal(), attempts = Mutex(0), slotCounts = SessionTestLog<Int>()
        try nestedRestartInstall(setup, nestedRestartTool("quick") { _, _, _ in .init(output: [.text(.init(text: "ok"))]) })
        try nestedRestartInstall(setup, nestedRestartTool("caller", replay: .safe) { _, api, context in
            let attempt = attempts.withLock { $0 += 1; return $0 }
            if attempt == 1 {
                _ = try await api.executeTool("quick", arguments: [:], context: context)
                finished.signal(); try await harnessToolAwaitAbort(context)
            }
            return .init(output: [.text(.init(text: "done"))])
        })
        try nestedRestartResponses(setup, caller: "caller")
        let first = try await nestedRestartOpen(path, setup), id = try await generationSubmit(first, "go").id
        await finished.wait()
        #expect(try await first.harness.snapshot(LiveDoc, conversationId: first.root.id, context: .background)?.nestedTools?.count == 1)
        try await first.harness.close(context: .background)
        let second = try await nestedRestartOpen(path, setup)
        let subscription = try second.harness.subscribeCommits { publication, _ in
            let terminalParent = publication.changes.contains { change in
                guard case .task(let task) = change else { return false }
                return task.kind == "pi.tool" && task.input["kind"] == "model" && task.state.status == "terminal"
            }
            if terminalParent {
                let live = publication.changes.compactMap { change -> JSONValue? in
                    if case .document(let doc) = change, doc.record.kind == "pi.live" { return doc.value.map(JSONValue.object) }; return nil
                }.first
                slotCounts.append(live?["nestedTools"]?.arrayValue?.count ?? 0)
            }
        }
        try second.harness.resume()
        #expect(try await nestedRestartWait(second, id).status == "done")
        #expect(attempts.withLock { $0 } == 2 && slotCounts.values == [0])
        subscription.cancel(); try await second.harness.close(context: .background)
    }

    // :518. A caller that omits an earlier unfinished call aborts it before settlement.
    @Test func rerunWithNoNestedCallsAbortsEarlierRunningCall() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("leftover-nested.sqlite").path
        let setup = HarnessChatSetup(), running = HarnessChatSignal(), attempts = Mutex(0)
        try nestedRestartInstall(setup, nestedRestartTool("slow", replay: .safe) { _, _, context in
            running.signal(); try await harnessToolAwaitAbort(context); return .init()
        })
        try nestedRestartInstall(setup, nestedRestartTool("caller", replay: .safe) { _, api, context in
            if attempts.withLock({ $0 += 1; return $0 }) == 1 {
                _ = try await api.executeTool("slow", arguments: [:], context: context, options: .init(key: "slow"))
            }
            return .init(output: [.text(.init(text: "done"))])
        })
        try nestedRestartResponses(setup, caller: "caller")
        let first = try await nestedRestartOpen(path, setup), id = try await generationSubmit(first, "go").id
        await running.wait(); try await first.harness.close(context: .background)
        let second = try await nestedRestartOpen(path, setup, resume: true)
        #expect(try await nestedRestartWait(second, id).status == "done")
        #expect(attempts.withLock { $0 } == 2)
        let leftover = try #require(try await nestedRestartTasks(second).first)
        guard case .terminal(let outcome, _) = leftover.state else { Issue.record("Expected terminal leftover"); return }
        #expect(outcome.status == "aborted")
        try await second.harness.close(context: .background)
    }

    // :563. Default and explicit keys reuse the saved task; changed arguments reject the rerun.
    @Test(arguments: [false, true])
    func safeCallerReusesKeysAndRejectsChangedArguments(swapped: Bool) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("keyed-nested.sqlite").path
        let setup = HarnessChatSetup(), blocked = HarnessChatSignal(), callerRuns = Mutex(0)
        let runs = SessionTestLog<String>(), seen = SessionTestLog<JSONValue?>()
        try nestedRestartInstall(setup, nestedRestartTool("echo") { args, _, _ in
            let text = args["text"]?.stringValue ?? ""; runs.append(text)
            return .init(output: [.text(.init(text: "echo \(text)"))])
        })
        try nestedRestartInstall(setup, nestedRestartTool("batch", replay: .safe) { _, api, context in
            let run = callerRuns.withLock { $0 += 1; return $0 }
            let first = try await api.executeTool("echo", arguments: ["text": .string(run == 2 && swapped ? "b" : "a")], context: context)
            let named = try await api.executeTool("echo", arguments: ["text": "named"], context: context, options: .init(key: "named"))
            if run == 1 { blocked.signal(); try await harnessToolAwaitAbort(context) }
            seen.append(first.structuredOutput); seen.append(named.structuredOutput); return .init()
        })
        try nestedRestartResponses(setup)
        let first = try await nestedRestartOpen(path, setup), id = try await generationSubmit(first, "go").id
        await blocked.wait(); try await first.harness.close(context: .background)
        let second = try await nestedRestartOpen(path, setup, resume: true)
        #expect(try await nestedRestartWait(second, id).status == "done")
        #expect(runs.values == ["a", "named"] && callerRuns.withLock { $0 } == 2)
        #expect(try await nestedRestartTasks(second).count == 2)
        let result = try #require(try await nestedRestartResults(second).first)
        #expect(result.isError == swapped)
        if swapped {
            #expect(harnessToolText(result).contains("Nested call c1/1 was already made with another tool"))
            #expect(seen.values.isEmpty)
        } else { #expect(seen.values == ["echo a", "echo named"]) }
        try await second.harness.close(context: .background)
    }

    // :621. A direct task created by an unsafe tool is abandoned even without a nested tool call.
    @Test func unsafeToolAbandonsItsDirectOwnedTask() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("direct-nested.sqlite").path
        let setup = HarnessChatSetup(), started = HarnessChatSignal(), phases = SessionTestLog<String>(), aborts = SessionTestLog<TaskAbortReason?>()
        let worker = nestedRestartWorker("test.nested-direct", started: started, phases: phases, aborts: aborts)
        try setup.registry.install(Extension(name: "direct-worker", tasks: [AnyTaskDefinition(worker)]))
        try nestedRestartInstall(setup, nestedRestartTool("work") { _, api, context in
            let id = try await api.createTask(worker, input: 0, options: .init(ownership: .task(taskId: api.taskId)), context: context)
            _ = try await api.waitForTask(id: id, context: context); return .init()
        })
        try nestedRestartResponses(setup, caller: "work")
        let first = try await nestedRestartOpen(path, setup), id = try await generationSubmit(first, "go").id
        await started.wait(); try await first.harness.close(context: .background)
        let second = try await nestedRestartOpen(path, setup, resume: true)
        #expect(try await nestedRestartWait(second, id).status == "done")
        #expect(phases.values == ["work"] && aborts.values == [.restart])
        try await second.harness.close(context: .background)
    }

    // :669. Background work in an owned conversation survives nested-call abandonment.
    @Test func abandonedNestedCallLeavesBackgroundConversationTaskRunning() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("background-nested.sqlite").path
        let setup = HarnessChatSetup(), started = HarnessChatSignal(), backgroundID = Mutex<TaskID?>(nil)
        let worker = nestedRestartWorker("test.nested-background", started: started,
            phases: SessionTestLog<String>(), aborts: SessionTestLog<TaskAbortReason?>())
        try setup.registry.install(Extension(name: "background-worker", tasks: [AnyTaskDefinition(worker)]))
        try nestedRestartInstall(setup, nestedRestartTool("spawn") { _, api, context in
            let id = try await api.commit({ tx in
                let conversation = try await tx.createConversation(ownership: .task(taskId: api.taskId))
                return try await tx.createTask(worker, input: 0, options: .init(ownership: .conversation(), conversationId: conversation.id, background: true))
            }, context: context)
            backgroundID.withLock { $0 = id }; try await harnessToolAwaitAbort(context); return .init()
        })
        try nestedRestartInstall(setup, nestedRestartTool("batch") { _, api, context in
            _ = try await api.executeTool("spawn", arguments: [:], context: context); return .init()
        })
        try nestedRestartResponses(setup)
        let first = try await nestedRestartOpen(path, setup), id = try await generationSubmit(first, "go").id
        await started.wait(); try await first.harness.close(context: .background)
        let second = try await nestedRestartOpen(path, setup, resume: true)
        #expect(try await nestedRestartWait(second, id).status == "done")
        let spawn = try #require(try await nestedRestartTasks(second).first)
        #expect(spawn.abortReason == .restart && spawn.state.status == "terminal")
        let background = try #require(backgroundID.withLock { $0 })
        try await w3State(second.harness, background, "running")
        #expect(try await second.harness.getTask(id: background, context: .background)?.abortRequested == false)
        _ = try await second.harness.abortTask(id: background, context: .background)
        #expect(try await w3Terminal(second.harness, background).outcome.status == "aborted")
        try await second.harness.close(context: .background)
    }

    // v1.3.0 harness-nested-tools.test.ts:568. A rerun reuses a completed call and admits a new default key.
    @Test func safeRerunReusesCompletedCallThenAdmitsNewCall() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("new-key-nested.sqlite").path
        let setup = HarnessChatSetup(), blocked = HarnessChatSignal(), attempts = Mutex(0), runs = SessionTestLog<String>()
        try nestedRestartInstall(setup, nestedRestartTool("echo") { args, _, _ in
            let text = args["text"]?.stringValue ?? ""; runs.append(text)
            return .init(output: [.text(.init(text: "echo \(text)"))])
        })
        try nestedRestartInstall(setup, nestedRestartTool("batch", replay: .safe) { _, api, context in
            let attempt = attempts.withLock { $0 += 1; return $0 }
            let one = try await api.executeTool("echo", arguments: ["text": "a"], context: context)
            if attempt == 1 { blocked.signal(); try await harnessToolAwaitAbort(context) }
            let two = try await api.executeTool("echo", arguments: ["text": "b"], context: context)
            let text = "run \(attempt): \(one.structuredOutput?.stringValue ?? ""), \(two.structuredOutput?.stringValue ?? "")"
            return .init(output: [.text(.init(text: text))])
        })
        try nestedRestartResponses(setup)
        let first = try await nestedRestartOpen(path, setup), id = try await generationSubmit(first, "go").id
        await blocked.wait(); try await first.harness.close(context: .background)
        let second = try await nestedRestartOpen(path, setup, resume: true)
        #expect(try await nestedRestartWait(second, id).status == "done")
        #expect(attempts.withLock { $0 } == 2 && runs.values == ["a", "b"])
        let result = try #require(try await nestedRestartResults(second).first)
        #expect(harnessToolText(result) == "run 2: echo a, echo b")
        let tasks = try await nestedRestartTasks(second)
        #expect(tasks.count == 2)
        for task in tasks {
            guard case .terminal(let outcome, _) = task.state else { Issue.record("Expected terminal nested call"); continue }
            #expect(try JSONValue(encoding: outcome)["result"] == ["kind": "nested"])
        }
        try await second.harness.close(context: .background)
    }

    // v1.3.0 harness-nested-tools.test.ts:670. Restart during parent cleanup still ends its unfinished child.
    @Test func restartDuringLeftoverCleanupAbortsChildWithoutRerunningIt() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cleanup-nested.sqlite").path
        let setup = HarnessChatSetup(), running = HarnessChatSignal(), cleaning = HarnessChatSignal(), release = HarnessChatSignal()
        let runs = Mutex(0)
        try nestedRestartInstall(setup, nestedRestartTool("hang") { _, api, context in
            runs.withLock { $0 += 1 }; try api.output(.text("partial\n"), nil)
            try await api.details(["step": 1], context); running.signal()
            do { try await harnessToolAwaitAbort(context) } catch {}
            cleaning.signal(); await release.wait(); throw TaskDefinitionError("aborted")
        })
        try nestedRestartInstall(setup, nestedRestartTool("batch") { _, api, context in
            _ = settled { try await api.executeTool("hang", arguments: [:], context: context) }
            await running.wait(); return .init(output: [.text(.init(text: "returned early"))])
        })
        try nestedRestartResponses(setup)
        let first = try await nestedRestartOpen(path, setup), id = try await generationSubmit(first, "go").id
        await cleaning.wait()
        let closed = settled { try await first.harness.close(context: .background) }
        try await harnessEventually { first.harness.tasks.closing }
        release.signal()
        try await harnessEventually { closed.isSettled }
        try #require(closed.result).get()
        let second = try await nestedRestartOpen(path, setup, resume: true)
        #expect(try await nestedRestartWait(second, id).status == "done")
        try await second.harness.waitForIdle(context: .background)
        let result = try #require(try await nestedRestartResults(second).first)
        #expect(result.toolCallId == "c1" && result.isError)
        #expect(harnessToolText(result).contains("Tool batch was interrupted"))
        let child = try #require(try await nestedRestartTasks(second).first)
        guard case .terminal(let outcome, _) = child.state else { Issue.record("Expected terminal child"); return }
        #expect(outcome.status == "aborted" && runs.withLock { $0 } == 1)
        #expect(try await second.harness.snapshot(LiveDoc, conversationId: second.root.id, context: .background) == LiveState())
        try await second.harness.close(context: .background)
    }
}
