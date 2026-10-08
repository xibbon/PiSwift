import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

struct V110BashChunkCase: Sendable {
    let chunks: [Data]
    let beforeFinish: String
    let output: String
}

private let v110BashChunkCases = [
    V110BashChunkCase(
        chunks: ["\u{1b}[31mERROR: file.py:1\u{1b}[0", "m\n"].map { Data($0.utf8) },
        beforeFinish: "ERROR: file.py:1\n", output: "ERROR: file.py:1\n"
    ),
    V110BashChunkCase(
        chunks: ["before\u{1b}", "[32mafter\n"].map { Data($0.utf8) },
        beforeFinish: "beforeafter\n", output: "beforeafter\n"
    ),
    V110BashChunkCase(
        chunks: ["a\u{1b}]0;window ", "title\u{1b}", "\\b\n"].map { Data($0.utf8) },
        beforeFinish: "ab\n", output: "ab\n"
    ),
    V110BashChunkCase(
        chunks: [Data("ok".utf8), Data([0xc3])],
        beforeFinish: "ok", output: "ok\u{fffd}"
    ),
    V110BashChunkCase(
        chunks: [Data(("\u{1b}]" + String(repeating: "x", count: 300)).utf8)],
        beforeFinish: "]" + String(repeating: "x", count: 300),
        output: "]" + String(repeating: "x", count: 300)
    ),
]

private enum V110BashOperationError: Error {
    case aborted
}

private struct V110ChunkBashOperations: BashOperations {
    let chunks: [String]
    var spillPath: String?
    var abort = false
    var returnedOutput: String?

    func execute(_ command: String, options: BashExecutorOptions?) async throws -> BashResult {
        for chunk in chunks { options?.onChunk?(chunk) }
        if abort {
            options?.signal?.cancel()
            throw V110BashOperationError.aborted
        }
        return BashResult(
            output: returnedOutput ?? chunks.joined(), exitCode: 0, cancelled: false,
            truncated: spillPath != nil, fullOutputPath: spillPath
        )
    }
}

@Suite struct V110BashOutputStreamTests {
    // v1.1.0 agent-session-bash-persistence.test.ts:341-398 (#10504).
    @Test(arguments: v110BashChunkCases)
    func upstreamChunkCases(_ testCase: V110BashChunkCase) {
        var stream = BashOutputStream()
        var output = ""
        for chunk in testCase.chunks { output += stream.append(chunk) }
        #expect(output == testCase.beforeFinish)
        output += stream.finish()
        #expect(output == testCase.output)
        #expect(stream.finish().isEmpty)
    }

    @Test func ansiPatternsAndTerminators() {
        #expect(stripAnsi("a\u{1b}[38:2:1:2:3mb\u{9b}0mc") == "abc")
        #expect(stripAnsi("a\u{1b}]0;title\u{7}b\u{1b}]0;title\u{9c}c") == "abc")
        #expect(stripAnsi("a\u{1b}]0;title\u{1b}\\b") == "ab")
        #expect(stripAnsi("plain") == "plain")
        let split = splitIncompleteAnsiSuffix("a\u{1b}[3")
        #expect(split.complete == "a")
        #expect(split.pending == "\u{1b}[3")
        #expect(splitIncompleteAnsiSuffix("plain").pending.isEmpty)
    }

    @Test func ansiWindowUsesUpstreamUtf16Limit() {
        let held = "\u{1b}]" + String(repeating: "x", count: 254)
        #expect(splitIncompleteAnsiSuffix(held).pending == held)
        let released = held + "x"
        #expect(splitIncompleteAnsiSuffix(released).complete == released)
        #expect(splitIncompleteAnsiSuffix(released).pending.isEmpty)
        let emojiWindow = "\u{1b}]" + String(repeating: "😀", count: 128)
        #expect(splitIncompleteAnsiSuffix(emojiWindow).pending.isEmpty)
    }

    // Decision U4: invalid bytes emit U+FFFD and must not block valid text.
    @Test func invalidUtf8DoesNotStopStreaming() {
        var stream = BashOutputStream()
        #expect(stream.append(Data([0xff])) == "\u{fffd}")
        #expect(stream.append(Data("valid".utf8)) == "valid")
        #expect(stream.append(Data([0xe2, 0x28, 0xa1])) == "\u{fffd}(\u{fffd}")
        #expect(stream.finish().isEmpty)
    }

    @Test func invalidUtf8PrefixIsNotHeld() {
        var stream = BashOutputStream()
        #expect(stream.append(Data([0xf4, 0x90])) == "\u{fffd}\u{fffd}")
        #expect(stream.append(Data([0xed, 0xa0])) == "\u{fffd}\u{fffd}")
        #expect(stream.append(Data([0xf0, 0x80])) == "\u{fffd}\u{fffd}")
        #expect(stream.append(Data("ok".utf8)) == "ok")
        #expect(stream.finish().isEmpty)
    }

    @Test func validUtf8CharactersAcrossEveryByteBoundary() {
        let text = "aé€😀z"
        var stream = BashOutputStream()
        let output = Data(text.utf8).reduce(into: "") { output, byte in
            output += stream.append(Data([byte]))
        } + stream.finish()
        #expect(output == text)
    }

    @Test func initialUtf8BomMatchesTextDecoder() {
        var stream = BashOutputStream()
        #expect(stream.append(Data([0xef])).isEmpty)
        #expect(stream.append(Data([0xbb])).isEmpty)
        #expect(stream.append(Data([0xbf])).isEmpty)
        #expect(stream.append(Data("\u{feff}text".utf8)) == "\u{feff}text")
    }

    @Test func stripsAnsiBeforeBinaryAndCarriageReturnRemoval() {
        var stream = BashOutputStream()
        #expect(stream.append(Data("\u{1b}[31mA\0\r\nB\u{1b}[0m".utf8)) == "A\nB")
        #expect(stream.finish().isEmpty)
    }

    @Test func customOperationChunksAndFinalOutputAreClean() async throws {
        let chunks = ["\u{1b}[31mERR\u{1b}[0", "m\r\n"]
        let streamed = LockedState("")
        let result = try await executeBashWithOperations(
            "fake", operations: V110ChunkBashOperations(chunks: chunks),
            options: BashExecutorOptions(onChunk: { chunk in
                streamed.withLock { $0 += chunk }
            })
        )
        #expect(result.output == "ERR\n")
        #expect(streamed.withLock { $0 } == "ERR\n")
    }

    @Test(arguments: ["\u{7}", "\u{1b}\\"])
    func longAnsiReleasedBeforeTerminatorKeepsStreamFinalAndSpillEqual(_ terminator: String) async throws {
        let chunks = ["before\u{1b}]" + String(repeating: "x", count: 300), terminator + "after\n"]
        let raw = Data(chunks.joined().utf8)
        let path = try writeOutputFile(prefix: "v110-long-osc", extension: ".log", data: raw)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let streamed = LockedState("")
        let result = try await executeBashWithOperations("fake",
            operations: V110ChunkBashOperations(chunks: chunks, spillPath: path),
            options: BashExecutorOptions(onChunk: { text in streamed.withLock { $0 += text } }))
        // The long OSC was released; a later standalone ESC-backslash leaves its backslash.
        let suffix = terminator == "\u{7}" ? "" : "\\"
        let expected = "before]" + String(repeating: "x", count: 300) + suffix + "after\n"
        #expect(streamed.withLock { $0 } == expected)
        #expect(result.output == expected)
        let cleanPath = try #require(result.fullOutputPath)
        defer { try? FileManager.default.removeItem(atPath: cleanPath) }
        #expect(try String(contentsOfFile: cleanPath, encoding: .utf8) == expected)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == raw)
    }

    @Test func customReturnedOutputCanDifferFromStreamOrHaveNoChunks() async throws {
        let streamed = LockedState("")
        let result = try await executeBashWithOperations("fake",
            operations: V110ChunkBashOperations(chunks: ["\u{1b}[31mstream\u{1b}[0m"],
                                                returnedOutput: "\u{1b}[31mtail\u{1b}[0m"),
            options: BashExecutorOptions(onChunk: { text in streamed.withLock { $0 += text } }))
        #expect(result.output == "tail")
        #expect(streamed.withLock { $0 } == "stream")
        let noChunks = try await executeBashWithOperations("fake",
            operations: V110ChunkBashOperations(chunks: [], returnedOutput: "\u{1b}[31mERR\u{1b}[0m\n"))
        #expect(noChunks.output == "ERR\n")
    }

    @Test func canceledOperationKeepsPartialOutput() async throws {
        let token = CancellationToken()
        let streamed = LockedState("")
        let result = try await executeBashWithOperations(
            "fake",
            operations: V110ChunkBashOperations(chunks: ["\u{1b}[31mkept\u{1b}[0m"], abort: true),
            options: BashExecutorOptions(onChunk: { chunk in
                streamed.withLock { $0 += chunk }
            }, signal: token)
        )
        #expect(result.cancelled)
        #expect(result.exitCode == nil)
        #expect(result.output == "kept")
        #expect(streamed.withLock { $0 } == "kept")
    }

    @Test func customSpillGetsNewCleanFile() async throws {
        let raw = Data("\u{1b}[31mERR\u{1b}[0m\r\n".utf8) + Data([0xff])
        let path = try writeOutputFile(prefix: "v110-raw-bash", extension: ".log", data: raw)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await executeBashWithOperations(
            "fake", operations: V110ChunkBashOperations(chunks: ["ERR\n"], spillPath: path)
        )
        let cleanPath = try #require(result.fullOutputPath)
        defer { try? FileManager.default.removeItem(atPath: cleanPath) }
        #expect(cleanPath != path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == raw)
        #expect(try String(contentsOfFile: cleanPath, encoding: .utf8) == "ERR\n\u{fffd}")
    }

    @Test func bashToolResultAndUpdatesHaveNoAnsiFragments() async throws {
        let tool = createBashTool(
            cwd: "/tmp",
            options: BashToolOptions(operations: V110ChunkBashOperations(
                chunks: ["\u{1b}[31mERR\u{1b}", "[0m\n"]
            ))
        )
        let updates = LockedState<[String]>([])
        let result = try await tool.execute(
            "v110-call", ["command": AnyCodable("fake")], nil, { update in
                updates.withLock { $0.append(Self.text(update)) }
            }
        )
        #expect(Self.text(result) == "ERR\n")
        #expect(updates.withLock { $0.last } == "ERR\n")
        #expect(updates.withLock { $0.allSatisfy { !$0.contains("[31m") && !$0.contains("[0m") } })
        #expect((result.structuredContent?.value as? [String: Any])?["output"] as? String == "ERR\n")
    }

    #if !canImport(UIKit)
    @Test func systemBashChunksAndOutputHaveNoAnsiFragments() async throws {
        let streamed = LockedState("")
        let result = try await SystemBashOperations().execute(
            #"printf '\033[31mERR\033[0m\n'"#,
            options: BashExecutorOptions(onChunk: { chunk in
                streamed.withLock { $0 += chunk }
            })
        )
        #expect(result.output == "ERR\n")
        #expect(streamed.withLock { $0 } == "ERR\n")
        #expect(result.exitCode == 0)
    }

    @Test func systemBashSpillContainsStrippedText() async throws {
        let result = try await SystemBashOperations().execute(
            #"for ((i=0;i<20000;i++)); do printf '\033[31mERR\033[0m\n'; done"#,
            options: nil
        )
        #expect(result.truncated)
        let path = try #require(result.fullOutputPath)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == String(repeating: "ERR\n", count: 20000))
        #expect(!result.output.contains("[31m"))
        #expect(!result.output.contains("[0m"))
    }
    #endif

    private static func text(_ result: AgentToolResult) -> String {
        result.content.compactMap { content in
            if case .text(let text) = content { return text.text }
            return nil
        }.joined()
    }
}
