import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
import Testing
@testable import PiSwiftDurable

private struct ExampleCIResult: Codable, Sendable {
    enum Status: String, Codable, Sendable { case passed, failed }
    let status: Status
    let logUrl: String
}

private actor ExampleCI {
    struct Build: Equatable, Sendable {
        let id: String
        let ref: String
        var cancelled = false
    }

    private var builds: [String: Build] = [:]
    private var webhooks: [String: TaskID] = [:]
    private(set) var triggerKeys: [String] = []

    var orderedBuilds: [Build] { builds.values.sorted { $0.id < $1.id } }

    func expectWebhook(_ key: String, taskId: TaskID) {
        webhooks[key] = taskId
    }

    func trigger(ref: String, key: String) throws -> Build {
        _ = try #require(webhooks[key])
        triggerKeys.append(key)
        if let build = builds[key] { return build }
        let build = Build(id: "build-\(builds.count + 1)", ref: ref)
        builds[key] = build
        return build
    }

    func deliver(_ payload: ExampleCIResult, for key: String, token: SignalToken<ExampleCIResult>,
                 harness: Harness) async throws -> SignalResult {
        let task = try #require(webhooks[key])
        return try await harness.signal(taskId: task, token: token, key: "done", value: payload, context: .background)
    }

    func cancel(buildId: String) {
        if let key = builds.first(where: { $0.value.id == buildId })?.key { cancel(key: key) }
    }

    func cancel(key: String) { builds[key]?.cancelled = true }
}

private struct ExampleCIArguments: Decodable, Sendable { let ref: String }
private struct ExampleJobArguments: Decodable, Sendable { let name: String }

private actor ExampleJobService {
    struct Check: Equatable, Sendable {
        let id: String
        let at: Int64
        let poll: Int
        let wake: WakeReason?
    }

    private(set) var started: [String: String] = [:]
    private(set) var checks: [Check] = []
    private(set) var startCalls = 0

    func start(_ name: String, key: String) -> String {
        #expect(name == "nightly")
        startCalls += 1
        if let id = started[key] { return id }
        let id = "job-\(started.count + 7)"
        started[key] = id
        return id
    }

    func isDone(_ check: Check) -> Bool {
        checks.append(check)
        return checks.count >= 4
    }
}

@Suite(.timeLimit(.minutes(1))) struct UpstreamToolParkExamplesTests {
    // v1.6.0 test/examples/40-tool-waits-for-webhook.ts.
    @Test func example40ToolWaitsForWebhook() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ci.sqlite").path
        let clock = TestClock(now: 1_000), ci = ExampleCI()
        let triggered = HarnessChatSignal(), releaseResult = HarnessChatSignal()
        let setup = HarnessChatSetup(clock: clock)
        let signal: SignalToken<ExampleCIResult> = try defineSignal(name: "example.ci-result", version: 1, schema: [
            "type": "object", "required": ["status", "logUrl"],
            "properties": ["status": ["enum": ["passed", "failed"]], "logUrl": ["type": "string"]],
        ])
        let twoHours: Int64 = 2 * 60 * 60 * 1_000
        let tool = try defineTool(name: "run_ci", description: "Run CI on a git ref and report the result",
            parameters: ["type": "object", "properties": ["ref": ["type": "string"]], "required": ["ref"]],
            args: ExampleCIArguments.self, replay: .safe, cancel: { _, api, context in
                #expect(api.wake == nil)
                if let id = api.checkpoint?["buildId"]?.stringValue {
                    await ci.cancel(buildId: id)
                } else {
                    let key = try #require(try await api.memo("ci.run", nil, context)?.stringValue)
                    await ci.cancel(key: key)
                }
            }, execute: { args, api, context in
                switch try await api.readSignal(signal, key: "done", context: context) {
                case .value(let result):
                    #expect(api.wake == .signal(signal: signal.name, key: "done"))
                    await releaseResult.wait()
                    let text = "CI \(result.status.rawValue): \(result.logUrl)"
                    return .result(.init(output: [.text(.init(text: text))], isError: result.status != .passed))
                case .expired:
                    let id = try #require(api.checkpoint?["buildId"]?.stringValue)
                    return .result(.init(output: [.text(.init(text: "CI build \(id) never reported"))], isError: true))
                case nil:
                    break
                }
                let key = try #require(try await api.memo("ci.run", .string(UUID().uuidString), context)?.stringValue)
                await ci.expectWebhook(key, taskId: api.taskId)
                let build = try await ci.trigger(ref: args.ref, key: key)
                let checkpoint: JSONValue = ["buildId": .string(build.id)]
                try await api.details(checkpoint, context)
                if !triggered.isSignalled {
                    triggered.signal()
                    try await harnessToolAwaitAbort(context)
                }
                return .park(.sleep(until: Double(try api.now() + twoHours), signals: [try signal.key("done")], checkpoint: checkpoint))
            })
        try installHarnessTool(tool, setup: setup)
        setup.models.setResponses([
            .message(try toolCalls([("run_ci", ["ref": "main"], "main")])),
            .message(chatAssistant("CI is green.")),
            .message(try toolCalls([("run_ci", ["ref": "feature"], "feature")])),
        ])

        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        let submission = try await generationSubmit(first, "Run CI on main")
        try await eventually { triggered.isSignalled }
        #expect(await ci.orderedBuilds == [.init(id: "build-1", ref: "main")])
        first.harness.session.fail(TaskDefinitionError("Example process stopped after triggering CI"))
        _ = await first.harness.closed

        clock.advance(by: 250)
        let opened = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        try opened.harness.resume()
        try await waitForPark(opened, at: 1_250 + twoHours)
        let replayed = await ci.triggerKeys
        let key = try #require(replayed.first)
        #expect(replayed == [key, key])
        #expect(await ci.orderedBuilds == [.init(id: "build-1", ref: "main")])
        let slot = try #require(try await generationLive(opened)?.tools?.first)
        #expect(slot.details == ["buildId": "build-1"] && slot.output == nil)

        clock.advance(by: 100)
        let payload = ExampleCIResult(status: .passed, logUrl: "https://ci/1")
        #expect(try await ci.deliver(payload, for: key, token: signal, harness: opened.harness) == .delivered)
        #expect(try await ci.deliver(payload, for: key, token: signal, harness: opened.harness) == .duplicate)
        releaseResult.signal()
        let resumed = try #require(try await opened.harness.submission(id: submission.id, context: .background))
        #expect(try await resumed.wait(context: .background).status == "done")
        let main = try #require(try harnessToolResults(await allEntries(opened.root)).first)
        #expect(harnessToolText(main) == "CI passed: https://ci/1" && !main.isError && main.durationMs == 350)

        let feature = try await generationSubmit(opened, "Run CI on feature")
        try await waitForPark(opened, at: 1_350 + twoHours)
        let featureTask = try #require(try await generationLive(opened)?.tools?.first?.taskId)
        try await opened.root.abort(context: .background)
        #expect(try await feature.wait(context: .background).status == "unanswered")
        #expect(try await opened.harness.waitForTask(id: featureTask, context: .background).outcome.status == "aborted")
        #expect(await ci.orderedBuilds == [.init(id: "build-1", ref: "main"), .init(id: "build-2", ref: "feature", cancelled: true)])
        let aborted = try #require(try harnessToolResults(await allEntries(opened.root)).last)
        #expect(aborted.toolCallId == "feature" && aborted.isError)
        #expect(harnessToolText(aborted) == "<harness>\n[error] Tool run_ci was aborted\n</harness>")
        try await opened.harness.close(context: .background)
    }

    // v1.6.0 test/examples/41-tool-polls.ts.
    @Test func example41ToolPolls() async throws {
        let clock = TestClock(), jobs = ExampleJobService(), wakes = SessionTestLog<HarnessWake>()
        let setup = HarnessChatSetup(clock: clock)
        let tool = try defineTool(name: "wait_for_job", description: "Start a job and wait until it is done",
            parameters: ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]],
            args: ExampleJobArguments.self, replay: .safe, execute: { args, api, context in
                let id: String
                if let saved = api.checkpoint?["id"]?.stringValue {
                    id = saved
                } else {
                    let key = try #require(try await api.memo("job.key", .string(UUID().uuidString), context)?.stringValue)
                    id = await jobs.start(args.name, key: key)
                }
                let poll = Int(api.checkpoint?["polls"]?.numberValue ?? 0) + 1
                let now = try api.now()
                if await jobs.isDone(.init(id: id, at: now, poll: poll, wake: api.wake)) {
                    return .result(.init(output: [.text(.init(text: "\(id) done after \(poll) polls"))]))
                }
                let delay = min((api.checkpoint?["delayMs"]?.numberValue ?? 500) * 2, 60_000)
                return .park(.sleep(until: Double(now) + delay,
                    checkpoint: ["id": .string(id), "polls": .number(Double(poll)), "delayMs": .number(delay)]))
            })
        try installHarnessTool(tool, setup: setup)
        setup.models.setResponses([
            .message(try toolCalls([("wait_for_job", ["name": "nightly"], "poll")])),
            .message(chatAssistant("The nightly job is done.")),
        ])
        let harness = try await Harness.open(storage: MemoryStorage(), options: .init(
            models: setup.models, registry: setup.registry, clock: clock,
            setTimer: { _, _, _ in {} }, onWake: { wakes.append($0) }), context: .background)
        let root = try await harness.root(options: .init(agent: .init(model: .set(.init(provider: "faux", modelId: "faux-1")))), context: .background)
        let opened = OpenChatResult(harness: harness, root: root)
        let submission = try await generationSubmit(opened, "Run the nightly job")

        let deadlines: [Int64] = [1_000, 3_000, 7_000]
        for deadline in deadlines {
            try await waitForPark(opened, at: deadline)
            let wake = HarnessWake(active: false, at: Double(deadline))
            try await eventually { wakes.values.contains(wake) }
            clock.advance(by: deadline - clock.now())
            try harness.resume()
        }
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(await jobs.started.count == 1)
        #expect(await jobs.startCalls == 1)
        #expect(await jobs.checks == [
            .init(id: "job-7", at: 0, poll: 1, wake: nil),
            .init(id: "job-7", at: 1_000, poll: 2, wake: .time()),
            .init(id: "job-7", at: 3_000, poll: 3, wake: .time()),
            .init(id: "job-7", at: 7_000, poll: 4, wake: .time()),
        ])
        let result = try #require(try harnessToolResults(await allEntries(root)).first)
        #expect(!result.isError && harnessToolText(result) == "job-7 done after 4 polls" && result.durationMs == 7_000)
        try await harness.close(context: .background)
    }

    private func waitForPark(_ opened: OpenChatResult, at deadline: Int64) async throws {
        try await eventually {
            try await generationLive(opened)?.tools?.first?.status == .sleeping &&
                opened.harness.wake() == .init(active: false, at: Double(deadline))
        }
    }
}
