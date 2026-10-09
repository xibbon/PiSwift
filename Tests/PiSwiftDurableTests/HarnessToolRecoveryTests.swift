import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private func recoveryCall(_ name: String, id: String = "c1") -> AssistantMessage {
    var message = chatAssistant("", reason: .toolUse)
    message.content = [.toolCall(ToolCall(id: id, name: name, arguments: [:]))]
    return message
}
private func recoveryTool(_ name: String = "work", replay: ToolReplay? = nil,
    execute: @escaping @Sendable (JSONValue, ToolExecutionApi, ChordContext) async throws -> ToolExecutionResult
) throws -> ToolRegistration {
    try ToolRegistration(name: name, description: name, parameters: ["type": "object", "properties": [:]], replay: replay, execute: execute)
}
private func recoveryInstall(_ setup: HarnessChatSetup, tool: ToolRegistration) throws {
    try setup.registry.install(Extension(name: "recovery-work", tools: [tool]))
}
private func recoveryOpen(_ storage: any DurableStorage, setup: HarnessChatSetup, env: HarnessEnvFactory? = nil,
                          resume: Bool = true) async throws -> OpenChatResult {
    let harness = try await Harness.open(storage: storage, options: HarnessOptions(models: setup.models,
        registry: setup.registry, settings: setup.settingsProvider, env: env, onReport: { setup.reports.append($0) }), context: .background)
    let root = try await harness.root(options: .init(agent: AgentChange(model: .set(ModelRef(provider: "faux", modelId: "faux-1")))), context: .background)
    if resume { try harness.resume() }
    return OpenChatResult(harness: harness, root: root)
}
private func recoveryResults(_ opened: OpenChatResult) async throws -> [ToolResultMessage] {
    try await allEntries(opened.root).filter { $0.kind == toolResultEntry.kind }.compactMap {
        guard case .toolResult(let result) = try $0.messages()?.first else { return nil }
        return result
    }
}
private func recoveryText(_ message: ToolResultMessage?) -> String {
    (message?.content ?? []).map { if case .text(let text) = $0 { text.text } else { "" } }.joined(separator: "|")
}
private func recoveryToolID(_ opened: OpenChatResult) async throws -> TaskID {
    try #require(try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background)?.tools?.first?.taskId)
}
private func recoveryWait(_ opened: OpenChatResult, id: SubmissionID) async throws -> SettledSubmission {
    let submission = try #require(try await opened.harness.submission(id: id, context: .background))
    return try await submission.wait(context: .background)
}
private func recoveryAborted(_ context: ChordContext) async throws {
    let signal = try #require(context.abortSignal)
    let reached = HarnessChatSignal()
    let listener = signal.addAbortListener { _ in reached.signal() }
    defer { signal.removeAbortListener(listener) }
    if signal.aborted { reached.signal() }
    await reached.wait()
    try signal.throwIfAborted()
}
private final class RecoveryBlockingTool: Sendable {
    let started = HarnessChatSignal()
    let runs = Mutex(0)
    var count: Int { runs.withLock { $0 } }
    func registration(replay: ToolReplay? = nil) throws -> ToolRegistration {
        try recoveryTool(replay: replay) { [self] _, api, context in
            let run = runs.withLock { $0 += 1; return $0 }
            try api.output(.text("run \(run)\n"), nil)
            try await api.details(.object(["run": .number(Double(run))]), context)
            if run == 1 { started.signal(); try await recoveryAborted(context) }
            return ToolExecutionResult()
        }
    }
}

@Suite struct HarnessToolRecoveryTests {
    // harness-tools-recovery.test.ts:109. A new SQLite connection reads the execute intent and partial output.
    @Test func unsafeToolRecoversDurablePartialOutputWithoutRunningAgain() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("unsafe-tool.sqlite").path
        let setup = HarnessChatSetup(), work = RecoveryBlockingTool()
        try recoveryInstall(setup, tool: work.registration())
        setup.models.setResponses([.message(recoveryCall("work")), .message(chatAssistant("done"))])
        let first = try await recoveryOpen(SqliteStorage.open(path: path), setup: setup)
        let id = try await generationSubmit(first, "go").id
        await work.started.wait()
        let taskID = try await recoveryToolID(first)
        try await first.harness.close(context: .background)
        let second = try await recoveryOpen(SqliteStorage.open(path: path), setup: setup, resume: false)
        let record = try #require(try await second.harness.getTask(id: taskID, context: .background))
        guard case .pending(let checkpoint, _) = record.state else { Issue.record("Expected pending execute intent"); return }
        let intent = try checkpoint.decode(ToolTaskCheckpoint.self)
        #expect(intent.phase == .execute)
        #expect(intent.arguments == [:])
        #expect(intent.replay == .unsafe)
        try second.harness.resume()
        #expect(try await recoveryWait(second, id: id).status == "done")
        #expect(work.count == 1)
        let result = try #require(try await recoveryResults(second).first)
        #expect(result.isError)
        #expect(try durableJSON(fromFoundation: result.details?.value ?? NSNull()) == .object(["run": 1]))
        #expect(recoveryText(result) == "run 1\n|<harness>\n[error] Tool work was interrupted and may have partially run\n</harness>")
        #expect(try await second.harness.snapshot(LiveDoc, conversationId: second.root.id, context: .background) == LiveState())
        try await second.harness.close(context: .background)
    }

    // harness-tools-recovery.test.ts:136. Stored and current replay policies must both permit a rerun.
    @Test(arguments: [(ToolReplay.safe, ToolReplay.safe), (.safe, .unsafe), (.unsafe, .safe)])
    func replayRequiresBothPoliciesToBeSafe(policies: (ToolReplay, ToolReplay)) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("tool-policy.sqlite").path
        let setup = HarnessChatSetup(), work = RecoveryBlockingTool()
        try recoveryInstall(setup, tool: work.registration(replay: policies.0))
        setup.models.setResponses([.message(recoveryCall("work")), .message(chatAssistant("done"))])
        let first = try await recoveryOpen(SqliteStorage.open(path: path), setup: setup)
        let id = try await generationSubmit(first, "go").id
        await work.started.wait()
        try await first.harness.close(context: .background)
        try recoveryInstall(setup, tool: work.registration(replay: policies.1))
        let second = try await recoveryOpen(SqliteStorage.open(path: path), setup: setup)
        #expect(try await recoveryWait(second, id: id).status == "done")
        let reruns = policies.0 == .safe && policies.1 == .safe
        let result = try #require(try await recoveryResults(second).first)
        #expect(work.count == (reruns ? 2 : 1))
        #expect(result.isError == !reruns)
        if reruns { #expect(recoveryText(result) == "run 2\n") }
        try await second.harness.close(context: .background)
    }

    // harness-tools-recovery.test.ts:165. Each attempt gets the current conversation environment.
    @Test(arguments: ["cwd", "deselect"])
    func safeRecoveryUsesCurrentCwdAndDoesNotRunDeselectedTool(change: String) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("tool-env.sqlite").path
        let setup = HarnessChatSetup(), started = HarnessChatSignal(), cwds = SessionTestLog<String>()
        let work = try recoveryTool(replay: .safe) { _, api, context in
            cwds.append(api.env?.cwd ?? "none")
            if cwds.count == 1 { started.signal(); try await recoveryAborted(context) }
            return ToolExecutionResult()
        }
        try recoveryInstall(setup, tool: work)
        setup.models.setResponses([.message(recoveryCall("work")), .message(chatAssistant("done"))])
        let env: HarnessEnvFactory = { target, _ in FakeExecutionEnv(cwd: target.cwd ?? "/") }
        let first = try await recoveryOpen(SqliteStorage.open(path: path), setup: setup, env: env)
        try await first.root.configure(change: AgentChange(cwd: .set("/one")), context: .background)
        let id = try await generationSubmit(first, "go").id
        await started.wait()
        try await first.root.configure(change: change == "cwd" ? AgentChange(cwd: .set("/two")) : AgentChange(extensions: .set(.exact([]))), context: .background)
        try await first.harness.close(context: .background)
        let second = try await recoveryOpen(SqliteStorage.open(path: path), setup: setup, env: env)
        #expect(try await recoveryWait(second, id: id).status == "done")
        let result = try #require(try await recoveryResults(second).first)
        #expect(cwds.values == (change == "cwd" ? ["/one", "/two"] : ["/one"]))
        if change == "cwd" { #expect(!result.isError) } else { #expect(recoveryText(result).contains("was interrupted")) }
        try await second.harness.close(context: .background)
    }

    // harness-tools-recovery.test.ts:213. The call phase repeats hooks, but memo keeps the first decision.
    @Test func beforeIntentRecoveryRepeatsHookAndKeepsMemoThenExecutesOnce() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("tool-hook.sqlite").path
        let setup = HarnessChatSetup(), reached = HarnessChatSignal()
        let attempts = Mutex(0), runs = Mutex(0), decisions = SessionTestLog<JSONValue?>()
        try recoveryInstall(setup, tool: recoveryTool { _, _, _ in
            runs.withLock { $0 += 1 }; return ToolExecutionResult(content: [])
        })
        try setup.registry.install(Extension(name: "recovery-hook", hooks: [hook(ToolHooks(beforeTool: { _, api, context in
            let attempt = attempts.withLock { $0 += 1; return $0 }
            decisions.append(try await api.memo("test:decision", .string("attempt \(attempt)"), context))
            if attempt == 1 { reached.signal(); try await recoveryAborted(context) }
            return nil
        }))]))
        setup.models.setResponses([.message(recoveryCall("work")), .message(chatAssistant("done"))])
        let first = try await recoveryOpen(SqliteStorage.open(path: path), setup: setup)
        let id = try await generationSubmit(first, "go").id
        await reached.wait()
        try await first.harness.close(context: .background)
        let second = try await recoveryOpen(SqliteStorage.open(path: path), setup: setup)
        #expect(try await recoveryWait(second, id: id).status == "done")
        #expect(attempts.withLock { $0 } == 2)
        #expect(runs.withLock { $0 } == 1)
        #expect(decisions.values == [.string("attempt 1"), .string("attempt 1")])
        try await second.harness.close(context: .background)
    }

    // harness-tools-recovery.test.ts:252. Recovery repeats the generation tools hook before its commit.
    @Test func generationToolsPhaseRunsAgainBeforeItsCommitWithoutDuplicateEntries() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("after-tools.sqlite").path
        let setup = HarnessChatSetup(), reached = HarnessChatSignal(), observations = Mutex(0)
        try recoveryInstall(setup, tool: recoveryTool { _, _, _ in ToolExecutionResult(content: []) })
        try setup.registry.install(Extension(name: "recovery-generation-hook", hooks: [hook(GenerationHooks(afterTools: { _, _, _, context in
            let observed = observations.withLock { $0 += 1; return $0 }
            if observed == 1 { reached.signal(); try await recoveryAborted(context) }
        }))]))
        setup.models.setResponses([.message(recoveryCall("work")), .message(chatAssistant("done"))])
        let first = try await recoveryOpen(SqliteStorage.open(path: path), setup: setup)
        let id = try await generationSubmit(first, "go").id
        await reached.wait()
        try await first.harness.close(context: .background)
        let second = try await recoveryOpen(SqliteStorage.open(path: path), setup: setup)
        #expect(try await recoveryWait(second, id: id).status == "done")
        #expect(observations.withLock { $0 } == 2)
        #expect(try await allEntries(second.root).map(\.kind) == ["pi.user", "pi.system", "pi.assistant", "pi.tool-result", "pi.assistant"])
        try await second.harness.close(context: .background)
    }

    // harness-tools-recovery.test.ts:289. Abort settles the partial result and lets generation continue.
    @Test func abortReturnsPartialOutputAndRunContinues() async throws {
        let setup = HarnessChatSetup(), work = RecoveryBlockingTool()
        try recoveryInstall(setup, tool: work.registration())
        setup.models.setResponses([.message(recoveryCall("work")), .message(chatAssistant("done"))])
        let opened = try await recoveryOpen(MemoryStorage(), setup: setup)
        let submission = try await generationSubmit(opened, "go")
        await work.started.wait()
        let taskID = try await recoveryToolID(opened)
        #expect(try await opened.harness.abortTask(id: taskID, context: .background) == .marked)
        let receipt = try await opened.harness.waitForTask(id: taskID, context: .background)
        #expect(receipt.outcome.status == "aborted")
        guard case .aborted(_, let result, _) = receipt.outcome else { Issue.record("Expected aborted result"); return }
        let durableResult = try #require(result).decode(ToolTaskResult.self)
        #expect(try await opened.harness.commit({ tx in try await tx.entry(durableResult.entryId) }, context: .background) != nil)
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(try await recoveryText(recoveryResults(opened).first) == "run 1\n|<harness>\n[error] Tool work was aborted\n</harness>")
        try await opened.harness.close(context: .background)
    }

    // harness-tools-recovery.test.ts:310. Swift cannot store a function in JSONValue; infinity is also invalid strict JSON.
    @Test func faultedResultGetsContextFallbackAndRunContinues() async throws {
        let setup = HarnessChatSetup(), requests = SessionTestLog<String>()
        try recoveryInstall(setup, tool: recoveryTool("bad") { _, _, _ in ToolExecutionResult(content: [], details: .number(.infinity)) })
        setup.models.setResponses([.message(recoveryCall("bad")), .factory { transcript, _, _, _ in
            let result = transcript.messages.compactMap { message -> ToolResultMessage? in
                if case .toolResult(let result) = message { return result }; return nil
            }.first
            requests.append(recoveryText(result)); return chatAssistant("done")
        }])
        let opened = try await recoveryOpen(MemoryStorage(), setup: setup)
        #expect(try await generationSubmit(opened, "go").wait(context: .background).status == "done")
        #expect(try await recoveryResults(opened).isEmpty)
        #expect(requests.values == ["Tool result unavailable: history ends before this call completed."])
        let tasks = try await opened.harness.commit({ tx in try await tx.scanTasks(TaskQuery(conversationId: opened.root.id), limit: 20, cursor: nil) }, context: .background)
        let faulted = try #require(tasks.items.first { $0.kind == "pi.tool" })
        guard case .terminal(let outcome, _) = faulted.state else { Issue.record("Expected terminal tool"); return }
        #expect(outcome.status == "faulted")
        try await opened.harness.close(context: .background)
    }

    // harness-tools-recovery.test.ts:338 requires the real coding shell tool; that integration belongs to P1 B.
    // The scripted shell test below checks the ExecutionEnv boundary without a process or host file system.
    @Test func scriptedShellUsesFakeEnvironmentAndReportsOutput() async throws {
        let env = FakeExecutionEnv(cwd: "/conversation", files: ["seed.txt": "seed"], exec: [{ _, options, context in
            do { try options?.onOutput?("started\n", context, ShellOutputInfo(stream: .stdout)); return .success(ShellExecResult(exitCode: 0)) }
            catch { return .failure(ExecutionError(.callbackError, message: String(describing: error))) }
        }])
        let output = SessionTestLog<String>()
        #expect(try await env.readTextFile("seed.txt", context: .background).get() == "seed")
        let result = await env.exec(.shell("scripted"), options: ShellExecOptions(onOutput: { text, _, _ in output.append(text) }), context: .background)
        #expect(try result.get().exitCode == 0)
        #expect(output.values == ["started\n"])
        #expect(env.execCalls.map(\.cwd) == ["/conversation"])
    }

    @Test func fakeFilesUseByteOffsetsAndZeroBasedLineRanges() async throws {
        let env = FakeExecutionEnv(cwd: "/one/two", files: ["seed.txt": "é\nb\n"])
        #expect(try await env.joinPath(["relative", "..", "file"], context: .background).get() == "file")
        #expect(try await env.fileInfo("/one", context: .background).get().kind == .directory)
        let reader = try await env.openBinaryReader("seed.txt", options: nil, context: .background).get()
        let scan = try await reader.scanLines(options: .init(startLine: 0, endLine: 1), context: .background).get()
        #expect(scan == LineScan(newlines: 2, start: 0, end: 2, firstLineEnd: 2, lastLineStart: 0, selectedBytes: 2, firstLineBytes: 2))
        let tail = try await reader.scanLines(options: .init(startLine: 1), context: .background).get()
        #expect(tail == LineScan(newlines: 2, start: 3, end: 5, firstLineEnd: 4, lastLineStart: 5, selectedBytes: 2, firstLineBytes: 1))
        #expect(try await env.readTextLines("missing", options: .init(maxLines: 0), context: .background).get().isEmpty)
        try await env.writeFile("created.txt", content: .text("a"), context: .background).get()
        try await env.appendFile("created.txt", content: .text("b"), context: .background).get()
        #expect(try await env.readTextFile("created.txt", context: .background).get() == "ab")
        await reader.close(context: .background)
    }

    // harness-tools-recovery.test.ts:366. The safe attempt starts with clean progress fields.
    @Test func safeReplayClearsPriorAttemptProgress() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("tool-progress.sqlite").path
        let setup = HarnessChatSetup(), signals = [HarnessChatSignal(), HarnessChatSignal()], runs = Mutex(0)
        try recoveryInstall(setup, tool: recoveryTool(replay: .safe) { _, api, context in
            let run = runs.withLock { $0 += 1; return $0 }
            if run == 1 {
                try api.diagnostic(ToolDiagnostic(severity: .info, message: "first a"))
                try api.diagnostic(ToolDiagnostic(severity: .info, message: "first b"))
                try await api.details(.object(["run": 1, "extra": true]), context)
            } else {
                try api.diagnostic(ToolDiagnostic(severity: .info, message: "second"))
                try await api.details(.object(["run": 2]), context)
            }
            signals[run - 1].signal(); try await recoveryAborted(context)
            return ToolExecutionResult()
        })
        setup.models.setResponses([.message(recoveryCall("work")), .message(chatAssistant("done"))])
        let first = try await recoveryOpen(SqliteStorage.open(path: path), setup: setup)
        _ = try await generationSubmit(first, "go")
        await signals[0].wait()
        try await first.harness.close(context: .background)
        let second = try await recoveryOpen(SqliteStorage.open(path: path), setup: setup)
        await signals[1].wait()
        let slot = try #require(try await second.harness.snapshot(LiveDoc, conversationId: second.root.id, context: .background)?.tools?.first)
        #expect(slot.diagnostics == [ToolDiagnostic(severity: .info, message: "second")])
        #expect(slot.details == .object(["run": 2]))
        try await second.harness.close(context: .background)
    }

    // A process crash leaves the old terminal commit held. Recovery sees only the durable execute intent.
    @Test func crashBeforeResultCommitKeepsPartialOutputAndDoesNotReplayUnsafeTool() async throws {
        let storage = ControlledStorage(), setup = HarnessChatSetup(), reached = HarnessChatSignal(), finish = HarnessChatSignal(), runs = Mutex(0)
        try recoveryInstall(setup, tool: recoveryTool { _, api, context in
            runs.withLock { $0 += 1 }
            try api.output(.text("partial\n"), nil)
            try await api.details(.object(["kept": true]), context)
            reached.signal(); await finish.wait()
            return ToolExecutionResult()
        })
        setup.models.setResponses([.message(recoveryCall("work")), .message(chatAssistant("done"))])
        let first = try await recoveryOpen(storage, setup: setup)
        let id = try await generationSubmit(first, "go").id
        await reached.wait()
        let held = await storage.holdCommits()
        finish.signal()
        await held.waitUntilEntered()
        await storage.crash()
        let second = try await recoveryOpen(storage, setup: setup)
        #expect(try await recoveryWait(second, id: id).status == "done")
        #expect(runs.withLock { $0 } == 1)
        let result = try #require(try await recoveryResults(second).first)
        #expect(recoveryText(result) == "partial\n|<harness>\n[error] Tool work was interrupted and may have partially run\n</harness>")
        try await second.harness.close(context: .background)
    }
}
