import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

@Test func malformedPromptFrontmatterBecomesResourceWarning() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("c5-prompts-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("bad.md")
    try "---\ndescription: Broken: unquoted colon\n---\nbody".write(to: file, atomically: true, encoding: .utf8)
    try "Valid prompt content.".write(to: root.appendingPathComponent("valid.md"), atomically: true, encoding: .utf8)
    let result = loadPromptTemplatesWithDiagnostics(.init(cwd: root.path, agentDir: root.path, promptPaths: [root.path], includeDefaults: false))
    #expect(result.templates.map(\.name) == ["valid"])
    #expect(result.diagnostics.count == 1)
    #expect(URL(fileURLWithPath: result.diagnostics[0].path ?? "").resolvingSymlinksInPath().path == file.resolvingSymlinksInPath().path)
    #expect(result.diagnostics[0].message.contains("line 1, column 14"))
}

@Test func crashLogRoundTripAndAnnounceOnce() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("c5-crash-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let log = CrashLog(path: root.appendingPathComponent("crashes.json").path)
    let record = log.append(kind: .uncaughtException, error: TestError.broken, stack: "Error\n  at /tmp/plugin.dylib", cwd: "/tmp", version: "0.87.1")
    #expect(record != nil)
    #expect(log.read().count == 1)
    #expect(log.unannounced().count == 1)
    #expect(log.takeUnannounced()?.message == "broken")
    #expect(log.takeUnannounced() == nil)
    #expect(log.read()[0].notified == true)
    #expect(findExtensionStackMatches("Error: /tmp/other.dylib\n  at /tmp/plugin.dylib", extensions: [
        CrashExtension(label: "plugin", dylibPath: "/tmp/plugin.dylib")
    ]) == ["plugin"])
}

private enum TestError: LocalizedError { case broken
    var errorDescription: String? { "broken" }
}

@Test func bugReportRedactionAndFiles() throws {
    #expect(redactBugReportURL("https://user:pass@proxy.example.com:8080/") == "https://proxy.example.com:8080/")
    #expect(redactBugReportURL("git:https://pat@github.com/org/repo") == "git:https://github.com/org/repo")
    #expect(redactBugReportURL("https://api.example/v1?api-key=abc&model=x") == "https://api.example/v1?api-key=%3Credacted%3E&model=x")
    let source = AnyCodable(["apiKey": "secret", "headers": ["Authorization": "Bearer x", "X-Trace": "1"],
                             "compaction": ["reserveTokens": 16_384], "baseUrl": "https://me:secret@example.com/"] as [String: Any])
    let result = redactBugReportValue(source).jsonValue as? [String: Any]
    #expect(result?["apiKey"] as? String == "<redacted>")
    #expect((result?["headers"] as? [String: Any])?["Authorization"] as? String == "<redacted>")
    #expect((result?["headers"] as? [String: Any])?["X-Trace"] as? String == "1")
    #expect((result?["compaction"] as? [String: Any])?["reserveTokens"] as? Int == 16_384)
    #expect(result?["baseUrl"] as? String == "https://example.com/")

    let session = SessionManager.inMemory()
    session.appendMessage(.assistant(AssistantMessage(content: [.text(TextContent(text: "private conversation"))], api: .anthropicMessages,
        provider: "anthropic", model: "test", usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .error, errorMessage: "unexpected", diagnostics: [.init(type: "request", details: ["status": AnyCodable(500)])])))
    let input = BugReportMetadataInput(id: "fixed", sessionId: session.getSessionId(), cwd: "/private", includeSession: false,
        includeSummary: true, messageCount: 1, thinkingLevel: "off", globalSettings: ["trackingId": AnyCodable("tracking-secret"),
                                                                                         "apiKey": AnyCodable("key")])
    let metadata = collectBugReportMetadata(input, environment: ["PI_SECRET": "secret-value"])
    let bundle = try makeBugReportBundle(metadata: metadata, session: session, includeSession: false, summary: "Summary")
    let files = try bugReportFiles(bundle)
    #expect(files.map(\.name) == ["report.json", "diagnostics.json", "summary.md"])
    #expect(!files[0].data.contains("tracking-secret"))
    #expect(!files[0].data.contains("secret-value"))
    #expect(files[0].data.contains("PI_SECRET"))
    #expect(!files[1].data.contains("private conversation"))
    #expect(files[1].data.contains("unexpected"))
    #expect(files[2].data == "Summary\n")
}

@Test func modelAndProviderMetadataExposeNamesWithoutCredentials() throws {
    let model = Model(id: "example", name: "Example", api: .openAIResponses, provider: "custom",
                      baseUrl: "https://user:password@example.test/v1?token=secret", reasoning: false,
                      input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                      contextWindow: 8_000, maxTokens: 1_000,
                      headers: ["Authorization": "Bearer secret", "X-Trace": "trace-value"])
    let input = BugReportMetadataInput(id: "model", sessionId: "session", cwd: "/work", includeSession: false,
        includeSummary: false, messageCount: 0, model: model,
        provider: ["id": AnyCodable("custom"), "apiKey": AnyCodable("provider-secret"),
                   "authStatus": AnyCodable("available")], thinkingLevel: "off")
    let metadata = collectBugReportMetadata(input, environment: [:])
    let report = try bugReportFiles(.init(metadata: metadata, diagnostics: [:]))[0].data
    #expect(report.contains("Authorization"))
    #expect(report.contains("X-Trace"))
    #expect(report.contains("<redacted>"))
    #expect(!report.contains("Bearer secret"))
    #expect(!report.contains("trace-value"))
    #expect(!report.contains("provider-secret"))
    #expect(!report.contains("user:password"))
    #expect(!report.contains("\"cwd\""))
}

@Test func zipArchiveRoundTripsStoredFiles() throws {
    let data = try createZipArchive([ZipEntry(name: "report.json", text: "{\"ok\":true}\n"), ZipEntry(name: "summary.md", text: "héllo\n")])
    func number(_ offset: Int, _ count: Int) -> Int {
        (0..<count).reduce(0) { $0 | (Int(data[offset + $1]) << ($1 * 8)) }
    }
    var offset = 0
    var values: [String: String] = [:]
    while number(offset, 4) == 0x04034b50 {
        let size = number(offset + 18, 4)
        let nameSize = number(offset + 26, 2)
        let name = String(decoding: data[(offset + 30)..<(offset + 30 + nameSize)], as: UTF8.self)
        let start = offset + 30 + nameSize
        values[name] = String(decoding: data[start..<(start + size)], as: UTF8.self)
        offset = start + size
    }
    #expect(values == ["report.json": "{\"ok\":true}\n", "summary.md": "héllo\n"])
    #expect(number(offset, 4) == 0x02014b50)
}

@Test func clipboardFallbackDecisionsAreTyped() {
    let failed = ClipboardBackend(nativeCopy: { _ in false }, nativeRead: { .unavailable },
                                  command: { _, _, _ in .unavailable }, emitOSC52: { _ in true })
    #expect(copyToClipboard("text", platform: .linux, environment: ["DISPLAY": ":0"], backend: failed) ==
            .failure("Clipboard unavailable: install `xclip` or `xsel`, or check X11 access"))
    #expect(copyToClipboard("text", platform: .linux, environment: [:], backend: failed) == .osc52SentUnverified)
    let success = ClipboardBackend(nativeCopy: { _ in false }, nativeRead: { .unavailable },
                                   command: { name, _, _ in name == "xsel" ? .content("") : .unavailable }, emitOSC52: { _ in false })
    #expect(copyToClipboard("text", platform: .linux, environment: ["DISPLAY": ":0"], backend: success) == .success)
    let empty = ClipboardBackend(nativeCopy: { _ in false }, nativeRead: { .content("stale") },
                                 command: { name, _, _ in name == "wl-paste" ? .empty : .content("stale") }, emitOSC52: { _ in false })
    #expect(readClipboardText(platform: .linux, environment: ["WAYLAND_DISPLAY": "wayland-0", "DISPLAY": ":0"], backend: empty) == .empty)
    let image = ClipboardImageBackend(nativeRead: { .unavailable },
                                      command: { name, _ in name == "wl-paste" ? .empty : .content(Data([1, 2, 3])) })
    #expect(readClipboardImagePngData(platform: .linux,
                                      environment: ["WAYLAND_DISPLAY": "wayland-0", "DISPLAY": ":0"], backend: image) == .empty)
    let wslImage = ClipboardImageBackend(nativeRead: { .unavailable },
                                         command: { _, _ in .empty },
                                         wslRead: { .content(Data([0x89, 0x50, 0x4e, 0x47])) })
    #expect(readClipboardImagePngData(platform: .linux,
                                      environment: ["WAYLAND_DISPLAY": "wayland-0", "WSL_DISTRO_NAME": "Ubuntu"], backend: wslImage) ==
            .content(Data([0x89, 0x50, 0x4e, 0x47])))
    let windows = ClipboardBackend(nativeCopy: { _ in false }, nativeRead: { .unavailable },
                                   command: { name, _, _ in name == "wslpath" ? .content("C:\\clip.txt\n") : .empty },
                                   emitOSC52: { _ in false })
    #expect(copyToClipboard("héllo", platform: .linux, environment: ["WSL_DISTRO_NAME": "Ubuntu"], backend: windows) == .success)
    #expect(copyToClipboard(String(repeating: "x", count: 80_000), platform: .linux,
                            environment: ["SSH_CONNECTION": "remote"], backend: failed) == .osc52SentUnverified)
    let oversize = ClipboardBackend(nativeCopy: { _ in false }, nativeRead: { .unavailable },
                                    command: { _, _, _ in .unavailable }, emitOSC52: { _ in false })
    #expect(copyToClipboard("x", platform: .linux, environment: ["SSH_CONNECTION": "remote"], backend: oversize) ==
            .failure("Clipboard unavailable: text exceeds the OSC 52 size limit"))
}

@Test func bugHintIsOncePerSessionAndExcludesRetryAndCancellation() async {
    let tracker = BugReportHintTracker()
    func message(_ error: String) -> AssistantMessage {
        AssistantMessage(content: [], api: .anthropicMessages, provider: "anthropic", model: "test",
                         usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                         stopReason: .error, errorMessage: error)
    }
    #expect(await !tracker.shouldSuggest(sessionId: "a", message: message("503 Service Unavailable")))
    #expect(await !tracker.shouldSuggest(sessionId: "a", message: message("Request cancelled")))
    #expect(await tracker.shouldSuggest(sessionId: "a", message: message("Unexpected internal state")))
    #expect(await !tracker.shouldSuggest(sessionId: "a", message: message("Another failure")))
    #expect(await tracker.shouldSuggest(sessionId: "b", message: message("503 Service Unavailable"), retryExhausted: true))
}
