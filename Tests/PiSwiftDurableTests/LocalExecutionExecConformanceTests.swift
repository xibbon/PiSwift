import Foundation
import Testing
import PiSwiftDurable
import PiSwiftDurableTesting

#if os(macOS)
private let localExecConformanceNames: Set<String> = [
    "argv exec passes arguments to the program without shell parsing",
    "exec reports the stream of every chunk in both forms",
    "argv exec honors cwd and exit codes",
    "argv exec reports missing programs and empty argv as spawn errors",
    "windowed exec keeps the exact tail and counts what it skips",
    "argv exec distinguishes timeout from abort",
    "binary reader follows symlinks unless noFollow refuses the final one",
    "watch reports changes to the file a watched symbolic link points to",
]

private let localExecConformanceCases = envConformanceCases(makeSymlink: { target, path, context in
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    let result = try await LocalExecutionEnv(cwd: parent).exec(
        .argv(["ln", "-s", target, path]), options: nil, context: context
    ).get()
    guard result.exitCode == 0 else {
        throw EnvConformanceFailure("ln -s returned exit code \(result.exitCode)")
    }
}, withEnv: { use in
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-durable-exec-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let env = LocalExecutionEnv(cwd: directory.path, watch: .init(mode: .polling, pollIntervalMs: 100))
    do {
        try await use(env)
        await env.cleanup(context: .background)
    } catch {
        await env.cleanup(context: .background)
        throw error
    }
}).filter { localExecConformanceNames.contains($0.name) }

struct LocalExecutionExecConformanceTests {
    // Upstream env-conformance.ts: the six exec checks and both symbolic link checks.
    @Test("LocalExecutionEnv exec and symbolic link conformance", arguments: localExecConformanceCases)
    func exec(_ testCase: EnvConformanceCase) async throws {
        try await testCase.run()
    }
}
#endif
