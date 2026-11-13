import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

@Suite("PiSwiftDurableTests.D12HarnessStreams", .serialized, .timeLimit(.minutes(1)))
struct D12HarnessStreamTests {
    private func normalized(_ value: JSONValue) -> JSONValue {
        switch value {
        case .array(let items): return .array(items.map(normalized))
        case .object(var fields):
            if fields["role"] == "assistant", fields["api"] != nil { fields["api"] = "<faux-api>" }
            for (key, member) in fields { fields[key] = normalized(member) }
            return .object(fields)
        default: return value
        }
    }
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/durable-fixtures/d12-harness-streams-v152.json")
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
    @Test(arguments: ["text", "thinking", "arguments", "output", "crash", "close"], ["sqlite", "jsonl"])
    func providerStreamCommitsMatchTag(scenario: String, backend: String) async throws {
        let expected = try #require(JSONValue(jsonData: Data(contentsOf: fixture))["cases"]?[scenario])
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage: any DurableStorage = backend == "sqlite"
            ? try await SqliteStorage.open(path: directory.appendingPathComponent("store.sqlite").path)
            : try await JsonlStorage.open(directory: directory.appendingPathComponent("store").path,
                fileSystem: LocalExecutionEnv(cwd: directory.path))
        let controlled = ControlledStorage(storage)
        let manual = scenario == "crash" || scenario == "close"
        let clock = TestClock(now: 1_700_000_000_000)
        let setup = HarnessChatSetup(options: .init(minTokenSize: 100, maxTokenSize: 100),
            settings: .init(retry: .init(enabled: false), progress: .init(
                persistWithinMs: scenario == "crash" ? 150 : .infinity)),
            clock: clock, tagCacheAccounting: true)
        if scenario == "arguments" || scenario == "output" {
            try installHarnessTool(ToolRegistration(name: "echo", description: "Echo",
                parameters: ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]) {
                _, api, _ in
                if scenario == "output" {
                    try api.output(.text("one\n"), nil)
                    try api.output(.text("two\n"), nil)
                }
                return .init(output: [.text(.init(text: "tool done"))])
            }, setup: setup)
        }
        let models = manual ? HarnessManualModels(base: setup.models) : nil
        let opened = try await openChat(storage: controlled, setup: setup, models: models)
        let baselineBatches = await controlled.commitBatches.flatMap { $0 }.count
        let address = DocumentAddress(kind: "pi.live", scope: .conversation(conversationId: opened.root.id))
        let live = try #require(try await controlled.findDocument(address, at: .current, context: .background))
        func response(_ text: String) -> AssistantMessage {
            var message = chatAssistant(text)
            message.timestamp = 1_700_000_000_000
            message.durationMs = 0
            message.thinkingLevel = .off
            return message
        }
        if scenario == "text" { setup.models.setResponses([.message(response("abcd efgh"))]) }
        else if scenario == "thinking" {
            var message = response("done")
            message.content = [.thinking(.init(thinking: "why now")), .text(.init(text: "done"))]
            setup.models.setResponses([.message(message)])
        } else if !manual {
            var call = try toolCalls([("echo", ["text": "hello"], "call-1")])
            call.timestamp = 1_700_000_000_000; call.durationMs = 0; call.thinkingLevel = .off
            setup.models.setResponses([.message(call), .message(response("done"))])
        }
        let submission = try await opened.root.submit(.input(content: .text("go")), context: .background)
        if let models {
            try await eventually { models.seen.withLock { !$0.isEmpty } }
            var partial = chatAssistant("held", reason: .pending)
            partial.timestamp = 1_700_000_000_000
            models.stream.push(.textDelta(contentIndex: 0, delta: "held", partial: partial))
            try await eventually { clock.pendingSleeperCount >= (scenario == "crash" ? 2 : 1) }
            clock.advance(by: 100)
            try await eventually { try await generationLive(opened)?.generation?.message?[
                "content"]?[0]?["text"] == .string("held") }
            if scenario == "crash" {
                let before = await controlled.commitBatches.flatMap { $0 }.count
                clock.advance(by: 150)
                try await eventually { await controlled.commitBatches.flatMap { $0 }.count > before }
                opened.harness.session.fail(D12StreamCrash())
                _ = await opened.harness.closed
            } else { try await opened.harness.close(context: .background) }
        } else {
            #expect(try await submission.wait(context: .background).status == "done")
            try await opened.root.waitForIdle(context: .background)
        }
        let batches = Array((await controlled.commitBatches.flatMap { $0 }).dropFirst(baselineBatches))
        let commits: [JSONValue] = try batches.enumerated().map { index, writes in
            let changes: [JSONValue] = try writes.compactMap { write in
                guard case .documentChange(let id, let content, _) = write, id == live.id else { return nil }
                return try JSONValue(encoding: content)
            }
            return ["seq": .number(Double(baselineBatches + index + 1)), "live": .array(changes)]
        }
        if let mismatch = difference(normalized(.array(commits)), expected) {
            Issue.record("\(scenario)-\(backend): \(mismatch)")
        }
        if !manual { try await opened.harness.close(context: .background) }
    }
}

private struct D12StreamCrash: Error {}
