import Foundation
import zlib
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

@Suite("PiSwiftDurableTests.D5bEndings", .serialized)
struct D5bEndingFixtureTests {
    private var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/durable-fixtures/d5b-endings-v160")
    }
    private var frozenInputDirectory: URL {
        fixtureDirectory.deletingLastPathComponent().appendingPathComponent("d5b-endings-v152")
    }
    private func item(_ name: String) throws -> JSONValue {
        let data = try Data(contentsOf: fixtureDirectory.appendingPathComponent("manifest.json"))
        let cases = try #require(JSONValue(jsonData: data)["cases"]?.objectValue)
        var item = try #require(cases[name]?.objectValue)
        if let name = item["recordsFrom"]?.stringValue {
            let records = try #require(cases[name]?.objectValue)
            for (key, value) in records where item[key] == nil { item[key] = value }
        }
        return .object(item)
    }
    private func inflateSQLite(_ source: URL, to destination: URL) throws {
        let compressed = try Data(contentsOf: source)
        try #require(compressed.count >= 18)
        let size = compressed.withUnsafeBytes {
            Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: compressed.count - 4, as: UInt32.self)))
        }
        try #require(size > 0 && size <= 10 * 1_024 * 1_024)
        var stream = z_stream()
        let initialized = inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        try #require(initialized == Z_OK)
        defer { inflateEnd(&stream) }
        var uncompressed = Data(count: size)
        let status = compressed.withUnsafeBytes { input in
            uncompressed.withUnsafeMutableBytes { output in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(output.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        try #require(status == Z_STREAM_END && stream.total_out == size)
        try uncompressed.write(to: destination)
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

    private static let endings = ["model_error", "no_model", "aborted", "reset", "faulted", "orphaned",
                                  "interrupted", "restart_limit", "nothing_to_answer", "turn_limit", "answer", "terminate"]
    private static let names = endings.flatMap { ending in ["\(ending)-sqlite", "\(ending)-jsonl"] }
        + ["orphaned-future-sqlite", "orphaned-future-jsonl"]

    @Test(.timeLimit(.minutes(1))) func fixtureMatrixHasEveryEndingOnBothBackends() throws {
        let manifest = try JSONValue(jsonData: Data(contentsOf: fixtureDirectory.appendingPathComponent("manifest.json")))
        #expect(manifest["tag"] == "v1.6.0" && manifest["inputTag"] == "v1.5.2")
        #expect(Set(manifest["cases"]?.objectValue?.keys.map { $0 } ?? []) == Set(Self.names))
        for name in Self.names {
            let value = try item(name), ending = try #require(value["ending"]?.stringValue)
            let post = try #require(value["post"])
            let documents = try #require(post["documents"]?.arrayValue)
            let index = try #require(documents.firstIndex { $0["kind"] == "pi.live" })
            let live = try #require(post["values"]?[index]?["value"])
            #expect(live["run"] == nil)
            if ["answer", "terminate"].contains(ending) {
                #expect(live["runFailure"] == nil)
                #expect(post["submissions"]?[0]?["status"] == "done")
            } else { #expect(live["runFailure"]?["reason"] == .string(ending)) }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: names)
    func swiftResumesTagWrittenEndingFile(name: String) async throws {
        let item = try item(name), backend = try #require(item["backend"]?.stringValue)
        let root = try #require(item["rootId"]).decode(ConversationID.self)
        let task = try #require(item["ids"]?["taskId"]).decode(TaskID.self)
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // v1.6.0 D1: generation.ts:184-194 migrates the same frozen v1.5.2 input to v3.
        // The new future-v4 orphaned case follows scheduler.ts:2178-2185.
        let sourceDirectory = name.hasPrefix("orphaned-future") ? fixtureDirectory : frozenInputDirectory
        let source = sourceDirectory.appendingPathComponent(name).appendingPathComponent(backend == "sqlite" ? "pre.sqlite.gz" : "pre")
        let path = directory.appendingPathComponent(backend == "sqlite" ? "resume.sqlite" : "resume")
        if backend == "sqlite" { try inflateSQLite(source, to: path) }
        else { try FileManager.default.copyItem(at: source, to: path) }
        let storage = try await open(path, backend: backend)
        #expect(try await snapshot(storage, root: root) == item["pre"])
        let ending = try #require(item["ending"]?.stringValue)
        let models = FakeDurableModels()
        let provider: HarnessModelsProvider = {
            if ending == "faulted" { throw TaskDefinitionError("Fixture model provider failed") }
            return models
        }
        let harness = try await Harness.open(storage: storage,
            options: .init(models: provider, registry: createRegistry(),
                           settings: .init { .init(retry: .init(enabled: false)) }, now: { 1_700_000_000_000 }), context: .background)
        try harness.resume()
        _ = try await harness.waitForTask(id: task, context: .background)
        let after = try await snapshot(storage, root: root)
        let matches = after == item["post"]
        #expect(matches, "Tag and Swift records differ for \(name): \(difference(after, item["post"] ?? .null) ?? "none")")
        try await harness.close(context: .background)
    }

}
