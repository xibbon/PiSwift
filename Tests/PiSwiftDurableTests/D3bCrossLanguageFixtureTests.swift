import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
import Testing
@testable import PiSwiftDurable

#if os(macOS)
@Suite("PiSwiftDurableTests.D3bCrossLanguageFixtures", .serialized, .timeLimit(.minutes(2)))
struct D3bCrossLanguageFixtureTests {
    private struct Fixture: Decodable {
        enum Backend: String, Decodable { case sqlite, jsonl }
        enum Scenario: String, Decodable { case nested, notify, restart }
        enum Step: String, Decodable { case park, finish }
        let backend: Backend
        let scenario: Scenario
        let path: String
        let step: Step
    }
    private struct WaiterCheckpoint: TaskCheckpoint {
        enum Phase: String, Codable, Sendable { case sleep, woke }
        let phase: Phase
    }
    private typealias Waiter = TaskDefinition<JSONValue, WaiterCheckpoint, String, NoTaskHooks>

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PISWIFT_D3B_PLAN"] != nil))
    func continueD3bFiles() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["PISWIFT_D3B_PLAN"])
        let plan = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let done: SignalToken<JSONValue> = try defineSignal(name: "fixture.d3b-done", version: 1,
            schema: ["type": "object", "properties": ["text": ["type": "string"]],
                     "required": ["text"], "additionalProperties": false])
        for item in plan { try await run(item, done: done) }
    }

    private func waiter() -> Waiter {
        Waiter(name: "fixture.d3b-waiter", version: 1, initial: { _ in .init(phase: .sleep) },
            phase: { task, runtime, context in
                switch task.checkpoint.phase {
                case .sleep:
                    try await runtime.sleep(signals: [SubmissionSettled.key("settled")],
                        checkpoint: JSONValue(encoding: WaiterCheckpoint(phase: .woke)), context: context)
                case .woke:
                    guard case .value(let record) = try await runtime.readSignal(SubmissionSettled,
                        key: "settled", context: context), record.status == "done" else {
                        throw TaskDefinitionError("D3b fixture lost the settlement signal")
                    }
                    try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: "done")) }, context: context)
                }
            }, abort: { _, runtime, context in
                try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
            })
    }

    private func registry(for item: Fixture, done: SignalToken<JSONValue>) throws -> Registry {
        let registry = createRegistry()
        let waiter = waiter()
        var tools: [ToolRegistration] = []
        if item.scenario != .notify {
            let research = try ToolRegistration(name: "research", description: "research",
                parameters: ["type": "object", "properties": ["topic": ["type": "string"]],
                             "required": ["topic"], "additionalProperties": false], replay: .safe,
                execute: { args, api, context in
                    if case .value(let value) = try await api.readSignal(done, key: "done", context: context) {
                        let topic = args["topic"]?.stringValue ?? ""
                        let text = value["text"]?.stringValue ?? ""
                        return .result(.init(output: [.text(.init(text: "\(topic): \(text)"))]))
                    }
                    return .park(.sleep(signals: [try done.key("done")]))
                })
            tools.append(research)
            let parent = try ToolRegistration(name: "fixture.d3b-parent", description: "fixture.d3b-parent",
                parameters: ["type": "object", "properties": [:], "additionalProperties": false],
                replay: item.scenario == .nested ? .safe : nil,
                execute: { _, api, context in
                    let a = try await api.executeTool("research", arguments: ["topic": "x"],
                        context: context, wait: false, key: "a")
                    if item.scenario == .restart {
                        if api.wake == nil { return .park(.wait(on: [a.taskId], policy: .allSettled)) }
                        let result = try await a.result(context: context)
                        return .result(.init(output: [.text(.init(text: result.structuredOutput?.stringValue ?? ""))]))
                    }
                    let b = try await api.executeTool("research", arguments: ["topic": "y"],
                        context: context, wait: false, key: "b")
                    var open: [TaskID] = []
                    for id in [a.taskId, b.taskId] {
                        if try await api.getTask(id: id, context: context)?.state.status != "terminal" { open.append(id) }
                    }
                    if !open.isEmpty { return .park(.wait(on: open, policy: .any)) }
                    let ra = try await a.result(context: context)
                    let rb = try await b.result(context: context)
                    return .result(.init(output: [.text(.init(text: "\(ra.structuredOutput?.stringValue ?? "") + \(rb.structuredOutput?.stringValue ?? "")"))]))
                })
            tools.append(parent)
        }
        try registry.install(Extension(name: "fixture.d3b", tools: tools, tasks: [AnyTaskDefinition(waiter)]))
        return registry
    }

    private func run(_ item: Fixture, done: SignalToken<JSONValue>) async throws {
        let storage: any DurableStorage
        switch item.backend {
        case .sqlite: storage = try await SqliteStorage.open(path: item.path)
        case .jsonl: storage = try await JsonlStorage.open(directory: item.path,
            fileSystem: LocalExecutionEnv(cwd: item.path))
        }
        let registry = try registry(for: item, done: done)
        let harness = try await Harness.open(storage: storage, options: .init(models: FakeDurableModels(),
            registry: registry, clock: TestClock(now: 1_000), onWake: { _ in }), context: .background)
        do {
            try harness.resume()
            if item.step == .park {
                try await park(item, harness: harness, storage: storage, done: done)
            } else {
                try await finish(item, harness: harness, storage: storage, done: done)
            }
        } catch {
            try? await harness.close(context: .background)
            throw error
        }
        try await harness.close(context: .background)
    }

    private func tasks(_ storage: any DurableStorage) async throws -> [TaskRecord] {
        try await storage.scanTasks(.init(order: .ascending), limit: 100, cursor: nil, context: .background).items
    }

    private func park(_ item: Fixture, harness: Harness, storage: any DurableStorage,
                      done: SignalToken<JSONValue>) async throws {
        if item.scenario == .notify {
            try await harnessEventually {
                try await tasks(storage).first { $0.kind == "fixture.d3b-waiter" }?.state.status == "sleeping"
                    && !harness.wake().active
            }
            return
        }
        try await harnessEventually {
            let records = try await tasks(storage)
            let parent = records.first { $0.kind == "pi.tool" && $0.input["kind"] == "model" }
            let children = records.filter { $0.kind == "pi.tool" && $0.input["kind"] == "nested" }
            return parent?.state.status == "waiting" && children.count == (item.scenario == .nested ? 2 : 1)
                && children.allSatisfy { $0.state.status == "sleeping" } && !harness.wake().active
        }
        guard item.scenario == .nested else { return }
        let b = try #require(try await tasks(storage).first { $0.input["kind"] == "nested" && $0.input["key"] == "b" })
        #expect(try await harness.signal(taskId: b.id, token: done, key: "done",
            value: ["text": "bee"], context: .background) == .delivered)
        try await harnessEventually {
            let parent = try await tasks(storage).first { $0.kind == "pi.tool" && $0.input["kind"] == "model" }
            guard let parent, case .waiting(_, let on, _, _) = parent.state else { return false }
            return on.count == 1 && on[0] != b.id && !harness.wake().active
        }
    }

    private func finish(_ item: Fixture, harness: Harness, storage: any DurableStorage,
                        done: SignalToken<JSONValue>) async throws {
        let records = try await tasks(storage)
        if item.scenario == .notify {
            let submission = try #require(try await storage.scanSubmissions(.init(order: .ascending),
                limit: 10, cursor: nil, context: .background).items.first)
            #expect(submission.status == "queued")
            let root = try await harness.root(context: .background)
            try await root.commit({ tx in
                let entry = try await tx.appendEntry(root.id, value: EntryDraft(kind: "note"))
                try tx.placeSubmission(submission.id, entry: entry.id)
            }, context: .background)
            let task = try #require(records.first { $0.kind == "fixture.d3b-waiter" })
            #expect(try await harness.waitForTask(id: task.id, context: .background).outcome.status == "completed")
            return
        }
        let a = try #require(records.first { $0.input["kind"] == "nested" && $0.input["key"] == "a" })
        if item.scenario == .restart {
            try await harnessEventually { !harness.wake().active }
            #expect(try await harness.getTask(id: a.id, context: .background)?.abortRequested == false)
        }
        #expect(try await harness.signal(taskId: a.id, token: done, key: "done",
            value: ["text": "ay"], context: .background) == .delivered)
        let parent = try #require(records.first { $0.kind == "pi.tool" && $0.input["kind"] == "model" })
        #expect(try await harness.waitForTask(id: parent.id, context: .background).outcome.status == "completed")
    }
}
#endif
