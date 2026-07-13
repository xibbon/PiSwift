import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

private func textOutput(_ result: AgentToolResult) -> String {
    result.content.compactMap { block in
        if case .text(let text) = block { return text.text }
        return nil
    }.joined(separator: "\n")
}

private func runTool(_ tool: AgentTool, _ id: String, _ params: [String: AnyCodable]) async throws -> AgentToolResult {
    try await tool.execute(id, params, nil, nil)
}

private func withTempDir(_ body: (String) async throws -> Void) async rethrows {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("coding-agent-test-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    try await body(tempDir)
}

@Test func readToolReadsFile() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("test.txt").path
        let content = "Hello, world!\nLine 2\nLine 3"
        try content.write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = try await runTool(createReadTool(cwd: dir), "test-call-1", ["path": AnyCodable(testFile)])
        #expect(textOutput(result) == content)
        #expect(result.details == nil)
    }
}

@Test func readToolNonExistent() async {
    await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("missing.txt").path
        do {
            _ = try await runTool(createReadTool(cwd: dir), "test-call-2", ["path": AnyCodable(testFile)])
            #expect(Bool(false), "Expected read to throw")
        } catch {
            #expect(error.localizedDescription.lowercased().contains("not found") || error.localizedDescription.lowercased().contains("no such file"))
        }
    }
}

@Test func readToolTruncatesByLines() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("large.txt").path
        let lines = (0..<2500).map { "Line \($0 + 1)" }.joined(separator: "\n")
        try lines.write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = try await runTool(createReadTool(cwd: dir), "test-call-3", ["path": AnyCodable(testFile)])
        let output = textOutput(result)
        #expect(output.contains("Line 1"))
        #expect(output.contains("Line 2000"))
        #expect(!output.contains("Line 2001"))
        #expect(output.contains("Use offset=2001"))

        let details = result.details?.value as? [String: Any]
        let truncation = details?["truncation"] as? [String: Any]
        #expect(truncation?["truncated"] as? Bool == true)
        #expect(truncation?["truncatedBy"] as? String == "lines")
        #expect(truncation?["totalLines"] as? Int == 2500)
        #expect(truncation?["outputLines"] as? Int == 2000)
    }
}

@Test func readToolTruncatesByBytes() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("large-bytes.txt").path
        let lines = (0..<500).map { "Line \($0 + 1): " + String(repeating: "x", count: 200) }.joined(separator: "\n")
        try lines.write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = try await runTool(createReadTool(cwd: dir), "test-call-4", ["path": AnyCodable(testFile)])
        let output = textOutput(result)
        #expect(output.contains("Line 1:"))
        #expect(output.contains("limit"))
    }
}

@Test func editToolPrepareArgumentsFoldsLegacySingleEditBeforeValidation() async throws {
    try await withTempDir { dir in
        let tool = createEditTool(cwd: dir)
        let raw: [String: AnyCodable] = [
            "path": AnyCodable("file.txt"),
            "oldText": AnyCodable("old"),
            "newText": AnyCodable("new"),
        ]

        let prepared = try await tool.prepareArguments?(raw) ?? raw
        _ = try validateToolArguments(
            tool: tool.aiTool,
            toolCall: ToolCall(id: "edit-legacy", name: "edit", arguments: prepared)
        )

        #expect(prepared["oldText"] == nil)
        #expect(prepared["newText"] == nil)
        let edits = prepared["edits"]?.value as? [Any]
        let first = edits?.first as? [String: Any]
        #expect(first?["oldText"] as? String == "old")
        #expect(first?["newText"] as? String == "new")
    }
}

@Test func editToolSchemaAllowsModelInventedReplacementFields() async throws {
    try await withTempDir { dir in
        let tool = createEditTool(cwd: dir)
        let arguments: [String: AnyCodable] = [
            "path": AnyCodable("file.txt"),
            "edits": AnyCodable([[
                "oldText": "old",
                "newText": "new",
                "explanation": "Model-added metadata",
            ]]),
        ]

        _ = try validateToolArguments(
            tool: tool.aiTool,
            toolCall: ToolCall(id: "edit-extra-fields", name: "edit", arguments: arguments)
        )
    }
}

@Test func readToolOffsetAndLimit() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("offset.txt").path
        let lines = (0..<100).map { "Line \($0 + 1)" }.joined(separator: "\n")
        try lines.write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = try await runTool(createReadTool(cwd: dir), "test-call-5", ["path": AnyCodable(testFile), "offset": AnyCodable(51)])
        let output = textOutput(result)
        #expect(!output.contains("Line 50"))
        #expect(output.contains("Line 51"))
        #expect(output.contains("Line 100"))

        let limited = try await runTool(createReadTool(cwd: dir), "test-call-6", ["path": AnyCodable(testFile), "limit": AnyCodable(10)])
        let limitedOutput = textOutput(limited)
        #expect(limitedOutput.contains("Line 10"))
        #expect(!limitedOutput.contains("Line 11"))
        #expect(limitedOutput.contains("Use offset=11"))

        let offsetLimit = try await runTool(createReadTool(cwd: dir), "test-call-7", [
            "path": AnyCodable(testFile),
            "offset": AnyCodable(41),
            "limit": AnyCodable(20),
        ])
        let offsetOutput = textOutput(offsetLimit)
        #expect(offsetOutput.contains("Line 41"))
        #expect(offsetOutput.contains("Line 60"))
        #expect(!offsetOutput.contains("Line 61"))
        #expect(offsetOutput.contains("Use offset=61"))
    }
}

@Test func readToolOffsetBeyondEnd() async {
    await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("short.txt").path
        try? "Line 1\nLine 2\nLine 3".write(toFile: testFile, atomically: true, encoding: .utf8)

        do {
            _ = try await runTool(createReadTool(cwd: dir), "test-call-8", ["path": AnyCodable(testFile), "offset": AnyCodable(100)])
            #expect(Bool(false), "Expected offset error")
        } catch {
            #expect(error.localizedDescription.contains("Offset 100"))
        }
    }
}

@Test func readToolImageDetection() async throws {
    try await withTempDir { dir in
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X2Z0AAAAASUVORK5CYII="
        let pngData = Data(base64Encoded: pngBase64) ?? Data()
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("image.txt").path
        try pngData.write(to: URL(fileURLWithPath: testFile))

        let result = try await runTool(createReadTool(cwd: dir), "test-call-img-1", ["path": AnyCodable(testFile)])
        if let first = result.content.first {
            if case .text = first {
                #expect(true)
            } else {
                #expect(Bool(false), "Expected first content block to be text")
            }
        }
        #expect(textOutput(result).contains("Read image file [image/png]"))
        let imageBlock = result.content.first { block in
            if case .image = block { return true }
            return false
        }
        #expect(imageBlock != nil)
    }
}

@Test func readToolImageExtensionNonImage() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("not-an-image.png").path
        try "definitely not a png".write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = try await runTool(createReadTool(cwd: dir), "test-call-img-2", ["path": AnyCodable(testFile)])
        #expect(textOutput(result).contains("definitely not a png"))
        let hasImage = result.content.contains { block in
            if case .image = block { return true }
            return false
        }
        #expect(!hasImage)
    }
}

@Test func writeToolWritesFile() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("write-test.txt").path
        let result = try await runTool(createWriteTool(cwd: dir), "test-call-3", ["path": AnyCodable(testFile), "content": AnyCodable("Test content")])
        let output = textOutput(result)
        #expect(output.contains("Successfully wrote"))
        #expect(output.contains(testFile))
    }
}

@Test func writeToolCreatesParents() async throws {
    try await withTempDir { dir in
        let nested = URL(fileURLWithPath: dir).appendingPathComponent("nested/dir/test.txt").path
        let result = try await runTool(createWriteTool(cwd: dir), "test-call-4", ["path": AnyCodable(nested), "content": AnyCodable("Nested content")])
        #expect(textOutput(result).contains("Successfully wrote"))
    }
}

@Test func editToolReplacesText() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("edit-test.txt").path
        try "Hello, world!".write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = try await runTool(createEditTool(cwd: dir), "test-call-5", [
            "path": AnyCodable(testFile),
            "oldText": AnyCodable("world"),
            "newText": AnyCodable("testing"),
        ])
        #expect(textOutput(result).contains("Successfully replaced"))
        let details = result.details?.value as? [String: Any]
        #expect(details?["diff"] as? String != nil)
    }
}

@Test func editToolNotFound() async {
    await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("edit-test.txt").path
        try? "Hello, world!".write(toFile: testFile, atomically: true, encoding: .utf8)

        do {
            _ = try await runTool(createEditTool(cwd: dir), "test-call-6", [
                "path": AnyCodable(testFile),
                "oldText": AnyCodable("nonexistent"),
                "newText": AnyCodable("testing"),
            ])
            #expect(Bool(false), "Expected edit failure")
        } catch {
            #expect(error.localizedDescription.contains("Could not find the exact text"))
        }
    }
}

@Test func editToolMultipleOccurrences() async {
    await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("edit-test.txt").path
        try? "foo foo foo".write(toFile: testFile, atomically: true, encoding: .utf8)

        do {
            _ = try await runTool(createEditTool(cwd: dir), "test-call-7", [
                "path": AnyCodable(testFile),
                "oldText": AnyCodable("foo"),
                "newText": AnyCodable("bar"),
            ])
            #expect(Bool(false), "Expected edit failure")
        } catch {
            #expect(error.localizedDescription.contains("Found 3 occurrences"))
        }
    }
}

@Test func bashToolExecutes() async throws {
    let cwd = FileManager.default.currentDirectoryPath
    let result = try await runTool(createBashTool(cwd: cwd), "test-call-8", ["command": AnyCodable("echo 'test output'")])
    #expect(textOutput(result).contains("test output"))
}

@Test func bashToolErrors() async {
    let cwd = FileManager.default.currentDirectoryPath
    do {
        _ = try await runTool(createBashTool(cwd: cwd), "test-call-9", ["command": AnyCodable("exit 1")])
        #expect(Bool(false), "Expected bash failure")
    } catch {
        #expect(error.localizedDescription.contains("code 1") || error.localizedDescription.contains("Command"))
    }
}

@Test func bashToolTimeout() async {
    let cwd = FileManager.default.currentDirectoryPath
    do {
        _ = try await runTool(createBashTool(cwd: cwd), "test-call-10", ["command": AnyCodable("sleep 5"), "timeout": AnyCodable(1)])
        #expect(Bool(false), "Expected timeout")
    } catch {
        #expect(error.localizedDescription.lowercased().contains("timed out"))
    }
}

@Test func grepToolSingleFile() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("example.txt").path
        try "first line\nmatch line\nlast line".write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = try await runTool(createGrepTool(cwd: dir), "test-call-11", [
            "pattern": AnyCodable("match"),
            "path": AnyCodable(testFile),
        ])
        #expect(textOutput(result).contains("example.txt:2: match line"))
    }
}

@Test func grepToolContextLimit() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("context.txt").path
        let content = ["before", "match one", "after", "middle", "match two", "after two"].joined(separator: "\n")
        try content.write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = try await runTool(createGrepTool(cwd: dir), "test-call-12", [
            "pattern": AnyCodable("match"),
            "path": AnyCodable(testFile),
            "limit": AnyCodable(1),
            "context": AnyCodable(1),
        ])
        let output = textOutput(result)
        #expect(output.contains("context.txt-1- before"))
        #expect(output.contains("context.txt:2: match one"))
        #expect(output.contains("context.txt-3- after"))
        #expect(output.contains("limit reached"))
        #expect(!output.contains("match two"))
    }
}

@Test func findToolIncludesHidden() async throws {
    try await withTempDir { dir in
        let hiddenDir = URL(fileURLWithPath: dir).appendingPathComponent(".secret")
        try FileManager.default.createDirectory(at: hiddenDir, withIntermediateDirectories: true)
        try "hidden".write(to: hiddenDir.appendingPathComponent("hidden.txt"), atomically: true, encoding: .utf8)
        try "visible".write(to: URL(fileURLWithPath: dir).appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)

        let result = try await runTool(createFindTool(cwd: dir), "test-call-13", [
            "pattern": AnyCodable("**/*.txt"),
            "path": AnyCodable(dir),
        ])
        let lines = textOutput(result).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.contains("visible.txt"))
        #expect(lines.contains(".secret/hidden.txt"))
    }
}

@Test func findToolRespectsGitignore() async throws {
    try await withTempDir { dir in
        try "ignored.txt\n".write(to: URL(fileURLWithPath: dir).appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "ignored".write(to: URL(fileURLWithPath: dir).appendingPathComponent("ignored.txt"), atomically: true, encoding: .utf8)
        try "kept".write(to: URL(fileURLWithPath: dir).appendingPathComponent("kept.txt"), atomically: true, encoding: .utf8)

        let result = try await runTool(createFindTool(cwd: dir), "test-call-14", [
            "pattern": AnyCodable("**/*.txt"),
            "path": AnyCodable(dir),
        ])
        let output = textOutput(result)
        #expect(output.contains("kept.txt"))
        #expect(!output.contains("ignored.txt"))
    }
}

@Test func lsToolListsDotfiles() async throws {
    try await withTempDir { dir in
        try "secret".write(to: URL(fileURLWithPath: dir).appendingPathComponent(".hidden-file"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: dir).appendingPathComponent(".hidden-dir"), withIntermediateDirectories: true)

        let result = try await runTool(createLsTool(cwd: dir), "test-call-15", ["path": AnyCodable(dir)])
        let output = textOutput(result)
        #expect(output.contains(".hidden-file"))
        #expect(output.contains(".hidden-dir/"))
    }
}

@Test func editToolCRLFHandling() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("crlf-test.txt").path
        try "line one\r\nline two\r\nline three\r\n".write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = try await runTool(createEditTool(cwd: dir), "test-crlf-1", [
            "path": AnyCodable(testFile),
            "oldText": AnyCodable("line two\n"),
            "newText": AnyCodable("replaced line\n"),
        ])
        #expect(textOutput(result).contains("Successfully replaced"))

        let content = try String(contentsOfFile: testFile, encoding: .utf8)
        #expect(content == "line one\r\nreplaced line\r\nline three\r\n")
    }
}

@Test func editToolPreservesLF() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("lf-test.txt").path
        try "first\nsecond\nthird\n".write(toFile: testFile, atomically: true, encoding: .utf8)

        _ = try await runTool(createEditTool(cwd: dir), "test-lf-1", [
            "path": AnyCodable(testFile),
            "oldText": AnyCodable("second\n"),
            "newText": AnyCodable("REPLACED\n"),
        ])

        let content = try String(contentsOfFile: testFile, encoding: .utf8)
        #expect(content == "first\nREPLACED\nthird\n")
    }
}

// MARK: - Edit tool additional tests

@Test func editToolFuzzyPrefersExactMatch() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("exact-preferred.txt").path
        // File has both exact and fuzzy-matchable content
        try "const x = 'exact';\nconst y = 'other';\n".write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = try await runTool(createEditTool(cwd: dir), "test-fuzzy-6", [
            "path": AnyCodable(testFile),
            "oldText": AnyCodable("const x = 'exact';"),
            "newText": AnyCodable("const x = 'changed';"),
        ])
        #expect(textOutput(result).contains("Successfully replaced"))

        let content = try String(contentsOfFile: testFile, encoding: .utf8)
        #expect(content == "const x = 'changed';\nconst y = 'other';\n")
    }
}

@Test func editToolFuzzyStillFailsWhenNotFound() async {
    await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("no-match.txt").path
        try? "completely different content\n".write(toFile: testFile, atomically: true, encoding: .utf8)

        do {
            _ = try await runTool(createEditTool(cwd: dir), "test-fuzzy-7", [
                "path": AnyCodable(testFile),
                "oldText": AnyCodable("this does not exist"),
                "newText": AnyCodable("replacement"),
            ])
            #expect(Bool(false), "Expected edit to fail")
        } catch {
            #expect(error.localizedDescription.contains("Could not find the exact text"))
        }
    }
}

@Test func editToolFuzzyDuplicatesDetected() async {
    await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("fuzzy-dups.txt").path
        // Two lines that are identical after trailing whitespace is stripped
        try? "hello world   \nhello world\n".write(toFile: testFile, atomically: true, encoding: .utf8)

        do {
            _ = try await runTool(createEditTool(cwd: dir), "test-fuzzy-8", [
                "path": AnyCodable(testFile),
                "oldText": AnyCodable("hello world"),
                "newText": AnyCodable("replaced"),
            ])
            #expect(Bool(false), "Expected duplicate error")
        } catch {
            #expect(error.localizedDescription.contains("Found 2 occurrences"))
        }
    }
}

@Test func editToolCRLFDuplicatesDetected() async {
    await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("mixed-endings.txt").path
        try? "hello\r\nworld\r\n---\r\nhello\nworld\n".write(toFile: testFile, atomically: true, encoding: .utf8)

        do {
            _ = try await runTool(createEditTool(cwd: dir), "test-crlf-dup", [
                "path": AnyCodable(testFile),
                "oldText": AnyCodable("hello\nworld\n"),
                "newText": AnyCodable("replaced\n"),
            ])
            #expect(Bool(false), "Expected duplicate error")
        } catch {
            #expect(error.localizedDescription.contains("Found 2 occurrences"))
        }
    }
}

// MARK: - BOM Preservation Tests

@Test func editToolPreservesBOM() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("bom-test.txt").path
        // Write file with BOM using Data to ensure it's written correctly
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let content = "first line\nsecond line\n"
        var data = Data(bom)
        data.append(content.data(using: .utf8)!)
        try data.write(to: URL(fileURLWithPath: testFile))

        let result = try await runTool(createEditTool(cwd: dir), "test-bom-1", [
            "path": AnyCodable(testFile),
            "oldText": AnyCodable("first line"),
            "newText": AnyCodable("modified line"),
        ])
        #expect(textOutput(result).contains("Successfully replaced"))

        // Verify BOM is preserved
        let readData = try Data(contentsOf: URL(fileURLWithPath: testFile))
        #expect(readData.prefix(3) == Data(bom))

        let readContent = try String(contentsOfFile: testFile, encoding: .utf8)
        #expect(readContent.contains("modified line"))
    }
}

// MARK: - Fuzzy Matching Tests

@Test func editToolFuzzySmartQuotes() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("smart-quotes.txt").path
        // File contains smart quotes (U+2018, U+2019)
        try "const msg = \u{2018}hello world\u{2019};\n".write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = try await runTool(createEditTool(cwd: dir), "test-smart-quotes", [
            "path": AnyCodable(testFile),
            // User provides straight quotes
            "oldText": AnyCodable("const msg = 'hello world';"),
            "newText": AnyCodable("const msg = 'goodbye world';"),
        ])
        #expect(textOutput(result).contains("Successfully replaced"))

        let content = try String(contentsOfFile: testFile, encoding: .utf8)
        #expect(content.contains("goodbye world"))
    }
}

@Test func editToolFuzzyDoubleSmartQuotes() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("smart-dquotes.txt").path
        // File contains smart double quotes (U+201C, U+201D)
        try "const msg = \u{201C}hello world\u{201D};\n".write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = try await runTool(createEditTool(cwd: dir), "test-smart-dquotes", [
            "path": AnyCodable(testFile),
            // User provides straight double quotes
            "oldText": AnyCodable("const msg = \"hello world\";"),
            "newText": AnyCodable("const msg = \"goodbye world\";"),
        ])
        #expect(textOutput(result).contains("Successfully replaced"))
    }
}

@Test func editToolFuzzyUnicodeDashes() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("unicode-dash.txt").path
        // File contains en-dash (U+2013)
        try "range: 1\u{2013}10\n".write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = try await runTool(createEditTool(cwd: dir), "test-unicode-dash", [
            "path": AnyCodable(testFile),
            // User provides regular hyphen
            "oldText": AnyCodable("range: 1-10"),
            "newText": AnyCodable("range: 1-20"),
        ])
        #expect(textOutput(result).contains("Successfully replaced"))

        let content = try String(contentsOfFile: testFile, encoding: .utf8)
        #expect(content.contains("1-20"))
    }
}

@Test func editToolFuzzyNBSP() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("nbsp.txt").path
        // File contains narrow no-break space (U+202F) before AM
        try "Time: 10:00\u{202F}AM\n".write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = try await runTool(createEditTool(cwd: dir), "test-nbsp", [
            "path": AnyCodable(testFile),
            // User provides regular space
            "oldText": AnyCodable("Time: 10:00 AM"),
            "newText": AnyCodable("Time: 11:00 AM"),
        ])
        #expect(textOutput(result).contains("Successfully replaced"))

        let content = try String(contentsOfFile: testFile, encoding: .utf8)
        #expect(content.contains("11:00"))
    }
}

@Test func editToolFuzzyTrailingWhitespace() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("trailing-ws.txt").path
        // File has trailing whitespace that user doesn't include
        try "hello world   \ngoodbye\n".write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = try await runTool(createEditTool(cwd: dir), "test-trailing-ws", [
            "path": AnyCodable(testFile),
            // User doesn't include trailing whitespace
            "oldText": AnyCodable("hello world\ngoodbye"),
            "newText": AnyCodable("hello there\ngoodbye"),
        ])
        #expect(textOutput(result).contains("Successfully replaced"))

        let content = try String(contentsOfFile: testFile, encoding: .utf8)
        #expect(content.contains("hello there"))
    }
}

// MARK: - Bash tool additional tests

@Test func bashToolNonExistentCwd() async {
    let nonexistentCwd = "/this/directory/definitely/does/not/exist/12345"
    let bashWithBadCwd = createBashTool(cwd: nonexistentCwd)

    do {
        _ = try await bashWithBadCwd.execute("test-bad-cwd", ["command": AnyCodable("cd '\(nonexistentCwd)' && echo test")], nil, nil)
        #expect(Bool(false), "Expected error for non-existent cwd")
    } catch {
        // The error will come from cd failing, which is expected
        #expect(true)
    }
}

@Test func bashToolCommandPrefix() async throws {
    // Test that command prefix is prepended to commands
    let bashWithPrefix = createBashTool(
        cwd: FileManager.default.currentDirectoryPath,
        options: BashToolOptions(commandPrefix: "export TEST_VAR=prefixed")
    )

    let result = try await bashWithPrefix.execute(
        "test-prefix",
        ["command": AnyCodable("echo $TEST_VAR")],
        nil,
        nil
    )

    if case .text(let textContent) = result.content.first {
        #expect(textContent.text.contains("prefixed"))
    } else {
        #expect(Bool(false), "Expected text output")
    }
}

// MARK: - computeEditDiff tests

@Test func computeEditDiffSuccess() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("diff-test.txt").path
        try "line one\nline two\nline three\n".write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = computeEditDiff(path: testFile, oldText: "line two", newText: "modified line", cwd: dir)

        if case .success(let diffResult) = result {
            #expect(diffResult.diff.contains("-"))
            #expect(diffResult.diff.contains("+"))
            #expect(diffResult.diff.contains("line two") || diffResult.diff.contains("modified"))
            #expect(diffResult.firstChangedLine != nil)
        } else {
            #expect(Bool(false), "Expected success result")
        }
    }
}

@Test func computeEditDiffFileNotFound() {
    let result = computeEditDiff(path: "/nonexistent/file.txt", oldText: "foo", newText: "bar", cwd: "/tmp")

    if case .error(let err) = result {
        #expect(err.error.contains("File not found"))
    } else {
        #expect(Bool(false), "Expected error result")
    }
}

@Test func computeEditDiffTextNotFound() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("diff-notfound.txt").path
        try "some content here\n".write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = computeEditDiff(path: testFile, oldText: "does not exist", newText: "replacement", cwd: dir)

        if case .error(let err) = result {
            #expect(err.error.contains("Could not find"))
        } else {
            #expect(Bool(false), "Expected error result")
        }
    }
}

@Test func computeEditDiffMultipleOccurrences() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("diff-multi.txt").path
        try "hello world\nhello world\n".write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = computeEditDiff(path: testFile, oldText: "hello world", newText: "hi world", cwd: dir)

        if case .error(let err) = result {
            #expect(err.error.contains("2 occurrences"))
        } else {
            #expect(Bool(false), "Expected error result")
        }
    }
}

@Test func computeEditDiffNoChanges() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("diff-nochange.txt").path
        try "same text\n".write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = computeEditDiff(path: testFile, oldText: "same text", newText: "same text", cwd: dir)

        if case .error(let err) = result {
            #expect(err.error.contains("No changes"))
        } else {
            #expect(Bool(false), "Expected error result")
        }
    }
}
