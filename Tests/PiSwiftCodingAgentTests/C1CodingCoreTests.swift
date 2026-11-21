import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func c1Temp(_ body: (URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("c1-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root)
}

private func c1Files(_ root: URL, _ paths: [String]) throws {
    for path in paths {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }
}

private func c1Find(_ root: URL, _ pattern: String) async throws -> [String] {
    let result = try await createFindTool(cwd: root.path).execute("find", ["pattern": AnyCodable(pattern)], nil, nil)
    guard case .text(let block) = result.content[0], block.text != "No files found matching pattern" else { return [] }
    return block.text.components(separatedBy: "\n").sorted()
}

// test/tools.test.ts: "should ignore a leading ./ in the pattern".
@Test func shouldIgnoreALeadingDotSlashInThePattern() async throws {
    try await c1Temp { root in
        try c1Files(root, ["src/a.ts", "file.json", "src/b.json"])
        #expect(try await c1Find(root, "./src/*.ts") == ["src/a.ts"])
        #expect(try await c1Find(root, "./src/**/*.ts") == ["src/a.ts"])
        #expect(try await c1Find(root, "././src/*.ts") == ["src/a.ts"])
        #expect(try await c1Find(root, "./*.json") == ["file.json", "src/b.json"])
    }
}

// test/suite/regressions/12066-find-ancestor-glob.test.ts, all five cases.
@Test func doesNotMatchThroughAnAncestorFolderWithTheSameName() async throws {
    try await c1Temp { root in
        let project = root.appendingPathComponent("src/app")
        try c1Files(project, ["src/a.ts", "lib/b.ts", "test/c.ts", "pkg/src/d.ts"])
        #expect(try await c1Find(project, "src/**/*.ts") == ["src/a.ts"])
        #expect(try await c1Find(project, "app/**/*.ts") == [])
    }
}

@Test func anchorsPathPatternsAtTheSearchPathALeadingGlobstarMatchesAtAnyDepth() async throws {
    try await c1Temp { root in
        let project = root.appendingPathComponent("src/app")
        try c1Files(project, ["src/a.ts", "lib/b.ts", "test/c.ts", "pkg/src/d.ts"])
        for (pattern, expected) in [
            ("src/*.ts", ["src/a.ts"]), ("./src/*.ts", ["src/a.ts"]),
            ("pkg/src/*.ts", ["pkg/src/d.ts"]),
            ("**/src/*.ts", ["pkg/src/d.ts", "src/a.ts"]),
            ("**/src/**/*.ts", ["pkg/src/d.ts", "src/a.ts"]),
            ("*.ts", ["lib/b.ts", "pkg/src/d.ts", "src/a.ts", "test/c.ts"]),
            (project.resolvingSymlinksInPath().path + "/lib/*.ts", ["lib/b.ts"]),
        ] {
            let actual = try await c1Find(project, pattern)
            #expect(actual == expected, "pattern \(pattern)")
        }
    }
}

@Test func treatsGlobCharactersInTheSearchPathLiterally() async throws {
    try await c1Temp { root in
        let project = root.appendingPathComponent("w*?[1]{x,y}/src")
        try c1Files(project, ["src/a.ts"])
        #expect(try await c1Find(project, "src/*.ts") == ["src/a.ts"])
    }
}

@Test func keepsSmartCaseWhenTheSearchPathHasUpperCaseLetters() async throws {
    try await c1Temp { root in
        let project = root.appendingPathComponent("Upper")
        try c1Files(project, ["src/A.ts", "src/b.ts"])
        #expect(try await c1Find(project, "src/a.ts") == ["src/A.ts"])
        #expect(try await c1Find(project, "src/B.ts") == [])
    }
}

@Test func worksThroughASymlinkedSearchPath() async throws {
    try await c1Temp { root in
        let project = root.appendingPathComponent("src/app")
        try c1Files(project, ["src/a.ts"])
        let link = root.appendingPathComponent("src/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: project)
        #expect(try await c1Find(link, "src/**/*.ts") == ["src/a.ts"])
    }
}

private func c1Assistant(_ kind: String, _ rows: [[String: Any]], _ timestamp: Int64 = 1) -> AssistantMessage {
    AssistantMessage(content: [.text(TextContent(text: "ok"))], api: .anthropicMessages,
        provider: "anthropic", model: "test",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop,
        timestamp: timestamp, diagnostics: [AssistantMessageDiagnostic(type: kind,
            details: ["transformations": AnyCodable(rows)])])
}

// test/interactive-mode-assistant-diagnostics.test.ts: Anthropic and OpenAI notice cases.
@Test func showsAnthropicThinkingDropsWhenCacheMissNoticesAreEnabled() {
    let notice = reasoningDropNotice(in: c1Assistant("anthropic_input_transformations", (0..<3).map { _ in
        ["type": "thinking_dropped", "reason": "prefix_binding_mismatch"]
    }))
    #expect(notice?.text == "Anthropic dropped 3 thinking blocks: prefix_binding_mismatch (details in session)")
}

@Test func showsOpenAIReasoningRemovalsWithTheirReasons() {
    let previous = c1Assistant("anthropic_input_transformations", (0..<3).map { _ in ["type": "thinking_dropped"] })
    let current = c1Assistant("openai_input_transformations", [
        ["type": "reasoning", "reason": "prefix_mismatch"],
        ["type": "reasoning", "reason": "organization_mismatch"],
    ])
    #expect(newThinkingDropNotice(current: current, previous: previous)?.text ==
        "OpenAI dropped 2 reasoning items: prefix_mismatch, organization_mismatch (details in session)")
}

@Test func showsOpenAIReasoningRemovalsOnlyWhenNewItemsAreRemoved() {
    let previous = c1Assistant("openai_input_transformations", (0..<2).map { _ in
        ["type": "reasoning", "reason": "prefix_mismatch"]
    })
    #expect(newThinkingDropNotice(current: previous, previous: previous) == nil)
    let grown = c1Assistant("openai_input_transformations", (0..<3).map { _ in
        ["type": "reasoning", "reason": "prefix_mismatch"]
    })
    #expect(newThinkingDropNotice(current: grown, previous: previous)?.text ==
        "OpenAI dropped 3 reasoning items: prefix_mismatch (details in session)")
}

@Test func diagnosticDecodedFromSessionJSONLForBothProviders() throws {
    for (kind, droppedType, provider) in [
        ("anthropic_input_transformations", "thinking_dropped", "Anthropic"),
        ("openai_input_transformations", "reasoning", "OpenAI"),
    ] {
        let json = """
        {"type":"session","version":3,"id":"s","timestamp":"2026-11-20T00:00:00Z","cwd":"/tmp"}
        {"type":"message","id":"m","parentId":null,"timestamp":"2026-11-20T00:00:01Z","message":{"role":"assistant","content":[],"api":"anthropic-messages","provider":"anthropic","model":"test","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"stop","timestamp":1795132801000,"diagnostics":[{"type":"\(kind)","timestamp":1795132801000,"details":{"transformations":[{"type":"\(droppedType)","reason":"prefix_mismatch"}]}}]}}
        """
        let entry = try #require(parseSessionEntries(json).last)
        guard case .entry(.message(let messageEntry)) = entry, case .assistant(let assistant) = messageEntry.message else {
            Issue.record("Assistant session entry was not decoded"); continue
        }
        #expect(reasoningDropNotice(in: assistant)?.provider == provider)
        #expect(reasoningDropNotice(in: assistant)?.count == 1)
        #expect(reasoningDropNotice(in: assistant)?.reasons == ["prefix_mismatch"])
    }
}

// test/export-html-ansi-links.test.ts: all three cases.
private func c1Link(_ url: String, _ text: String, _ end: String = "\u{1b}\\") -> String {
    "\u{1b}]8;;\(url)\(end)\(text)\u{1b}]8;;\(end)"
}

@Test func convertsOSC8HyperlinksToAnchors() {
    #expect(ansiToHtml("see \(c1Link("https://example.com/a?b=1&c=2", "\u{1b}[4mdocs\u{1b}[24m")).") ==
        "see <a href=\"https://example.com/a?b=1&amp;c=2\"><span style=\"text-decoration:underline\">docs</span></a>.")
    #expect(ansiToHtml(c1Link("mailto:me@example.com", "mail", "\u{07}")) ==
        "<a href=\"mailto:me@example.com\">mail</a>")
}

@Test func keepsStyledTextNestedInsideTheAnchorAndClosesAnUnterminatedLink() {
    #expect(ansiToHtml("\u{1b}[31mred \u{1b}]8;;https://example.com\u{1b}\\link") ==
        "<span style=\"color:#800000\">red </span><a href=\"https://example.com\"><span style=\"color:#800000\">link</span></a>")
}

@Test func dropsLinksWithUnsafeSchemesAndOtherEscapeSequences() {
    #expect(ansiToHtml(c1Link("javascript:alert(1)", "x")) == "x")
    #expect(ansiToHtml(c1Link("java\u{01}script:alert(1)", "x")) == "x")
    #expect(ansiToHtml("\u{1b}]0;title\u{07}a\u{1b}[2Kb\u{1b}]133;A\u{1b}\\c\u{1b}_pi:c\u{07}d\u{1b}e") == "abcde")
}

@Test func OSC8EscapesAttributesAndRejectsIncompleteControls() {
    #expect(ansiToHtml(c1Link("https://example.com/\"<x>", "<ok>")) ==
        "<a href=\"https://example.com/&quot;&lt;x&gt;\">&lt;ok&gt;</a>")
    #expect(!ansiToHtml("\u{1b}]8;;https://example.com\"<tag").contains("<a"))
    #expect(ansiToHtml("\u{1b}]8;;https://example.com\"<tag") == "]8;;https://example.com&quot;&lt;tag")
}

private func c1LastText(_ replies: [AssistantMessage]) -> String? {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "test", model: model),
        getApiKey: { _ in "test-key" }))
    agent.messages = replies.map { .assistant($0) }
    let manager = SessionManager.inMemory("/tmp")
    let auth = AuthStorage.inMemory(["openai": .apiKey(ApiKeyCredential(key: "test-key"))])
    let registry = ModelRegistry(auth)
    let session = AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager,
        settingsManager: SettingsManager.inMemory(), resourceLoader: TestResourceLoader(), modelRegistry: registry))
    defer { session.dispose() }
    agent.messages = replies.map { .assistant($0) }
    return session.getLastAssistantText()
}

private func c1Reply(_ content: [ContentBlock], _ stopReason: StopReason) -> AssistantMessage {
    AssistantMessage(content: content, api: .openAIResponses, provider: "openai", model: "gpt-4o-mini",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: stopReason)
}

// test/suite/regressions/12119-copy-after-abort-or-error.test.ts, three cases.
@Test func returnsThePreviousAnswerAfterEscDuringAToolCall() {
    let answer = c1Reply([.text(TextContent(text: "Here is the answer."))], .stop)
    let call = c1Reply([.toolCall(ToolCall(id: "block", name: "block", arguments: [:]))], .toolUse)
    let aborted = c1Reply([], .aborted)
    #expect(c1LastText([answer, call, aborted]) == "Here is the answer.")
}

@Test func returnsThePreviousAnswerAfterAProviderError() {
    let answer = c1Reply([.text(TextContent(text: "Here is the answer."))], .stop)
    #expect(c1LastText([answer, c1Reply([], .error)]) == "Here is the answer.")
}

@Test func keepsAReplyThatEndedNormallyWithoutTextAsTheLastReply() {
    let answer = c1Reply([.text(TextContent(text: "Here is the answer."))], .stop)
    #expect(c1LastText([answer, c1Reply([], .stop)]) == nil)
}

// test/tools.test.ts: "should keep a text-only model's image warning out of what the model gets".
@Test func shouldKeepATextOnlyModelsImageWarningOutOfWhatTheModelGets() async throws {
    try await c1Temp { root in
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X2Z0AAAAASUVORK5CYII=")!
        let file = root.appendingPathComponent("image.png")
        try png.write(to: file)
        let textOnly = Model(id: "text-only", name: "Text only", api: .openAIResponses,
            provider: "openai", baseUrl: "https://example.invalid", reasoning: false,
            input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 1000, maxTokens: 100)
        let tool = createReadTool(cwd: root.path, options: ReadToolOptions(modelProvider: { textOnly }))
        let result = try await tool.execute("read", ["path": AnyCodable(file.path)], nil, nil)
        #expect(result.content.contains { if case .image = $0 { return true }; return false })
        #expect(result.content.compactMap { if case .text(let text) = $0 { return text.text }; return nil }
            == ["Read image file [image/png]"])
        #expect(result.details == AnyCodable(["imageUnsupportedByModel": "text-only"]))
        let contextualTool = createReadTool(cwd: root.path)
        let execute = try #require(contextualTool.executeWithContext)
        let contextual = try await execute("context", ["path": AnyCodable(file.path)], nil, nil,
            AgentToolExecutionContext(cwd: root.path, model: textOnly))
        #expect(contextual.details == AnyCodable(["imageUnsupportedByModel": "text-only"]))
        let oldResult = try await createReadTool(cwd: root.path).execute("old", ["path": AnyCodable(file.path)], nil, nil)
        #expect(oldResult.details == nil)
    }
}

private struct C1LongLineBash: BashOperations {
    func execute(_ command: String, options: BashExecutorOptions?) async throws -> BashResult {
        let output = "first line\n" + String(repeating: "y", count: 219_000) + "END\n"
        let bytes = Array(output.utf8)
        for start in stride(from: 0, to: bytes.count, by: 8192) {
            options?.onChunk?(String(decoding: bytes[start..<min(start + 8192, bytes.count)], as: UTF8.self))
        }
        return BashResult(output: output, exitCode: 0, cancelled: false, truncated: false)
    }
}

// test/tools.test.ts: "should show the end of an over-long last line after a short line".
@Test func shouldShowTheEndOfAnOverLongLastLineAfterAShortLine() async throws {
    let tool = createBashTool(cwd: "/tmp", options: BashToolOptions(operations: C1LongLineBash()))
    let result = try await tool.execute("bash", ["command": AnyCodable("grep -n x bundle.min.js")], nil, nil)
    guard case .text(let block) = result.content[0] else { Issue.record("No text"); return }
    #expect(block.text.contains("yyyyEND"))
    #expect(block.text.contains("[Showing last 50.0KB of line 2"))
    #expect(!block.text.contains("[Showing lines 3-2 of 2]"))
    let details = result.details?.value as? [String: Any]
    let truncation = details?["truncation"] as? [String: Any]
    #expect(truncation?["lastLinePartial"] as? Bool == true)
}

// test/exec.test.ts: "reports 128 + SIGTERM for a timeout".
@Test func reports128PlusSIGTERMForATimeout() async throws {
    let result = try await execCommand("/bin/sh", ["-c", "exec sleep 10"], "/tmp", ExecOptions(timeout: 0.1))
    #expect(result.code == 143)
    #expect(result.killed)
    #expect(!result.truncated)
}

// test/exec.test.ts: "reports 128 + the signal number for a command killed by someone else".
@Test func reports128PlusTheSignalNumberForACommandKilledBySomeoneElse() async throws {
    let result = try await execCommand("/bin/sh", ["-c", "kill -KILL $$"], "/tmp")
    #expect(result.code == 137)
    #expect(!result.killed)
    #expect(!result.truncated)
}

// test/read-streaming.test.ts: "rejects without an unhandled stream error when aborted while opening a local file".
@Test func rejectsWithoutAnUnhandledStreamErrorWhenAbortedWhileOpeningALocalFile() async throws {
    try await c1Temp { root in
        let file = root.appendingPathComponent("abort-on-open.txt")
        try "line\n".write(to: file, atomically: true, encoding: .utf8)
        let signal = CancellationToken()
        let operations = ReadOperations(readFile: { _ in Data() }, access: { _ in signal.cancel() },
            createReadStream: { path, token in
                let chunks = try LocalReadChunks(path: path, signal: token)
                return AsyncThrowingStream(unfolding: { try await chunks.next() })
            })
        do {
            _ = try await createReadTool(cwd: root.path, options: ReadToolOptions(operations: operations))
                .execute("read", ["path": AnyCodable(file.path)], signal, nil)
            Issue.record("Expected cancellation")
        } catch { #expect(error.localizedDescription == "Operation aborted") }
    }
}

// test/read-streaming.test.ts: "stops reading a local file when aborted mid-read".
@Test func stopsReadingALocalFileWhenAbortedMidRead() async throws {
    try await c1Temp { root in
        let file = root.appendingPathComponent("abort-mid-read.txt")
        try Data(repeating: 120, count: 1024 * 1024).write(to: file)
        let signal = CancellationToken()
        let pulls = LockedState(0)
        let operations = ReadOperations(readFile: { _ in Data() }, access: { _ in },
            createReadStream: { path, token in
                let chunks = try LocalReadChunks(path: path, signal: token)
                return AsyncThrowingStream(unfolding: {
                    let data = try await chunks.next()
                    pulls.withLock { $0 += 1; if $0 == 1 { signal.cancel() } }
                    return data
                })
            })
        do {
            _ = try await createReadTool(cwd: root.path, options: ReadToolOptions(operations: operations))
                .execute("read", ["path": AnyCodable(file.path)], signal, nil)
            Issue.record("Expected cancellation")
        } catch { #expect(error.localizedDescription == "Operation aborted") }
        #expect(pulls.withLock { $0 } == 1)
    }
}

// test/session-manager/file-operations.test.ts: "does not crash when aborted after a file that is not a session was skipped".
@Test func doesNotCrashWhenAbortedAfterAFileThatIsNotASessionWasSkipped() async throws {
    try await c1Temp { root in
        let folder = root.appendingPathComponent("sessions/project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let invalid = folder.appendingPathComponent("other.jsonl")
        try ("{\"type\":\"other\"}\n" + String(repeating: "x", count: 1024 * 1024) + "\n")
            .write(to: invalid, atomically: true, encoding: .utf8)
        let listing = Task { try await SessionManager.listAll(inAgentDir: root.path, onPartial: { _, _, _ in }) }
        #expect(try await listing.value.isEmpty)
        listing.cancel()
    }
}

#if canImport(Darwin)
import Darwin

// test/exec.test.ts: "reports 128 + SIGTERM for an abort".
@Test func reports128PlusSIGTERMForAnAbort() async throws {
    try await c1Temp { root in
        let ready = root.appendingPathComponent("ready")
        let descriptor = open(root.path, O_EVTONLY)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        let signal = CancellationToken()
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: .write, queue: .global())
        source.setEventHandler {
            if FileManager.default.fileExists(atPath: ready.path) { signal.cancel() }
        }
        source.resume()
        defer { source.cancel() }
        let result = try await execCommand("/bin/sh", ["-c", "touch \"$1\"; exec sleep 10", "sh", ready.path],
            root.path, ExecOptions(signal: signal))
        #expect(result.code == 143)
        #expect(result.killed)
        #expect(!result.truncated)
    }
}
#endif

@Test func imageUnsupportedDetailsRemainSessionJSONCompatible() throws {
    for details in ["", ",\"details\":{\"imageUnsupportedByModel\":\"text-only\"}"] {
        let json = """
        {"type":"session","version":3,"id":"s","timestamp":"2026-11-20T00:00:00Z","cwd":"/tmp"}
        {"type":"message","id":"r","parentId":null,"timestamp":"2026-11-20T00:00:01Z","message":{"role":"toolResult","toolCallId":"read-1","toolName":"read","content":[{"type":"text","text":"Read image file [image/png]"},{"type":"image","data":"AQ==","mimeType":"image/png"}],"isError":false,"timestamp":1795132801000\(details)}}
        """
        guard case .entry(.message(let entry)) = try #require(parseSessionEntries(json).last),
              case .toolResult(let result) = entry.message else {
            Issue.record("Tool result was not decoded"); continue
        }
        let value = result.details?.value as? [String: Any]
        #expect(value?["imageUnsupportedByModel"] as? String == (details.isEmpty ? nil : "text-only"))
        #expect(result.content.count == 2)
    }
}

// test/export-html-whitespace.test.ts: escape-only trailing render line.
@Test func trimsTUISpacingLinesFromCustomToolResultHTML() {
    #expect(stripAnsiEscapes("\u{1b}[0m\u{1b}]8;;\u{07}").isEmpty)
    #expect(ansiLinesToHtml(["one", "two"]) ==
        "<div class=\"ansi-line\">one</div><div class=\"ansi-line\">two</div>")
}
