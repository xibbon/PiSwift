import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftMCP

private actor PipeExitGate {
    private var result: Result<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?

    func wait() async throws {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func settle(_ outcome: Result<Void, Error>) {
        guard result == nil else { return }
        result = outcome
        if let waiter {
            waiter.resume(with: outcome)
            self.waiter = nil
        }
    }
}

private actor FakeMcpPipe: McpPipe {
    nonisolated let exited: Task<Void, Error>
    private let gate: PipeExitGate
    private var calls: [String] = []
    private var written: [Data] = []
    private let finishOnStdinClose: Bool

    init(finishOnStdinClose: Bool = false) {
        let gate = PipeExitGate()
        self.gate = gate
        self.exited = Task { try await gate.wait() }
        self.finishOnStdinClose = finishOnStdinClose
    }

    func write(_ data: Data) async throws { written.append(data) }
    func closeStdin() async {
        calls.append("closeStdin")
        if finishOnStdinClose { await gate.settle(.success(())) }
    }
    func close() async {
        calls.append("close")
        await gate.settle(.failure(McpTransportError.invalidResponse("aborted")))
    }
    func exit() async { await gate.settle(.success(())) }
    func fail(_ text: String) async { await gate.settle(.failure(McpTransportError.invalidResponse(text))) }
    func snapshot() -> ([String], [Data]) { (calls, written) }
}

private struct FakeProgram {
    let transport: PipeTransport
    let pipe: FakeMcpPipe
    let handlers: LockedState<McpPipeHandlers?>
    let errors: LockedState<[String]>

    func stdout(_ text: String) { handlers.withLock { $0 }?.onStdout(Data(text.utf8)) }
    func stderr(_ text: String) { handlers.withLock { $0 }?.onStderr(Data(text.utf8)) }
}

private func fakeProgram(maxMessageBytes: Int = mcpDefaultMaxMessageBytes, maxStderrBytes: Int = 64 * 1024,
                         closeTimeout: Duration = .seconds(2), finishOnStdinClose: Bool = false,
                         onStderr: (@Sendable (String) -> Void)? = nil) async throws -> FakeProgram {
    let pipe = FakeMcpPipe(finishOnStdinClose: finishOnStdinClose)
    let handlers = LockedState<McpPipeHandlers?>(nil)
    let errors = LockedState<[String]>([])
    let transport = PipeTransport(open: { registered in
        handlers.withLock { $0 = registered }
        return pipe
    }, maxMessageBytes: maxMessageBytes, maxStderrBytes: maxStderrBytes,
       onStderr: onStderr, onError: { error in errors.withLock { $0.append(error.localizedDescription) } },
       closeTimeout: closeTimeout)
    try await transport.start()
    return FakeProgram(transport: transport, pipe: pipe, handlers: handlers, errors: errors)
}

private func ping(_ id: Int) -> String { "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"ping\"}" }

@Test("joins a message split across many chunks once, when its newline arrives", .timeLimit(.minutes(1)))
func m1LineJoinsManyChunks() async throws {
    let reader = JsonRpcLineReader(maxMessageBytes: 2 * 1024 * 1024, maxStderrBytes: 8)
    let text = String(repeating: "x", count: 1024 * 1024)
    let bytes = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"text\":\"\(text)\"}}\n".utf8)
    for offset in stride(from: 0, to: bytes.count, by: 4096) {
        await reader.readStdout(Data(bytes[offset..<min(offset + 4096, bytes.count)]))
    }
    #expect(await reader.takeReady()?.count == bytes.count - 1)
}

@Test("handles multi-byte characters, CRLF, blank lines, and several messages per chunk at any split", .timeLimit(.minutes(1)))
func m1LineSplits() async throws {
    let first = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"text\":\"héllo 🌍\"}}"
    let second = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/x\"}"
    let third = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}"
    let input = Data("\(first)\n\n\(second)\r\nnot json\n\(third)\n".utf8)
    for chunkSize in 1...input.count {
        let errors = LockedState<[String]>([])
        let reader = JsonRpcLineReader(maxMessageBytes: 1024, maxStderrBytes: 8,
                                       onError: { error in errors.withLock { $0.append(error.localizedDescription) } })
        for offset in stride(from: 0, to: input.count, by: chunkSize) {
            await reader.readStdout(Data(input[offset..<min(offset + chunkSize, input.count)]))
        }
        await reader.end()
        #expect(await reader.takeReady() == Data(first.utf8))
        #expect(await reader.takeReady() == Data(second.utf8))
        #expect(await reader.takeReady() == Data(third.utf8))
        #expect(errors.withLock { $0.count } == 1)
    }
}

@Test("drops an oversized message and keeps reading the next one")
func m1LineOversizeContinues() async throws {
    let errors = LockedState<[String]>([])
    let reader = JsonRpcLineReader(maxMessageBytes: 64, maxStderrBytes: 8,
                                   onError: { error in errors.withLock { $0.append(error.localizedDescription) } })
    await reader.readStdout(Data(String(repeating: "a", count: 50).utf8))
    await reader.readStdout(Data("\(String(repeating: "a", count: 50))\n{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}\n".utf8))
    #expect(errors.withLock { $0 } == ["MCP stdio message exceeds 64 bytes"])
    #expect(await reader.takeReady() != nil)
}

@Test("reports a message without its newline at the end")
func m1LineIncompleteEnd() async {
    let errors = LockedState<[String]>([])
    let reader = JsonRpcLineReader(maxMessageBytes: 1024, maxStderrBytes: 8,
                                   onError: { error in errors.withLock { $0.append(error.localizedDescription) } })
    await reader.readStdout(Data("{\"jsonrpc\":\"2.0\",".utf8))
    await reader.end()
    #expect(errors.withLock { $0 } == ["MCP stdio server closed with an incomplete JSON-RPC message"])
}

@Test("joins messages split across chunks and splits several messages in one chunk", .timeLimit(.minutes(1)))
func m1PipeFraming() async throws {
    let p = try await fakeProgram()
    let a = ping(1), b = ping(2), c = ping(3)
    p.stdout(String(a.prefix(10)))
    p.stdout("\(a.dropFirst(10))\n\(b)")
    p.stdout("\n\(c)\n")
    #expect(try await p.transport.receive() == Data(a.utf8))
    #expect(try await p.transport.receive() == Data(b.utf8))
    #expect(try await p.transport.receive() == Data(c.utf8))
    await p.pipe.exit()
    await p.transport.close()
}

@Test("strips a trailing carriage return and skips blank lines", .timeLimit(.minutes(1)))
func m1PipeBlankLines() async throws {
    let p = try await fakeProgram()
    p.stdout("\n\r\n   \n\(ping(1))\r\n\n")
    #expect(try await p.transport.receive() == Data(ping(1).utf8))
    await p.pipe.exit()
    await p.transport.close()
}

@Test("reports invalid messages and keeps reading", .timeLimit(.minutes(1)))
func m1PipeInvalidContinues() async throws {
    let p = try await fakeProgram()
    p.stdout("not json\n{\"jsonrpc\":\"1.0\"}\n\(ping(1))\n")
    #expect(try await p.transport.receive() == Data(ping(1).utf8))
    #expect(p.errors.withLock { $0.count } == 2)
    await p.pipe.exit()
    await p.transport.close()
}

@Test("drops messages over maxMessageBytes, complete or not", .timeLimit(.minutes(1)))
func m1PipeOversizeContinues() async throws {
    let p = try await fakeProgram(maxMessageBytes: 48)
    p.stdout("{\"jsonrpc\":\"2.0\",\"method\":\"\(String(repeating: "x", count: 48))\"}\n\(ping(1))\n")
    p.stdout(String(repeating: "y", count: 49))
    p.stdout("\n\(ping(2))\n")
    #expect(try await p.transport.receive() == Data(ping(1).utf8))
    #expect(try await p.transport.receive() == Data(ping(2).utf8))
    #expect(p.errors.withLock { $0 } == ["MCP stdio message exceeds 48 bytes", "MCP stdio message exceeds 48 bytes"])
    await p.pipe.exit()
    await p.transport.close()
}

@Test("keeps a bounded stderr tail and passes every chunk to onStderr", .timeLimit(.minutes(1)))
func m1PipeStderr() async throws {
    let chunks = LockedState<[String]>([])
    let p = try await fakeProgram(maxStderrBytes: 8, onStderr: { chunk in chunks.withLock { $0.append(chunk) } })
    p.stderr("starting\n")
    p.stderr("ready\n")
    await p.pipe.exit()
    await p.transport.close()
    #expect(await p.transport.stderr == "g\nready\n")
    #expect(chunks.withLock { $0 } == ["starting\n", "ready\n"])
}

@Test("writes each message as one line")
func m1PipeWritesLine() async throws {
    let p = try await fakeProgram()
    try await p.transport.send(Data(ping(1).utf8))
    #expect(await p.pipe.snapshot().1 == [Data("\(ping(1))\n".utf8)])
    await p.pipe.exit()
    await p.transport.close()
}

@Test("reports an incomplete message when the program exits, then closes", .timeLimit(.minutes(1)))
func m1PipeIncompleteExit() async throws {
    let p = try await fakeProgram()
    p.stdout("{\"jsonrpc\":\"2.0\"")
    await p.pipe.exit()
    await p.transport.close()
    #expect(p.errors.withLock { $0 } == ["MCP stdio server closed with an incomplete JSON-RPC message"])
}

@Test("reports a failed exit it did not cause, then closes", .timeLimit(.minutes(1)))
func m1PipeFailedExit() async throws {
    let p = try await fakeProgram()
    await p.pipe.fail("connection lost")
    do { _ = try await p.transport.receive(); Issue.record("Expected close") } catch {}
    #expect(p.errors.withLock { $0 } == ["connection lost"])
}

@Test("rejects send after close and after the program ended", .timeLimit(.minutes(1)))
func m1PipeRejectsSend() async throws {
    let first = try await fakeProgram(finishOnStdinClose: true)
    await first.transport.close()
    await #expect(throws: McpError.self) { try await first.transport.send(Data(ping(1).utf8)) }
    let second = try await fakeProgram()
    await second.pipe.exit()
    do { _ = try await second.transport.receive() } catch {}
    await #expect(throws: McpError.self) { try await second.transport.send(Data(ping(1).utf8)) }
}

@Test("closes stdin and does not kill a program that exits in time", .timeLimit(.minutes(1)))
func m1PipeGracefulClose() async throws {
    let p = try await fakeProgram(finishOnStdinClose: true)
    await p.transport.close()
    #expect(await p.pipe.snapshot().0 == ["closeStdin"])
}

@Test("shuts down once when closed twice", .timeLimit(.minutes(1)))
func m1PipeCloseOnce() async throws {
    let p = try await fakeProgram(finishOnStdinClose: true)
    await p.transport.close()
    await p.transport.close()
    #expect(await p.pipe.snapshot().0 == ["closeStdin"])
}

@Test("kills a program only after closeTimeoutMs", .timeLimit(.minutes(1)))
func m1PipeTimeoutKill() async throws {
    let p = try await fakeProgram(closeTimeout: .milliseconds(30))
    await p.transport.close()
    #expect(await p.pipe.snapshot().0 == ["closeStdin", "close"])
    #expect(p.errors.withLock { $0 }.isEmpty)
}

@Test("rejects start when open rejects")
func m1PipeOpenRejects() async {
    let transport = PipeTransport(open: { _ in throw McpTransportError.invalidResponse("not_supported") })
    await #expect(throws: McpTransportError.self) { try await transport.start() }
}

@Test("kills a program that finished starting after close", .timeLimit(.minutes(1)))
func m1PipeCloseDuringOpen() async throws {
    let entered = PipeExitGate()
    let release = PipeExitGate()
    let pipe = FakeMcpPipe()
    let transport = PipeTransport(open: { _ in
        await entered.settle(.success(()))
        try await release.wait()
        return pipe
    })
    let starting = Task { try await transport.start() }
    try await entered.wait()
    await transport.close()
    await release.settle(.success(()))
    await #expect(throws: McpError.self) { try await starting.value }
    #expect(await pipe.snapshot().0 == ["close"])
}

@Test("replaces invalid UTF-8 bytes while decoding a stdio line")
func m1LineInvalidUTF8() async throws {
    let reader = JsonRpcLineReader(maxMessageBytes: 1024, maxStderrBytes: 8)
    var input = Data(#"{"jsonrpc":"2.0","id":1,"result":{"text":""#.utf8)
    input.append(0xff)
    input.append(Data("\"}}\n".utf8))
    await reader.readStdout(input)
    let line = try #require(await reader.takeReady())
    #expect(String(decoding: line, as: UTF8.self).contains("�"))
}
