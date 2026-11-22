import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

private struct D6CutoffCheckpoint: TaskCheckpoint {
    enum Phase: String, Codable, Sendable { case run }
    let phase: Phase = .run
}

@Suite("PiSwiftDurableTests.D6ResumeFixtures", .serialized)
struct D6ResumeFixtureTests {
    private var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/durable-fixtures/d6-resume-v152")
    }
    private var generator: URL { directory.deletingLastPathComponent().appendingPathComponent("generate-d6-resume-v152.mjs") }
    private func item(_ name: String) throws -> JSONValue {
        // v1.6.0 D1: generate-d6-resume-v152.mjs --v160 resumes the same frozen
        // pre files with tool.ts:159 v4 and generation.ts:188 v3.
        let oracle = directory.deletingLastPathComponent().appendingPathComponent("d6-resume-v160/manifest.json")
        return try #require(JSONValue(jsonData: Data(contentsOf: oracle))["cases"]?[name])
    }
    private func open(_ path: URL, backend: String) async throws -> any DurableStorage {
        if backend == "jsonl" { return try await JsonlStorage.open(directory: path.path, fileSystem: LocalExecutionEnv(cwd: path.path)) }
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
                    content["sessionId"] = "<provider-session-id>"
                    object["value"] = .object(content)
                    encoded = .object(object)
                }
                values.append(encoded)
            } else { values.append(.null) }
        }
        var fields: JSONObject = ["tasks": try JSONValue(encoding: tasks.items),
                           "submissions": try JSONValue(encoding: submissions.items),
                           "entries": try JSONValue(encoding: entries.items),
                           "documents": try JSONValue(encoding: documents.items),
                           "values": .array(values)]
        var nested: [JSONValue] = []
        for task in tasks.items {
            let members = try await storage.scanDocuments(.init(scope: .task(taskId: task.id), at: .current),
                limit: 100, cursor: nil, context: .background)
            for member in members.items {
                let value = try await storage.document(member.id, at: .current, context: .background)
                nested.append(["document": try JSONValue(encoding: member),
                               "value": try value.map { try JSONValue(encoding: $0) } ?? .null])
            }
        }
        if !nested.isEmpty { fields["nested"] = .array(nested) }
        return normalized(.object(fields))
    }
    private func normalized(_ value: JSONValue) -> JSONValue {
        switch value {
        case .array(let values): return .array(values.map(normalized))
        case .object(var fields):
            if fields["role"]?.stringValue == "assistant", fields["api"] != nil { fields["api"] = "<faux-api>" }
            if fields["role"]?.stringValue == "toolResult", fields["details"] == .null { fields.removeValue(forKey: "details") }
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
                if let mismatch = difference(a, b, path: "\(path).\(key)") { return mismatch }
            }
        }
        if let left = actual.arrayValue, let right = expected.arrayValue {
            if left.count != right.count { return "\(path): count \(left.count) != \(right.count)" }
            for index in left.indices {
                if let mismatch = difference(left[index], right[index], path: "\(path)[\(index)]") { return mismatch }
            }
        }
        return "\(path): \(actual) != \(expected)"
    }
    private func registry(_ scenario: String) throws -> Registry {
        let registry = createRegistry()
        if scenario == "nested-restart" {
            let leaf = try ToolRegistration(name: "leaf", description: "Leaf", parameters: ["type": "object", "properties": [:]],
                replay: .safe, execute: { _, _, _ in .init(output: [.text(.init(text: "leaf reran"))]) })
            let batch = try ToolRegistration(name: "batch", description: "Batch", parameters: ["type": "object", "properties": [:]],
                replay: .safe, execute: { _, api, context in
                    let child = try await api.executeTool("leaf", arguments: [:], context: context)
                    return .init(output: [.text(.init(text: "batch \(child.structuredOutput?.stringValue ?? "undefined")"))])
                })
            try registry.install(Extension(name: "d6-nested-restart", tools: [leaf, batch]))
            return registry
        }
        if scenario == "afterRun-cutoff" {
            let child = cutoffChild()
            try registry.install(Extension(name: "d6-cutoff", tasks: [AnyTaskDefinition(child)]))
            return registry
        }
        let hooks = ToolHooks(beforeTool: { _, _, _ in scenario == "blocked" ? .init(block: "fixture block") : nil },
            afterTool: { _, result, _, _ in
                var changed = result
                changed.output = [.text(.init(text: "hooked \(scenario)"))]
                return changed
            })
        var tools: [ToolRegistration] = []
        if scenario != "unoffered" && scenario != "missing" {
            let replay: ToolReplay = scenario == "safe-replay" ? .safe : .unsafe
            tools = [try ToolRegistration(name: "echo", description: "Echo",
                parameters: ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]],
                replay: replay, execute: { _, _, _ in .init(output: [.text(.init(text: "ran"))]) })]
        }
        try registry.install(Extension(name: "d6-resume", tools: tools, hooks: [hook(hooks)]))
        return registry
    }
    private func cutoffChild() -> TaskDefinition<JSONValue, D6CutoffCheckpoint, JSONValue, NoTaskHooks> {
        TaskDefinition(name: "d6.after-run-cutoff", version: 1, initial: { _ in .init() },
            phase: { _, _, _ in throw TaskDefinitionError("Cutoff child must not run") },
            abort: { _, _, _ in throw TaskDefinitionError("Cutoff child abort must not run") })
    }
    private func harness(_ storage: any DurableStorage, scenario: String) async throws -> Harness {
        let settings: HarnessSettingsProvider? = scenario == "afterRun-cutoff"
            ? HarnessSettingsProvider { HarnessSettings(restartLimit: 1) } : nil
        let opened = try await Harness.open(storage: storage,
            options: .init(models: FakeDurableModels(), registry: registry(scenario), settings: settings,
                           now: { 1_700_000_000_000 }),
            context: .background)
        opened.tasks.toolServices.setExecutionTime { .zero }
        return opened
    }
    private func copyPre(_ name: String, backend: String, to path: URL) throws {
        let source = directory.appendingPathComponent(name).appendingPathComponent(backend == "sqlite" ? "pre.sqlite" : "pre")
        try FileManager.default.copyItem(at: source, to: path)
    }

    @Test("tagged Node tool task files resume under Swift to equal records", .timeLimit(.minutes(2)),
          arguments: ["unoffered", "missing", "invalid", "blocked", "safe-replay", "unsafe-replay", "restart-limit", "afterRun-cutoff", "nested-restart"], ["sqlite", "jsonl"])
    func swiftResumesTaggedFile(scenario: String, backend: String) async throws {
        let name = "\(scenario)-\(backend)", saved = try item(name)
        let root = try #require(saved["rootId"]).decode(ConversationID.self)
        let taskId = try #require(saved["ids"]?["taskId"]).decode(TaskID.self)
        let temporary = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let path = temporary.appendingPathComponent(backend == "sqlite" ? "resume.sqlite" : "resume")
        try copyPre(name, backend: backend, to: path)
        let storage = try await open(path, backend: backend)
        #expect(try await snapshot(storage, root: root) == saved["pre"])
        let opened = try await harness(storage, scenario: scenario)
        try opened.resume()
        _ = try await opened.waitForTask(id: taskId, context: .background)
        let actual = try await snapshot(storage, root: root)
        // v1.6.0 tool.ts:1178 now applies to the Swift continuation too.
        if let mismatch = difference(actual, try #require(saved["post"])) { Issue.record("\(name): \(mismatch)") }
        try await opened.close(context: .background)
    }

    #if os(macOS)
    @Test("tagged Node resumes Swift written tool task files to equal records", .timeLimit(.minutes(2)),
          arguments: ["unoffered", "missing", "invalid", "blocked", "safe-replay", "unsafe-replay", "restart-limit", "afterRun-cutoff", "nested-restart"], ["sqlite", "jsonl"])
    func taggedNodeResumesSwiftFile(scenario: String, backend: String) async throws {
        let name = "\(scenario)-\(backend)", saved = try item(name)
        let temporary = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let path = temporary.appendingPathComponent(backend == "sqlite" ? "swift.sqlite" : "swift")
        let storage = try await open(path, backend: backend)
        let opened = try await harness(storage, scenario: scenario)
        let root = try await opened.root(options: .init(agent: AgentChange(model: .set(ModelRef(provider: "faux", modelId: "faux-1")))), context: .background)
        if scenario == "nested-restart" {
            let ids = try await root.commit({ tx in
                let model = try #require(saved["pre"]?["entries"]?[0]?["model"]?.arrayValue)
                let assistant = try await tx.appendEntry(root.id, value: EntryDraft(kind: assistantEntry.kind, model: model))
                let parent = try await tx.createTask(toolTask.kind, input: ToolTaskInput.model(assistant: assistant.id, callId: "call-d6"),
                    options: .init(ownership: .conversation()))
                let member = try await tx.doc(NestedCallDoc, taskId: parent, key: "1", seed: nil)
                let call = ToolCall(id: "call-d6/1", name: "leaf", arguments: [:])
                let child = try await tx.createTask(toolTask.kind,
                    input: ToolTaskInput.nested(parent: parent, parentCallId: "call-d6", key: "1", call: call, progress: nil),
                    options: .init(ownership: .task(taskId: parent), abandonOnRestart: false))
                try member.set("taskId", JSONValue(encoding: child))
                let live = try await tx.doc(LiveDoc, conversationId: root.id)
                try live.set("tools", try #require(saved["pre"]?["values"]?[0]?["value"]?["tools"]))
                try live.set("nestedTools", try #require(saved["pre"]?["values"]?[0]?["value"]?["nestedTools"]))
                return (assistant.id, parent, child)
            }, context: .background)
            let expectedAssistant = try #require(saved["ids"]?["assistant"]).decode(EntryID.self)
            let expectedParent = try #require(saved["ids"]?["taskId"]).decode(TaskID.self)
            let expectedChild = try #require(saved["ids"]?["childId"]).decode(TaskID.self)
            #expect(ids.0 == expectedAssistant)
            #expect(ids.1 == expectedParent)
            #expect(ids.2 == expectedChild)
            try await root.commit({ tx in
                for record in try #require(saved["swiftPre"]?["tasks"]?.arrayValue) { try tx.setTask(record.decode(TaskRecord.self)) }
            }, context: .background)
        } else if scenario == "afterRun-cutoff" {
            let ids = try await root.commit({ tx in
                let user = try await tx.appendEntry(root.id, value: EntryDraft(kind: userEntry.kind,
                    model: try #require(saved["pre"]?["entries"]?[0]?["model"]?.arrayValue)))
                let answer = try await tx.appendEntry(root.id, value: EntryDraft(kind: assistantEntry.kind,
                    model: try #require(saved["pre"]?["entries"]?[1]?["model"]?.arrayValue)))
                _ = try await tx.createSubmission(.continue(conversationId: root.id, state: .done(answer: answer.id)))
                let generation = try await createGeneration(tx: tx, conversationId: root.id)
                let child = try await tx.createTask(cutoffChild(), input: .null,
                    options: .init(ownership: .task(taskId: generation)))
                let live = try await tx.doc(LiveDoc, conversationId: root.id)
                try live.set("run", try #require(saved["pre"]?["values"]?[0]?["value"]?["run"]))
                return (user.id, answer.id, generation, child)
            }, context: .background)
            let expectedGeneration = try #require(saved["ids"]?["taskId"]).decode(TaskID.self)
            let expectedChild = try #require(saved["ids"]?["childId"]).decode(TaskID.self)
            #expect(ids.2 == expectedGeneration)
            #expect(ids.3 == expectedChild)
            try await root.commit({ tx in
                for record in try #require(saved["swiftPre"]?["tasks"]?.arrayValue) {
                    try tx.setTask(record.decode(TaskRecord.self))
                }
            }, context: .background)
        } else {
            let ids = try await root.commit({ tx in
                let model = try #require(saved["pre"]?["entries"]?[0]?["model"]?.arrayValue)
                let assistant = try await tx.appendEntry(root.id, value: EntryDraft(kind: assistantEntry.kind, model: model))
                let input: ToolTaskInput = scenario == "unoffered"
                    ? .unofferedModel(assistant: assistant.id, callId: "call-d6")
                    : .model(assistant: assistant.id, callId: "call-d6")
                let taskId = try await tx.createTask(toolTask.kind, input: input, options: .init(ownership: .conversation()))
                let live = try await tx.doc(LiveDoc, conversationId: root.id)
                try live.set("tools", try #require(saved["pre"]?["values"]?[0]?["value"]?["tools"]))
                return (assistant.id, taskId)
            }, context: .background)
            let expectedAssistant = try #require(saved["ids"]?["assistant"]).decode(EntryID.self)
            let expectedTask = try #require(saved["ids"]?["taskId"]).decode(TaskID.self)
            #expect(ids.0 == expectedAssistant)
            #expect(ids.1 == expectedTask)
            if scenario.hasSuffix("replay") || scenario == "restart-limit" {
            try await root.commit({ tx in
                try tx.setTask(try #require(saved["swiftPre"]?["tasks"]?[0]).decode(TaskRecord.self))
            }, context: .background)
            }
        }
        let actual = try await snapshot(storage, root: root.id)
        if let mismatch = difference(actual, try #require(saved["swiftPre"])) { Issue.record("\(name) Swift pre: \(mismatch)"); return }
        try await opened.close(context: .background)

        let log = temporary.appendingPathComponent("node.log")
        #expect(FileManager.default.createFile(atPath: log.path, contents: nil))
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = ["node", generator.path, "--v160", "--resume-swift", name, path.path]
        child.standardOutput = handle; child.standardError = handle
        try child.run(); child.waitUntilExit()
        let output = try String(contentsOf: log, encoding: .utf8)
        #expect(child.terminationStatus == 0, "Node status \(child.terminationStatus): \(output)")
    }
    #endif
}
