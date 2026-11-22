import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private struct GateApproval: Codable, Sendable { let allow: Bool }
private let gateDay: Int64 = 86_400_000
private let gateKey = "rm_-rf_build"

private final class GateCount: Sendable {
    private let number = Mutex(0)
    var value: Int { number.withLock { $0 } }
    @discardableResult func next() -> Int { number.withLock { $0 += 1; return $0 } }
}

@Suite("PiSwiftDurableTests.HarnessToolGates", .serialized, .timeLimit(.minutes(2)))
struct HarnessToolGateTests {
    private struct GateFixture: Decodable {
        let backend: String
        let path: String
        let step: String
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PISWIFT_D4_GATE_PLAN"] != nil))
    func crossLanguageGateFiles() async throws {
        let planPath = try #require(ProcessInfo.processInfo.environment["PISWIFT_D4_GATE_PLAN"])
        let plan = try JSONDecoder().decode([GateFixture].self,
            from: Data(contentsOf: URL(fileURLWithPath: planPath)))
        let token: SignalToken<GateApproval> = try defineSignal(name: "fixture.approval", version: 1,
            schema: ["type": "object", "properties": ["allow": ["type": "boolean"]],
                     "required": ["allow"], "additionalProperties": false])
        for item in plan {
            let storage: any DurableStorage
            switch item.backend {
            case "sqlite": storage = try await SqliteStorage.open(path: item.path)
            case "jsonl": storage = try await JsonlStorage.open(directory: item.path,
                fileSystem: LocalExecutionEnv(cwd: item.path))
            default: throw TaskDefinitionError("Unknown D4 gate backend \(item.backend)")
            }
            let runs = GateCount(), registry = createRegistry()
            try registry.install(Extension(name: "fixture.gate", tools: [tool(runs)],
                hooks: [hook(ToolHooks(beforeTool: { call, api, context in
                    let command = call.arguments["command"]?.value as? String ?? ""
                    let key = command.replacingOccurrences(of: " ", with: "_")
                    let state = try await api.readSignal(token, key: key, context: context)
                    switch state {
                    case nil: return .init(sleep: .init(signals: [try token.key(key)]))
                    case .expired: return .init(block: "Not approved")
                    case .value(let value): return value.allow ? nil : .init(block: "Not approved")
                    }
                }))]))
            let harness = try await Harness.open(storage: storage, options: .init(
                models: FakeDurableModels(), registry: registry, clock: TestClock(now: 1_000),
                onWake: { _ in }), context: .background)
            do {
                let tasks = try await storage.scanTasks(.init(kind: "pi.tool"), limit: 10,
                    cursor: nil, context: .background).items
                let id = try #require(tasks.first?.id)
                try harness.resume()
                switch item.step {
                case "park":
                    try await eventually {
                        try await harness.getTask(id: id, context: .background)?.state.status == "sleeping"
                            && !harness.wake().active
                    }
                    let record = try #require(try await harness.getTask(id: id, context: .background))
                    #expect(record.state.checkpoint?["phase"] == "call")
                    #expect(runs.value == 0)
                case "finish":
                    try await eventually { !harness.wake().active }
                    #expect(try await harness.signal(taskId: id, token: token, key: gateKey,
                        value: .init(allow: true), context: .background) == .delivered)
                    #expect(try await harness.waitForTask(id: id, context: .background).outcome.status == "completed")
                    #expect(runs.value == 1)
                default: throw TaskDefinitionError("Unknown D4 gate step \(item.step)")
                }
            } catch {
                try? await harness.close(context: .background)
                throw error
            }
            try await harness.close(context: .background)
        }
    }
    private func approval() throws -> SignalToken<GateApproval> {
        try defineSignal(name: "test.approval", version: 1,
            schema: ["type": "object", "properties": ["allow": ["type": "boolean"]],
                     "required": ["allow"]])
    }
    private func tool(_ runs: GateCount, parkInExecute: SignalKey? = nil) throws -> ToolRegistration {
        try ToolRegistration(name: "bash", description: "bash",
            parameters: ["type": "object", "properties": ["command": ["type": "string"]],
                         "required": ["command"]], replay: .safe, execute: { args, api, _ in
                runs.next()
                if let parkInExecute, api.wake == nil { return .park(.sleep(signals: [parkInExecute])) }
                return .result(.init(output: [.text(.init(text: "ran \(args["command"]?.stringValue ?? "")"))]))
            })
    }
    private func gate(_ approval: SignalToken<GateApproval>, _ passes: GateCount) -> ToolHooks {
        ToolHooks(beforeTool: { call, api, context in
            passes.next()
            let key = (call.arguments["command"]?.value as? String)?.replacingOccurrences(of: " ", with: "_") ?? ""
            let state = try await api.readSignal(approval, key: key, context: context)
            let until = try await api.memo("approvals.until.\(key)", .number(Double(try api.now() + gateDay)), context)
            switch state {
            case nil: return .init(sleep: .init(until: until?.numberValue, signals: [try approval.key(key)]))
            case .expired: return .init(block: "No approval within a day")
            case .value(let value): return value.allow ? nil : .init(block: "Not approved")
            }
        })
    }
    private func setup(_ runs: GateCount, passes: GateCount, clock: TestClock = TestClock(now: 1_000),
                       approval: SignalToken<GateApproval>, withGate: Bool = true,
                       parkInExecute: SignalKey? = nil) throws -> HarnessChatSetup {
        let setup = HarnessChatSetup(clock: clock)
        try setup.registry.install(Extension(name: "tool", tools: [tool(runs, parkInExecute: parkInExecute)]))
        if withGate { try setup.registry.install(Extension(name: "approvals", hooks: [hook(gate(approval, passes))])) }
        setup.models.setResponses([.message(try toolCalls([("bash", ["command": "rm -rf build"], "c1")])),
                                   .message(chatAssistant("done"))])
        return setup
    }
    private func open(_ setup: HarnessChatSetup, storage: any DurableStorage = MemoryStorage()) async throws -> OpenChatResult {
        let opened = try await openChat(storage: storage, setup: setup)
        try opened.harness.resume()
        return opened
    }
    private func parked(_ opened: OpenChatResult) async throws -> TaskID {
        try await eventually {
            guard let slot = try await generationLive(opened)?.tools?.first,
                  slot.status == .sleeping, let id = slot.taskId else { return false }
            return try await opened.harness.getTask(id: id, context: .background)?.state.status == "sleeping"
        }
        return try #require(try await generationLive(opened)?.tools?.first?.taskId)
    }
    private func result(_ opened: OpenChatResult) async throws -> ToolResultMessage {
        try #require(try harnessToolResults(await allEntries(opened.root)).first)
    }
    private func text(_ opened: OpenChatResult) async throws -> String { harnessToolText(try await result(opened)) }

    @Test func parksTheCallBeforeItRunsAndRunsOnceApproved() async throws {
        let approval = try approval(), runs = GateCount(), passes = GateCount()
        let opened = try await open(setup(runs, passes: passes, approval: approval))
        let submission = try await generationSubmit(opened, "go")
        let id = try await parked(opened)
        let task = try #require(try await opened.harness.getTask(id: id, context: .background))
        #expect(task.state.checkpoint?["phase"] == "call")
        #expect(runs.value == 0)
        #expect(try await opened.harness.signal(taskId: id, token: approval, key: gateKey,
            value: .init(allow: true), context: .background) == .delivered)
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(runs.value == 1)
        #expect(passes.value == 2)
        #expect(try await text(opened) == "ran rm -rf build")
        try await opened.harness.close(context: .background)
    }

    @Test(arguments: [false, true]) func blocksOnDenialAndDeadline(expired: Bool) async throws {
        let approval = try approval(), runs = GateCount(), passes = GateCount(), clock = TestClock(now: 1_000)
        let opened = try await open(setup(runs, passes: passes, clock: clock, approval: approval))
        let submission = try await generationSubmit(opened, "go")
        let id = try await parked(opened)
        if expired { clock.advance(by: gateDay); try opened.harness.resume() }
        else { #expect(try await opened.harness.signal(taskId: id, token: approval, key: gateKey,
            value: .init(allow: false), context: .background) == .delivered) }
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(runs.value == 0)
        #expect(try await text(opened) .contains(expired ? "No approval within a day" : "Not approved"))
        if expired { #expect(try await opened.harness.signal(taskId: id, token: approval, key: gateKey,
            value: .init(allow: true), context: .background) == .closed) }
        try await opened.harness.close(context: .background)
    }

    @Test func asksEveryGateAgainInOrderAndStopsAtFirstSleep() async throws {
        let approval = try approval(), runs = GateCount(), passes = GateCount(), quiet = GateCount()
        let setup = try setup(runs, passes: passes, approval: approval)
        try setup.registry.install(Extension(name: "quiet", hooks: [hook(ToolHooks(beforeTool: { _, _, _ in
            quiet.next(); return nil
        }))]))
        let opened = try await open(setup)
        let submission = try await generationSubmit(opened, "go")
        let id = try await parked(opened)
        #expect(passes.value == 1 && quiet.value == 0)
        _ = try await opened.harness.signal(taskId: id, token: approval, key: gateKey,
            value: .init(allow: true), context: .background)
        _ = try await submission.wait(context: .background)
        #expect(passes.value == 2 && quiet.value == 1 && runs.value == 1)
        try await opened.harness.close(context: .background)
    }

    @Test func emptyGateSleepFailsAsInvalidPark() async throws {
        let runs = GateCount(), setup = HarnessChatSetup(clock: TestClock(now: 1_000))
        try setup.registry.install(Extension(name: "tool", tools: [tool(runs)]))
        let codes = Mutex<[String]>([])
        try setup.registry.install(Extension(name: "bad", hooks: [hook(ToolHooks(
            beforeTool: { _, _, _ in .init(sleep: .init()) },
            afterTool: { _, result, _, _ in
                codes.withLock { $0 += (result.diagnostics ?? []).compactMap(\.code) }
                return nil
            }))]))
        setup.models.setResponses([.message(try toolCalls([("bash", ["command": "rm -rf build"], "c1")])),
                                   .message(chatAssistant("done"))])
        let opened = try await open(setup)
        let submission = try await generationSubmit(opened, "go")
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(runs.value == 0)
        #expect(try await text(opened).contains("cannot wait at its gates"))
        #expect(codes.withLock { $0 } == ["invalid_park"])
        let toolTask = try #require(try await opened.harness.session.storage.scanTasks(
            .init(kind: "pi.tool"), limit: 10, cursor: nil, context: .background).items.first)
        #expect(toolTask.state.outcome?.status == "completed")
        try await opened.harness.close(context: .background)
    }

    @Test func deadlineOnlyGateOmitsSignalsOnWire() async throws {
        let runs = GateCount(), passes = GateCount(), clock = TestClock(now: 1_000)
        let setup = HarnessChatSetup(clock: clock)
        try setup.registry.install(Extension(name: "tool", tools: [tool(runs)]))
        try setup.registry.install(Extension(name: "deadline", hooks: [hook(ToolHooks(beforeTool: { _, _, _ in
            passes.next() == 1 ? .init(sleep: .init(until: 2_000)) : nil
        }))]))
        setup.models.setResponses([.message(try toolCalls([("bash", ["command": "rm -rf build"], "c1")])),
                                   .message(chatAssistant("done"))])
        let opened = try await open(setup)
        let submission = try await generationSubmit(opened, "go")
        let id = try await parked(opened)
        let record = try #require(try await opened.harness.getTask(id: id, context: .background))
        let wire = try JSONValue(encoding: record.state)
        #expect(wire["signals"] == nil)
        #expect(wire["until"] == .number(2_000))
        clock.advance(by: 1_000)
        try opened.harness.resume()
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(passes.value == 2 && runs.value == 1)
        try await opened.harness.close(context: .background)
    }

    @Test func registryChangesWakeGatedCallAndRemovedGateLetsItRun() async throws {
        let approval = try approval(), runs = GateCount(), passes = GateCount()
        let setup = try setup(runs, passes: passes, approval: approval)
        let opened = try await open(setup)
        let submission = try await generationSubmit(opened, "go")
        _ = try await parked(opened)
        try setup.registry.install(Extension(name: "other"))
        try await eventually { passes.value == 2 }
        setup.registry.uninstall(name: "approvals")
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(passes.value == 2 && runs.value == 1)
        try await opened.harness.close(context: .background)
    }

    @Test func publicationDuringGateRunWakesItsCommittedSleep() async throws {
        let approval = try approval(), runs = GateCount(), passes = GateCount()
        let entered = HarnessChatSignal(), release = HarnessChatSignal()
        defer { release.signal() }
        let setup = try setup(runs, passes: GateCount(), approval: approval, withGate: false)
        try setup.registry.install(Extension(name: "slow", hooks: [hook(ToolHooks(beforeTool: { _, _, _ in
            let pass = passes.next()
            if pass == 1 { entered.signal(); await release.wait() }
            return pass < 3 ? .init(sleep: .init(signals: [try approval.key("k\(pass)" )])) : nil
        }))]))
        let opened = try await open(setup)
        let submission = try await generationSubmit(opened, "go")
        await entered.wait()
        try setup.registry.install(Extension(name: "other"))
        release.signal()
        let id = try await parked(opened)
        try await eventually { passes.value == 2 }
        #expect(try await opened.harness.signal(taskId: id, token: approval, key: "k2",
            value: .init(allow: true), context: .background) == .delivered)
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(passes.value == 3 && runs.value == 1)
        try await opened.harness.close(context: .background)
    }

    @Test func reopenWakesGateBeforeDeadlineAfterGateRemoval() async throws {
        let directory = try sqliteTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("gate.sqlite").path
        let approval = try approval(), runs = GateCount(), passes = GateCount(), clock = TestClock(now: 1_000)
        let firstSetup = try setup(runs, passes: passes, clock: clock, approval: approval)
        let first = try await open(firstSetup, storage: SqliteStorage.open(path: path))
        let submission = try await generationSubmit(first, "go")
        _ = try await parked(first)
        let submissionID = submission.id
        try await first.harness.close(context: .background)
        let secondSetup = try setup(runs, passes: passes, clock: clock, approval: approval, withGate: false)
        secondSetup.models.setResponses([.message(chatAssistant("done"))])
        let second = try await open(secondSetup, storage: SqliteStorage.open(path: path))
        let resumed = try #require(try await second.harness.submission(id: submissionID, context: .background))
        #expect(try await resumed.wait(context: .background).status == "done")
        #expect(passes.value == 1 && runs.value == 1)
        try await second.harness.close(context: .background)
    }

    @Test func registryChangeLeavesExecuteParkAlone() async throws {
        let directory = try sqliteTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("execute.sqlite").path
        let approval = try approval(), runs = GateCount(), passes = GateCount()
        let setup = try setup(runs, passes: passes, approval: approval, withGate: false,
            parkInExecute: approval.key("done"))
        let first = try await open(setup, storage: SqliteStorage.open(path: path))
        _ = try await generationSubmit(first, "go")
        let id = try await parked(first)
        try setup.registry.install(Extension(name: "other"))
        try await first.harness.close(context: .background)
        let second = try await open(setup, storage: SqliteStorage.open(path: path))
        try await eventually { !second.harness.wake().active }
        #expect(try await second.harness.getTask(id: id, context: .background)?.state.checkpoint?["phase"] == "parked")
        #expect(runs.value == 1)
        try await second.harness.close(context: .background)
    }

    @Test func reopeningAfterDeadlineExpiresGateKey() async throws {
        let directory = try sqliteTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("expired.sqlite").path
        let approval = try approval(), runs = GateCount(), passes = GateCount(), clock = TestClock(now: 1_000)
        let setup = try setup(runs, passes: passes, clock: clock, approval: approval)
        let first = try await open(setup, storage: SqliteStorage.open(path: path))
        let submission = try await generationSubmit(first, "go")
        let id = try await parked(first)
        let submissionID = submission.id
        try await first.harness.close(context: .background)
        clock.advance(by: 2 * gateDay)
        setup.models.setResponses([.message(chatAssistant("done"))])
        let second = try await open(setup, storage: SqliteStorage.open(path: path))
        let resumed = try #require(try await second.harness.submission(id: submissionID, context: .background))
        #expect(try await resumed.wait(context: .background).status == "done")
        #expect(passes.value == 2 && runs.value == 0)
        #expect(try await text(second).contains("No approval within a day"))
        #expect(try await second.harness.signal(taskId: id, token: approval, key: gateKey,
            value: .init(allow: true), context: .background) == .closed)
        try await second.harness.close(context: .background)
    }
}
