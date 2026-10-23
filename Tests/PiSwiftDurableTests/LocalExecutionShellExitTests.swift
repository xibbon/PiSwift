#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

struct LocalExecutionShellExitTests {
    @Test("rechecks waitpid after the exit event is consumed", .timeLimit(.minutes(1)))
    func exitBeforeWaitable() async throws {
        struct State: Sendable {
            var deferredPolls = 0
            var wakes = 0
        }
        let state = Mutex(State())
        let hooks = LocalShellHooks(loopWoke: { state.withLock { $0.wakes += 1 } },
            waitForChild: { pid, status, options in
                // The empty command can wake once for each EOF pipe and once for NOTE_EXIT.
                // Keep waitpid unready through all three. A fourth wake needs a bounded wait.
                if options & WNOHANG != 0 {
                    let deferPoll = state.withLock { value in
                        if value.wakes < 4 {
                            value.deferredPolls += 1
                            return true
                        }
                        return false
                    }
                    if deferPoll { return 0 }
                }
                return waitpid(pid, &status, options)
            })
        let env = LocalExecutionEnv(cwd: FileManager.default.temporaryDirectory.path, shellHooks: hooks)
        let result = await env.exec(.shell("exit 23"), options: nil, context: .background)
        #expect(try result.get().exitCode == 23)
        #expect(state.withLock { $0.deferredPolls } >= 2)
        #expect(state.withLock { $0.wakes } >= 4)
        await env.cleanup(context: .background)
    }

    @Test("500 short commands finish with 32 commands at a time and no timeout", .timeLimit(.minutes(1)))
    func shortCommandStress() async throws {
        let env = LocalExecutionEnv()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<500 {
                if index >= 32 { try await group.next() }
                group.addTask {
                    let result = try await env.exec(.argv(["/usr/bin/true"]), options: nil, context: .background).get()
                    #expect(result.exitCode == 0)
                }
            }
            try await group.waitForAll()
        }
        await env.cleanup(context: .background)
    }
}
#endif
