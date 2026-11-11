import Foundation
import Testing
@testable import PiSwiftMCP
#if os(macOS)
import Darwin

@Test("kills children still holding the pipes after the server process exited", .timeLimit(.minutes(1)))
func m1StdioKillsChildrenAfterParentExit() async throws {
    let fixture = try #require(Bundle.module.url(forResource: "exiting-parent-server", withExtension: "sh", subdirectory: "fixtures"))
    let transport = StdioTransport(command: "/bin/sh", args: [fixture.path], closeTimeout: .milliseconds(100))
    try await transport.start()
    let parent = try #require(await transport.processID)
    var helper: pid_t?
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        let tail = await transport.stderr
        if let match = tail.range(of: #"helper (\d+)"#, options: .regularExpression) {
            helper = pid_t(tail[match].dropFirst("helper ".count))
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    let child = try #require(helper)
    while kill(parent, 0) == 0 && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(kill(parent, 0) == -1)
    #expect(kill(child, 0) == 0)
    defer { _ = kill(child, SIGKILL) }
    await transport.close()
    let killedDeadline = ContinuousClock.now + .seconds(2)
    while kill(child, 0) == 0 && ContinuousClock.now < killedDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(kill(child, 0) == -1)
}
#endif
