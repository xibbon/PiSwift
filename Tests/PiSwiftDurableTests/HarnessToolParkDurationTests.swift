import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
import Synchronization
import Testing
@testable import PiSwiftDurable

private struct SignalParkRun: Equatable, Sendable {
    let wake: WakeReason?
    let checkpoint: JSONValue?
}

@Suite(.timeLimit(.minutes(1))) struct HarnessToolParkDurationTests {
    // v1.6.0 harness-tool-parks.test.ts:119–154.
    @Test func holdsNoInvocationShowsTheSlotSleepingWithoutOutputAndRunsAgainOnceWoken() async throws {
        let clock = TestClock(now: 1_000)
        let setup = HarnessChatSetup(clock: clock)
        let done = try parkDoneSignal(), runs = SessionTestLog<SignalParkRun>()
        try installHarnessTool(signalParkTool(done, runs: runs), setup: setup)
        let opened = try await openParkChat(setup, tool: "ci")
        let submission = try await generationSubmit(opened)
        let task = try await sleepingTool(opened)
        #expect(try JSONValue(encoding: task.state) == [
            "status": "sleeping",
            "checkpoint": ["phase": "parked", "arguments": [:], "replay": "unsafe", "checkpoint": ["build": 1]],
            "signals": [["signal": "test.park-done", "key": "done"]],
        ])
        let slot = try #require(try await generationLive(opened)?.tools?.first)
        #expect(slot.status == .sleeping && slot.output == nil)
        #expect(slot.details == ["build": 1])
        #expect(slot.diagnostics == [.init(severity: .info, message: "run 1")])
        #expect(opened.harness.wake() == .init(active: false))

        clock.advance(by: 25)
        #expect(try await opened.harness.signal(taskId: task.id, token: done, key: "done", value: ["text": "passed"], context: .background) == .delivered)
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(runs.values == [
            .init(wake: nil, checkpoint: nil),
            .init(wake: .signal(signal: done.name, key: "done"), checkpoint: ["build": 1]),
        ])
        let result = try #require(try harnessToolResults(await allEntries(opened.root)).first)
        #expect(!result.isError && harnessToolDetails(result) == ["build": 1])
        #expect(harnessToolText(result) == "passed|<harness>\n[info] run 1\n</harness>")
        #expect(result.durationMs == 25)
        try await opened.harness.close(context: .background)
    }

    // v1.6.0 harness-tool-parks.test.ts:156–181.
    @Test func parksOnTimeAndWakesWithReasonTime() async throws {
        let clock = TestClock(now: 1_000), wakes = Mutex<[WakeReason?]>([])
        let setup = HarnessChatSetup(clock: clock)
        let poll = try ToolRegistration(name: "poll", description: "Polls again after a time limit",
            parameters: ["type": "object", "properties": [:]], execute: { _, api, _ in
                wakes.withLock { $0.append(api.wake) }
                if api.wake == nil { return .park(.sleep(until: Double(try api.now() + 500))) }
                return .result(.init(output: []))
            })
        try installHarnessTool(poll, setup: setup)
        let opened = try await openParkChat(setup, tool: "poll")
        let submission = try await generationSubmit(opened)
        let parked = try await sleepingTool(opened)
        #expect(parked.startedAt == 1_000)
        #expect(opened.harness.wake() == .init(active: false, at: 1_500))

        clock.advance(by: 500)
        try opened.harness.resume()
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(wakes.withLock { $0 } == [nil, .time()])
        let result = try #require(try harnessToolResults(await allEntries(opened.root)).first)
        #expect(result.durationMs == 500 && result.timestamp == 1_500)
        try await opened.harness.close(context: .background)
    }

    // v1.6.0 harness-tool-parks.test.ts:183–200 and tool.ts:1174–1178.
    @Test func staysParkedAcrossReopenAndWakesOnALaterDelivery() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("tool-park-duration.sqlite").path
        let clock = TestClock(now: 1_000), runs = SessionTestLog<SignalParkRun>()
        let setup = HarnessChatSetup(clock: clock), done = try parkDoneSignal()
        try installHarnessTool(signalParkTool(done, runs: runs), setup: setup)
        let first = try await openParkChat(setup, tool: "ci", storage: SqliteStorage.open(path: path))
        let submission = try await generationSubmit(first)
        let parked = try await sleepingTool(first)
        clock.advance(by: 100)
        try await first.harness.close(context: .background)

        clock.advance(by: 700)
        let second = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        try second.harness.resume()
        #expect(try await sleepingTool(second).id == parked.id)
        #expect(runs.count == 1)
        clock.advance(by: 200)
        #expect(try await second.harness.signal(taskId: parked.id, token: done, key: "done", value: ["text": "later"], context: .background) == .delivered)
        let resumed = try #require(try await second.harness.submission(id: submission.id, context: .background))
        #expect(try await resumed.wait(context: .background).status == "done")
        #expect(runs.values == [
            .init(wake: nil, checkpoint: nil),
            .init(wake: .signal(signal: done.name, key: "done"), checkpoint: ["build": 1]),
        ])
        let result = try #require(try harnessToolResults(await allEntries(second.root)).first)
        #expect(result.durationMs == 1_000 && result.timestamp == 2_000)
        #expect(harnessToolText(result).hasPrefix("later"))
        try await second.harness.close(context: .background)
    }

    // v1.6.0 harness-tool-parks.test.ts:204–244.
    @Test func parksANestedCallWhileItsCallerAwaitsItAndReturnsItsResultOnceWoken() async throws {
        let clock = TestClock(now: 1_000), runs = SessionTestLog<SignalParkRun>()
        let setup = HarnessChatSetup(clock: clock), done = try parkDoneSignal()
        try installHarnessTool(signalParkTool(done, runs: runs), setup: setup)
        let outer = try ToolRegistration(name: "outer", description: "Waits for a nested tool",
            parameters: ["type": "object", "properties": [:]], replay: .safe, execute: { _, api, context in
                let result = try await api.executeTool("ci", arguments: [:], context: context, options: .init(key: "ci"))
                #expect(!result.isError && result.durationMs == 2_000)
                let live = try await api.snapshot(LiveDoc, conversationId: api.conversationId, context: context)
                let slot = try #require(live?.nestedTools?.first)
                #expect(slot.status == .done && slot.summary?.durationMs == 2_000)
                let text = try #require(result.structuredOutput?.stringValue)
                return .result(.init(output: [.text(.init(text: text))]))
            })
        try installHarnessTool(outer, setup: setup)
        let opened = try await openParkChat(setup, tool: "outer")
        let submission = try await generationSubmit(opened)
        try await eventually { try await generationLive(opened)?.nestedTools?.first?.status == .sleeping }
        let nested = try #require(try await generationLive(opened)?.nestedTools?.first)
        #expect(nested.output == nil)
        clock.advance(by: 2_000)
        #expect(try await opened.harness.signal(taskId: nested.taskId, token: done, key: "done", value: ["text": "nested passed"], context: .background) == .delivered)
        #expect(try await submission.wait(context: .background).status == "done")
        let result = try #require(try harnessToolResults(await allEntries(opened.root)).first)
        #expect(harnessToolText(result) == "nested passed")
        #expect(runs.count == 2)
        try await opened.harness.close(context: .background)
    }

    private func parkDoneSignal() throws -> SignalToken<JSONValue> {
        try defineSignal(name: "test.park-done", version: 1, schema: [
            "type": "object", "properties": ["text": ["type": "string"]], "required": ["text"],
        ])
    }

    private func signalParkTool(_ done: SignalToken<JSONValue>, runs: SessionTestLog<SignalParkRun>) throws -> ToolRegistration {
        let signal = try done.key("done")
        return try ToolRegistration(name: "ci", description: "Waits for the build result",
            parameters: ["type": "object", "properties": [:]], execute: { _, api, context in
                runs.append(.init(wake: api.wake, checkpoint: api.checkpoint))
                if case .value(let value) = try await api.readSignal(done, key: "done", context: context) {
                    return .result(.init(output: [.text(.init(text: value["text"]?.stringValue ?? ""))]))
                }
                let checkpoint: JSONValue = ["build": .number(Double(runs.count))]
                try await api.details(checkpoint, context)
                try api.output(.text("started\n"), nil)
                try api.diagnostic(.init(severity: .info, message: "run \(runs.count)"))
                return .park(.sleep(signals: [signal], checkpoint: checkpoint))
            })
    }

    private func openParkChat(_ setup: HarnessChatSetup, tool: String,
                              storage: any DurableStorage = MemoryStorage()) async throws -> OpenChatResult {
        setup.models.setResponses([.message(try toolCalls([(tool, [:], "c1")])), .message(chatAssistant("done"))])
        return try await openChat(storage: storage, setup: setup)
    }

    private func sleepingTool(_ opened: OpenChatResult) async throws -> TaskRecord {
        try await eventually {
            try await generationLive(opened)?.tools?.first?.status == .sleeping && !opened.harness.wake().active
        }
        let taskID = try #require(try await generationLive(opened)?.tools?.first?.taskId)
        return try #require(try await opened.harness.getTask(id: taskID, context: .background))
    }
}
