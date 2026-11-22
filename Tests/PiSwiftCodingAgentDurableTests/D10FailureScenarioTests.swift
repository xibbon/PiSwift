import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentDurable
import PiSwiftDurable
import PiSwiftDurableTesting
import Testing

private struct D10FailureDirectory: Sendable {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("d10-failure-" + UUID().uuidString)
    var cwd: String { base.appendingPathComponent("project").path }
    var agent: String { base.appendingPathComponent("agent").path }
    init() throws {
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: agent, withIntermediateDirectories: true)
        try Data("{\"retry\":{\"enabled\":false},\"compaction\":{\"enabled\":false}}".utf8)
            .write(to: URL(fileURLWithPath: agent).appendingPathComponent("settings.json"))
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
    func open(_ models: FakeDurableModels, clock: TestClock, model: ModelRef? = .init(provider: "faux", modelId: "faux-1"),
              continuing: Bool = false, registry: (any RegistryReader)? = nil) async throws -> OpenDurableResult {
        try await openDurable(.init(cwd: cwd, continueSession: continuing, transcriptMode: .paged), dependencies: .init(
            agentDirectory: agent, makeModels: { _ in
                .init(models: models, available: models.models, initial: { _ in .init(model: model) })
            }, clock: clock, registry: registry))
    }
}

@Suite(.timeLimit(.minutes(1))) struct D10FailureScenarioTests {
    @Test func modelErrorCanContinueAndTheAnswerClearsTheEnding() async throws {
        let directory = try D10FailureDirectory()
        defer { directory.remove() }
        let clock = TestClock(now: 100)
        let models = FakeDurableModels(responses: [
            .message(chatAssistant("", reason: .error, error: "Invalid API key")),
            .message(chatAssistant("Recovered answer"))
        ])
        let opened = try await directory.open(models, clock: clock)
        await opened.hostController.submit("Answer this", whenBusy: .steer)
        try await eventually { opened.hostView.hostCurrent().ending?.reason == .modelError }
        let failed = opened.hostView.hostCurrent()
        let ending = try #require(failed.ending)
        #expect(ending.detail?.contains("Invalid API key") == true)
        #expect(!ending.inputs.isEmpty)
        #expect(failed.live.run == nil)
        try await opened.continueRun()
        try await eventually {
            let view = opened.hostView.hostCurrent()
            return view.live.run == nil && view.rows.contains { row in
                guard case .entry(let entry) = row.item, entry.kind == "pi.assistant" else { return false }
                return (try? entry.messages()?.compactMap { textOf($0) }.joined()) == "Recovered answer"
            }
        }
        #expect(opened.hostView.hostCurrent().ending == nil)
        #expect(models.state().callCount == 2)
        await opened.close()
    }

    @Test func emptyContinueHasNoProviderCallAndSurvivesReopen() async throws {
        let directory = try D10FailureDirectory()
        defer { directory.remove() }
        let clock = TestClock(now: 100)
        let models = FakeDurableModels()
        let opened = try await directory.open(models, clock: clock)
        try await opened.continueRun()
        try await eventually { opened.hostView.hostCurrent().ending?.reason == .nothingToAnswer }
        let ending = try #require(opened.hostView.hostCurrent().ending)
        #expect(ending.first == nil)
        #expect(models.state().callCount == 0)
        await opened.close()
        let reopened = try await directory.open(models, clock: clock, continuing: true)
        #expect(reopened.hostView.hostCurrent().ending == ending)
        #expect(models.state().callCount == 0)
        await reopened.close()
    }

    @Test func unavailableModelNamesTheFailureWithoutCallingTheProvider() async throws {
        let directory = try D10FailureDirectory()
        defer { directory.remove() }
        let models = FakeDurableModels()
        let opened = try await directory.open(models, clock: TestClock(now: 100),
            model: .init(provider: "faux", modelId: "missing-model"))
        await opened.hostController.submit("Answer this", whenBusy: .steer)
        try await eventually { opened.hostView.hostCurrent().ending?.reason == .noModel }
        let view = opened.hostView.hostCurrent()
        #expect(view.ending?.detail?.contains("missing-model") == true)
        #expect(view.live.run == nil)
        #expect(models.state().callCount == 0)
        await opened.close()
    }

    @Test func abortKeepsTheFinalRunIdentityAndNoParkedNotice() async throws {
        let directory = try D10FailureDirectory()
        defer { directory.remove() }
        let unanswered = HarnessUnanswered()
        let models = FakeDurableModels(responses: [unanswered.step])
        let opened = try await directory.open(models, clock: TestClock(now: 100))
        await opened.hostController.submit("Wait", whenBusy: .steer)
        try await eventually { unanswered.reached.isSignalled && opened.hostView.hostCurrent().live.run != nil }
        let task = try #require(opened.hostView.hostCurrent().live.run?.taskId)
        await opened.hostController.abort()
        try await eventually { opened.hostView.hostCurrent().ending?.reason == .aborted }
        let view = opened.hostView.hostCurrent()
        #expect(view.ending?.taskId == task)
        #expect(view.live.run == nil)
        #expect(!view.notices.contains { $0.message.lowercased().contains("parked") })
        await opened.close()
    }

    @Test func handoffShowsResetContextAndKeepsTheRunTurnCount() async throws {
        let directory = try D10FailureDirectory()
        defer { directory.remove() }
        let registry = createRegistry()
        let tool = try ToolRegistration(name: "handoff", description: "Hand off context", parameters: [:]) { _, _, _ in
            ToolExecutionResult(output: [], control: .init(handoff: "Continue from this context"))
        }
        try registry.install(Extension(name: "handoff-test", tools: [tool]))
        var call = chatAssistant("", reason: .toolUse)
        call.content = [.toolCall(.init(id: "handoff-call", name: "handoff", arguments: [:]))]
        let held = HarnessGatedResponse(message: chatAssistant("Handoff answer"))
        let models = FakeDurableModels(responses: [.message(call), held.step])
        let opened = try await directory.open(models, clock: TestClock(now: 100), registry: registry)
        await opened.hostController.submit("Start handoff", whenBusy: .steer)
        try await eventually {
            held.reached.isSignalled && opened.hostView.hostCurrent().live.run?.turns == 1
                && opened.hostView.hostCurrent().rows.contains { row in
                    if case .entry(let entry) = row.item { return entry.kind == "pi.reset" }
                    return false
                }
        }
        let view = opened.hostView.hostCurrent()
        #expect(view.live.run?.turns == 1)
        #expect(view.ending == nil)
        #expect(view.rows.contains { row in
            guard case .entry(let entry) = row.item, entry.kind == "pi.reset" else { return false }
            return (try? entry.messages()?.compactMap { textOf($0) }.joined()) == "Continue from this context"
        })
        held.release()
        try await eventually { opened.hostView.hostCurrent().live.run == nil }
        #expect(opened.hostView.hostCurrent().ending == nil)
        await opened.close()
    }

    // Reuse the unmodified tag's persisted phase files. This exercises host startup,
    // durable recovery, watch delivery, and typed ending presentation together.
    @Test(arguments: ["model_error", "no_model", "aborted", "reset", "faulted", "orphaned-old", "orphaned-future", "interrupted", "restart_limit", "nothing_to_answer", "turn_limit"])
    func tagWrittenPhaseResumesToHostEnding(scenario: String) async throws {
        let directory = try D10FailureDirectory()
        defer { directory.remove() }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let caseName = scenario == "orphaned-old" ? "orphaned"
            : scenario == "orphaned-future" ? "orphaned-future" : scenario
        let fixtureRoot = repository.appendingPathComponent("Scripts/durable-fixtures/" +
            (scenario == "orphaned-future" ? "d5b-endings-v160" : "d5b-endings-v152"))
        // v1.6.0 D1: generation.ts:184-194 makes the frozen v3 orphaned seed runnable.
        // The v1.6.0 Node oracle records its aborted ending and a new future-v4 orphaned case.
        let oracleURL = repository.appendingPathComponent("Scripts/durable-fixtures/d5b-endings-v160/manifest.json")
        let oracle = try JSONValue(jsonData: Data(contentsOf: oracleURL))
        let expectedCase = try #require(oracle["cases"]?[caseName + "-sqlite"])
        let expectedLive = try #require(expectedCase["post"]?["values"]?.arrayValue?.first {
            $0["record"]?["kind"] == "pi.live"
        }?["value"])
        let expectedFailure = try #require(expectedLive["runFailure"])
        let reason = try #require(expectedFailure["reason"]?.stringValue)
        #expect(reason == (scenario == "orphaned-old" ? "aborted" : scenario == "orphaned-future" ? "orphaned" : scenario))
        let copy = directory.base.appendingPathComponent("tag-session")
        try FileManager.default.copyItem(at: fixtureRoot.appendingPathComponent(caseName + "-jsonl/pre"), to: copy)
        let models = FakeDurableModels()
        let clock = TestClock(now: 1_700_000_000_000)
        let opened = try await openDurable(.init(cwd: directory.cwd, transcriptMode: .paged), dependencies: .init(
            agentDirectory: directory.agent, makeModels: { _ in
                .init(models: models, available: models.models, initial: { _ in .init(model: nil) })
            }, makeStorage: { _ in try await JsonlStorage.open(directory: copy.path, context: .background) }, clock: clock,
            modelsProvider: {
                if scenario == "faulted" { throw TaskDefinitionError("Fixture model provider failed") }
                return models
            }))
        try await eventually { opened.hostView.hostCurrent().ending?.reason.rawValue == reason }
        let view = opened.hostView.hostCurrent()
        #expect(view.live.run == nil)
        #expect(view.ending?.reason.rawValue == reason)
        let ending = try #require(view.ending)
        let snapshot = "\(reason) | task=\(ending.taskId.rawValue) | inputs=\(ending.inputs.map { String($0.rawValue) }.joined(separator: ",")) | first=\(ending.first.map { String($0.rawValue) } ?? "none") | detail=\(ending.detail ?? "none")"
        let expectedTask = try #require(expectedFailure["taskId"]).decode(TaskID.self)
        let expectedInputs = try #require(expectedFailure["inputs"]).decode([SubmissionID].self)
        let expectedFirst = try expectedFailure["first"]?.decode(EntryID.self)
        let oracleSnapshot = "\(reason) | task=\(expectedTask.rawValue) | inputs=\(expectedInputs.map { String($0.rawValue) }.joined(separator: ",")) | first=\(expectedFirst.map { String($0.rawValue) } ?? "none") | detail=\(expectedFailure["detail"]?.stringValue ?? "none")"
        #expect(snapshot == oracleSnapshot)
        let expectedURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/D10-failure-scenarios-recovery.txt")
        let expected = try String(contentsOf: expectedURL, encoding: .utf8)
        #expect(expected.split(separator: "\n").map(String.init).contains(snapshot))
        #expect(!view.notices.contains { $0.message.lowercased().contains("parked") })
        if reason == "faulted" || reason == "orphaned" {
            try await eventually { opened.hostView.hostCurrent().outcomes.contains { $0.id == ending.taskId } }
            let outcome = try #require(opened.hostView.hostCurrent().outcomes.first { $0.id == ending.taskId })
            #expect(outcome.outcome.status == reason)
        }
        await opened.close()
    }

}
