import Darwin
import Foundation
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting
import Testing
@testable import PiSwiftCodingAgentDurable

// Run with PI_D10_BENCH=1. Optional PI_D10_BENCH_COUNT=1000|100000 and
// PI_D10_BENCH_BACKEND=sqlite|jsonl|all select the size and storage backend.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PI_D10_BENCH"] == "1"),
      .timeLimit(.minutes(10)))
func d10OpenBenchmark() async throws {
    let environment = ProcessInfo.processInfo.environment
    let count = Int(environment["PI_D10_BENCH_COUNT"] ?? "1000") ?? 0
    #expect(count == 1_000 || count == 100_000)
    guard count == 1_000 || count == 100_000 else { return }
    let selected = environment["PI_D10_BENCH_BACKEND"] ?? "all"
    let backends = DurableStorageKind.allBenchmarkCases.filter { selected == "all" || selected == $0.rawValue }
    #expect(!backends.isEmpty)
    for backend in backends {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("piswift-d10-bench-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let cwd = base.appendingPathComponent("project").path
        let agent = base.appendingPathComponent("agent").path
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: agent, withIntermediateDirectories: true)
        let location = try await selectSession(cwd, continueSession: false, agentDirectory: agent)
        let storage: any DurableStorage
        switch backend {
        case .sqlite: storage = try await SqliteStorage.open(path: location.database)
        case .jsonl: storage = try await JsonlStorage.open(directory: location.directory)
        }
        let harness = try await Harness.open(storage: storage,
            options: .init(models: FakeDurableModels(), registry: createRegistry()), context: .background)
        let root = try await harness.root(context: .background)
        // Keep each seed transaction small enough to avoid a large temporary batch.
        for start in stride(from: 0, to: count, by: 1_000) {
            let end = min(start + 1_000, count)
            try await root.commit({ tx in
                for index in start..<end {
                    _ = try await tx.appendEntry(root.id, value: .init(kind: "benchmark.line",
                        data: .string("Benchmark entry \(index + 1): saved transcript text.")))
                }
            }, context: .background)
        }
        try await harness.close(context: .background)
        location.release()
        let dependencies = OpenDurableDependencies(agentDirectory: agent, makeModels: { _ in
            DurableRuntimeModels(models: FakeDurableModels(), available: [],
                initial: { _ in .init(model: nil, thinkingLevel: nil) })
        })
        for mode in [DurableTranscriptMode.paged, .compatibility] {
            let before = try benchmarkResidentBytes()
            let clock = ContinuousClock()
            let start = clock.now
            let opened = try await openDurable(.init(cwd: cwd, continueSession: true,
                transcriptMode: mode, storageKind: backend), dependencies: dependencies)
            let elapsed = start.duration(to: clock.now)
            let after = try benchmarkResidentBytes()
            let rows = mode == .paged ? opened.hostView.hostCurrent().rows.count
                : opened.view.current().conversation.entries.count
            let parts = elapsed.components
            let milliseconds = Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
            print("D10-BENCH backend=\(backend.rawValue) entries=\(count) mode=\(mode.rawValue) open_ms=\(String(format: "%.3f", milliseconds)) resident_delta_bytes=\(after - before) resident_bytes=\(after) rows=\(rows)")
            if mode == .paged { #expect(rows <= 51) }
            else { #expect(rows == count) }
            await opened.close()
        }
    }
}

private extension DurableStorageKind {
    static var allBenchmarkCases: [Self] { [.sqlite, .jsonl] }
}

private func benchmarkResidentBytes() throws -> Int64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { throw BenchmarkMemoryError.readFailed(result) }
    return Int64(info.resident_size)
}

private enum BenchmarkMemoryError: Error { case readFailed(kern_return_t) }
