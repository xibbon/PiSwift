import Foundation
import Testing
import PiSwiftDurable
import PiSwiftDurableTesting

func sqliteTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-durable-sqlite-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private let sqliteDirectCases = storageConformanceCases { check in
    let directory = try sqliteTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = try await SqliteStorage.open(path: directory.appendingPathComponent("storage.sqlite").path)
    do { try await check(storage) }
    catch { try? await storage.close(context: .background); throw error }
    try await storage.close(context: .background)
}

private let sqliteReopenCases = storageConformanceCases { check in
    let directory = try sqliteTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("storage.sqlite").path
    let storage = ReopeningStorage(storage: try await SqliteStorage.open(path: path), path: path)
    do { try await check(storage) }
    catch { try? await storage.close(context: .background); throw error }
    try await storage.close(context: .background)
}

@Suite("PiSwiftDurableTests.SqliteConformance")
struct SqliteConformanceTests {
    @Test(arguments: sqliteDirectCases)
    func direct(_ storageCase: StorageConformanceCase) async throws { try await storageCase.run() }

    @Test(arguments: sqliteReopenCases)
    func reopen(_ storageCase: StorageConformanceCase) async throws { try await storageCase.run() }
}
