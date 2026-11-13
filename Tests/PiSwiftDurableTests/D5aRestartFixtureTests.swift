import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

#if os(macOS)
private struct D5aFixtureCheckpoint: TaskCheckpoint {
    enum Phase: String, Codable, Sendable { case run }
    let phase: Phase = .run
}

@Suite("PiSwiftDurableTests.D5aRestartFixtures", .serialized, .timeLimit(.minutes(5)))
struct D5aRestartFixtureTests {
    private var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/durable-fixtures/restart-endings-v152")
    }

    private var generator: URL {
        fixtureDirectory.deletingLastPathComponent().appendingPathComponent("generate-restart-endings-v152.mjs")
    }

    private func item(_ name: String) throws -> JSONValue {
        let manifest = try JSONValue(jsonData: Data(contentsOf: fixtureDirectory.appendingPathComponent("manifest.json")))
        #expect(manifest["tag"] == "v1.5.2")
        return try #require(manifest["cases"]?[name])
    }

    private func definition() -> TaskDefinition<JSONValue, D5aFixtureCheckpoint, JSONValue, NoTaskHooks> {
        TaskDefinition(name: "fixture.restart-loop", version: 1,
            initial: { _ in D5aFixtureCheckpoint() },
            phase: { _, _, _ in throw TaskDefinitionError("A cut-off task ran again") },
            abort: { _, _, _ in throw TaskDefinitionError("A cut-off abort handler ran again") })
    }

    private func registry(_ task: TaskDefinition<JSONValue, D5aFixtureCheckpoint, JSONValue, NoTaskHooks>) throws -> Registry {
        let registry = createRegistry()
        try registry.install(Extension(name: "fixture", tasks: [AnyTaskDefinition(task)]))
        return registry
    }

    private func copyPre(_ name: String, to directory: URL) throws -> URL {
        let backend = name.hasSuffix("-jsonl") ? "jsonl" : "sqlite"
        let source = fixtureDirectory.appendingPathComponent(name).appendingPathComponent(backend == "sqlite" ? "pre.sqlite" : "pre")
        let target = directory.appendingPathComponent(backend == "sqlite" ? "resume.sqlite" : "resume")
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    private func open(_ path: URL, backend: String) async throws -> any DurableStorage {
        if backend == "jsonl" {
            return try await JsonlStorage.open(directory: path.path, fileSystem: LocalExecutionEnv(cwd: path.path))
        }
        return try await SqliteStorage.open(path: path.path)
    }

    private func snapshot(_ storage: any DurableStorage, item: JSONValue) async throws -> JSONValue {
        let root = try #require(item["rootId"]).decode(ConversationID.self)
        let tasks = try await storage.scanTasks(.init(order: .ascending), limit: 100, cursor: nil, context: .background)
        let documents = try await storage.scanDocuments(.init(scope: .conversation(conversationId: root), at: .current),
            limit: 100, cursor: nil, context: .background)
        #expect(tasks.next == nil && documents.next == nil)
        return ["ids": try #require(item["ids"]),
                "tasks": try JSONValue(encoding: tasks.items),
                "documents": try JSONValue(encoding: documents.items)]
    }

    // v1.5.2 D5a harness-restart-failure.test.ts: extension, compaction, and nested endings.
    @Test(arguments: ["extension-run-sqlite", "extension-run-jsonl", "extension-abort-sqlite",
                      "extension-abort-jsonl", "compaction-sqlite", "compaction-jsonl",
                      "nested-extension-sqlite", "nested-extension-jsonl"])
    func taggedPreFilesEndWithTheSameStoredRecords(name: String) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = try item(name), backend = try #require(item["backend"]?.stringValue)
        let restartLimit = try #require(item["restartLimit"]?.numberValue)
        let path = try copyPre(name, to: directory)
        let storage = try await open(path, backend: backend)
        #expect(try await snapshot(storage, item: item) == item["pre"])
        let task = definition()
        let harness = try await Harness.open(storage: storage,
            options: .init(models: FakeDurableModels(), registry: registry(task),
                settings: HarnessSettingsProvider { HarnessSettings(restartLimit: restartLimit) },
                now: { 1_700_000_000_000 }), context: .background)
        let id = try #require(item["ids"]?["task"]).decode(TaskID.self)
        #expect(try JSONValue(encoding: await harness.getTask(id: id, context: .background)) == item["post"]?["afterOpen"])
        try harness.resume()
        let ended = try await harness.waitForTask(id: id, context: .background)
        #expect(try JSONValue(encoding: ended.record) == item["post"]?["terminal"])
        if let owner = item["ids"]?["owner"] {
            _ = try await harness.waitForTask(id: owner.decode(TaskID.self), context: .background)
        }
        try await harnessEventually { try await harness.inspect(context: .background).tasks.isEmpty }
        let final = try await snapshot(harness.session.storage, item: item)
        #expect(final == item["post"]?["after"])
        // A restart scenario must leave no parked or otherwise live task.
        #expect(try #require(final["tasks"]?.arrayValue).allSatisfy { $0["state"]?["status"] == "terminal" })
        try await harness.close(context: .background)
    }

    // v1.5.2 D5a: the Swift writer creates the pre file; the unmodified tag resumes it.
    @Test(arguments: [false, true])
    func taggedNodeResumesSwiftPreFile(abortRequested: Bool) async throws {
        let name = abortRequested ? "extension-abort-sqlite" : "extension-run-sqlite"
        let item = try item(name), directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("swift-pre.sqlite")
        let storage = try await SqliteStorage.open(path: path.path)
        let task = definition()
        let harness = try await Harness.open(storage: storage,
            options: .init(models: FakeDurableModels(), registry: registry(task),
                settings: HarnessSettingsProvider { HarnessSettings(restartLimit: 2) },
                now: { 1_700_000_000_000 }), context: .background)
        let root = try await harness.root(context: .background)
        let id = try await root.commit({ tx in
            try await tx.createTask(task, input: .null, options: .init(ownership: .conversation()))
        }, context: .background)
        try await root.commit({ tx in
            let record = try #require(await tx.task(id))
            try tx.setTask(record.replacing(state: .running(checkpoint: ["phase": "run"]),
                abortRequested: abortRequested, restarts: .some(1)))
        }, context: .background)
        #expect(try await snapshot(harness.session.storage, item: item) == item["pre"])
        try await harness.close(context: .background)

        let log = directory.appendingPathComponent("node.log")
        #expect(FileManager.default.createFile(atPath: log.path, contents: nil))
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = ["node", generator.path, "--resume-swift", name, path.path]
        child.standardOutput = handle; child.standardError = handle
        try child.run(); child.waitUntilExit()
        let output = try String(contentsOf: log, encoding: .utf8)
        #expect(child.terminationStatus == 0, "Node status \(child.terminationStatus): \(output)")
    }

    /// Export all D5a pre-event shapes through Swift storage for tagged resume.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PISWIFT_D12_D5A_EXPORT"] != nil),
          .timeLimit(.minutes(2)))
    func exportsSwiftWrittenRestartPreFiles() async throws {
        let environment = ProcessInfo.processInfo.environment
        let seeds = URL(fileURLWithPath: try #require(environment["PISWIFT_D12_D5A_SEEDS"]))
        let output = URL(fileURLWithPath: try #require(environment["PISWIFT_D12_D5A_EXPORT"]))
        for scenario in ["extension-run", "extension-abort", "compaction", "nested-extension"] {
            for backend in ["sqlite", "jsonl"] {
                let name = "\(scenario)-\(backend)", item = try item(name)
                let root = try #require(item["rootId"]).decode(ConversationID.self)
                let sourcePath = seeds.appendingPathComponent(name).appendingPathComponent(backend == "sqlite" ? "pre.sqlite" : "pre")
                let source = try await open(sourcePath, backend: backend)
                let conversation = try #require(await source.conversation(root, context: .background))
                let directory = output.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let path = directory.appendingPathComponent(backend == "sqlite" ? "pre.sqlite" : "pre")
                let destination = try await open(path, backend: backend)
                var first: [StorageWrite] = [.conversation(value: conversation)]
                for raw in try #require(item["pre"]?["documents"]?.arrayValue) {
                    let record = try raw.decode(DocumentRecord.self)
                    let stored = try #require(await source.document(record.id, at: .current, context: .background))
                    let create = DocumentCreate(id: record.id, kind: record.kind, scope: record.scope,
                        key: record.key, history: record.history, fork: record.fork, extensionFields: record.extensionFields)
                    first.append(.documentCreate(record: create, content: .init(version: stored.version, value: stored.value)))
                }
                _ = try await destination.commitOne(first, context: .background)
                let tasks = try #require(item["pre"]?["tasks"]?.arrayValue).map { StorageWrite.task(value: try $0.decode(TaskRecord.self)) }
                _ = try await destination.commitOne(tasks, context: .background)
                try await source.close(context: .background)
                try await destination.close(context: .background)
            }
        }
    }
}
#endif
