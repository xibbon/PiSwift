import Testing
import PiSwiftDurable
import PiSwiftDurableTesting

private let memoryStorageCases = storageConformanceCases { check in
    try await check(MemoryStorage())
}

@Suite("PiSwiftDurableTests.StorageConformance")
struct StorageConformanceTests {
    @Test(arguments: memoryStorageCases)
    func storageConformance(_ storageCase: StorageConformanceCase) async throws {
        try await storageCase.run()
    }
}
