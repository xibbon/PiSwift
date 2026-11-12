import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

@Suite("PiSwiftDurableTests.D5bConversations", .serialized)
struct D5bConversationFixtureTests {
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/durable-fixtures/d5b-conversations-v152.json")
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
                // The faux provider registers an ephemeral API key on each runtime.
                fields["api"] = "<faux-api>"
            }
            if fields["role"]?.stringValue == "toolResult", fields["details"] == .null {
                // The Swift message codec retains a null optional field.
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

    @Test(.timeLimit(.minutes(5)))
    func twentySeededConversationsMatchTaggedRecords() async throws {
        let data = try Data(contentsOf: fixture)
        let scripts = try #require(JSONValue(jsonData: data)["scripts"]?.arrayValue)
        #expect(scripts.count == 20)
        #expect(Set(scripts.compactMap { $0["seed"]?.intValue }) == Set(0..<20))
        #expect(Set(scripts.compactMap { $0["kind"]?.stringValue }) ==
                Set(["simple", "continue", "tool", "turnLimit", "handoff", "followUp", "abort", "compaction"]))
        for script in scripts {
            let seed = try #require(script["seed"]?.intValue)
            let kind = try #require(script["kind"]?.stringValue)
            for backend in ["sqlite", "jsonl"] {
                let directory = try sqliteTestDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }
                let storage: any DurableStorage
                if backend == "sqlite" { storage = try await SqliteStorage.open(path: directory.appendingPathComponent("store.sqlite").path) }
                else { storage = try await JsonlStorage.open(directory: directory.path, fileSystem: LocalExecutionEnv(cwd: directory.path)) }
                let setup = HarnessChatSetup(settings: .init(retry: .init(enabled: false),
                    compaction: kind == "compaction" ? .init(enabled: false, keepRecentTokens: 1) : nil), clock: TestClock(now: 1_700_000_000_000),
                                             tagCacheAccounting: true)
                if ["tool", "turnLimit", "handoff"].contains(kind) {
                    let handoff = kind == "handoff" ? "fresh-\(seed)" : nil
                    try installHarnessTool(ToolRegistration(name: "echo", description: "Echo",
                        parameters: ["type": "object", "properties": [:]], execute: { _, _, _ in
                        .init(output: [.text(.init(text: "tool output"))],
                              control: handoff.map { .init(handoff: $0) })
                    }), setup: setup)
                }
                let chat = try await openChat(storage: storage, setup: setup)
                if kind == "turnLimit" {
                    try await chat.root.configure(change: .init(maxTurns: .set(1)), context: .background)
                }
                func answer() -> AssistantMessage {
                    var message = chatAssistant("answer-\(seed)")
                    message.timestamp = 1_700_000_000_000
                    message.durationMs = 0
                    message.thinkingLevel = .off
                    return message
                }
                let reached = HarnessChatSignal(), held = HarnessChatSignal()
                if kind == "followUp" || kind == "abort" {
                    let reply = answer()
                    setup.models.setResponses([.factory { _, options, _, _ in
                        reached.signal()
                        let remove = options?.signal?.onCancel { held.signal() }
                        defer { remove?() }
                        if options?.signal?.isCancelled == true { held.signal() }
                        await held.wait()
                        return reply
                    }, .message(reply)])
                } else if kind == "compaction" {
                    var summary = answer()
                    summary.content = [.text(.init(text: "summary-\(seed)"))]
                    setup.models.setResponses([.message(answer()), .message(answer()), .message(summary), .message(answer())])
                } else if kind == "simple" { setup.models.setResponses([.message(answer())]) }
                else if kind == "continue" {
                    var failure = chatAssistant("", reason: .error, error: "invalid-\(seed)")
                    failure.content = []; failure.timestamp = 1_700_000_000_000; failure.durationMs = 0; failure.thinkingLevel = .off
                    setup.models.setResponses([.message(failure)])
                } else {
                    var call = try toolCalls([("echo", [:], "call-\(seed)")])
                    call.timestamp = 1_700_000_000_000; call.durationMs = 0; call.thinkingLevel = .off
                    setup.models.setResponses([.message(call), .message(answer())])
                }
                let input = try await chat.root.submit(.input(content: .text("question-\(seed)")), context: .background)
                if kind == "followUp" || kind == "abort" {
                    await reached.wait()
                    if kind == "followUp" {
                        let next = try await chat.root.submit(.input(content: .text("follow-up-\(seed)")), context: .background)
                        let queued = try await next.status(context: .background)
                        #expect(queued.status == "queued")
                        #expect(normalized(try JSONValue(encoding: queued)) == normalized(try #require(script["queued"])))
                        held.signal()
                        _ = try await input.wait(context: .background)
                        _ = try await next.wait(context: .background)
                    } else {
                        try await chat.root.abort(context: .background)
                        #expect(try await input.wait(context: .background).reason == "aborted")
                    }
                } else {
                    _ = try await input.wait(context: .background)
                    if kind == "continue" {
                        setup.models.setResponses([.message(answer())])
                        _ = try await chat.root.submit(.continue(), context: .background).wait(context: .background)
                    } else if kind == "turnLimit" {
                        _ = try await chat.root.submit(.continue(), context: .background).wait(context: .background)
                    } else if kind == "compaction" {
                        _ = try await chat.root.submit(.input(content: .text("history-\(seed)")), context: .background).wait(context: .background)
                        let compacted = try await chat.harness.waitForTask(id: chat.root.compact(context: .background), context: .background)
                        #expect(compacted.outcome.status == "completed")
                        _ = try await chat.root.submit(.input(content: .text("after-summary-\(seed)")), context: .background).wait(context: .background)
                        #expect(try await allEntries(chat.root).contains { $0.kind == "pi.compaction" })
                    }
                }
                try await chat.root.waitForIdle(context: .background)
                let actual = normalized(try await snapshot(storage, root: chat.root.id))
                let expected = normalized(try #require(script["records"]))
                if let mismatch = difference(actual, expected) {
                    Issue.record("seed \(seed), \(kind), \(backend): \(mismatch)")
                    return
                }
                try await chat.harness.close(context: .background)
            }
        }
    }
}
