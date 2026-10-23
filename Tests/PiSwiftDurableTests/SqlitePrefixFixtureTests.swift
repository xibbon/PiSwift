import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurable

extension PiSwiftDurableTests {
    private func comparePrefixReads(_ storage: SqliteStorage) async throws {
        for (index, read) in try #require(fixture()["reads"]?.arrayValue).enumerated() {
            let method = try #require(read["method"]?.stringValue)
            let args = try #require(read["arguments"]?.arrayValue)
            let actual = try await sqliteReplayRead(method, args: args, storage: storage)
            #expect(actual == read["result"], "Upstream prefixed read \(index + 1): \(method)")
        }
    }

    private func writePrefixFile(_ path: String) async throws {
        let storage = try await SqliteStorage.open(path: path, prefix: "pi_")
        do {
            for batch in try #require(fixture()["batches"]?.arrayValue) {
                let writes = try #require(batch["writes"]).decode([StorageWrite].self)
                #expect(try JSONValue(encoding: await storage.commit(writes, context: .background)) == batch["seq"])
            }
            try await comparePrefixReads(storage)
        } catch { try? await storage.close(context: .background); throw error }
        try await storage.close(context: .background)
        let reopened = try await SqliteStorage.open(path: path, prefix: "pi_")
        do { try await comparePrefixReads(reopened) }
        catch { try? await reopened.close(context: .background); throw error }
        try await reopened.close(context: .background)
    }

    @Test func sqliteReadsPrefixedUpstreamFileAcrossReopen() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try #require(Bundle.module.url(forResource: "prefix-upstream-v130", withExtension: "sqlite", subdirectory: "Fixtures"))
        let path = directory.appendingPathComponent("prefix.sqlite").path
        try FileManager.default.copyItem(atPath: source.path, toPath: path)
        for _ in 0..<2 {
            let storage = try await SqliteStorage.open(path: path, prefix: "pi_")
            do { try await comparePrefixReads(storage) }
            catch { try? await storage.close(context: .background); throw error }
            try await storage.close(context: .background)
        }
    }

    @Test func sqlitePrefixedStorageMatchesEveryUpstreamRead() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await writePrefixFile(directory.appendingPathComponent("prefix.sqlite").path)
    }

    @Test func sqlitePrefixExportForUpstreamRead() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_DURABLE_PREFIX_SQLITE_EXPORT"] else { return }
        try await writePrefixFile(path)
    }
}
