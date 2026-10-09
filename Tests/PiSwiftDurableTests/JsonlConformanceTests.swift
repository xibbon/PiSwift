import Foundation
import Testing
import PiSwiftDurable
import PiSwiftDurableTesting

func jsonlTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-durable-jsonl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private let jsonlDirectCases = storageConformanceCases { check in
    let directory = try jsonlTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = try await JsonlStorage.open(directory: directory.path, fileSystem: LocalExecutionEnv(cwd: directory.path))
    do { try await check(storage) }
    catch { try? await storage.close(context: .background); throw error }
    try await storage.close(context: .background)
}

private let jsonlReopenCases = storageConformanceCases { check in
    let directory = try jsonlTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.path
    let storage = JsonlReopeningStorage(storage: try await JsonlStorage.open(directory: path, fileSystem: LocalExecutionEnv(cwd: path)), directory: path)
    do { try await check(storage) }
    catch { try? await storage.close(context: .background); throw error }
    try await storage.close(context: .background)
}

@Suite("PiSwiftDurableTests.JsonlConformance")
struct JsonlConformanceTests {
    @Test(arguments: jsonlDirectCases)
    func direct(_ storageCase: StorageConformanceCase) async throws { try await storageCase.run() }

    @Test(arguments: jsonlReopenCases)
    func reopen(_ storageCase: StorageConformanceCase) async throws { try await storageCase.run() }
}
