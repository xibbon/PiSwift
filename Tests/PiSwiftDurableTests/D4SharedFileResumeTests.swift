import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

#if os(macOS)
private struct D4ResumeCheckpoint: TaskCheckpoint {
    enum Phase: String, Codable, Sendable { case start, after, run }
    var phase: Phase
    var slept: Double?
}

// The host resolves a persisted deferred handle after a reopen. The provider's
// saved handle is checked in full before this deterministic response is returned.
private final class D4ResumeModels: DurableModels {
    let base = FakeDurableModels(responses: [.message(chatAssistant("resumed"))])
    private let polls = Mutex<[DeferredHandle]>([])
    var handles: [DeferredHandle] { polls.withLock { $0 } }
    func getModel(provider: String, modelId: String) -> Model? { base.getModel(provider: provider, modelId: modelId) }
    func streamSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) -> AssistantMessageEventStream {
        base.streamSimple(model: model, context: context, options: options)
    }
    func fetchDeferred(model: Model, handle: DeferredHandle, options: DeferredFetchOptions) async -> AssistantMessage {
        polls.withLock { $0.append(handle) }
        return chatAssistant("resumed")
    }
    func cancelDeferred(model: Model, handle: DeferredHandle, options: DeferredCancelOptions) async throws {
        try await base.cancelDeferred(model: model, handle: handle, options: options)
    }
}

@Suite("PiSwiftDurableTests.D4SharedFileResume", .serialized)
struct D4SharedFileResumeTests {
    private func bridge(_ mode: String, directory: URL, backend: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = directory.appendingPathComponent("\(mode)-\(backend).log")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let log = try FileHandle(forWritingTo: url)
        defer { try? log.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = ["node", root.appendingPathComponent("Scripts/durable-fixtures/shared-file-matrix.mjs").path,
                           mode, directory.path, backend]
        child.standardOutput = log
        child.standardError = log
        try child.run()
        child.waitUntilExit()
        let output = try String(contentsOf: url, encoding: .utf8)
        try #require(child.terminationStatus == 0, "\(output)")
    }

    private func prepare(_ directory: URL, backend: String) throws -> [String: JSONValue] {
        try bridge("prepare-resume", directory: directory, backend: backend)
        let data = try JSONValue(jsonData: Data(contentsOf: directory.appendingPathComponent("manifest-resume-\(backend).json")))
        var cases: [String: JSONValue] = [:]
        for item in try #require(data.arrayValue) { cases[try #require(item["name"]?.stringValue)] = item }
        #expect(cases.count == 10)
        return cases
    }

    private func open(_ path: URL, backend: String) async throws -> any DurableStorage {
        if backend == "jsonl" {
            return try await JsonlStorage.open(directory: path.path, fileSystem: LocalExecutionEnv(cwd: path.path))
        }
        return try await SqliteStorage.open(path: path.path, prefix: backend == "prefix" ? "pi_" : nil)
    }

    private func path(_ directory: URL, backend: String, name: String) -> URL {
        directory.appendingPathComponent("node-resume/\(backend)/\(name)")
    }

    private func checkSeed(_ storage: any DurableStorage, item: JSONValue) async throws {
        for read in try #require(item["reads"]?.arrayValue) {
            let actual = try await PiSwiftDurableTests().sqliteReplayRead(#require(read["method"]?.stringValue),
                args: #require(read["arguments"]?.arrayValue), storage: storage)
            #expect(actual == read["result"])
        }
    }

    private func idle(_ harness: Harness) async throws {
        try await harnessEventually {
            harness.tasks.state.withLock { !$0.pumping && !$0.wakeScheduled }
        }
    }

    // Record all full reads after Swift writes, then have the target tag read them.
    // Scans include new records created while the task resumes.
    private func capture(_ directory: URL, backend: String, name: String, item: JSONValue) async throws -> JSONValue {
        let storage = try await open(path(directory, backend: backend, name: name), backend: backend)
        do {
            var reads: [JSONValue] = []
            func read(_ method: String, _ args: [JSONValue]) async throws -> JSONValue {
                let value = try await PiSwiftDurableTests().sqliteReplayRead(method, args: args, storage: storage)
                reads.append(["method": .string(method), "arguments": .array(args), "result": value])
                return value
            }
            for call in try #require(item["reads"]?.arrayValue) {
                _ = try await read(#require(call["method"]?.stringValue), #require(call["arguments"]?.arrayValue))
            }
            let conversations = try await read("scanConversations", [["order": "ascending"], 1000, .null])
            let tasks = try await read("scanTasks", [["order": "ascending"], 1000, .null])
            _ = try await read("scanSubmissions", [["order": "ascending"], 1000, .null])
            var scopes: [JSONValue] = [["kind": "session"]]
            for record in try #require(conversations["items"]?.arrayValue) {
                let id = try #require(record["id"])
                _ = try await read("scanEntries", [["conversationId": id, "order": "ascending"], 1000, .null])
                scopes.append(["kind": "conversation", "conversationId": id])
            }
            for record in try #require(tasks["items"]?.arrayValue) {
                scopes.append(["kind": "task", "taskId": try #require(record["id"])])
            }
            for scope in scopes {
                let documents = try await read("scanDocuments", [["scope": scope, "at": "current"], 1000, .null])
                for record in try #require(documents["items"]?.arrayValue) {
                    _ = try await read("document", [#require(record["id"]), "current"])
                }
            }
            try await storage.close(context: .background)
            return ["name": .string(name), "reads": .array(reads)]
        } catch { try? await storage.close(context: .background); throw error }
    }

    private func verify(_ expected: [JSONValue], directory: URL, backend: String) throws {
        try Data(JSONValue.array(expected).jsonText().utf8).write(to: directory.appendingPathComponent("expected-resume-\(backend).json"))
        try bridge("verify-resume", directory: directory, backend: backend)
    }

    @Test(arguments: ["sqlite", "prefix", "jsonl"])
    func sleepingFilesResumeOnlyWhenDueAndKeepCarriers(backend: String) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cases = try prepare(directory, backend: backend)
        var expected: [JSONValue] = []
        for name in ["integerSleep", "fractionalSleep", "carriers"] {
            let item = try #require(cases[name]), raw = try #require(item["record"])
            let record = try raw.decode(TaskRecord.self)
            let due = try #require(item["dueClock"]?.intValue)
            let clock = TestClock(now: 1000), runs = SessionTestLog<Double>(), registry = Registry()
            let definition = TaskDefinition<JSONValue, D4ResumeCheckpoint, Double, NoTaskHooks>(name: "fixture.nap", version: 1,
                initial: { _ in D4ResumeCheckpoint(phase: .start) }, phase: { task, runtime, context in
                    #expect(task.checkpoint.phase == .after)
                    #expect(task.checkpoint.slept == record.input["delay"]?.numberValue)
                    runs.append(Double(try runtime.now()))
                    try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(Double(try runtime.now())))) }, context: context)
                }, abort: { _, runtime, context in
                    try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
                })
            try registry.install(Extension(name: "fixture", tasks: [AnyTaskDefinition(definition)]))
            let storage = try await open(path(directory, backend: backend, name: name), backend: backend)
            try await checkSeed(storage, item: item)
            let harness = try await Harness.open(storage: storage, options: .init(models: FakeDurableModels(), registry: registry,
                clock: clock, onWake: { _ in }), context: .background)
            #expect(try JSONValue(encoding: await harness.getTask(id: record.id, context: .background)) == raw)
            try harness.resume(); try await idle(harness)
            #expect(runs.values == [])
            clock.advance(by: Int64(due - 1001))
            try harness.resume(); try await idle(harness)
            #expect(runs.values == [])
            #expect(try JSONValue(encoding: await harness.getTask(id: record.id, context: .background)) == raw)
            clock.advance(by: 1)
            try harness.resume()
            let receipt = try await harness.waitForTask(id: record.id, context: .background)
            #expect(try JSONValue(encoding: receipt.record) == item["terminalDue"])
            #expect(runs.values == [Double(due)])
            try await harness.close(context: .background)
            expected.append(try await capture(directory, backend: backend, name: name, item: item))
        }
        try verify(expected, directory: directory, backend: backend)
    }

    @Test(arguments: ["sqlite", "prefix", "jsonl"])
    func parkedFilesStayParkedUntilRetryTask(backend: String) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = try #require(prepare(directory, backend: backend)["parked"])
        let raw = try #require(item["record"]), record = try raw.decode(TaskRecord.self)
        let runs = SessionTestLog<Int>(), registry = Registry()
        let definition = TaskDefinition<JSONValue, D4ResumeCheckpoint, JSONValue, NoTaskHooks>(name: "fixture.crash-loop", version: 1,
            initial: { _ in D4ResumeCheckpoint(phase: .run) }, phase: { _, runtime, context in
                runs.append(1)
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
            }, abort: { _, runtime, context in
                try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
            })
        try registry.install(Extension(name: "fixture", tasks: [AnyTaskDefinition(definition)]))
        let storage = try await open(path(directory, backend: backend, name: "parked"), backend: backend)
        try await checkSeed(storage, item: item)
        let harness = try await Harness.open(storage: storage, options: .init(models: FakeDurableModels(), registry: registry,
            settings: HarnessSettingsProvider { .init(restartLimit: 3) }, clock: TestClock(now: 1000), onWake: { _ in }), context: .background)
        try harness.resume(); try await idle(harness)
        #expect(runs.values == [])
        #expect(try JSONValue(encoding: await harness.getTask(id: record.id, context: .background)) == raw)
        let inspection = try await harness.inspect(context: .background)
        guard case .blocked(.restartLimit, _) = inspection.tasks.first(where: { $0.record.id == record.id })?.state else {
            throw TaskDefinitionError("Expected the shared task to stay parked")
        }
        try await harness.retryTask(id: record.id, context: .background)
        let receipt = try await harness.waitForTask(id: record.id, context: .background)
        var terminal = try #require(raw.objectValue)
        terminal["state"] = ["status": "terminal", "outcome": ["status": "completed", "result": .null]]
        terminal["restarts"] = nil
        terminal["endedAt"] = 1000
        #expect(try JSONValue(encoding: receipt.record) == .object(terminal))
        #expect(runs.values == [1])
        try await harness.close(context: .background)
        try verify([try await capture(directory, backend: backend, name: "parked", item: item)], directory: directory, backend: backend)
    }

    @Test(arguments: ["sqlite", "prefix", "jsonl"])
    func retryAndPollFilesResumeFromStoredDeadlines(backend: String) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cases = try prepare(directory, backend: backend)
        var expected: [JSONValue] = []
        for name in ["retrySleep", "pollSleep", "legacyRunningRetry"] {
            let item = try #require(cases[name]), raw = try #require(item["record"])
            let record = try raw.decode(TaskRecord.self), clock = TestClock(now: 1000), models = D4ResumeModels()
            let storage = try await open(path(directory, backend: backend, name: name), backend: backend)
            try await checkSeed(storage, item: item)
            let harness = try await Harness.open(storage: storage, options: .init(models: models, registry: createRegistry(),
                settings: HarnessSettingsProvider { .init(retry: .init(enabled: true, maxRetries: 2, baseDelayMs: 60_000)) },
                clock: clock, onWake: { _ in }), context: .background)
            try harness.resume()
            try await harnessEventually { try await harness.getTask(id: record.id, context: .background)?.state.status == "sleeping" }
            try await idle(harness)
            var sleeping = try #require(raw.objectValue)
            if name == "legacyRunningRetry" {
                sleeping["state"] = ["status": "sleeping", "checkpoint": try #require(raw["state"]?["checkpoint"]), "until": 61_000]
            }
            #expect(try JSONValue(encoding: await harness.getTask(id: record.id, context: .background)) == .object(sleeping))
            #expect(models.base.calls().streamSimple == 0)
            #expect(models.handles == [])
            clock.advance(by: 59_999)
            try harness.resume(); try await idle(harness)
            #expect(try JSONValue(encoding: await harness.getTask(id: record.id, context: .background)) == .object(sleeping))
            #expect(models.base.calls().streamSimple == 0)
            #expect(models.handles == [])
            clock.advance(by: 1)
            try harness.resume()
            let receipt = try await harness.waitForTask(id: record.id, context: .background)
            guard case .completed(let result, _) = receipt.outcome else {
                throw TaskDefinitionError("Shared generation did not complete: \(receipt.outcome)")
            }
            let entryID = try #require(result["entryId"]).decode(EntryID.self)
            let entry = try #require(await harness.session.storage.entry(entryID, context: .background)).entry
            #expect(entry.kind == "pi.assistant")
            #expect(entry.model?.count == 1)
            #expect(entry.model?.first?["content"]?[0]?["text"] == "resumed")
            var terminal = try #require(raw.objectValue)
            terminal["state"] = ["status": "terminal", "outcome": ["status": "completed", "result": ["entryId": try JSONValue(encoding: entryID)]]]
            terminal["restarts"] = nil
            terminal["endedAt"] = 61_000
            #expect(try JSONValue(encoding: receipt.record) == .object(terminal))
            if name == "pollSleep" {
                #expect(models.base.calls().streamSimple == 0)
                #expect(try JSONValue(encoding: models.handles.map(GenerationDeferredHandle.init)) == [#require(raw["state"]?["checkpoint"]?["handle"])])
            } else {
                #expect(models.base.calls().streamSimple == 1)
                #expect(models.handles == [])
            }
            try await harness.close(context: .background)
            expected.append(try await capture(directory, backend: backend, name: name, item: item))
        }
        try verify(expected, directory: directory, backend: backend)
    }
}
#endif
