import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite("PiSwiftDurableTests.D5bPlainByteProbe", .serialized)
struct D5bPlainByteProbeTests {
    private func changedPaths(_ old: JSONValue?, _ new: JSONValue?, at path: String = "$") -> [String] {
        guard let old, let new else { return [path] }
        if old == new { return [] }
        if let before = old.objectValue, let after = new.objectValue {
            return Set(before.keys).union(after.keys).sorted().flatMap { key in
                changedPaths(before[key], after[key], at: "\(path).\(key)")
            }
        }
        if let before = old.arrayValue, let after = new.arrayValue, before.count == after.count {
            return before.indices.flatMap { index in changedPaths(before[index], after[index], at: "\(path)[\(index)]") }
        }
        return [path]
    }

    private func normalized(_ value: JSONValue) -> JSONValue {
        switch value {
        case .array(let values): return .array(values.map(normalized))
        case .object(let fields):
            var result = JSONObject()
            for (key, field) in fields {
                result[key] = key == "sessionId" ? .string("<provider-session-id>") : normalized(field)
            }
            return .object(result)
        default: return value
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["sqlite", "jsonl"])
    func twoTurnPlainHarnessCommitBytes(backend: String) async throws {
        // D5b Round 1: run this identical source at 1de58fd and in the D5b tree.
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base: any DurableStorage
        if backend == "sqlite" { base = try await SqliteStorage.open(path: directory.appendingPathComponent("plain.sqlite").path) }
        else { base = try await JsonlStorage.open(directory: directory.path, fileSystem: LocalExecutionEnv(cwd: directory.path)) }
        let storage = ControlledStorage(base)
        let setup = HarnessChatSetup(clock: TestClock(now: 1_700_000_000_000))
        setup.models.setResponses([.message(chatAssistant("first answer")), .message(chatAssistant("second answer"))])
        let chat = try await openChat(storage: storage, setup: setup)
        #expect(try await generationSubmit(chat, "first question").wait(context: .background).status == "done")
        #expect(try await generationSubmit(chat, "second question").wait(context: .background).status == "done")
        try await chat.harness.close(context: .background)
        let current = normalized(try JSONValue(encoding: await storage.commits))
        let bytes = try current.jsonText() + "\n"
        if let destination = ProcessInfo.processInfo.environment["D5B_PLAIN_BYTES_DIR"] {
            let url = URL(fileURLWithPath: destination).appendingPathComponent("plain-\(backend).json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url, atomically: true, encoding: .utf8)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let baseline = root.appendingPathComponent("Scripts/durable-fixtures/d5b-plain-pre/plain-\(backend).json")
        if FileManager.default.fileExists(atPath: baseline.path) {
            let before = try JSONValue(jsonData: Data(contentsOf: baseline))
            // v1.5.2 D7 generation.ts:276-286 and session.ts:1091-1101: each cleared pi.live progress
            // commit is held and folded into the next stored commit. All other bytes keep the D5b diff.
            var prior = try #require(before.arrayValue)
            prior.remove(at: 9); prior.remove(at: 4)
            #expect(Set(changedPaths(.array(prior), current)) == Set([
                "$[1][3].content.value.run.first", "$[4][0].value.model[0].thinkingLevel",
                "$[5][3].content.value.run.first", "$[8][0].value.model[0].thinkingLevel"
            ]))
            #expect(current[1]?[3]?["content"]?["value"]?["run"]?["first"] == 7)
            #expect(current[5]?[3]?["content"]?["value"]?["run"]?["first"] == 11)
            #expect(current[4]?[0]?["value"]?["model"]?[0]?["thinkingLevel"] == "off")
            #expect(current[8]?[0]?["value"]?["model"]?[0]?["thinkingLevel"] == "off")
        }
        #expect(bytes.utf8.count > 100)
    }
}
