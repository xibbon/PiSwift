import Foundation
import Testing
@testable import PiSwiftMCP

#if os(macOS)
// Upstream v0.99.1 transports/stdio.ts propagates the Node spawn error.
@Test(.timeLimit(.minutes(1))) func f2StdioMissingCommandUsesSpawnErrorText() async throws {
    let command = "pi-mcp-missing-\(UUID().uuidString)"
    let transport = StdioTransport(command: command)
    do {
        try await transport.start()
        Issue.record("A missing command must fail")
    } catch McpError.connectionFailed(let message) {
        #expect(message == "spawn \(command) ENOENT")
    }
    await transport.close()
}

@Test(.timeLimit(.minutes(1))) func f2StdioMissingWorkingDirectoryUsesSpawnErrorText() async throws {
    let transport = StdioTransport(command: "/bin/sh", cwd: "/private/tmp/pi-mcp-missing-\(UUID().uuidString)")
    do {
        try await transport.start()
        Issue.record("A missing working directory must fail")
    } catch McpError.connectionFailed(let message) {
        #expect(message == "spawn /bin/sh ENOENT")
    }
    await transport.close()
}

@Test(.timeLimit(.minutes(1))) func f2StdioNonExecutableCommandUsesSpawnErrorText() async throws {
    let command = FileManager.default.temporaryDirectory.appendingPathComponent("pi-mcp-denied-\(UUID().uuidString)")
    try "#!/bin/sh\nexit 0\n".write(to: command, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: command.path)
    defer { try? FileManager.default.removeItem(at: command) }
    let transport = StdioTransport(command: command.path)
    do {
        try await transport.start()
        Issue.record("A command with no execute permission must fail")
    } catch McpError.connectionFailed(let message) {
        #expect(message == "spawn \(command.path) EACCES")
    }
    await transport.close()
}
#endif
