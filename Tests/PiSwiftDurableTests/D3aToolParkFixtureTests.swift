import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
import Testing
@testable import PiSwiftDurable

#if os(macOS)
@Suite("PiSwiftDurableTests.D3aToolParkFixtures", .serialized)
struct D3aToolParkFixtureTests {
    private struct Fixture: Decodable {
        enum Backend: String, Decodable { case sqlite, jsonl }
        enum Scenario: String, Decodable { case signal, any, cancel, duration }
        enum Step: String, Decodable { case park, finish }

        let backend: Backend
        let scenario: Scenario
        let path: String
        let step: Step

        var parkStatus: String { scenario == .any ? "waiting" : "sleeping" }
        var finishTime: Int64 { scenario == .duration ? 3_500 : 1_000 }
    }

    private struct Run: Sendable, Equatable {
        let wake: WakeReason?
        let checkpoint: JSONValue?
    }

    private struct ChildCheckpoint: TaskCheckpoint {
        enum Phase: String, Codable, Sendable { case sleep, finish }
        let phase: Phase
    }

    private typealias Child = TaskDefinition<JSONValue, ChildCheckpoint, String, NoTaskHooks>
    private static let key = "ready"
    private static let checkpoint: JSONValue = ["cursor": 2]
    private static let payload: JSONValue = ["text": "ready"]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PISWIFT_D3A_PARK_PLAN"] != nil),
          .timeLimit(.minutes(2)))
    func crossLanguageToolParkFiles() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["PISWIFT_D3A_PARK_PLAN"])
        let plan = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let answer: SignalToken<JSONValue> = try defineSignal(name: "fixture.park-ready", version: 1, schema: [
            "type": "object", "properties": ["text": ["type": "string"]],
            "required": ["text"], "additionalProperties": false,
        ])
        let child = makeChild(answer)
        for item in plan {
            try await run(item, answer: answer, child: child)
        }
    }

    private func makeChild(_ signal: SignalToken<JSONValue>) -> Child {
        Child(name: "fixture.park-child", version: 1, initial: { _ in .init(phase: .sleep) },
            phase: { task, runtime, context in
                switch task.checkpoint.phase {
                case .sleep:
                    try await runtime.sleep(signals: [signal.key(Self.key)],
                        checkpoint: JSONValue(encoding: ChildCheckpoint(phase: .finish)), context: context)
                case .finish:
                    try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: "child")) }, context: context)
                }
            }, abort: { _, runtime, context in
                try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "fixture")) }, context: context)
            })
    }

    private func registry(for item: Fixture, answer: SignalToken<JSONValue>, child: Child,
                          runs: SessionTestLog<Run>, cancels: SessionTestLog<Run>) throws -> Registry {
        let registry = createRegistry()
        let name = "fixture.park"
        let tool = try ToolRegistration(name: name, description: name,
            parameters: ["type": "object", "properties": [:], "additionalProperties": false], replay: .safe,
            cancel: { _, api, _ in cancels.append(Run(wake: api.wake, checkpoint: api.checkpoint)) },
            execute: { _, api, context -> ToolExecutionOutcome in
                runs.append(Run(wake: api.wake, checkpoint: api.checkpoint))
                guard let wake = api.wake else {
                    if item.scenario == .cancel { try await api.details(["stage": "parked"], context) }
                    if item.scenario == .any {
                        let options = TaskOptions(ownership: .task(taskId: api.taskId))
                        let first = try await api.createTask(child, input: .null, options: options, context: context)
                        let second = try await api.createTask(child, input: .null, options: options, context: context)
                        let on = [first, second]
                        return .park(.wait(on: on, policy: .any, checkpoint: ["on": try JSONValue(encoding: on)]))
                    }
                    return .park(.sleep(signals: [try answer.key(Self.key)], checkpoint: Self.checkpoint))
                }
                let checkpoint = try #require(api.checkpoint)
                let text: String
                if item.scenario == .any {
                    let on = try #require(checkpoint["on"]).decode([TaskID].self)
                    try #require(on.count == 2)
                    #expect(wake == .tasks(ended: [on[1]]))
                    let other = try #require(try await api.getTask(id: on[0], context: context))
                    #expect(other.state.status == "sleeping")
                    #expect(other.abortRequested == false)
                    text = "joined"
                } else {
                    #expect(wake == .signal(signal: answer.name, key: Self.key))
                    #expect(checkpoint == Self.checkpoint)
                    if case .value(let payload)? = try await api.readSignal(answer, key: Self.key, context: context) {
                        #expect(payload == Self.payload)
                        text = try #require(payload["text"]?.stringValue)
                    } else {
                        throw TaskDefinitionError("The tool did not read the signal that woke it")
                    }
                }
                let details: JSONValue = ["checkpoint": checkpoint, "wake": try JSONValue(encoding: wake)]
                return .result(.init(output: [.text(.init(text: text))], details: details))
            })
        try registry.install(Extension(name: "fixture.tool-parks", tools: [tool], tasks: [child.eraseToAnyTaskDefinition()]))
        return registry
    }

    private func run(_ item: Fixture, answer: SignalToken<JSONValue>, child: Child) async throws {
        let storage: any DurableStorage
        switch item.backend {
        case .sqlite: storage = try await SqliteStorage.open(path: item.path)
        case .jsonl: storage = try await JsonlStorage.open(directory: item.path, fileSystem: LocalExecutionEnv(cwd: item.path))
        }
        let clock = TestClock(now: item.step == .park ? 1_000 : item.finishTime)
        let runs = SessionTestLog<Run>()
        let cancels = SessionTestLog<Run>()
        let reports = SessionTestLog<String>()
        let registry = try registry(for: item, answer: answer, child: child, runs: runs, cancels: cancels)
        let harness = try await Harness.open(storage: storage, options: .init(models: FakeDurableModels(),
            registry: registry, clock: clock, onWake: { _ in }, onReport: { (report: Report) in
                reports.append(String(describing: report.error))
            }), context: .background)
        do {
            let page = try await storage.scanTasks(.init(kind: "pi.tool"), limit: 10, cursor: nil, context: .background)
            try #require(page.items.count == 1)
            let record = try #require(page.items.first)
            if item.step == .park {
                try harness.resume()
                try await harnessEventually {
                    try await harness.getTask(id: record.id, context: .background)?.state.status == item.parkStatus
                        && !harness.wake().active
                }
                let live = try #require(try await harness.snapshot(LiveDoc, conversationId: record.conversationId, context: .background))
                let slot = try #require(live.tools?.first)
                #expect(slot.status.rawValue == item.parkStatus)
                #expect(slot.output == nil)
                #expect(runs.values == [Run(wake: nil, checkpoint: nil)])
            } else {
                try await finish(item, signal: answer, record: record, storage: storage, harness: harness)
                if item.scenario == .cancel {
                    #expect(runs.values.isEmpty)
                    #expect(cancels.values == [Run(wake: nil, checkpoint: Self.checkpoint)])
                } else {
                    #expect(runs.count == 1)
                    #expect(cancels.values.isEmpty)
                }
            }
        } catch {
            try? await harness.close(context: .background)
            throw error
        }
        try await harness.close(context: .background)
        #expect(reports.values.isEmpty)
    }

    private func finish(_ item: Fixture, signal: SignalToken<JSONValue>, record: TaskRecord,
                        storage: any DurableStorage, harness: Harness) async throws {
        #expect(record.state.status == item.parkStatus)
        try harness.resume()
        try await harnessEventually { !harness.wake().active }
        switch item.scenario {
        case .cancel:
            #expect(try await harness.abortTask(id: record.id, context: .background) == .marked)
        case .any:
            guard case .waiting(_, let on, .any, _) = record.state else {
                throw TaskDefinitionError("Expected the tool to wait for its first terminal child")
            }
            try #require(on.count == 2)
            try await deliver(signal, to: on[1], in: harness)
            try await harnessEventually {
                try await harness.getTask(id: record.id, context: .background)?.state.status == "completing"
            }
            try await deliver(signal, to: on[0], in: harness)
        case .signal, .duration:
            try await deliver(signal, to: record.id, in: harness)
        }

        let receipt = try await harness.waitForTask(id: record.id, context: .background)
        let result: JSONValue
        switch (item.scenario, receipt.outcome) {
        case (.cancel, .aborted(_, let value?, _)), (_, .completed(let value, _)):
            result = value
        default: throw TaskDefinitionError("Unexpected tool outcome \(receipt.outcome)")
        }
        #expect(receipt.outcome.status == (item.scenario == .cancel ? "aborted" : "completed"))
        guard case .model(let entryId, _) = try result.decode(ToolTaskResult.self) else {
            throw TaskDefinitionError("Expected a transcript result")
        }
        let entry = try #require(try await storage.entry(entryId, context: .background))
        guard case .toolResult(let message)? = try entry.entry.messages()?.first else {
            throw TaskDefinitionError("Expected a tool result message")
        }
        #expect(message.durationMs == Int(item.finishTime - 1_000))
        if item.scenario == .cancel { #expect(harnessToolDetails(message) == ["stage": "parked"]) }
    }

    private func deliver(_ signal: SignalToken<JSONValue>, to id: TaskID, in harness: Harness) async throws {
        #expect(try await harness.signal(taskId: id, token: signal, key: Self.key, value: Self.payload,
            context: .background) == .delivered)
    }
}
#endif
