import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func ctaToolText(_ result: AgentToolResult) -> String {
    result.content.compactMap { if case .text(let value) = $0 { return value.text }; return nil }.joined(separator: "\n")
}

private func ctaWithDirectory(_ body: (String) async throws -> Void) async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("cta-find-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: path) }
    try await body(path)
}

private func ctaWriteFiles(_ names: [String], in path: String) throws {
    for name in names {
        try Data().write(to: URL(fileURLWithPath: path).appendingPathComponent(name))
    }
}

// Upstream 676af1d777ef6f04b6bc8daf4cf3b9b1799cff4d, test/tools.test.ts:
// "should report the result limit only when more results exist" (#7121).
@Test func ctaFindReportsResultLimitOnlyWhenMoreResultsExist() async throws {
    try await ctaWithDirectory { path in
        try ctaWriteFiles(["a.txt", "b.txt", "c.txt"], in: path)
        let tool = createFindTool(cwd: path)
        let exact = try await tool.execute("exact", ["pattern": AnyCodable("*.txt"), "limit": AnyCodable(3)], nil, nil)
        #expect(ctaToolText(exact).split(separator: "\n").sorted() == ["a.txt", "b.txt", "c.txt"])
        #expect(exact.details == nil)
        let over = try await tool.execute("over", ["pattern": AnyCodable("*.txt"), "limit": AnyCodable(2)], nil, nil)
        let parts = ctaToolText(over).components(separatedBy: "\n\n")
        #expect(parts.first?.split(separator: "\n").count == 2)
        #expect(parts.last == "[2 results limit reached. Use limit=4 for more, or refine pattern]")
        #expect(over.details == AnyCodable(["resultLimitReached": 2]))
    }
}

// Upstream 676af1d77, test/tools.test.ts: find and ls
// "should treat limits below 1 as 1 and floor fractional limits".
@Test(arguments: [0.0, -5.0, 0.5, 1.9])
func ctaFindAndLsClampSmallAndFractionalLimits(_ limit: Double) async throws {
    try await ctaWithDirectory { path in
        try ctaWriteFiles(["a.txt", "b.txt", "c.txt"], in: path)
        let find = try await createFindTool(cwd: path).execute("find", ["pattern": AnyCodable("*.txt"), "limit": AnyCodable(limit)], nil, nil)
        let parts = ctaToolText(find).components(separatedBy: "\n\n")
        #expect(parts.first?.split(separator: "\n").count == 1)
        #expect(parts.last == "[1 results limit reached. Use limit=2 for more, or refine pattern]")
        #expect(find.details == AnyCodable(["resultLimitReached": 1]))
        let ls = try await createLsTool(cwd: path).execute("ls", ["limit": AnyCodable(limit)], nil, nil)
        #expect(ctaToolText(ls) == "a.txt\n\n[1 entries limit reached. Use limit=2 for more]")
        #expect(ls.details == AnyCodable(["entryLimitReached": 1]))
    }
}

// Upstream 676af1d77, test/tools.test.ts:
// "should report the entry limit only when more entries exist".
@Test func ctaLsExactLimitHasNoNotice() async throws {
    try await ctaWithDirectory { path in
        try ctaWriteFiles(["a.txt", "b.txt", "c.txt"], in: path)
        let result = try await createLsTool(cwd: path).execute("ls", ["limit": AnyCodable(3)], nil, nil)
        #expect(ctaToolText(result) == "a.txt\nb.txt\nc.txt")
        #expect(result.details == nil)
    }
}

// Upstream 676af1d77, test/tools.test.ts: "should report full output totals past the byte cap".
@Test func ctaFindReportsFullOutputTotalsPastByteCap() async throws {
    try await ctaWithDirectory { path in
        let names = (0..<300).map { String(format: "%03d", $0) + String(repeating: "x", count: 193) + ".txt" }
        try ctaWriteFiles(names, in: path)
        let result = try await createFindTool(cwd: path).execute("find", ["pattern": AnyCodable("*.txt")], nil, nil)
        let expected = truncateHead(names.joined(separator: "\n"), options: TruncationOptions(maxLines: Int.max))
        let details = try #require(result.details?.value as? [String: Any])
        let truncation = try #require(details["truncation"] as? [String: Any])
        #expect(truncation["totalLines"] as? Int == expected.totalLines)
        #expect(truncation["totalBytes"] as? Int == expected.totalBytes)
        #expect(truncation["outputLines"] as? Int == expected.outputLines)
        #expect(truncation["outputBytes"] as? Int == expected.outputBytes)
        #expect(truncation["truncatedBy"] as? String == expected.truncatedBy)
        #expect(details["resultLimitReached"] == nil)
        #expect(ctaToolText(result).hasSuffix("\n\n[50.0KB limit reached]"))
    }
}

// a07f251296c5f912ed105c78e5f306db9b1a9019: test/find-abort-before-spawn.test.ts.
// The Swift tool does not start fd or perform async .git lookups. Check its native entry boundary.
@Test func ctaFindDoesNotReadSearchPathWhenAlreadyAborted() async throws {
    let token = CancellationToken()
    token.cancel()
    do {
        _ = try await createFindTool(cwd: "/missing-cta-find").execute("find", ["pattern": AnyCodable("*")], token, nil)
        Issue.record("Expected cancellation")
    } catch {
        #expect(error.localizedDescription == "Operation aborted")
    }
}

private struct CTAChunkBashOperations: BashOperations {
    let chunks: [String]
    var cancel = false
    func execute(_ command: String, options: BashExecutorOptions?) async throws -> BashResult {
        for chunk in chunks { options?.onChunk?(chunk) }
        if cancel {
            options?.signal?.cancel()
            throw CancellationError()
        }
        return BashResult(output: chunks.joined(), exitCode: 0, cancelled: false, truncated: false)
    }
}

// Upstream 66c6556771bcdbfbd37496e77f05515e99d1a2dd, test/bash-executor-truncation.test.ts:
// "reports discarded chunks when cancelled=%s" and "does not mark short output as truncated".
@Test(arguments: [false, true])
func ctaBashReportsDiscardedChunks(_ cancelled: Bool) async throws {
    let first = "error: missing build dependency\n".padding(toLength: 64 * 1024, withPad: "x", startingAt: 0)
    let last = "remaining build output\n".padding(toLength: 44 * 1024, withPad: "y", startingAt: 0)
    let result = try await executeBashWithOperations("cat build.log",
        operations: CTAChunkBashOperations(chunks: [first, last], cancel: cancelled),
        options: BashExecutorOptions(signal: CancellationToken()))
    let path = try #require(result.fullOutputPath)
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(try String(contentsOfFile: path, encoding: .utf8) == first + last)
    #expect(result.cancelled == cancelled)
    #expect(result.output == last)
    #expect(result.truncated)
    let text = bashExecutionToText(BashExecutionMessage(command: "cat build.log", output: result.output,
        exitCode: result.exitCode, cancelled: result.cancelled, truncated: result.truncated,
        fullOutputPath: path, timestamp: 0))
    #expect(text.contains("[Output truncated. Full output: \(path)]"))
}

@Test func ctaBashDoesNotMarkShortOutputAsTruncated() async throws {
    let result = try await executeBashWithOperations("echo done", operations: CTAChunkBashOperations(chunks: ["done\n"]))
    #expect(result.output == "done\n")
    #expect(!result.truncated)
    #expect(result.fullOutputPath == nil)
}

#if !canImport(UIKit) && !os(Windows)
// Upstream 06aa6563e4d51d6df5de6c9664c3a868f3f5bb2a:
// test/suite/regressions/11613-bash-timeout-after-shell-exit.test.ts.
@Test(.timeLimit(.minutes(1))) func ctaBashTimeoutReportsShellExitWhileBackgroundKeepsWriting() async throws {
    do {
        _ = try await createBashTool(cwd: FileManager.default.temporaryDirectory.path).execute("timeout", [
            "command": AnyCodable("(for i in {1..100}; do echo tick; sleep 0.05; done) & sleep 0.1; exit 3"),
            "timeout": AnyCodable(1),
        ], nil, nil)
        Issue.record("Expected timeout")
    } catch {
        let message = error.localizedDescription
        #expect(message.contains("Command timed out after 1 seconds. The shell exited with code 3 after "))
        #expect(message.hasSuffix("seconds, but background processes it started kept writing output until the timeout."))
    }
}

@Test(.timeLimit(.minutes(1))) func ctaBashTimeoutWhileShellRunsKeepsPlainMessage() async throws {
    do {
        _ = try await createBashTool(cwd: FileManager.default.temporaryDirectory.path).execute("timeout", [
            "command": AnyCodable("sleep 5"), "timeout": AnyCodable(1),
        ], nil, nil)
        Issue.record("Expected timeout")
    } catch {
        #expect(error.localizedDescription == "(no output)\n\nCommand timed out after 1 seconds")
    }
}
#endif

@Test func ctaBashTimeoutStatusUsesExactUpstreamFormat() {
    let error = BashToolError.commandTimedOut(seconds: 3, output: "boom",
        shellExit: BashShellExit(exitCode: 1, afterSeconds: 1.1))
    #expect(error.localizedDescription == "boom\n\nCommand timed out after 3 seconds. The shell exited with code 1 after 1.1 seconds, but background processes it started kept writing output until the timeout.")
}

// Upstream 463b8f8938eee62fa6f14de438a39b0033389d99:
// test/suite/regressions/3302-find-path-glob.test.ts, including the POSIX cases.
@Test func ctaFindPathGlobPatternsMatchDirectAndNestedFiles() async throws {
    try await ctaWithDirectory { path in
        for directory in ["some/parent/child", "src/foo/bar"] {
            try FileManager.default.createDirectory(atPath: path + "/" + directory, withIntermediateDirectories: true)
        }
        try ctaWriteFiles(["some/parent/child/file.ext", "some/parent/child/test.spec.ts",
                           "src/foo/bar/example.spec.ts", "src/direct.spec.ts", "src/a&b (1).ts"], in: path)
        let tool = createFindTool(cwd: path)
        let cases: [(String, [String])] = [
            ("*.spec.ts", ["some/parent/child/test.spec.ts", "src/direct.spec.ts", "src/foo/bar/example.spec.ts"]),
            ("some/parent/child/**", ["some/parent/child/file.ext", "some/parent/child/test.spec.ts"]),
            ("**/parent/child/*", ["some/parent/child/file.ext", "some/parent/child/test.spec.ts"]),
            ("src/**/*.spec.ts", ["src/direct.spec.ts", "src/foo/bar/example.spec.ts"]),
            ("src/*.spec.ts", ["src/direct.spec.ts"]),
            ("{src,some}/**/[et]*.spec.ts", ["some/parent/child/test.spec.ts", "src/foo/bar/example.spec.ts"]),
            ("src/[!x]&b (1).ts", ["src/a&b (1).ts"]),
        ]
        for (pattern, expected) in cases {
            let result = try await tool.execute("glob", ["pattern": AnyCodable(pattern)], nil, nil)
            #expect(ctaToolText(result).components(separatedBy: "\n").sorted() == expected)
            #expect(result.details == nil)
        }
        let limited = try await tool.execute("limit", ["pattern": AnyCodable("src/**/*.spec.ts"), "limit": AnyCodable(1)], nil, nil)
        #expect(limited.details == AnyCodable(["resultLimitReached": 1]))
        #expect(["src/direct.spec.ts", "src/foo/bar/example.spec.ts"].contains(ctaToolText(limited).components(separatedBy: "\n")[0]))
        #if os(Windows)
        for (pattern, expected) in [
            (#"src\**\*.spec.ts"#, ["src/direct.spec.ts", "src/foo/bar/example.spec.ts"]),
            (#"src\*.spec.ts"#, ["src/direct.spec.ts"]),
            (#"**\parent\child\*"#, ["some/parent/child/file.ext", "some/parent/child/test.spec.ts"]),
            (#"src\**/*.spec.ts"#, ["src/direct.spec.ts", "src/foo/bar/example.spec.ts"]),
        ] {
            let result = try await tool.execute("windows-glob", ["pattern": AnyCodable(pattern)], nil, nil)
            #expect(ctaToolText(result).components(separatedBy: "\n").sorted() == expected)
        }
        #else
        try ctaWriteFiles(["src/*.ts", "src/other.ts"], in: path)
        let escaped = try await tool.execute("escaped", ["pattern": AnyCodable(#"src/\*.ts"#)], nil, nil)
        #expect(ctaToolText(escaped) == "src/*.ts")
        #endif
    }
}
