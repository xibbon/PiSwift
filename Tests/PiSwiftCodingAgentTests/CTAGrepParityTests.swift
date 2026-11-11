import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

private func ctaGrepDirectory(_ body: (URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-cta-grep-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root)
}

private func ctaGrepText(_ result: AgentToolResult) -> String {
    result.content.compactMap {
        if case .text(let text) = $0 { return text.text }
        return nil
    }.joined(separator: "\n")
}

private func ctaGrepDetails(_ result: AgentToolResult) -> [String: Any] {
    result.details?.value as? [String: Any] ?? [:]
}

private func ctaGrep(_ root: URL, _ file: String, _ text: String, _ parameters: [String: AnyCodable] = [:]) async throws -> AgentToolResult {
    try text.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
    var params = parameters
    params["path"] = AnyCodable(file)
    if params["pattern"] == nil { params["pattern"] = AnyCodable("needle") }
    return try await createGrepTool(cwd: root.path).execute("cta-grep", params, nil, nil)
}

struct CTAGrepParityTests {
    // fecc19e4e tools.test.ts:912; final expectation in 8da141c2a tools.test.ts:912.
    @Test("should keep context line numbers aligned with ripgrep when a file contains a lone CR")
    func loneCRContext() async throws {
        try await ctaGrepDirectory { root in
            let result = try await ctaGrep(root, "lone-cr.txt", "before\rprogress\nneedle\nafter", ["context": AnyCodable(1)])
            #expect(ctaGrepText(result) == "lone-cr.txt-1- before\rprogress\nlone-cr.txt:2: needle\nlone-cr.txt-3- after")
        }
    }

    // 8da141c2a tools.test.ts:930.
    @Test("should print overlapping context once and keep the last match's trailing context")
    func mergedContext() async throws {
        try await ctaGrepDirectory { root in
            let result = try await ctaGrep(root, "rg-context.txt", "a\nmatch one\nb\nmatch two\nmatch three\nc\nmatch four", [
                "pattern": AnyCodable("match"), "context": AnyCodable(1), "limit": AnyCodable(2),
            ])
            #expect(ctaGrepText(result) == "rg-context.txt-1- a\nrg-context.txt:2: match one\nrg-context.txt-3- b\nrg-context.txt:4: match two\nrg-context.txt-5- match three\n\n[2 matches limit reached. Use limit=4 for more, or refine pattern]")
        }
    }

    // 8da141c2a tools.test.ts:953.
    @Test("should keep counting matches past the byte cap")
    func countsPastByteCap() async throws {
        try await ctaGrepDirectory { root in
            let line = "match " + String(repeating: "x", count: 400)
            let result = try await ctaGrep(root, "byte-cap.txt", Array(repeating: line, count: 200).joined(separator: "\n"), ["pattern": AnyCodable("match"), "limit": AnyCodable(150)])
            #expect(ctaGrepText(result).contains("150 matches limit reached"))
            #expect(ctaGrepText(result).contains("50.0KB limit reached"))
            #expect(ctaGrepDetails(result)["matchLimitReached"] as? Int == 150)
            let truncation = ctaGrepDetails(result)["truncation"] as? [String: Any]
            #expect(truncation?["totalLines"] as? Int == 150)
            let expectedBytes = (1...150).reduce(0) { $0 + "byte-cap.txt:\($1): \(line)".utf8.count + 1 } - 1
            #expect(truncation?["totalBytes"] as? Int == expectedBytes)
        }
    }

    // 8da141c2a tools.test.ts:972.
    @Test("should report truncation when stored output ends exactly at the byte cap")
    func exactByteCap() async throws {
        try await ctaGrepDirectory { root in
            let lines = Array(repeating: String(repeating: "x", count: 490), count: 103) + [String(repeating: "x", count: 7), "extra x"]
            let result = try await ctaGrep(root, "x", lines.joined(separator: "\n"), ["pattern": AnyCodable("x"), "limit": AnyCodable(1000)])
            #expect(ctaGrepText(result).hasSuffix("[50.0KB limit reached]"))
            #expect((ctaGrepDetails(result)["truncation"] as? [String: Any])?["totalLines"] as? Int == 105)
        }
    }

    // 8da141c2a tools.test.ts:988.
    @Test("should accept a huge context value")
    func hugeContext() async throws {
        try await ctaGrepDirectory { root in
            let result = try await ctaGrep(root, "huge-context.txt", "before\nneedle\nafter", ["context": AnyCodable(1e30)])
            #expect(ctaGrepText(result) == "huge-context.txt-1- before\nhuge-context.txt:2: needle\nhuge-context.txt-3- after")
        }
    }

    // 8da141c2a tools.test.ts:1004. Also check the big-endian BOM.
    @Test("should decode UTF-16 files with context", arguments: [false, true])
    func utf16Context(bigEndian: Bool) async throws {
        try await ctaGrepDirectory { root in
            let file = root.appendingPathComponent("utf16.txt")
            let text = "before\nneedle 中文\nafter\n"
            var data = Data(bigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE])
            data.append(try #require(text.data(using: bigEndian ? .utf16BigEndian : .utf16LittleEndian)))
            try data.write(to: file)
            let result = try await createGrepTool(cwd: root.path).execute("utf16", ["pattern": AnyCodable("needle"), "path": AnyCodable(file.path), "context": AnyCodable(1)], nil, nil)
            #expect(ctaGrepText(result) == "utf16.txt-1- before\nutf16.txt:2: needle 中文\nutf16.txt-3- after")
        }
    }

    // 8da141c2a tools.test.ts:1019.
    @Test("should keep a lone CR inside a line and strip CRLF terminators", arguments: [0, 1])
    func crlfTerminators(context: Int) async throws {
        try await ctaGrepDirectory { root in
            let result = try await ctaGrep(root, "mixed-cr.txt", "one\rtwo needle\r\nnext\r\n", ["context": AnyCodable(context)])
            #expect(ctaGrepText(result) == "mixed-cr.txt:1: one\rtwo needle" + (context == 1 ? "\nmixed-cr.txt-2- next" : ""))
        }
    }

    // 8da141c2a tools.test.ts:1036 (including its fractional-limit vector).
    @Test("should not report the match limit when exactly limit matches exist", arguments: [0, 1])
    func exactMatchLimit(context: Int) async throws {
        try await ctaGrepDirectory { root in
            let text = "match one\nx\nmatch two\ny"
            let exact = try await ctaGrep(root, "exact-limit.txt", text, ["pattern": AnyCodable("match"), "context": AnyCodable(context), "limit": AnyCodable(2)])
            #expect(!ctaGrepText(exact).contains("limit reached"))
            #expect(ctaGrepDetails(exact)["matchLimitReached"] == nil)
            for limit in [1.0, 1.5, 0.0, -1.0] {
                let over = try await ctaGrep(root, "exact-limit.txt", text, ["pattern": AnyCodable("match"), "context": AnyCodable(context), "limit": AnyCodable(limit)])
                #expect(ctaGrepText(over).contains("[1 matches limit reached. Use limit=2 for more, or refine pattern]"))
                #expect(ctaGrepDetails(over)["matchLimitReached"] as? Int == 1)
            }
        }
    }

    // 6bf2ab9bb tools.test.ts:1102.
    @Test("should resolve folder globs relative to path")
    func relativeFolderGlobs() async throws {
        try await ctaGrepDirectory { root in
            let repo = root.appendingPathComponent("repo")
            for path in ["migrations/main/a.js", "nested/migrations/main/b.js"] {
                let file = repo.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "hello\n".write(to: file, atomically: true, encoding: .utf8)
            }
            let link = root.appendingPathComponent("repo-link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo)
            for path in ["repo", "repo-link", repo.path, link.path] {
                for glob in ["migrations/main/*.js", "./migrations/main/*.js", "././migrations/main/*.js", "**/migrations/main/*.js", "*.js", "!./migrations/**", "!././migrations/**"] {
                    let result = try await createGrepTool(cwd: root.path).execute("glob", ["pattern": AnyCodable("hello"), "path": AnyCodable(path), "glob": AnyCodable(glob)], nil, nil)
                    let actual = ctaGrepText(result).split(separator: "\n").map(String.init).sorted()
                    let expected = glob.hasPrefix("!") ? ["nested/migrations/main/b.js:1: hello"] : (glob.hasPrefix("**/") || glob == "*.js") ? ["migrations/main/a.js:1: hello", "nested/migrations/main/b.js:1: hello"] : ["migrations/main/a.js:1: hello"]
                    #expect(actual == expected)
                }
            }
            let result = try await createGrepTool(cwd: root.path).execute("single-file-glob", ["pattern": AnyCodable("hello"), "path": AnyCodable("repo/migrations/main/a.js"), "glob": AnyCodable("*.swift")], nil, nil)
            #expect(ctaGrepText(result) == "a.js:1: hello")
        }
    }

    // 244e5f5db grep-operations.test.ts:19.
    @Test("accepts a deprecated synchronous or asynchronous readFile hook without calling it", arguments: [false, true])
    func ignoredLegacyReadHook(asynchronous: Bool) async throws {
        try await ctaGrepDirectory { root in
            try "before\nneedle\nafter\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            let read: @Sendable (String) async throws -> String = asynchronous ? { @Sendable _ in
                await Task.yield()
                Issue.record("The search called the legacy readFile hook")
                return "custom context"
            } : { @Sendable _ in
                Issue.record("The search called the legacy readFile hook")
                return "custom context"
            }
            let operations = GrepOperations(isDirectory: { _ in true }, readFile: read)
            let result = try await createGrepTool(cwd: root.path, options: GrepToolOptions(operations: operations)).execute("operations", ["pattern": AnyCodable("needle"), "context": AnyCodable(1)], nil, nil)
            #expect(ctaGrepText(result) == "file.txt-1- before\nfile.txt:2: needle\nfile.txt-3- after")
        }
    }

    // 244e5f5db grep-operations.test.ts:30.
    @Test("allows custom operations without a readFile hook")
    func operationsWithoutReadHook() async throws {
        try await ctaGrepDirectory { root in
            try "before\nneedle\nafter\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            let operations = GrepOperations(isDirectory: { _ in true })
            let result = try await createGrepTool(cwd: root.path, options: GrepToolOptions(operations: operations)).execute("operations", ["pattern": AnyCodable("needle"), "context": AnyCodable(1)], nil, nil)
            #expect(ctaGrepText(result) == "file.txt-1- before\nfile.txt:2: needle\nfile.txt-3- after")
            let originalFactory: (String) -> AgentTool = createGrepTool(cwd:)
            #expect(originalFactory(root.path).name == "grep")
        }
    }

    // Additional native-backend regression: a parse failure must not become a negative result.
    @Test("should surface regex parse errors")
    func invalidRegex() async throws {
        try await ctaGrepDirectory { root in
            try "[\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            do {
                _ = try await createGrepTool(cwd: root.path).execute("invalid", ["pattern": AnyCodable("[")], nil, nil)
                Issue.record("The search accepted an invalid regular expression")
            } catch {
                #expect(error.localizedDescription.contains("Invalid regular expression"))
            }
            let literal = try await createGrepTool(cwd: root.path).execute("literal", ["pattern": AnyCodable("["), "literal": AnyCodable(true)], nil, nil)
            #expect(ctaGrepText(literal) == "file.txt:1: [")
        }
    }

    @Test("should stream lines across read blocks without adding a final empty line")
    func blockBoundaries() async throws {
        try await ctaGrepDirectory { root in
            let before = String(repeating: "a", count: 65535)
            let result = try await ctaGrep(root, "blocks.txt", before + "\r\nneedle\n", ["context": AnyCodable(1)])
            #expect(ctaGrepText(result).contains("blocks.txt:2: needle"))
            #expect(!ctaGrepText(result).contains("blocks.txt-3-"))
            #expect(ctaGrepDetails(result)["linesTruncated"] as? Bool == true)
            #expect(ctaGrepText(result).contains("Some lines truncated to 500 chars"))
        }
    }
}
