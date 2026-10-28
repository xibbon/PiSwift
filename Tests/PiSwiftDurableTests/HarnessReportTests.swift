import Dispatch
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private struct CapturedHarnessReport: Sendable {
    let error: any Error
    let info: ReportInfo
    var message: String { String(describing: error) }
}

private final class TypedHarnessReports: Sendable {
    private let state = Mutex<[CapturedHarnessReport]>([])
    var values: [CapturedHarnessReport] { state.withLock { $0 } }
    func append(_ error: any Error, _ info: ReportInfo) {
        state.withLock { $0.append(CapturedHarnessReport(error: error, info: info)) }
    }
    func info(_ message: String) -> ReportInfo? { values.first { $0.message == message }?.info }
}

private func openReportHarness(_ tasks: [AnyTaskDefinition] = [],
    storage: any DurableStorage = MemoryStorage(), registry: Registry = Registry(),
    onWake: (@Sendable (HarnessWake) throws -> Void)? = nil,
    setTimer: HarnessSetTimer? = nil,
    reports: TypedHarnessReports) async throws -> Harness {
    if !tasks.isEmpty { try registry.install(Extension(name: "test", tasks: tasks)) }
    return try await Harness.open(storage: storage, options: .init(models: FakeDurableModels(), registry: registry,
        setTimer: setTimer, onWake: onWake, onReport: { error, info in reports.append(error, info) }), context: .background)
}

@Suite struct HarnessReportTests {
    // v1.4.0 harness-reports.test.ts:47
    @Test func taskReportsNameTheTaskAndItsExtension() async throws {
        let reports = TypedHarnessReports()
        let definition = harnessOneStep("test.faulty") { _, runtime, _ in
            try runtime.report(TaskDefinitionError("noted"))
            throw TaskDefinitionError("broken")
        }
        let harness = try await openReportHarness([AnyTaskDefinition(definition)], reports: reports)
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, definition)
        try harness.resume()
        #expect(try await harness.waitForTask(id: id, context: .background).outcome.status == "faulted")
        try await harnessEventually { reports.values.count == 2 }
        let task = ReportTask(id: id, kind: "test.faulty", conversationId: root.id)
        #expect(reports.values.map(\.message) == ["noted", "broken"])
        #expect(reports.values.map(\.info) == [
            .taskError(task: task, extension: "test"),
            .taskFaulted(task: task, extension: "test", reason: .threw)
        ])
        #expect(reports.values.map { $0.info.type } == ["task_error", "task_faulted"])
        try await harness.close(context: .background)
    }

    // v1.4.0 harness-reports.test.ts:78
    @Test func faultNamesTheExtensionWhoseDefinitionRanAfterReplacement() async throws {
        let gate = SessionTestGate(), started = SessionTestGate()
        let reports = TypedHarnessReports(), registry = Registry()
        let old = harnessOneStep("test.replaced") { _, _, _ in
            started.release()
            await gate.wait()
            throw TaskDefinitionError("broken in old")
        }
        let oldExtension = Extension(name: "old-extension", tasks: [AnyTaskDefinition(old)])
        try registry.install(oldExtension)
        let harness = try await openReportHarness(registry: registry, reports: reports)
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, old)
        try harness.resume()
        await started.wait()
        registry.uninstall(oldExtension)
        let replacement = harnessOneStep("test.replaced") { _, _, _ in throw TaskDefinitionError("broken in new") }
        try registry.install(Extension(name: "new-extension", tasks: [AnyTaskDefinition(replacement)]))
        gate.release()
        _ = try await harness.waitForTask(id: id, context: .background)
        try await harnessEventually { reports.values.contains { $0.info.type == "task_faulted" } }
        let fault = try #require(reports.values.first { $0.info.type == "task_faulted" })
        #expect(fault.message == "broken in old")
        #expect(fault.info == .taskFaulted(task: .init(id: id, kind: "test.replaced", conversationId: root.id),
                                         extension: "old-extension", reason: .threw))
        try await harness.close(context: .background)
    }

    // v1.4.0 harness-reports.test.ts:116
    @Test func sectionAndHookReportsNameTheirExtensionsAndEnvNamesTheHostCallback() async throws {
        let setup = HarnessChatSetup(), reports = TypedHarnessReports()
        setup.models.setResponses([.message(chatAssistant("answer"))])
        try setup.registry.install(Extension(name: "sections", sections: [
            section("broken") { _, _ in throw TaskDefinitionError("section") }
        ]))
        try setup.registry.install(Extension(name: "hooks", hooks: [
            hook(GenerationHooks(afterResponse: { _, _, _ in throw TaskDefinitionError("hook") }))
        ]))
        let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: setup.models,
            registry: setup.registry, env: { _, _ in throw TaskDefinitionError("env") },
            onReport: { error, info in reports.append(error, info) }), context: .background)
        let root = try await harness.root(options: .init(agent: .init(model: .set(.init(provider: "faux", modelId: "faux-1")))), context: .background)
        _ = try await root.submit(.input(content: .text("hi")), context: .background).wait(context: .background)
        try await harnessEventually { ["env", "section", "hook"].allSatisfy { reports.info($0) != nil } }
        let generation = try #require(try await harness.commit({ tx in
            try await tx.scanTasks(.init(conversationId: root.id), limit: 10)
        }, context: .background).items.first { $0.kind == "pi.generation" })
        let task = ReportTask(id: generation.id, kind: "pi.generation", conversationId: root.id)
        #expect(reports.info("env") == .hostError(callback: .env, task: task))
        #expect(reports.info("section") == .extensionError(extension: "sections", task: task))
        #expect(reports.info("hook") == .extensionError(extension: "hooks", task: task))
        try await harness.close(context: .background)
    }

    // v1.4.0 harness-reports.test.ts:164. Swift commit listeners cannot throw.
    // A throwing document-watch listener checks the same listener report.
    @Test func wrapperListenerWakeTimerAndSessionFailuresHaveSeparateReportTypes() async throws {
        let sleeper = harnessOneStep("test.sleeper") { task, runtime, context in
            if task.checkpoint.phase == .run {
                _ = runtime.setTimer({}, delay: 10)
                try await runtime.sleepUntil(Double(runtime.now()) + 60_000,
                    checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined)), context: context)
                return
            }
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }
        let storage = ControlledStorage(), registry = Registry(), reports = TypedHarnessReports()
        let harness = try await openReportHarness([AnyTaskDefinition(sleeper)], storage: storage, registry: registry,
            onWake: { _ in throw TaskDefinitionError("alarm") },
            setTimer: { _, _, _ in throw TaskDefinitionError("no timers") }, reports: reports)
        let echo = try ToolRegistration(name: "echo", description: "echo", parameters: ["type": "object"]) { _, _, _ in .init() }
        try registry.install(Extension(name: "tools", tools: [echo]))
        try registry.install(Extension(name: "wraps", wraps: [wrapTool(echo) { tool in
            var renamed = tool; renamed.name = "renamed"; return renamed
        }]))
        let root = try await harness.root(context: .background)
        let watch = try #require(try await harness.watchDoc(LiveDoc, conversationId: root.id, context: .background))
        try watch.start { _, _, _ in throw TaskDefinitionError("listener") }
        try await root.commit({ tx in try await tx.doc(LiveDoc, conversationId: root.id).set("compactions", []) }, context: .background)
        _ = await watch.closed
        _ = try await root.agent(context: .background)
        let id = try await harnessStart(root, sleeper)
        try harness.resume()
        try await harnessEventually { ["alarm", "no timers"].allSatisfy { reports.info($0) != nil } }
        try await harnessEventually { try await harness.getTask(id: id, context: .background)?.state.status == "sleeping" }
        #expect(reports.info("Wrapper renamed echo to renamed") == .extensionError(extension: "wraps", conversationId: root.id))
        #expect(reports.info("listener") == .listenerError)
        #expect(reports.info("alarm") == .hostError(callback: .onWake))
        #expect(reports.info("no timers") == .hostError(callback: .setTimer))
        let failure = TaskDefinitionError("disk gone")
        await storage.failNextCommit(failure)
        do {
            _ = try await root.commit({ tx in try await tx.createConversation(ownership: .ownerless()) }, context: .background)
            Issue.record("The failed storage commit returned a value")
        } catch {}
        _ = await harness.closed
        try await harnessEventually { reports.info("disk gone") != nil }
        #expect(reports.info("disk gone") == .sessionFailed)
    }

    @Test func oneArgumentHarnessReportAdapterKeepsTheSameErrorInstance() async throws {
        let failure = HarnessStorageFailure("legacy task report"), errors = HarnessReports()
        let definition = harnessOneStep("test.legacy-report") { _, runtime, context in
            try runtime.report(failure)
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }
        let registry = Registry()
        try registry.install(Extension(name: "legacy", tasks: [AnyTaskDefinition(definition)]))
        let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: FakeDurableModels(),
            registry: registry, onReport: { errors.append($0) }), context: .background)
        let root = try await harness.root(context: .background)
        _ = try await harness.waitForTask(id: harnessStart(root, definition), context: .background)
        try await harnessEventually { errors.count == 1 }
        #expect((errors.values[0] as? HarnessStorageFailure) === failure)
        try await harness.close(context: .background)
    }

    @Test func oneArgumentSessionReportAdapterKeepsTheSameErrorInstance() async throws {
        let failure = HarnessStorageFailure("legacy session report"), errors = HarnessReports()
        let storage = ControlledStorage()
        let session = try await Session.open(storage: storage, onReport: { errors.append($0) }, context: .background)
        await storage.failNextCommit(failure)
        do {
            _ = try await session.commit({ tx in try await tx.createConversation(ownership: .ownerless()) }, context: .background)
            Issue.record("The failed storage commit returned a value")
        } catch {}
        _ = await session.closed
        try await harnessEventually { errors.count == 1 }
        #expect((errors.values[0] as? HarnessStorageFailure) === failure)
    }

    @Test func slowFaultReportDoesNotHoldTheSessionLine() async throws {
        // Report callbacks run synchronously. A fault report must run outside the Session line.
        let entered = SessionTestGate(), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let definition = harnessOneStep("test.slow-fault-report") { _, _, _ in throw TaskDefinitionError("broken") }
        let registry = Registry()
        try registry.install(Extension(name: "test", tasks: [AnyTaskDefinition(definition)]))
        let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: FakeDurableModels(),
            registry: registry, onReport: { _, info in
                guard info.type == "task_faulted" else { return }
                entered.release()
                release.wait()
            }), context: .background)
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, definition)
        try harness.resume()
        await entered.wait()
        let read = settled { try await harness.getTask(id: id, context: .background) }
        let commit = settled {
            try await root.commit({ tx in try await tx.appendEntry(root.id, value: .init(kind: "note")) }, context: .background)
        }
        try await harnessEventually { read.isSettled && commit.isSettled }
        #expect(try read.result?.get()?.state.outcome?.status == "faulted")
        #expect(try commit.result?.get().kind == "note")
        release.signal()
        try await harness.close(context: .background)
    }

    @Test func migrationFailureNamesTheSelectedDefinition() async throws {
        let reports = TypedHarnessReports()
        let definition = HarnessTestTask(name: "test.report-migration", version: 2,
            initial: { _ in HarnessTaskCheckpoint() },
            phase: { _, _, _ in Issue.record("The failed migration ran") },
            abort: { _, _, _ in }, migrate: { _, _, _ in throw TaskDefinitionError("migration") })
        let harness = try await openReportHarness([AnyTaskDefinition(definition)], reports: reports)
        let root = try await harness.root(context: .background)
        let old = TaskKind<Int, HarnessTaskCheckpoint>(name: definition.name, version: 1, initial: { _ in HarnessTaskCheckpoint() })
        let id = try await root.commit({ tx in
            try await tx.createTask(old, input: 0, options: .init(ownership: .conversation()))
        }, context: .background)
        try harness.resume()
        try await harnessEventually { reports.info("migration") != nil }
        #expect(reports.info("migration") == .migrationFailed(task: .init(id: id, kind: definition.name, conversationId: root.id), extension: "test"))
        #expect(try await harness.getTask(id: id, context: .background)?.version == 1)
        try await harness.close(context: .background)
    }

    @Test(arguments: [false, true])
    func restartLimitSeparatesParkedTasksFromFaultedAbortHandlers(abortRequested: Bool) async throws {
        let storage = MemoryStorage(), registry = Registry(), reports = TypedHarnessReports()
        let definition = harnessOneStep("test.report-restarts") { _, _, _ in Issue.record("The restart limit task ran") }
        try registry.install(Extension(name: "test", tasks: [AnyTaskDefinition(definition)]))
        let id = try TaskID(20)
        let checkpoint = try JSONValue(encoding: HarnessTaskCheckpoint())
        _ = try await storage.commit([
            .conversation(value: ConversationRecord(id: rootConversationID)),
            .task(value: TaskRecord(id: id, conversationId: rootConversationID, kind: definition.name, version: 1,
                input: .number(0), state: .running(checkpoint: checkpoint), abortRequested: abortRequested, restarts: 1))
        ], context: .background)
        let settings = HarnessSettingsProvider { HarnessSettings(restartLimit: 2) }
        let harness = try await Harness.open(storage: storage, options: .init(models: FakeDurableModels(), registry: registry,
            settings: settings, onReport: { error, info in reports.append(error, info) }), context: .background)
        let task = ReportTask(id: id, kind: definition.name, conversationId: rootConversationID)
        if abortRequested {
            #expect(try await harness.waitForTask(id: id, context: .background).outcome.status == "faulted")
            try await harnessEventually { reports.values.contains { $0.info.type == "task_faulted" } }
            #expect(reports.values.first { $0.info.type == "task_faulted" }?.info == .taskFaulted(task: task, extension: "test", reason: .restartLimit))
        } else {
            try await harnessEventually { reports.values.contains { $0.info.type == "task_parked" } }
            #expect(reports.values.first { $0.info.type == "task_parked" }?.info == .taskParked(task: task, extension: "test"))
            #expect(try await harness.getTask(id: id, context: .background)?.state.status == "pending")
        }
        try await harness.close(context: .background)
    }

    @Test(arguments: [false, true])
    func outdatedTaskReportsNameTheDefinitionThatContinues(incompatible: Bool) async throws {
        let reports = TypedHarnessReports(), registry = Registry()
        let firstPhase = SessionTestGate(), proceed = SessionTestGate()
        let definition = harnessOneStep("test.report-outdated") { task, runtime, context in
            if task.checkpoint.phase == .run {
                firstPhase.release()
                await proceed.wait()
                try await runtime.commit({ _, _ in
                    .running(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined)))
                }, context: context)
            } else {
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
            }
        }
        let harness = try await openReportHarness([AnyTaskDefinition(definition)], registry: registry, reports: reports)
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, definition)
        try harness.resume()
        await firstPhase.wait()
        registry.uninstall(name: "test")
        if incompatible {
            let replacement = harnessOneStep(definition.name, version: 2) { _, _, _ in Issue.record("The incompatible task ran") }
            try registry.install(Extension(name: "replacement", tasks: [AnyTaskDefinition(replacement)]))
        }
        proceed.release()
        #expect(try await harness.waitForTask(id: id, context: .background).outcome.status == "completed")
        try await harnessEventually { reports.values.contains { $0.info.type == "task_outdated" } }
        #expect(reports.values.first { $0.info.type == "task_outdated" }?.info == .taskOutdated(
            task: .init(id: id, kind: definition.name, conversationId: root.id), extension: "test",
            reason: incompatible ? .incompatibleTask : .missingTask))
        try await harness.close(context: .background)
    }

    @Test func explicitRuntimeReportSourcesKeepTheTaskAndSelectTheSource() async throws {
        let reports = TypedHarnessReports()
        let definition = harnessOneStep("test.report-source") { _, runtime, context in
            try runtime.report(TaskDefinitionError("unnamed extension"), from: .extension())
            try runtime.report(TaskDefinitionError("named extension"), from: .extension("hooks"))
            try runtime.report(TaskDefinitionError("host settings"), from: .host(callback: .settings))
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }
        let harness = try await openReportHarness([AnyTaskDefinition(definition)], reports: reports)
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, definition)
        _ = try await harness.waitForTask(id: id, context: .background)
        let task = ReportTask(id: id, kind: definition.name, conversationId: root.id)
        #expect(reports.info("unnamed extension") == .extensionError(task: task))
        #expect(reports.info("named extension") == .extensionError(extension: "hooks", task: task))
        #expect(reports.info("host settings") == .hostError(callback: .settings, task: task))
        try await harness.close(context: .background)
    }

    @Test(arguments: [
        ["first", "second"], ["second", "first"],
        ["first", "wrap-a", "wrap-b"], ["wrap-b", "wrap-a", "first"]
    ])
    func sectionAndToolOwnersUseTheLastSelectedProviderOrWrapper(selection: [String]) throws {
        let registry = Registry()
        let tool = try harnessTestTool("owned")
        let prompt = section("owned") { _, _ in "text" }
        for name in ["first", "second"] {
            try registry.install(Extension(name: name, tools: [tool], sections: [prompt]))
        }
        for name in ["wrap-a", "wrap-b"] {
            try registry.install(Extension(name: name, wraps: [wrapTool(tool) { $0 }, wrapSection("owned") { $0 }]))
        }
        let agent = resolveAgent(state: .init(extensions: .exact(selection)), snapshot: registry.snapshot())
        #expect(sectionExtension(agent, key: "owned") == selection.last)
        #expect(toolExtension(agent, name: "owned") == selection.last)
        #expect(sectionExtension(agent, key: "absent") == nil)
        #expect(toolExtension(agent, name: "absent") == nil)
        let unowned = Agent(tools: [tool], sections: [prompt])
        #expect(sectionExtension(unowned, key: "owned") == nil)
        #expect(toolExtension(unowned, name: "owned") == nil)
    }

    @Test func invalidModelToolStructuredOutputReportNamesTheWrapper() async throws {
        let setup = HarnessChatSetup(), reports = TypedHarnessReports()
        var tool = try harnessTestTool()
        tool.structuredOutputSchema = ["type": "integer"]
        try setup.registry.install(Extension(name: "provider", tools: [tool]))
        try setup.registry.install(Extension(name: "wrapper", wraps: [wrapTool(tool) { tool in
            var changed = tool
            changed.execute = { _, _, _ in
                .init(output: [.text(TextContent(text: "kept"))], structuredOutput: .string("invalid"))
            }
            return changed
        }]))
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "c1")])), .message(chatAssistant("done"))])
        let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: setup.models,
            registry: setup.registry, onReport: { error, info in reports.append(error, info) }), context: .background)
        let root = try await harness.root(options: .init(agent: .init(model: .set(.init(provider: "faux", modelId: "faux-1")))), context: .background)
        #expect(try await root.submit(.input(content: .text("go")), context: .background).wait(context: .background).status == "done")
        let record = try #require(try await harness.commit({ tx in
            try await tx.scanTasks(.init(conversationId: root.id), limit: 10)
        }, context: .background).items.first { $0.kind == "pi.tool" })
        let report = try #require(reports.values.first { $0.message.contains("structuredOutput") })
        #expect(report.info == .extensionError(extension: "wrapper",
            task: .init(id: record.id, kind: "pi.tool", conversationId: root.id)))
        #expect(reports.values.count == 1)
        let entries = try await allEntries(root)
        let result = try #require(try harnessToolResults(entries).first)
        #expect(harnessToolText(result) == "kept")
        #expect(!result.isError)
        try await harness.close(context: .background)
    }

    @Test func deferredCancellationFailureNamesTheModelsCallbackAndGenerationTask() async throws {
        let clock = TestClock(), setup = HarnessChatSetup(), reports = TypedHarnessReports()
        let models = HarnessManualModels(base: setup.models, cancelFails: true)
        let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: models,
            registry: setup.registry, clock: clock, onReport: { error, info in reports.append(error, info) }), context: .background)
        let root = try await harness.root(options: .init(agent: .init(model: .set(.init(provider: "faux", modelId: "faux-1")))), context: .background)
        let opened = OpenChatResult(harness: harness, root: root)
        let submission = try await generationSubmit(opened)
        try await harnessEventually { models.seen.withLock { !$0.isEmpty } }
        var deferred = chatAssistant("", reason: .deferred)
        deferred.content = []
        deferred.deferred = DeferredHandle(provider: "faux", modelId: "faux-1", api: "openai-completions", id: "test")
        models.stream.push(.done(reason: .deferred, message: deferred))
        try await harnessEventually { try await generationLive(opened)?.generation?.deferred != nil }
        let id = try #require(try await generationLive(opened)?.run?.taskId)
        try await root.abort(context: .background)
        #expect(try await submission.wait(context: .background).reason == "aborted")
        #expect(reports.values.count == 1)
        #expect(reports.info("cancel failed") == .hostError(callback: .models,
            task: .init(id: id, kind: "pi.generation", conversationId: root.id)))
        try await harness.close(context: .background)
    }
}
