import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

private struct D6FixtureInput: Codable, Sendable { let label: String }
private struct D6FixtureCheckpoint: TaskCheckpoint {
    enum Phase: String, Codable, Sendable { case run }
    let phase: Phase = .run
}

@Suite("PiSwiftDurableTests.D6Conversations", .serialized)
struct D6ConversationFixtureTests {
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/durable-fixtures/d6-conversations-v152.json")
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

    private func normalized(_ value: JSONValue) -> JSONValue {
        switch value {
        case .array(let values): return .array(values.map(normalized))
        case .object(var fields):
            if fields["role"]?.stringValue == "assistant", fields["api"] != nil {
                fields["api"] = "<faux-api>"
            }
            if fields["role"]?.stringValue == "toolResult", fields["details"] == .null {
                fields.removeValue(forKey: "details")
            }
            for (key, value) in fields { fields[key] = normalized(value) }
            return .object(fields)
        default: return value
        }
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

    @Test("scripted tool-hook, afterRun and atomic-submit conversations match tagged SQLite and JSONL records", .timeLimit(.minutes(5)))
    func seededConversationsMatchTaggedRecords() async throws {
        let scripts = try #require(JSONValue(jsonData: Data(contentsOf: fixture))["scripts"]?.arrayValue)
        #expect(scripts.count == 12)
        for script in scripts {
            let seed = try #require(script["seed"]?.intValue)
            let kind = try #require(script["kind"]?.stringValue)
            for backend in ["sqlite", "jsonl"] {
                let directory = try sqliteTestDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }
                let storage: any DurableStorage
                if backend == "sqlite" { storage = try await SqliteStorage.open(path: directory.appendingPathComponent("store.sqlite").path) }
                else { storage = try await JsonlStorage.open(directory: directory.path, fileSystem: LocalExecutionEnv(cwd: directory.path)) }
                let setup = HarnessChatSetup(settings: .init(retry: .init(enabled: false)),
                    clock: TestClock(now: 1_700_000_000_000), tagCacheAccounting: true)
                if kind == "afterTool" {
                    let tool = try ToolRegistration(name: "echo", description: "Echo",
                        parameters: ["type": "object", "properties": [:]]) { _, _, _ in
                            ToolExecutionResult(output: [.text(.init(text: "original"))])
                        }
                    try setup.registry.install(Extension(name: "d6-hook", tools: [tool], hooks: [
                        hook(ToolHooks(afterTool: { _, result, _, _ in
                            var changed = result
                            changed.output = [.text(.init(text: "replaced-\(seed)"))]
                            return changed
                        }))
                    ]))
                } else if kind == "afterRun" || kind == "afterRunFailed" {
                    let child = TaskDefinition<D6FixtureInput, D6FixtureCheckpoint, String, NoTaskHooks>(
                        name: "d6.after-run", version: 1, initial: { _ in .init() },
                        phase: { task, runtime, context in
                            try await runtime.commit({ tx, _ in
                                _ = try await tx.appendEntry(runtime.conversationId,
                                    value: EntryDraft(kind: "d6.after-run", data: .string(task.input.label)))
                                if kind == "afterRunFailed" {
                                    return .terminal(outcome: .failed(error: TaskOutcomeError(message: "child failed")))
                                }
                                return .terminal(outcome: .completed(result: .string(task.input.label)))
                            }, context: context)
                        },
                        abort: { _, runtime, context in
                            try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "test")) }, context: context)
                        })
                    try setup.registry.install(Extension(name: "d6-after-run", hooks: [
                        hook(GenerationHooks(afterRun: { _, _, _ in
                            AfterRunResult(tasks: [try runEndTask(child, input: .init(label: "child-\(seed)"))])
                        }))
                    ], tasks: [AnyTaskDefinition(child)]))
                }
                let chat = try await openChat(storage: storage, setup: setup)
                // The tagged fixture uses a zero-duration tool clock.
                chat.harness.tasks.toolServices.setExecutionTime { .zero }
                func answer() -> AssistantMessage {
                    var message = chatAssistant("answer-\(seed)")
                    message.timestamp = 1_700_000_000_000
                    message.durationMs = 0
                    message.thinkingLevel = .off
                    return message
                }
                if kind == "afterTool" {
                    var call = try toolCalls([("echo", [:], "call-\(seed)")])
                    call.timestamp = 1_700_000_000_000
                    call.durationMs = 0
                    call.thinkingLevel = .off
                    setup.models.setResponses([.message(call), .message(answer())])
                } else { setup.models.setResponses([.message(answer())]) }
                if kind == "atomicSubmit" {
                    let id = try await chat.root.commit({ tx in
                        let admitted = try await chat.root.submit(tx, .input(content: .text("question-\(seed)")))
                        _ = try await tx.appendEntry(chat.root.id,
                            value: EntryDraft(kind: "d6.host-write", data: .object(["submission": .number(Double(admitted.rawValue))])))
                        return admitted
                    }, context: .background)
                    _ = try await chat.harness.submission(id: id, context: .background)?.wait(context: .background)
                } else {
                    _ = try await chat.root.submit(.input(content: .text("question-\(seed)")), context: .background).wait(context: .background)
                }
                try await chat.root.waitForIdle(context: .background)
                let actual = normalized(try await snapshot(storage, root: chat.root.id))
                let expected = normalized(try #require(script["records"]))
                if let mismatch = difference(actual, expected) {
                    Issue.record("seed \(seed), \(kind), \(backend): \(mismatch)")
                    return
                }
                try await chat.harness.close(context: .background)
                if seed == 30, let export = ProcessInfo.processInfo.environment["PISWIFT_D12_ATOMIC_EXPORT"] {
                    let source = backend == "sqlite" ? directory.appendingPathComponent("store.sqlite") : directory
                    let target = URL(fileURLWithPath: export).appendingPathComponent("swift-atomic-\(backend)")
                    try FileManager.default.copyItem(at: source, to: target)
                }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PISWIFT_D12_TAGGED_ATOMIC_DIR"] != nil),
          .timeLimit(.minutes(1)))
    func opensTaggedAtomicSubmitFile() async throws {
        let base = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PISWIFT_D12_TAGGED_ATOMIC_DIR"]))
        let scripts = try #require(JSONValue(jsonData: Data(contentsOf: fixture))["scripts"]?.arrayValue)
        let expected = try #require(scripts.first { $0["seed"]?.intValue == 30 }?["records"])
        for backend in ["sqlite", "jsonl"] {
            let path = base.appendingPathComponent("tagged-atomic-\(backend)")
            let storage: any DurableStorage = backend == "sqlite"
                ? try await SqliteStorage.open(path: path.path)
                : try await JsonlStorage.open(directory: path.path, fileSystem: LocalExecutionEnv(cwd: path.path))
            let page = try await storage.scanConversations(.init(), limit: 2, cursor: nil, context: .background)
            let root = try #require(page.items.first?.id)
            if let mismatch = difference(normalized(try await snapshot(storage, root: root)), normalized(expected)) {
                Issue.record("tagged atomic \(backend): \(mismatch)")
            }
            try await storage.close(context: .background)
        }
    }
}
