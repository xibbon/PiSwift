import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

#if os(macOS)
@Suite("PiSwiftDurableTests.D2SignalFixtures", .serialized)
struct D2SignalFixtureTests {
    private struct Plan: Decodable {
        let cases: [Fixture]
    }

    private struct Fixture: Decodable {
        enum Backend: String, Decodable { case sqlite, jsonl }
        enum Scenario: String, Decodable {
            case parkedTag = "parked-tag"
            case earlyTag = "early-tag"
            case parkedSwift = "parked-swift"
            case expiry
        }
        enum Step: String, Decodable { case seed, finish }

        let backend: Backend
        let scenario: Scenario
        let path: String
        let step: Step
    }

    private struct Input: Codable, Sendable {
        var until: Double?
    }

    private struct Checkpoint: TaskCheckpoint {
        enum Phase: String, Codable, Sendable { case ask, answered }
        var phase: Phase
    }

    private struct Result: Codable, Sendable {
        let wake: WakeReason
        let signal: JSONValue
    }

    private static let key = "answer"
    private static let payload: JSONValue = ["text": "yes"]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PISWIFT_D2_SIGNAL_PLAN"] != nil),
          .timeLimit(.minutes(2)))
    func crossLanguageSignalFiles() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["PISWIFT_D2_SIGNAL_PLAN"])
        let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let answer: SignalToken<JSONValue> = try defineSignal(name: "fixture.answer", version: 1, schema: [
            "type": "object",
            "properties": ["text": ["type": "string"]],
            "required": ["text"],
            "additionalProperties": false,
        ])
        let task = makeTask(answer)
        for item in plan.cases {
            try await run(item, answer: answer, task: task)
        }
    }

    private typealias Ask = TaskDefinition<Input, Checkpoint, Result, NoTaskHooks>

    private func makeTask(_ answer: SignalToken<JSONValue>) -> Ask {
        Ask(name: "fixture.ask", version: 1, initial: { _ in Checkpoint(phase: .ask) },
            phase: { task, runtime, context in
                switch task.checkpoint.phase {
                case .ask:
                    try await runtime.sleep(signals: [answer.key(Self.key)], until: task.input.until,
                        checkpoint: JSONValue(encoding: Checkpoint(phase: .answered)), context: context)
                case .answered:
                    let wake = try #require(try task.record.state.wakeReason())
                    let state = try #require(try await runtime.readSignal(answer, key: Self.key, context: context))
                    let signal: JSONValue
                    let memo: JSONValue
                    switch state {
                    case .value(let value):
                        signal = ["value": value]
                        memo = ["version": 1, "consumed": true, "value": value]
                    case .expired:
                        signal = ["expired": true]
                        memo = signal
                    }
                    #expect(task.record.memos == ["pi.signal.fixture.answer/answer": memo])
                    let result = try JSONValue(encoding: Result(wake: wake, signal: signal))
                    try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: result)) },
                        context: context)
                }
            }, abort: { _, runtime, context in
                try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "fixture")) },
                    context: context)
            })
    }

    private func run(_ item: Fixture, answer: SignalToken<JSONValue>, task: Ask) async throws {
        let storage: any DurableStorage
        switch item.backend {
        case .sqlite:
            storage = try await SqliteStorage.open(path: item.path)
        case .jsonl:
            storage = try await JsonlStorage.open(directory: item.path, fileSystem: LocalExecutionEnv(cwd: item.path))
        }
        let clock = TestClock(now: 1_000)
        let registry = createRegistry()
        try registry.install(Extension(name: "fixture.signals", tasks: [task.eraseToAnyTaskDefinition()]))
        let reports = SessionTestLog<String>()
        let harness = try await Harness.open(storage: storage, options: .init(models: FakeDurableModels(),
            registry: registry, clock: clock, onWake: { _ in }, onReport: { (report: Report) in
                reports.append(String(describing: report.error))
            }), context: .background)
        do {
            switch item.step {
            case .seed:
                let root = try await harness.root(context: .background)
                let id = try await root.commit({ tx in
                    try await tx.createTask(task, input: Input(until: nil), options: .init(ownership: .conversation()))
                }, context: .background)
                try harness.resume()
                try await harnessEventually {
                    try await harness.getTask(id: id, context: .background)?.state.status == "sleeping"
                        && !harness.wake().active
                }
            case .finish:
                let tasks = try await storage.scanTasks(.init(kind: task.name), limit: 10, cursor: nil, context: .background)
                try #require(tasks.items.count == 1)
                let record = try #require(tasks.items.first)
                try await finish(item, record: record, answer: answer, harness: harness, clock: clock)
            }
        } catch {
            try? await harness.close(context: .background)
            throw error
        }
        try await harness.close(context: .background)
        #expect(reports.values.isEmpty)
    }

    private func finish(_ item: Fixture, record: TaskRecord, answer: SignalToken<JSONValue>,
                        harness: Harness, clock: TestClock) async throws {
        let result: Result
        switch item.scenario {
        case .expiry:
            #expect(record.state.status == "sleeping")
            clock.advance(by: 1_000)
            let delivery = try await harness.commit({ tx in
                try await tx.signal(record.id, token: answer, key: Self.key, value: Self.payload)
            }, context: .background)
            #expect(delivery == .closed)
            result = Result(wake: .expired(), signal: ["expired": true])
        case .parkedTag, .parkedSwift, .earlyTag:
            if item.scenario == .earlyTag {
                #expect(record.state.status == "pending")
                #expect(record.memos == ["pi.signal.fixture.answer/answer": ["version": 1, "value": Self.payload]])
            } else {
                #expect(record.state.status == "sleeping")
                #expect(try await harness.signal(taskId: record.id, token: answer, key: Self.key, value: Self.payload,
                    context: .background) == .delivered)
            }
            result = Result(wake: .signal(signal: answer.name, key: Self.key), signal: ["value": Self.payload])
        }
        let settled = try await harness.waitForTask(id: record.id, context: .background)
        #expect(settled.outcome == .completed(result: try JSONValue(encoding: result)))
    }
}
#endif
