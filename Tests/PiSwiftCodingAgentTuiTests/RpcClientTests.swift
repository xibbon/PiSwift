import Foundation
import Testing
@testable import PiSwiftCodingAgentTui

private struct RpcClientTestTimeout: Error {}

private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw RpcClientTestTimeout()
        }

        guard let result = try await group.next() else {
            throw RpcClientTestTimeout()
        }
        group.cancelAll()
        return result
    }
}

@Test func rpcClientRejectsPendingRequestsWhenChildExits() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-rpc-client-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let scriptURL = tempDir.appendingPathComponent("exiting-rpc.sh")
    try """
    #!/bin/sh
    sleep 0.2
    echo child failed >&2
    exit 7
    """.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

    let client = RpcClient(options: RpcClientOptions(cliPath: scriptURL.path, cwd: tempDir.path))
    try await client.start()

    do {
        _ = try await withTimeout(seconds: 2) {
            try await client.getState()
        }
        Issue.record("Expected pending request to be rejected when child exits")
    } catch {
        let message = String(describing: error)
        #expect(message.contains("RPC process exited with exit code 7"))
        #expect(message.contains("child failed"))
    }

    await client.stop()
}
