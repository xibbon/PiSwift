import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

@Suite("PiSwiftDurableTests.D5bTaggedPhaseFixtures", .serialized)
struct D5bTaggedPhaseFixtureTests {
    private var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/durable-fixtures/d5b-phase-v152")
    }
    private func item(_ name: String) throws -> JSONValue {
        // v1.6.0 D1: generate-d5b-phase-v152.mjs --v160 resumes the frozen pre
        // with generation.ts:188 version 3; the v1.5.2 input files stay unchanged.
        let data = try Data(contentsOf: fixtureDirectory.deletingLastPathComponent()
            .appendingPathComponent("d5b-phase-v160/manifest.json"))
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
        return ["tasks": try JSONValue(encoding: tasks.items),
                "submissions": try JSONValue(encoding: submissions.items),
                "entries": try JSONValue(encoding: entries.items),
                "documents": try JSONValue(encoding: documents.items),
                "values": .array(values)]
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["finish-sqlite", "finish-jsonl", "drain-sqlite", "drain-jsonl",
                                              "retryPoll-sqlite", "retryPoll-jsonl"])
    func swiftResumesTagWrittenPhaseFile(name: String) async throws {
        let item = try item(name), backend = try #require(item["backend"]?.stringValue)
        let root = try #require(item["rootId"]).decode(ConversationID.self)
        let task = try #require(item["ids"]?["taskId"]).decode(TaskID.self)
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = fixtureDirectory.appendingPathComponent(name).appendingPathComponent(backend == "sqlite" ? "pre.sqlite" : "pre")
        let path = directory.appendingPathComponent(backend == "sqlite" ? "resume.sqlite" : "resume")
        try FileManager.default.copyItem(at: source, to: path)
        let storage = try await open(path, backend: backend)
        #expect(try await snapshot(storage, root: root) == item["pre"])
        let empty = FakeDurableModels(options: .init(provider: "empty"))
        let harness = try await Harness.open(storage: storage,
            options: .init(models: empty, registry: createRegistry(), now: { 1_700_000_000_000 }), context: .background)
        try harness.resume()
        _ = try await harness.waitForTask(id: task, context: .background)
        let after = try await snapshot(storage, root: root)
        #expect(after == item["post"], "Tag and Swift records differ for \(name)")
        try await harness.close(context: .background)
    }

    #if os(macOS)
    @Test(.timeLimit(.minutes(1)), arguments: ["finish-sqlite", "finish-jsonl", "drain-sqlite", "drain-jsonl",
                                               "retryPoll-sqlite", "retryPoll-jsonl"])
    func taggedNodeResumesSwiftWrittenPhaseFile(name: String) async throws {
        let item = try item(name), backend = try #require(item["backend"]?.stringValue)
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(backend == "sqlite" ? "swift-pre.sqlite" : "swift-pre")
        let storage = try await open(path, backend: backend)
        let harness = try await Harness.open(storage: storage,
            options: .init(models: FakeDurableModels(options: .init(provider: "empty")),
                           registry: createRegistry(), now: { 1_700_000_000_000 }), context: .background)
        let root = try await harness.root(context: .background)
        let ids = try await root.commit({ tx in
            let user = try await tx.appendEntry(root.id, value: EntryDraft(kind: userEntry.kind,
                model: [["role": "user", "content": "go", "timestamp": 1_700_000_000_000]]))
            let answer: EntryRecord?
            if name.hasPrefix("retryPoll") { answer = nil }
            else {
                let raw = try #require(item["pre"]?["entries"]?[1])
                answer = try await tx.appendEntry(root.id, value: EntryDraft(kind: assistantEntry.kind,
                    model: try #require(raw["model"]?.arrayValue)))
            }
            let submission = try await tx.createSubmission(.continue(conversationId: root.id,
                state: answer.map { .done(answer: $0.id) } ?? .placed()))
            let task = try await createGeneration(tx: tx, conversationId: root.id)
            let live = try await tx.doc(LiveDoc, conversationId: root.id)
            try live.set("run", JSONValue(encoding: LiveRun(taskId: task,
                inputs: answer == nil ? [submission.id] : [], first: user.id,
                afterRun: answer == nil ? nil : LiveAfterRun())))
            return (user.id, answer?.id, submission.id, task)
        }, context: .background)
        try await root.commit({ tx in
            let record = try #require(await tx.task(ids.3))
            let checkpoint: GenerationCheckpoint
            if name.hasPrefix("finish") {
                let answer = try #require(ids.1)
                checkpoint = .init(phase: .finish,
                    run: .init(reason: .answer, first: ids.0, answer: answer, last: answer))
            } else if name.hasPrefix("drain") {
                checkpoint = .init(phase: .drain, answer: try #require(ids.1), tasks: [])
            } else {
                checkpoint = .init(phase: .retry, attempt: 1, until: 1_700_000_000_000,
                    poll: .init(model: .init(provider: "faux", modelId: "faux-1"), thinkingLevel: .off,
                        cutoff: ids.0, handle: .init(DeferredHandle(provider: "faux", modelId: "faux-1",
                            api: "fixture-faux", id: "deferred:d5b"))))
            }
            try tx.setTask(record.replacing(state: .pending(checkpoint: try JSONValue(encoding: checkpoint))))
        }, context: .background)
        #expect(try await snapshot(storage, root: root.id) == item["swiftPre"])
        try await harness.close(context: .background)

        let log = directory.appendingPathComponent("node.log")
        #expect(FileManager.default.createFile(atPath: log.path, contents: nil))
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = ["node", fixtureDirectory.deletingLastPathComponent()
            .appendingPathComponent("generate-d5b-phase-v152.mjs").path, "--v160", "--resume-swift", name, path.path]
        child.standardOutput = handle; child.standardError = handle
        try child.run(); child.waitUntilExit()
        let output = try String(contentsOf: log, encoding: .utf8)
        #expect(child.terminationStatus == 0, "Node status \(child.terminationStatus): \(output)")
    }
    #endif
}
