import Foundation
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

@Suite("PiSwiftDurableTests.D12PrefixRecords")
struct D12PrefixRecordTests {
    @Test(.timeLimit(.minutes(1)))
    func taggedAndSwiftPrefixedRecordFilesAgree() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let taggedPath = environment["PI_D12_TAGGED_PREFIX"],
              let swiftPath = environment["PI_D12_SWIFT_PREFIX"] else { return }
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/migration-records-v152.json")
        let fixture = try JSONValue(jsonData: Data(contentsOf: fixtureURL))
        let reads = try #require(fixture["reads"]?.arrayValue)
        let tagged = try await SqliteStorage.open(path: taggedPath, prefix: "pi_")
        do {
            for read in reads {
                let actual = try await PiSwiftDurableTests().sqliteReplayRead(
                    #require(read["method"]?.stringValue), args: #require(read["arguments"]?.arrayValue),
                    storage: tagged)
                #expect(actual == read["result"])
            }
        } catch { try? await tagged.close(context: .background); throw error }
        try await tagged.close(context: .background)

        let swift = try await SqliteStorage.open(path: swiftPath, prefix: "pi_")
        do {
            for batch in try #require(fixture["batches"]?.arrayValue) {
                let writes = try #require(batch["writes"]).decode([StorageWrite].self)
                #expect(try JSONValue(encoding: await swift.commitOne(writes, context: .background)) == batch["seq"])
            }
            for read in reads {
                let actual = try await PiSwiftDurableTests().sqliteReplayRead(
                    #require(read["method"]?.stringValue), args: #require(read["arguments"]?.arrayValue),
                    storage: swift)
                #expect(actual == read["result"])
            }
        } catch { try? await swift.close(context: .background); throw error }
        try await swift.close(context: .background)
    }
}
