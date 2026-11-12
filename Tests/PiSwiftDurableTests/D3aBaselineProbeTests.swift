import Foundation
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

@Suite("PiSwiftDurableTests.D3aBaselineProbe", .serialized, .timeLimit(.minutes(15)))
struct D3aBaselineProbeTests {
    private func open(_ kind: String, _ path: String) async throws -> any DurableStorage {
        switch kind {
        case "sqlite": return try await SqliteStorage.open(path: path)
        case "jsonl": return try await JsonlStorage.open(directory: path)
        default: return MemoryStorage()
        }
    }

    private func conversation(_ session: Session) async throws -> ConversationID {
        try await session.commit({ tx in
            try await tx.createConversation(ownership: .ownerless()).id
        }, context: .background)
    }

    @Test
    func sequentialBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("d3a-bytes-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        for kind in ["sqlite", "jsonl"] {
            let path = directory + "/" + (kind == "sqlite" ? "session.sqlite" : "session-jsonl")
            let storage = try await open(kind, path)
            let session = try await Session.open(storage: storage, now: { 1_000 }, context: .background)
            let id = try await conversation(session)
            for index in 0..<6 {
                _ = try await session.commit({ tx in
                    try await tx.appendEntry(id, value: EntryDraft(kind: "head.\(index)", data: .number(Double(index))))
                }, context: .background)
            }
            try await session.close(context: .background)
        }
        let jsonl = try Data(contentsOf: URL(fileURLWithPath: directory + "/session-jsonl/main.jsonl"))
        let jsonlFixture = try #require(Bundle.module.url(forResource: "session-head-d3a", withExtension: "jsonl", subdirectory: "Fixtures"))
        let expectedJSONL = try Data(contentsOf: jsonlFixture)
        #expect(jsonl == expectedJSONL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [directory + "/session.sqlite", ".dump"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let dump = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let sqliteFixture = try #require(Bundle.module.url(forResource: "session-head-d3a.sqlite", withExtension: "dump", subdirectory: "Fixtures"))
        let expectedSQLite = try Data(contentsOf: sqliteFixture)
        #expect(dump == expectedSQLite)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PI_D3A_BENCH"] == "1"))
    func tenThousandSequentialAndConcurrent() async throws {
        for kind in ["memory", "sqlite", "jsonl"] {
            for concurrent in [false, true] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("d3a-bench-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let path = directory.appendingPathComponent(kind == "sqlite" ? "store.sqlite" : "store").path
                let backend = try await open(kind, path)
                let countGroups = ProcessInfo.processInfo.environment["PI_D3A_COUNT_GROUPS"] == "1"
                let counted = countGroups ? ControlledStorage(backend) : nil
                let storage: any DurableStorage = counted ?? backend
                let session = try await Session.open(storage: storage, now: { 1_000 }, context: .background)
                let id = try await conversation(session)
                let initialCalls = await counted?.callBatchCounts.count ?? 0
                if concurrent { await counted?.enableCommitGateDelays(seed: 0x5a17c0de) }
                let start = ContinuousClock.now
                if concurrent {
                    // v1.5.2 D3a writer.ts:138–143 groups parts admitted
                    // during a storage flight. Hold that flight so this
                    // benchmark actually presents waiting parts to the writer.
                    let flight = await counted?.holdCommits()
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for index in 0..<10_000 {
                            group.addTask {
                                _ = try await session.commit({ tx in
                                    try await tx.appendEntry(id, value: EntryDraft(kind: "bench.\(index)"))
                                }, context: .background)
                            }
                        }
                        if let flight {
                            await flight.waitUntilEntered()
                            for _ in 0..<50_000 {
                                if session.outstandingJobs == 256 { break }
                                await Task.yield()
                            }
                            let full = session.outstandingJobs == 256
                            await flight.release()
                            #expect(full)
                        }
                        try await group.waitForAll()
                    }
                } else {
                    for index in 0..<10_000 {
                        _ = try await session.commit({ tx in
                            try await tx.appendEntry(id, value: EntryDraft(kind: "bench.\(index)"))
                        }, context: .background)
                    }
                }
                let elapsed = start.duration(to: .now)
                print("D3A-BENCH \(kind) \(concurrent ? "concurrent" : "sequential") \(elapsed)")
                if let counted, concurrent {
                    let sizes = Array((await counted.callBatchCounts).dropFirst(initialCalls)).sorted()
                    #expect(sizes.reduce(0, +) == 10_000)
                    print("D3A-GROUPS \(kind) calls=\(sizes.count) min=\(sizes.first ?? 0) median=\(sizes[sizes.count / 2]) max=\(sizes.last ?? 0)")
                }
                try await session.close(context: .background)
            }
        }
    }
}
