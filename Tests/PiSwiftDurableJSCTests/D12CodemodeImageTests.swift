import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableJSC
import PiSwiftDurableTesting

#if os(macOS)
@Suite("PiSwiftDurableJSCTests.D12CodemodeImage", .serialized, .timeLimit(.minutes(1)))
struct D12CodemodeImageTests {
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/durable-fixtures/d12-codemode-image-v152.json")
    }
    private func normalize(_ value: JSONValue, cwd: String) -> JSONValue {
        switch value {
        case .array(let items): return .array(items.map { normalize($0, cwd: cwd) })
        case .object(var fields):
            if fields["role"] == "assistant", fields["api"] != nil { fields["api"] = "<faux-api>" }
            if fields["role"] == "toolResult", fields["details"] == .null { fields.removeValue(forKey: "details") }
            fields.removeValue(forKey: "durationMs")
            for (key, member) in fields { fields[key] = normalize(member, cwd: cwd) }
            return .object(fields)
        case .string(let string):
            return .string(string.replacingOccurrences(of: cwd, with: "<fixture-cwd>")
                .replacingOccurrences(of: "in a QuickJS sandbox", with: "in the <sandbox>")
                .replacingOccurrences(of: "in an injected sandbox", with: "in the <sandbox>")
                .replacingOccurrences(of: "/[^\\s]*/pi-codemode-[^/\\s]+/image-\\d+\\.png",
                    with: "<saved-image>", options: .regularExpression))
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
    @Test(arguments: ["sqlite", "jsonl"])
    func persistedReadImageConversationMatchesTag(backend: String) async throws {
        let fixture = try JSONValue(jsonData: Data(contentsOf: fixture))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("d12-image-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pngText = try #require(fixture["png"]?.stringValue)
        let png = try #require(Data(base64Encoded: pngText))
        try png.write(to: directory.appendingPathComponent("pixel.png"))
        let storage: any DurableStorage = backend == "sqlite"
            ? try await SqliteStorage.open(path: directory.appendingPathComponent("store.sqlite").path)
            : try await JsonlStorage.open(directory: directory.appendingPathComponent("store").path,
                fileSystem: LocalExecutionEnv(cwd: directory.path))
        let setup = HarnessChatSetup(settings: .init(retry: .init(enabled: false)),
            clock: TestClock(now: 1_700_000_000_000), tagCacheAccounting: true)
        let sandbox = JSCCodemodeSandbox(forceWatchdog: false)
        try setup.registry.install(Extension(name: "d12-codemode", tools: [
            createCodemodeTool(options: .init(sandbox: sandbox)), createReadTool()]))
        let harness = try await Harness.open(storage: storage, options: .init(models: setup.models,
            registry: setup.registry, settings: setup.settingsProvider,
            env: { target, _ in LocalExecutionEnv(cwd: target.cwd ?? directory.path) },
            clock: setup.clock), context: .background)
        let root = try await harness.root(options: .init(agent: .init(
            model: .set(.init(provider: "faux", modelId: "faux-1")), cwd: .set(directory.path))),
            context: .background)
        var call = chatAssistant("", reason: .toolUse)
        call.content = [.toolCall(ToolCall(id: "image-code", name: "codemode",
            arguments: ["code": AnyCodable(try #require(fixture["code"]?.stringValue))]))]
        call.timestamp = 1_700_000_000_000; call.durationMs = 0; call.thinkingLevel = .off
        var answer = chatAssistant("done")
        answer.timestamp = 1_700_000_000_000; answer.durationMs = 0; answer.thinkingLevel = .off
        setup.models.setResponses([.message(call), .message(answer)])
        let receipt = try await root.submit(.input(content: .text("show image")), context: .background).wait(context: .background)
        #expect(receipt.status == "done")
        try await root.waitForIdle(context: .background)
        let tasks = try await storage.scanTasks(.init(order: .ascending), limit: 100, cursor: nil, context: .background)
        let submissions = try await storage.scanSubmissions(.init(order: .ascending), limit: 100, cursor: nil, context: .background)
        let entries = try await storage.scanEntries(.init(conversationId: root.id, order: .ascending),
            limit: 100, cursor: nil, context: .background)
        let documents = try await storage.scanDocuments(.init(scope: .conversation(conversationId: root.id), at: .current),
            limit: 100, cursor: nil, context: .background)
        var values: [JSONValue] = []
        for doc in documents.items {
            let value = try #require(try await storage.document(doc.id, at: .current, context: .background))
            var encoded = try JSONValue(encoding: value)
            if doc.kind == "pi.provider", var object = encoded.objectValue,
               var content = object["value"]?.objectValue {
                content["sessionId"] = "<provider-session-id>"
                object["value"] = .object(content)
                encoded = .object(object)
            }
            values.append(encoded)
        }
        let records: JSONValue = ["tasks": try JSONValue(encoding: tasks.items),
            "submissions": try JSONValue(encoding: submissions.items),
            "entries": try JSONValue(encoding: entries.items),
            "documents": try JSONValue(encoding: documents.items), "values": .array(values)]
        let actual = normalize(records, cwd: directory.path)
        let expected = try #require(fixture["records"])
        if let mismatch = difference(actual, expected) { Issue.record("\(backend): \(mismatch)") }
        try await harness.close(context: .background)
        await sandbox.close()
    }
}
#endif
