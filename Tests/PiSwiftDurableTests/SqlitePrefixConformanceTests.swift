import Foundation
import Testing
import PiSwiftDurable
import PiSwiftDurableTesting

private let sqlitePrefixDirectCases = storageConformanceCases { check in
    let directory = try sqliteTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = try await SqliteStorage.open(path: directory.appendingPathComponent("storage.sqlite").path, prefix: "pi_")
    do { try await check(storage) }
    catch { try? await storage.close(context: .background); throw error }
    try await storage.close(context: .background)
}

private let sqlitePrefixReopenCases = storageConformanceCases { check in
    let directory = try sqliteTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("storage.sqlite").path
    let storage = ReopeningStorage(storage: try await SqliteStorage.open(path: path, prefix: "pi_"), path: path, prefix: "pi_")
    do { try await check(storage) }
    catch { try? await storage.close(context: .background); throw error }
    try await storage.close(context: .background)
}

@Suite("PiSwiftDurableTests.SqlitePrefixConformance")
struct SqlitePrefixConformanceTests {
    @Test(arguments: sqlitePrefixDirectCases)
    func direct(_ storageCase: StorageConformanceCase) async throws { try await storageCase.run() }

    @Test(arguments: sqlitePrefixReopenCases)
    func reopen(_ storageCase: StorageConformanceCase) async throws { try await storageCase.run() }
}
