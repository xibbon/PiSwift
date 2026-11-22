import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
import Testing
@testable import PiSwiftDurable

#if os(macOS)
@Suite(.serialized)
struct D5HookFixtureTests {
    private struct Fixture: Decodable {
        enum Backend: String, Decodable { case sqlite, jsonl }
        enum Phase: String, Decodable { case afterTools, yield }
        enum Step: String, Decodable { case park, finish }
        enum Mode: String, Decodable { case sleeping, running }

        let backend: Backend
        let phase: Phase
        let path: String
        let step: Step
        let mode: Mode?
        let workPath: String?
    }

    private struct RunningChild: Sendable {
        let reached = HarnessChatSignal()
        let release = HarnessChatSignal()

        func wait(context: ChordContext) async throws {
            let signal = context.abortSignal
            let listener = signal?.addAbortListener { _ in release.signal() }
            defer { if let listener { signal?.removeAbortListener(listener) } }
            if signal?.aborted == true { release.signal() }
            reached.signal()
            await release.wait()
            try signal?.throwIfAborted()
        }
    }

    private struct Checkpoint: TaskCheckpoint {
        enum Phase: String, Codable, Sendable { case park, decide }
        let phase: Phase
    }

    private typealias Child = TaskDefinition<JSONValue, Checkpoint, JSONValue, NoTaskHooks>
    private static let time: Int64 = 1_000
    private static let childName = "fixture.d5-hook"
    private static let key = "decision"
    private static let schema: JSONObject = [
        "type": "object", "properties": [:], "additionalProperties": false,
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PISWIFT_D5_HOOK_PLAN"] != nil),
          .timeLimit(.minutes(2)))
    func crossLanguageHookFiles() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["PISWIFT_D5_HOOK_PLAN"])
        let plan = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let signal: SignalToken<JSONValue> = try defineSignal(name: "fixture.d5-decision",
            version: 1, schema: .object(Self.schema))
        for item in plan {
            try await run(item, signal: signal)
        }
    }

    private func makeRegistry(_ item: Fixture, signal: SignalToken<JSONValue>, running: RunningChild?) throws -> Registry {
        let decision: JSONValue = item.phase == .afterTools ? ["terminate": true] : ["continue": "fixture revision"]
        let initial: Checkpoint.Phase = running == nil ? .park : .decide
        let child = Child(name: Self.childName, version: 1, initial: { _ in .init(phase: initial) },
            phase: { task, runtime, context in
                switch task.checkpoint.phase {
                case .park:
                    try await runtime.sleep(signals: [signal.key(Self.key)],
                        checkpoint: JSONValue(encoding: Checkpoint(phase: .decide)), context: context)
                case .decide:
                    if let running {
                        try await running.wait(context: context)
                    } else {
                        let delivered = try await runtime.readSignal(signal, key: Self.key, context: context)
                        guard case .value(let value)? = delivered, value == [:] else {
                            throw TaskDefinitionError("The hook task did not read the signal that woke it")
                        }
                    }
                    try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: decision)) }, context: context)
                }
            }, abort: { _, runtime, context in
                try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
            })
        let hooks: GenerationHooks
        let tools: [ToolRegistration]
        switch item.phase {
        case .afterTools:
            hooks = GenerationHooks(afterTools: { _, _, _, _ in AfterToolsResult(tasks: [try hookTask(child, input: .null)]) })
            tools = [try ToolRegistration(name: "fixture_step", description: "fixture_step", parameters: Self.schema,
                replay: .safe, execute: { _, _, _ in .result(.init(output: [.text(.init(text: "fixture tool result"))])) })]
        case .yield:
            hooks = GenerationHooks(onYield: { message, _, _ in
                guard textOf(.assistant(message)) == "fixture draft" else { return nil }
                return GenerationYield(tasks: [try hookTask(child, input: .null)])
            })
            tools = []
        }
        let registry = createRegistry()
        try registry.install(Extension(name: "fixture.d5", tools: tools,
            hooks: [hook(hooks)], tasks: [AnyTaskDefinition(child)]))
        return registry
    }

    private func run(_ item: Fixture, signal: SignalToken<JSONValue>) async throws {
        let running = item.mode == .running ? RunningChild() : nil
        let path = running != nil && item.step == .park ? try #require(item.workPath) : item.path
        let storage: any DurableStorage
        switch item.backend {
        case .sqlite: storage = try await SqliteStorage.open(path: path)
        case .jsonl:
            storage = try await JsonlStorage.open(directory: path, fileSystem: LocalExecutionEnv(cwd: path))
        }
        if running != nil && item.step == .finish {
            let children = try await storage.scanTasks(.init(kind: Self.childName), limit: 10, cursor: nil,
                context: .background).items
            #expect(children.count == 1)
            #expect(children.first?.state.status == "running")
        }
        let models = FakeDurableModels(tagCacheAccounting: true)
        switch (item.step, item.phase) {
        case (.park, .afterTools):
            models.setResponses([.message(fauxAssistantMessage(
                content: [fauxToolCall(name: "fixture_step", arguments: [:], id: "c1")],
                stopReason: .toolUse, timestamp: Self.time))])
        case (.park, .yield): models.setResponses([.message(answer("fixture draft"))])
        case (.finish, .yield): models.setResponses([.message(answer("fixture final"))])
        case (.finish, .afterTools): break
        }
        let reports = HarnessReports()
        let harness = try await Harness.open(storage: storage, options: .init(models: models,
            registry: makeRegistry(item, signal: signal, running: running),
            settings: HarnessSettingsProvider { .init(retry: .init(enabled: false)) },
            clock: TestClock(now: Self.time), onWake: { _ in }, onReport: { reports.appendReport($0) }), context: .background)
        do {
            try harness.resume()
            try await harnessEventually {
                if let running { return running.reached.isSignalled }
                let children = try await storage.scanTasks(.init(kind: Self.childName), limit: 10, cursor: nil,
                    context: .background).items
                return children.first?.state.status == "sleeping" && !harness.wake().active
            }
            let children = try await storage.scanTasks(.init(kind: Self.childName), limit: 10, cursor: nil,
                context: .background).items
            try #require(children.count == 1)
            let child = try #require(children.first)
            #expect(child.state.status == (running == nil ? "sleeping" : "running"))
            let owner = try #require(child.owner)
            let generation = try #require(await harness.getTask(id: owner, context: .background))
            #expect(generation.state.status == "waiting")
            #expect(generation.state.checkpoint?["phase"] == .string(item.phase.rawValue))
            #expect(generation.state.checkpoint?["tasks"] == (try JSONValue(encoding: [child.id])))
            if item.step == .park {
                if running != nil {
                    try copyRunningStore(from: path, to: item.path, backend: item.backend)
                }
            } else {
                if let running {
                    #expect(child.restarts == 1)
                    running.release.signal()
                } else {
                    #expect(try await harness.signal(taskId: child.id, token: signal, key: Self.key,
                        value: [:], context: .background) == .delivered)
                }
                try await harness.waitForIdle(context: .background)
                let submissions = try await storage.scanSubmissions(.init(conversationId: child.conversationId),
                    limit: 10, cursor: nil, context: .background).items
                #expect(submissions.count == 1)
                #expect(submissions.first?.status == "done")
                #expect(models.state().callCount == (item.phase == .yield ? 1 : 0))
            }
        } catch {
            try? await harness.close(context: .background)
            throw error
        }
        try await harness.close(context: .background)
        #expect(reports.values.isEmpty)
    }

    // The child holds before its terminal commit, so the database and journal are stable.
    private func copyRunningStore(from source: String, to destination: String, backend: Fixture.Backend) throws {
        let files = FileManager.default
        try files.copyItem(atPath: source, toPath: destination)
        if backend == .sqlite && files.fileExists(atPath: source + "-wal") {
            try files.copyItem(atPath: source + "-wal", toPath: destination + "-wal")
        }
    }

    private func answer(_ text: String) -> AssistantMessage {
        fauxAssistantMessage(content: [.text(.init(text: text))], timestamp: Self.time)
    }
}
#endif
