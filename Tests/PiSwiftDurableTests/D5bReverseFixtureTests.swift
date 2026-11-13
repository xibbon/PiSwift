import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

#if os(macOS)
/// Swift writes each pre-event file. The unmodified tag resumes a copy.
@Suite("PiSwiftDurableTests.D5bReverseFixtures", .serialized)
struct D5bReverseFixtureTests {
    private let clock: Int64 = 1_700_000_000_000
    private let scenarios = ["continue", "turn-limit", "model-error-retry", "host-death-request", "interrupted-poll", "handoff"]
    private let endings = ["model_error", "no_model", "aborted", "reset", "faulted", "orphaned",
                           "interrupted", "restart_limit", "nothing_to_answer", "turn_limit", "answer", "terminate"]
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/durable-fixtures/d5b-reverse-v152")
    }
    private func open(_ path: URL, backend: String) async throws -> any DurableStorage {
        if backend == "jsonl" {
            return try await JsonlStorage.open(directory: path.path, fileSystem: LocalExecutionEnv(cwd: path.path))
        }
        return try await SqliteStorage.open(path: path.path)
    }
    /// Replay the tagged ending records through Swift storage into a fresh file.
    /// The tag checks the stored preimage and resumes this Swift-written file.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PISWIFT_D12_ENDING_EXPORT"] != nil),
          .timeLimit(.minutes(3)))
    func exportsSwiftWrittenEndingFiles() async throws {
        let environment = ProcessInfo.processInfo.environment
        let seedDirectory = URL(fileURLWithPath: try #require(environment["PISWIFT_D12_ENDING_SEEDS"]))
        let exportDirectory = URL(fileURLWithPath: try #require(environment["PISWIFT_D12_ENDING_EXPORT"]))
        let fixture = fixtures.deletingLastPathComponent().appendingPathComponent("d5b-endings-v152/manifest.json")
        let cases = try #require(JSONValue(jsonData: Data(contentsOf: fixture))["cases"]?.objectValue)
        for ending in endings { for backend in ["sqlite", "jsonl"] {
            let name = "\(ending)-\(backend)"
            var item = try #require(cases[name]?.objectValue)
            if let sourceName = item["recordsFrom"]?.stringValue {
                let source = try #require(cases[sourceName]?.objectValue)
                for (key, value) in source where item[key] == nil { item[key] = value }
            }
            let pre = try #require(item["pre"]), root = try #require(item["rootId"]).decode(ConversationID.self)
            let sourcePath = seedDirectory.appendingPathComponent(name).appendingPathComponent(backend == "sqlite" ? "pre.sqlite" : "pre")
            let source = try await open(sourcePath, backend: backend)
            let conversation = try #require(await source.conversation(root, context: .background))
            let destinationDirectory = exportDirectory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            let destinationPath = destinationDirectory.appendingPathComponent(backend == "sqlite" ? "pre.sqlite" : "pre")
            let destination = try await open(destinationPath, backend: backend)
            var first: [StorageWrite] = [.conversation(value: conversation)]
            let documents = try #require(pre["documents"]?.arrayValue)
            let values = try #require(pre["values"]?.arrayValue)
            #expect(documents.count == values.count)
            for (raw, stored) in zip(documents, values) {
                let record = try raw.decode(DocumentRecord.self)
                let value = try #require(stored["value"]?.objectValue)
                let base: JSONObject = ending == "reset" && record.kind == "pi.inbox" ? ["items": []] : value
                let create = DocumentCreate(id: record.id, kind: record.kind, scope: record.scope,
                    key: record.key, history: record.history, fork: record.fork, extensionFields: record.extensionFields)
                first.append(.documentCreate(record: create, content: .init(
                    version: try #require(stored["version"]?.intValue), value: base)))
            }
            _ = try await destination.commitOne(first, context: .background)
            var second: [StorageWrite] = []
            for raw in try #require(pre["entries"]?.arrayValue) {
                second.append(.entry(value: try raw.decode(EntryRecord.self)))
            }
            for raw in try #require(pre["submissions"]?.arrayValue) {
                second.append(.submission(value: try raw.decode(SubmissionRecord.self)))
            }
            if ending == "reset", let index = documents.firstIndex(where: { $0["kind"] == "pi.inbox" }) {
                let id = try #require(documents[index]["id"]).decode(DocumentID.self)
                let items = try #require(values[index]["value"]?["items"])
                second.append(.documentChange(id: id, content: .delta(version: 1,
                    ops: [.set([.key("items")], items)])))
            }
            _ = try await destination.commitOne(second, context: .background)
            let tasks = try #require(pre["tasks"]?.arrayValue).map { StorageWrite.task(value: try $0.decode(TaskRecord.self)) }
            _ = try await destination.commitOne(tasks, context: .background)
            try await source.close(context: .background)
            try await destination.close(context: .background)
        } }
    }
    /// The tag writes three pre-event files; Swift resumes each saved event.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PISWIFT_D12_TAGGED_PRE_EVENTS"] != nil),
          .timeLimit(.minutes(1)))
    func swiftContinuesTagWrittenPreEvents() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PISWIFT_D12_TAGGED_PRE_EVENTS"]))
        let manifest = try JSONValue(jsonData: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
        let cases = try #require(manifest["cases"]?.objectValue)
        let resumeClock = Int64(try #require(manifest["resumeClock"]?.intValue))
        for scenario in ["continue", "turn-limit", "handoff"] { for backend in ["sqlite", "jsonl"] {
            let name = "\(scenario)-\(backend)", item = try #require(cases[name])
            let path = directory.appendingPathComponent(name).appendingPathComponent(backend == "sqlite" ? "pre.sqlite" : "pre")
            let reader = try await open(path, backend: backend)
            let root = try #require(item["rootId"]).decode(ConversationID.self)
            #expect(try await snapshot(reader, root: root) == item["pre"])
            try await reader.close(context: .background)
            let setup = try setup(scenario, at: resumeClock)
            if scenario == "handoff" {
                setup.models.setResponses([.message(try call(at: resumeClock)), .message(message("answer", at: resumeClock))])
            } else { setup.models.setResponses([.message(message("answer", at: resumeClock))]) }
            let chat = try await openChat(storage: open(path, backend: backend), setup: setup)
            let result: SubmissionRecord
            if scenario == "handoff" {
                try chat.harness.resume()
                let id = try #require(item["submissionId"]).decode(SubmissionID.self)
                let submission = try #require(await chat.harness.submission(id: id, context: .background))
                result = try await submission.wait(context: .background).record
            } else {
                result = try await chat.root.submit(.continue(), context: .background).wait(context: .background).record
            }
            try await chat.root.waitForIdle(context: .background)
            let actualResult = normalize(try JSONValue(encoding: result)), expectedResult = try #require(item["result"])
            #expect(actualResult == expectedResult, "\(name): \(difference(actualResult, expectedResult) ?? "none")")
            let actualPost = try await snapshot(chat.harness.session.storage, root: chat.root.id), expectedPost = try #require(item["post"])
            #expect(actualPost == expectedPost, "\(name): \(difference(actualPost, expectedPost) ?? "none")")
            try await chat.harness.close(context: .background)
        } }
    }
    private func normalize(_ value: JSONValue) -> JSONValue {
        switch value {
        case .array(let values): return .array(values.map(normalize))
        case .object(var fields):
            if fields["role"] == "assistant", fields["api"] != nil { fields["api"] = "<faux-api>" }
            if fields["role"] == "toolResult", fields["details"] == .null { fields.removeValue(forKey: "details") }
            for (key, child) in fields { fields[key] = normalize(child) }
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
    private func snapshot(_ storage: any DurableStorage, root: ConversationID) async throws -> JSONValue {
        let tasks = try await storage.scanTasks(.init(order: .ascending), limit: 100, cursor: nil, context: .background)
        let submissions = try await storage.scanSubmissions(.init(order: .ascending), limit: 100, cursor: nil, context: .background)
        let entries = try await storage.scanEntries(.init(conversationId: root, order: .ascending), limit: 100, cursor: nil, context: .background)
        let documents = try await storage.scanDocuments(.init(scope: .conversation(conversationId: root), at: .current), limit: 100, cursor: nil, context: .background)
        #expect(tasks.next == nil && submissions.next == nil && entries.next == nil && documents.next == nil)
        var values: [JSONValue] = []
        for doc in documents.items {
            var value = try JSONValue(encoding: await storage.document(doc.id, at: .current, context: .background))
            if doc.kind == "pi.provider", var object = value.objectValue, var content = object["value"]?.objectValue {
                content["sessionId"] = "<provider-session-id>"; object["value"] = .object(content); value = .object(object)
            }
            values.append(value)
        }
        return normalize(["conversation": try JSONValue(encoding: await storage.conversation(root, context: .background)),
            "tasks": try JSONValue(encoding: tasks.items), "submissions": try JSONValue(encoding: submissions.items),
            "entries": try JSONValue(encoding: entries.items), "documents": try JSONValue(encoding: documents.items), "values": .array(values)])
    }
    private func message(_ text: String, at: Int64, reason: StopReason = .stop) -> AssistantMessage {
        var result = chatAssistant(text, reason: reason)
        result.timestamp = at; result.durationMs = 0; result.thinkingLevel = .off
        return result
    }
    private func setup(_ scenario: String, at: Int64) throws -> HarnessChatSetup {
        let setup = HarnessChatSetup(settings: .init(retry: .init(enabled: scenario == "model-error-retry", maxRetries: 1, baseDelayMs: 1_000)),
            clock: TestClock(now: at), tagCacheAccounting: true)
        if scenario == "turn-limit" || scenario == "handoff" {
            try installHarnessTool(ToolRegistration(name: "echo", description: "Echo",
                parameters: ["type": "object", "properties": [:]], execute: { _, _, _ in
                    .init(output: [.text(.init(text: "tool output"))],
                          control: scenario == "handoff" ? .init(handoff: "fresh-16") : nil)
                }), setup: setup)
        }
        return setup
    }
    private func call(at: Int64) throws -> AssistantMessage {
        var result = try toolCalls([("echo", [:], "call-reverse")])
        result.timestamp = at; result.durationMs = 0; result.thinkingLevel = .off
        return result
    }
    private func generate(_ scenario: String, backend: String, directory: URL) async throws -> JSONValue {
        let name = "\(scenario)-\(backend)", caseDirectory = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: caseDirectory, withIntermediateDirectories: true)
        let path = caseDirectory.appendingPathComponent(backend == "sqlite" ? "pre.sqlite" : "pre")
        let firstSetup = try setup(scenario, at: clock)
        let first = try await openChat(storage: open(path, backend: backend), setup: firstSetup)
        var savedSubmission: SubmissionID?
        var savedTask: TaskID?
        if scenario == "continue" || scenario == "model-error-retry" {
            var error = message("", at: clock, reason: .error)
            error.content = []; error.errorMessage = scenario == "continue" ? "Invalid request" : "503 service unavailable"
            firstSetup.models.setResponses([.message(error)])
            let submission = try await first.root.submit(.input(content: .text("question")), context: .background)
            savedSubmission = submission.id
            if scenario == "continue" {
                #expect(try await submission.wait(context: .background).reason == "model_error")
            } else {
                try await harnessEventually {
                    try await first.harness.inspect(context: .background).tasks.contains { $0.record.state.status == "sleeping" }
                }
                savedTask = try #require(await generationLive(first)?.run?.taskId)
            }
        } else if scenario == "turn-limit" {
            try await first.root.configure(change: .init(maxTurns: .set(1)), context: .background)
            firstSetup.models.setResponses([.message(try call(at: clock))])
            let submission = try await first.root.submit(.input(content: .text("question")), context: .background)
            savedSubmission = submission.id
            #expect(try await submission.wait(context: .background).reason == "turn_limit")
        } else {
            let seeded = try await first.root.commit({ tx in
                let user = try await tx.appendEntry(first.root.id, value: EntryDraft(kind: userEntry.kind,
                    model: [["role": "user", "content": "question", "timestamp": .number(Double(clock))]]))
                let submission = try await tx.createSubmission(.input(conversationId: first.root.id, state: .placed(entry: user.id)))
                let task = try await createGeneration(tx: tx, conversationId: first.root.id)
                let live = try await tx.doc(LiveDoc, conversationId: first.root.id)
                try live.set("run", JSONValue(encoding: LiveRun(taskId: task, inputs: [submission.id], first: user.id)))
                if scenario == "host-death-request" {
                    let partial = try #require(EntryRecord.encodeMessages([.assistant(message("partial", at: clock))]).first?.objectValue)
                    try live.set("generation", JSONValue(encoding: LiveGeneration(attempt: 1, message: partial)))
                }
                return (submission.id, task, user.id)
            }, context: .background)
            savedSubmission = seeded.0; savedTask = seeded.1
            // Close before writing a running checkpoint, to keep the dead-host image intact.
            try await first.harness.close(context: .background)
            let storage = try await open(path, backend: backend)
            let record = try #require(await storage.task(seeded.1, context: .background))
            let checkpoint: GenerationCheckpoint
            if scenario == "handoff" { checkpoint = .init(phase: .prepare, attempt: 1) }
            else if scenario == "host-death-request" {
                checkpoint = .init(phase: .request, attempt: 1, model: .init(provider: "faux", modelId: "faux-1"),
                    thinkingLevel: .off, streamOptions: .init(), cutoff: seeded.2)
            } else {
                checkpoint = .init(phase: .poll, attempt: 1, model: .init(provider: "faux", modelId: "faux-1"),
                    thinkingLevel: .off, cutoff: seeded.2,
                    handle: .init(.init(provider: "faux", modelId: "faux-1", api: "fixture-faux", id: "deferred:reverse")), pollAt: clock)
            }
            let state: TaskState = scenario == "handoff" ? .pending(checkpoint: try JSONValue(encoding: checkpoint)) :
                .running(checkpoint: try JSONValue(encoding: checkpoint))
            _ = try await storage.commitOne([.task(value: record.replacing(state: state))], context: .background)
            try await storage.close(context: .background)
        }
        if ["continue", "turn-limit", "model-error-retry"].contains(scenario) { try await first.harness.close(context: .background) }
        let reader = try await open(path, backend: backend)
        let pre = try await snapshot(reader, root: first.root.id)
        try await reader.close(context: .background)
        let ownPath = caseDirectory.appendingPathComponent(backend == "sqlite" ? "swift-post.sqlite" : "swift-post")
        try FileManager.default.copyItem(at: path, to: ownPath)
        let resumedSetup = try setup(scenario, at: clock + 1_000)
        if scenario == "handoff" { resumedSetup.models.setResponses([.message(try call(at: clock + 1_000)), .message(message("answer", at: clock + 1_000))]) }
        else { resumedSetup.models.setResponses([.message(message("answer", at: clock + 1_000))]) }
        let resumed = try await openChat(storage: open(ownPath, backend: backend), setup: resumedSetup)
        let result: SubmissionRecord
        if scenario == "continue" || scenario == "turn-limit" {
            result = try await resumed.root.submit(.continue(), context: .background).wait(context: .background).record
        } else {
            try resumed.harness.resume()
            let submissionId = try #require(savedSubmission)
            let receipt = try #require(await resumed.harness.submission(id: submissionId, context: .background))
            result = try await receipt.wait(context: .background).record
        }
        try await resumed.root.waitForIdle(context: .background)
        let post = try await snapshot(resumed.harness.session.storage, root: resumed.root.id)
        let encodedResult = normalize(try JSONValue(encoding: result))
        let tasks = try #require(post["tasks"]?.arrayValue)
        #expect(tasks.allSatisfy { $0["state"]?["status"] == "terminal" })
        if scenario == "host-death-request" || scenario == "interrupted-poll" {
            #expect(encodedResult["status"] == "unanswered" && encodedResult["reason"] == "interrupted")
            #expect(resumedSetup.models.calls().streamSimple == 0)
            #expect(resumedSetup.models.calls().fetchDeferred == 0)
            if scenario == "interrupted-poll" {
                #expect(resumedSetup.models.state().cancelledDeferred.map(\.id) == ["deferred:reverse"])
            } else {
                let entries = try await allEntries(resumed.root)
                #expect(entries.count == 2)
                let partial = try #require(entries.last?.messages()?.first)
                #expect(textOf(partial) == "partial")
                if case .assistant(let message) = partial { #expect(message.stopReason == .aborted) }
                else { Issue.record("Expected the saved assistant partial") }
            }
        } else {
            #expect(encodedResult["status"] == "done")
            #expect(resumedSetup.models.calls().streamSimple == (scenario == "handoff" ? 2 : 1))
            if scenario == "handoff" {
                #expect(try await allEntries(resumed.root).filter { $0.kind == resetEntry.kind }.count == 1)
            }
        }
        try await resumed.harness.close(context: .background)
        let item: JSONValue = ["scenario": .string(scenario), "backend": .string(backend),
            "rootId": try JSONValue(encoding: first.root.id),
            "submissionId": try JSONValue(encoding: savedSubmission), "taskId": try JSONValue(encoding: savedTask),
            "pre": pre, "post": post, "result": encodedResult]
        try JSONEncoder().encode(item).write(to: caseDirectory.appendingPathComponent("case.json"))
        return item
    }

    @Test(.timeLimit(.minutes(5)))
    func swiftFilesResumeUnderTheUnmodifiedTag() async throws {
        let export = ProcessInfo.processInfo.environment["PISWIFT_D5B_REVERSE_EXPORT"]
        let directory = try export.map { URL(fileURLWithPath: $0) } ?? sqliteTestDirectory()
        defer { if export == nil { try? FileManager.default.removeItem(at: directory) } }
        var cases: JSONObject = [:]
        for scenario in scenarios { for backend in ["sqlite", "jsonl"] {
            cases["\(scenario)-\(backend)"] = try await generate(scenario, backend: backend, directory: directory)
        } }
        let manifest: JSONValue = ["tag": "v1.5.2", "clock": .number(Double(clock)), "resumeClock": .number(Double(clock + 1_000)),
            "normalization": "Provider session UUID; faux assistant API; absent tool result details", "cases": .object(cases)]
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
        if export == nil {
            let saved = try JSONValue(jsonData: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
            #expect(manifest == saved, "Swift reverse fixture records changed")
            let log = directory.appendingPathComponent("node.log")
            #expect(FileManager.default.createFile(atPath: log.path, contents: nil))
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node", fixtures.deletingLastPathComponent().appendingPathComponent("generate-d5b-reverse-v152.mjs").path,
                "--verify-swift", directory.path]
            process.standardOutput = handle; process.standardError = handle
            try process.run()
            // Bound the child separately: Swift Testing time limits do not stop Process.waitUntilExit.
            for _ in 0..<1_200 {
                if !process.isRunning { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning { process.terminate(); throw TestDeadlineError() }
            let output = try String(contentsOf: log, encoding: .utf8)
            #expect(process.terminationStatus == 0, "Node status \(process.terminationStatus): \(output)")
        }
    }
}
#endif
