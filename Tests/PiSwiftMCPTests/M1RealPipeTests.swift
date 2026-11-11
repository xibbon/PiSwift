import Foundation
import Testing
@testable import PiSwiftMCP

#if os(macOS)
private actor ChildExitGate {
    private var terminated = false
    private var stdoutEnded = false
    private var stderrEnded = false
    private var waiter: CheckedContinuation<Void, Never>?

    func markTerminated() { terminated = true; finishIfReady() }
    func markStdoutEnded() { stdoutEnded = true; finishIfReady() }
    func markStderrEnded() { stderrEnded = true; finishIfReady() }
    func wait() async {
        if terminated && stdoutEnded && stderrEnded { return }
        await withCheckedContinuation { waiter = $0 }
    }
    private func finishIfReady() {
        guard terminated && stdoutEnded && stderrEnded else { return }
        waiter?.resume()
        waiter = nil
    }
}

private actor SpawnedTestPipe: McpPipe {
    nonisolated let exited: Task<Void, Error>
    private let process: Process
    private let stdin: FileHandle

    init(handlers: McpPipeHandlers) throws {
        let process = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf 'pipe ready\\n' >&2; for n in 1 2 3; do IFS= read -r line; printf '%s\\n' \"$line\"; done; IFS= read -r pending; printf 'pending request failed\\n' >&2; exit 7"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let gate = ChildExitGate()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if bytes.isEmpty {
                handle.readabilityHandler = nil
                Task { await gate.markStdoutEnded() }
            } else { handlers.onStdout(bytes) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if bytes.isEmpty {
                handle.readabilityHandler = nil
                Task { await gate.markStderrEnded() }
            } else { handlers.onStderr(bytes) }
        }
        process.terminationHandler = { _ in Task { await gate.markTerminated() } }
        try process.run()
        self.process = process
        self.stdin = stdin.fileHandleForWriting
        self.exited = Task { await gate.wait() }
    }

    func write(_ data: Data) async throws { try stdin.write(contentsOf: data) }
    func closeStdin() async { try? stdin.close() }
    func close() async { if process.isRunning { process.terminate() } }
}

@Test("runs initialize, tools/list and tools/call", .timeLimit(.minutes(1)))
func m1PipeRealDescriptorsAndPendingExit() async throws {
    let transport = PipeTransport(open: { handlers in try SpawnedTestPipe(handlers: handlers) })
    try await transport.start()
    let first = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}".utf8)
    try await transport.send(first)
    #expect(try await transport.receive() == first)
    for (id, method) in [(2, "tools/list"), (3, "tools/call")] {
        let request = Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method)\"}".utf8)
        try await transport.send(request)
        #expect(try await transport.receive() == request)
    }
    let pending = Data("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/list\"}".utf8)
    try await transport.send(pending)
    do {
        _ = try await transport.receive()
        Issue.record("Expected child exit while request is pending")
    } catch McpTransportError.connectionClosed(let stderr) {
        #expect(stderr.contains("pipe ready"))
        #expect(stderr.contains("pending request failed"))
    }
    await transport.close()
}
#endif
