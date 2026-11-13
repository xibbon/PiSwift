import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

#if os(macOS)
@Suite("PiSwiftDurableTests.D5bRestartMatrix", .serialized)
struct D5bRestartMatrixTests {
    private var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/durable-fixtures/d5b-restart-round1-v152")
    }
    private func readGzip(_ path: URL) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", path.path]
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return data
    }
    private func item(_ name: String) throws -> JSONValue {
        let data = try readGzip(fixtureDirectory.appendingPathComponent("manifest.json.gz"))
        return try #require(JSONValue(jsonData: data)["cases"]?[name])
    }
    private func open(_ path: URL, backend: String) async throws -> any DurableStorage {
        if backend == "jsonl" {
            return try await JsonlStorage.open(directory: path.path, fileSystem: LocalExecutionEnv(cwd: path.path))
        }
        return try await SqliteStorage.open(path: path.path)
    }
    private func snapshot(_ storage: any DurableStorage, root: ConversationID) async throws -> JSONValue {
        let tasks = try await storage.scanTasks(.init(order: .ascending), limit: 100, cursor: nil, context: .background)
        let submissions = try await storage.scanSubmissions(.init(order: .ascending), limit: 100, cursor: nil, context: .background)
        let entries = try await storage.scanEntries(.init(conversationId: root, order: .ascending), limit: 100, cursor: nil, context: .background)
        let documents = try await storage.scanDocuments(.init(scope: .conversation(conversationId: root), at: .current),
            limit: 100, cursor: nil, context: .background)
        var values: [JSONValue] = []
        for doc in documents.items {
            if let value = try await storage.document(doc.id, at: .current, context: .background) {
                var encoded = try JSONValue(encoding: value)
                if doc.kind == "pi.provider", var object = encoded.objectValue,
                   var content = object["value"]?.objectValue {
                    // Tagged and Swift UUID generators select different provider session IDs.
                    content["sessionId"] = "<provider-session-id>"
                    object["value"] = .object(content)
                    encoded = .object(object)
                }
                values.append(encoded)
            } else { values.append(.null) }
        }
        return normalize(["tasks": try JSONValue(encoding: tasks.items),
                "submissions": try JSONValue(encoding: submissions.items),
                "entries": try JSONValue(encoding: entries.items),
                "documents": try JSONValue(encoding: documents.items),
                "values": .array(values)])
    }

    private func difference(_ actual: JSONValue, _ expected: JSONValue, path: String = "$") -> String? {
        if actual == expected { return nil }
        if let left = actual.objectValue, let right = expected.objectValue {
            for key in Set(left.keys).union(right.keys).sorted() {
                guard let a = left[key], let b = right[key] else { return "\(path).\(key): missing" }
                if let detail = difference(a, b, path: "\(path).\(key)") { return detail }
            }
        }
        if let left = actual.arrayValue, let right = expected.arrayValue {
            if left.count != right.count { return "\(path): count \(left.count) != \(right.count)" }
            for index in left.indices {
                if let detail = difference(left[index], right[index], path: "\(path)[\(index)]") { return detail }
            }
        }
        return "\(path): \(actual) != \(expected)"
    }

    private func normalize(_ value: JSONValue) -> JSONValue {
        switch value {
        case .array(let values): return .array(values.map(normalize))
        case .object(var fields):
            if fields["role"] == "assistant", fields["api"] != nil { fields["api"] = "<faux-api>" }
            for (key, child) in fields { fields[key] = normalize(child) }
            return .object(fields)
        default: return value
        }
    }
    private static let scenarios = ["request-retry", "request-backoff", "request-exhausted", "sleeping-retry",
        "waiting-tools", "prepare-limit", "poll-retry", "poll-cancel", "poll-clock-backward",
        "crash-clean-close", "charge-limit", "drop-partial", "abort-limit"]
    private static let names = scenarios.flatMap { ["\($0)-sqlite", "\($0)-jsonl"] }

    private func copyPre(_ name: String, backend: String, to directory: URL) throws -> URL {
        let source = fixtureDirectory.appendingPathComponent(name)
        let path = directory.appendingPathComponent(backend == "sqlite" ? "resume.sqlite" : "resume")
        if backend == "jsonl" {
            try FileManager.default.copyItem(at: source.appendingPathComponent("pre"), to: path)
        } else {
            #expect(FileManager.default.createFile(atPath: path.path, contents: nil))
            let file = try FileHandle(forWritingTo: path)
            defer { try? file.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            process.arguments = ["-dc", source.appendingPathComponent("pre.sqlite.gz").path]
            process.standardOutput = file
            try process.run(); process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        return path
    }
    private func expectSnapshot(_ storage: any DurableStorage, root: ConversationID, expected: JSONValue) async throws {
        let actual = try await snapshot(storage, root: root)
        if let mismatch = difference(actual, expected) { Issue.record("\(mismatch)") }
    }

    @Test(.timeLimit(.minutes(1)))
    func matrixMapsEveryPersistedRestartScenarioToBothBackends() throws {
        let manifest = try JSONValue(jsonData: readGzip(fixtureDirectory.appendingPathComponent("manifest.json.gz")))
        #expect(manifest["tag"] == "v1.5.2")
        let cases = try #require(manifest["cases"]?.objectValue)
        #expect(Set(cases.keys) == Set(Self.names))
        #expect(Set(cases.values.compactMap { $0["scenario"]?["line"]?.numberValue }) ==
            Set([141, 180, 204, 275, 330, 523, 554, 574, 596, 621, 648, 671].map(Double.init)))
        #expect(manifest["notApplicable"]?["737"]?.stringValue?.contains("normalRoundsDoNotResolveRestartLimitPerTask") == true)
    }

    // v1.5.2 harness-restart-failure.test.ts:141,180,204,275,330,523,554,574,596,621,648,671.
    @Test(.timeLimit(.minutes(1)), arguments: names)
    func swiftContinuesTagRestartImageToTheSameCanonicalRecords(name: String) async throws {
        let item = try item(name), backend = try #require(item["backend"]?.stringValue)
        let scenario = try #require(item["scenario"]), scenarioName = try #require(scenario["name"]?.stringValue)
        let root = try #require(item["rootId"]).decode(ConversationID.self)
        let task = try #require(item["ids"]?["taskId"]).decode(TaskID.self)
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = try copyPre(name, backend: backend, to: directory)
        var storage = try await open(path, backend: backend)
        try await expectSnapshot(storage, root: root, expected: #require(item["pre"]))
        let clock = TestClock(now: 1_700_000_000_000)
        let models = D5bRestartMatrixModels(clock: clock, recordsDuration: ["sleeping-retry", "waiting-tools"].contains(scenarioName))
        let settings = HarnessSettings(retry: .init(enabled: scenario["retry"] == true,
            maxRetries: Int(scenario["maxRetries"]?.numberValue ?? 2), baseDelayMs: 60_000),
            restartLimit: scenario["limit"]?.numberValue ?? 7)
        let options = HarnessOptions(models: models, registry: createRegistry(),
            settings: .init { settings }, clock: clock)
        var harness = try await Harness.open(storage: storage, options: options, context: .background)
        if scenario["cleanClose"] == true {
            try await harness.close(context: .background)
            storage = try await open(path, backend: backend)
            harness = try await Harness.open(storage: storage, options: options, context: .background)
        }
        try await expectSnapshot(storage, root: root, expected: #require(item["afterOpen"]))
        try harness.resume()
        if let sleeping = item["sleeping"] {
            let current = harness
            try await eventually { try await current.getTask(id: task, context: .background)?.state.status == "sleeping" }
            try await expectSnapshot(storage, root: root, expected: sleeping)
            if scenario["sleepOnly"] != true { clock.advance(by: 60_000) }
        }
        if scenario["sleepOnly"] != true {
            _ = try await harness.waitForTask(id: task, context: .background)
            let submissionId = try #require(item["ids"]?["submission"]).decode(SubmissionID.self)
            let submission = try #require(await harness.submission(id: submissionId, context: .background))
            _ = try await submission.wait(context: .background)
            let conversation = try #require(await harness.conversation(id: root, context: .background))
            try await conversation.waitForIdle(context: .background)
        }
        try await expectSnapshot(storage, root: root, expected: #require(item["post"]))
        #expect(models.fetched.values == item["calls"]?["fetched"]?.arrayValue?.compactMap(\.stringValue))
        #expect(models.cancelled.values == item["calls"]?["cancelled"]?.arrayValue?.compactMap(\.stringValue))
        if scenarioName == "waiting-tools" || scenarioName == "sleeping-retry" {
            #expect(item["afterOpen"]?["tasks"]?[0]?["restarts"] == nil)
        }
        try await harness.close(context: .background)
    }

    /// Write the same tagged pre-event records through Swift storage so the
    /// tagged Harness can resume every restart boundary in the reverse direction.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PISWIFT_D12_RESTART_EXPORT"] != nil),
          .timeLimit(.minutes(3)))
    func exportsSwiftWrittenRestartPreFiles() async throws {
        let environment = ProcessInfo.processInfo.environment
        let seeds = URL(fileURLWithPath: try #require(environment["PISWIFT_D12_RESTART_SEEDS"]))
        let output = URL(fileURLWithPath: try #require(environment["PISWIFT_D12_RESTART_EXPORT"]))
        for name in Self.names {
            let item = try item(name), backend = try #require(item["backend"]?.stringValue)
            let pre = try #require(item["pre"]), root = try #require(item["rootId"]).decode(ConversationID.self)
            let sourcePath = seeds.appendingPathComponent(name).appendingPathComponent(backend == "sqlite" ? "pre.sqlite" : "pre")
            let source = try await open(sourcePath, backend: backend)
            let conversation = try #require(await source.conversation(root, context: .background))
            let directory = output.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent(backend == "sqlite" ? "pre.sqlite" : "pre")
            let destination = try await open(path, backend: backend)
            var first: [StorageWrite] = [.conversation(value: conversation)]
            var liveDelta: (DocumentID, JSONObject)?
            let documents = try #require(pre["documents"]?.arrayValue)
            let values = try #require(pre["values"]?.arrayValue)
            #expect(documents.count == values.count)
            for (raw, expected) in zip(documents, values) {
                let record = try raw.decode(DocumentRecord.self)
                let stored = try #require(await source.document(record.id, at: .current, context: .background))
                let current = stored.value
                let deltaCount = expected["deltasSinceBase"]?.intValue ?? 0
                let base: JSONObject
                if record.kind == "pi.live" && deltaCount == 1 {
                    base = [:]
                    liveDelta = (record.id, current)
                } else { base = current }
                let create = DocumentCreate(id: record.id, kind: record.kind, scope: record.scope,
                    key: record.key, history: record.history, fork: record.fork, extensionFields: record.extensionFields)
                first.append(.documentCreate(record: create, content: .init(version: stored.version, value: base)))
            }
            _ = try await destination.commitOne(first, context: .background)
            var second: [StorageWrite] = []
            for raw in try #require(pre["entries"]?.arrayValue) {
                second.append(.entry(value: try raw.decode(EntryRecord.self)))
            }
            for raw in try #require(pre["submissions"]?.arrayValue) {
                second.append(.submission(value: try raw.decode(SubmissionRecord.self)))
            }
            if let (id, current) = liveDelta {
                second.append(.documentChange(id: id, content: .delta(version: 3,
                    ops: current.map { .set([.key($0.key)], $0.value) })))
            }
            _ = try await destination.commitOne(second, context: .background)
            let tasks = try #require(pre["tasks"]?.arrayValue).map { StorageWrite.task(value: try $0.decode(TaskRecord.self)) }
            _ = try await destination.commitOne(tasks, context: .background)
            try await source.close(context: .background)
            try await destination.close(context: .background)
        }
    }
}

private final class D5bRestartMatrixModels: DurableModels {
    let base = FakeDurableModels(tagCacheAccounting: true)
    let clock: TestClock
    let fetched = SessionTestLog<String>(), cancelled = SessionTestLog<String>()
    init(clock: TestClock, recordsDuration: Bool) {
        self.clock = clock
        base.setResponses([.factory { _, _, _, _ in
            var answer = chatAssistant("answer")
            answer.timestamp = 1_700_000_000_000; answer.thinkingLevel = .off
            if recordsDuration { answer.durationMs = 0 }
            return answer
        }])
    }
    func getModel(provider: String, modelId: String) -> Model? { base.getModel(provider: provider, modelId: modelId) }
    func streamSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) -> AssistantMessageEventStream {
        base.streamSimple(model: model, context: context, options: options)
    }
    func fetchDeferred(model: Model, handle: DeferredHandle, options: DeferredFetchOptions) async -> AssistantMessage {
        fetched.append(handle.id)
        var answer = chatAssistant("deferred answer")
        answer.timestamp = clock.now()
        return answer
    }
    func cancelDeferred(model: Model, handle: DeferredHandle, options: DeferredCancelOptions) async throws {
        cancelled.append(handle.id)
    }
}
#endif
