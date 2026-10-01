import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

@Test(arguments: [
    ("plain 🦊", "plain 🦊"),
    ("<&>\"'", "&lt;&amp;&gt;&quot;&#039;"),
    ("\u{1b}[31mred\u{1b}[0m plain", "<span style=\"color:#800000\">red</span> plain"),
    ("\u{1b}[1;2;3;4mstyled", "<span style=\"font-weight:bold;opacity:0.6;font-style:italic;text-decoration:underline\">styled</span>"),
    ("\u{1b}[1;2;3;4mx\u{1b}[22;23;24my", "<span style=\"font-weight:bold;opacity:0.6;font-style:italic;text-decoration:underline\">x</span>y"),
    ("\u{1b}[31;44ma\u{1b}[39mb\u{1b}[49mc", "<span style=\"color:#800000;background-color:#000080\">a</span><span style=\"background-color:#000080\">b</span>c"),
    ("\u{1b}[91;104mx", "<span style=\"color:#ff0000;background-color:#0000ff\">x</span>"),
    ("\u{1b}[38;5;24mx", "<span style=\"color:#005f87\">x</span>"),
    ("\u{1b}[48;5;232mx", "<span style=\"background-color:#080808\">x</span>"),
    ("\u{1b}[38;2;12;34;56;48;2;78;90;123mx", "<span style=\"color:rgb(12,34,56);background-color:rgb(78,90,123)\">x</span>"),
    ("\u{1b}[31ma\u{1b}[mb", "<span style=\"color:#800000\">a</span>b"),
    ("\u{1b}[31ma\u{1b}[;1mb", "<span style=\"color:#800000\">a</span><span style=\"font-weight:bold\">b</span>"),
    ("\u{1b}[31ma\u{1b}[999mb", "<span style=\"color:#800000\">a</span><span style=\"color:#800000\">b</span>"),
    ("\u{1b}[38;2;1mx", "<span style=\"font-weight:bold;opacity:0.6\">x</span>"),
    ("\u{1b}[31m", "<span style=\"color:#800000\"></span>"),
    ("\u{1b}[2K<", "\u{1b}[2K&lt;"),
    ("\u{1b}[38:5:1m<", "\u{1b}[38:5:1m&lt;"),
    ("\u{1b}[38;5;300mx", "<span style=\"color:#2b02b02b0\">x</span>"),
    ("\u{1b}[38;2;999;0;255mx", "<span style=\"color:rgb(999,0,255)\">x</span>"),
    ("\u{1b}[38;2;1000000000000000100;0;0mx", "<span style=\"color:rgb(1000000000000000100,0,0)\">x</span>"),
    ("\u{1b}[38;2;1000000000000000000000;0;0mx", "<span style=\"color:rgb(1e+21,0,0)\">x</span>")
])
func ansiHtmlMatchesUpstream(input: String, expected: String) {
    #expect(ansiToHtml(input) == expected)
}

@Test func ansiHtmlCoversAllIndexedColors() {
    let palette = ["000000", "800000", "008000", "808000", "000080", "800080", "008080", "c0c0c0",
                   "808080", "ff0000", "00ff00", "ffff00", "0000ff", "ff00ff", "00ffff", "ffffff"]
    for index in 0...255 {
        let hex: String
        if index < 16 { hex = palette[index] }
        else if index < 232 {
            let cube = index - 16
            let channels = [cube / 36, cube % 36 / 6, cube % 6].map { $0 == 0 ? 0 : 55 + $0 * 40 }
            hex = channels.map { String(format: "%02x", $0) }.joined()
        } else { hex = String(repeating: String(format: "%02x", 8 + (index - 232) * 10), count: 3) }
        for code in [38, 48] {
            let property = code == 38 ? "color" : "background-color"
            #expect(ansiToHtml("\u{1b}[\(code);5;\(index)mx") == "<span style=\"\(property):#\(hex)\">x</span>")
        }
    }
    for index in 0..<16 {
        let fg = index < 8 ? 30 + index : 90 + index - 8
        let bg = index < 8 ? 40 + index : 100 + index - 8
        #expect(ansiToHtml("\u{1b}[\(fg);\(bg)mx") == "<span style=\"color:#\(palette[index]);background-color:#\(palette[index])\">x</span>")
    }
}

// Port of export-html-whitespace.test.ts: no source whitespace between lines.
@Test func ansiHtmlLinesPreserveWhitespace() {
    #expect(ansiLinesToHtml(["one", "two"]) == "<div class=\"ansi-line\">one</div><div class=\"ansi-line\">two</div>")
    #expect(ansiLinesToHtml(["  one", "", "two  "]) == "<div class=\"ansi-line\">  one</div><div class=\"ansi-line\">&nbsp;</div><div class=\"ansi-line\">two  </div>")
    #expect(ansiLinesToHtml([]).isEmpty)
    #expect(ansiLinesToHtml(["\u{1b}[31ma", "b"]) == "<div class=\"ansi-line\"><span style=\"color:#800000\">a</span></div><div class=\"ansi-line\">b</div>")
}

private final class FakeHtmlRenderer: ToolHtmlRenderer {
    struct Event: Sendable {
        var id: String
        var name: String
        var arguments: OrderedJSON?
        var result: [ContentBlock]?
        var details: AnyCodable?
        var isError: Bool?
    }
    let events = Mutex<[Event]>([])
    let marker: String
    init(_ marker: String = "custom") { self.marker = marker }
    func renderCall(toolCallId: String, name: String, arguments: OrderedJSON) async -> String? {
        events.withLock { $0.append(Event(id: toolCallId, name: name, arguments: arguments)) }
        return name == "fallback" ? nil : name == "empty" ? "" : "<b>\(marker)</b>"
    }
    func renderResult(toolCallId: String, name: String, result: [ContentBlock], details: AnyCodable?, isError: Bool) async -> (collapsed: String?, expanded: String?)? {
        events.withLock { $0.append(Event(id: toolCallId, name: name, result: result, details: details, isError: isError)) }
        return name == "fallback" ? nil : ("<i>short</i>", "<pre>\(marker)</pre>")
    }
}

private func htmlEntries(_ names: [String]) throws -> [SessionEntry] {
    let source = try OrderedJSON.parse(#"{"z":1,"a":{"second":2,"first":1}}"#)
    let calls = names.enumerated().map { index, name in
        ContentBlock.toolCall(ToolCall(id: "id\(index)", name: name,
            arguments: ["z": AnyCodable(1), "a": AnyCodable(["second": 2, "first": 1])], argumentsJSON: source))
    }
    var entries: [SessionEntry] = [.message(SessionMessageEntry(id: "calls", timestamp: "now", message: .assistant(
        AssistantMessage(content: calls, api: .anthropicMessages, provider: "anthropic", model: "test", usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse))))]
    for (index, name) in names.enumerated() {
        entries.append(.message(SessionMessageEntry(id: "result\(index)", parentId: "calls", timestamp: "now", message: .toolResult(
            ToolResultMessage(toolCallId: "id\(index)", toolName: name, content: [.text(TextContent(text: " result "))], details: AnyCodable(["answer": 42]), isError: true)))))
    }
    return entries
}

@Test func customHtmlSkipsTemplateToolsAndKeepsCallOrder() async throws {
    let renderer = FakeHtmlRenderer()
    let rendered = try await preRenderCustomTools(entries: try htmlEntries(["bash", "read", "write", "edit", "ls", "find", "grep", "custom", "fallback", "empty"]), toolRenderer: renderer)
    #expect(Set(rendered.keys) == ["id5", "id6", "id7", "id9"])
    #expect(rendered["id7"] == RenderedToolHtml(callHtml: "<b>custom</b>", resultHtmlCollapsed: "<i>short</i>", resultHtmlExpanded: "<pre>custom</pre>"))
    #expect(rendered["id9"]?.callHtml == nil)
    let events = renderer.events.withLock { $0 }
    #expect(events.map(\.name) == ["find", "grep", "custom", "fallback", "empty", "find", "grep", "custom", "fallback", "empty"])
    #expect(events[0].arguments?.serialized() == #"{"z":1,"a":{"second":2,"first":1}}"#)
    #expect(events[5].details?.value as? [String: Int] == ["answer": 42])
    #expect(events[5].isError == true)
    #expect(events[5].result?.count == 1)
}

@Test func customHtmlRendersOrphanResultsAndExistingCalls() async throws {
    var entries = try htmlEntries(["custom"])
    guard case .message(var entry) = entries[1], case .toolResult(var result) = entry.message else { return }
    result.toolName = "bash"; entry.message = .toolResult(result); entries[1] = .message(entry)
    let renderer = FakeHtmlRenderer()
    #expect(try await preRenderCustomTools(entries: entries, toolRenderer: renderer)["id0"]?.resultHtmlExpanded != nil)
    result.toolName = "orphan"; entry.message = .toolResult(result)
    #expect(try await preRenderCustomTools(entries: [.message(entry)], toolRenderer: renderer)["id0"]?.callHtml == nil)
    result.toolCallId = ""; entry.message = .toolResult(result)
    #expect(try await preRenderCustomTools(entries: [.message(entry)], toolRenderer: renderer).isEmpty)
}

private func decodedHtmlData(_ path: String) throws -> OrderedJSON {
    let html = try String(contentsOfFile: path, encoding: .utf8)
    let regex = try NSRegularExpression(pattern: #"<script id="session-data" type="application/json">([^<]+)</script>"#)
    let match = try #require(regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)))
    let encoded = (html as NSString).substring(with: match.range(at: 1))
    let data = try #require(Data(base64Encoded: encoded))
    return try OrderedJSON.parse(String(decoding: data, as: UTF8.self))
}

@Test func customHtmlReachesTemplateAndSessionDefault() async throws {
    let context = createTestSession()
    defer { context.cleanup() }
    for entry in try htmlEntries(["custom"]) {
        guard case .message(let entry) = entry else { continue }
        context.sessionManager.appendMessage(entry.message)
    }
    let path = context.tempDir + "/export.html"
    let renderer = FakeHtmlRenderer("default")
    context.session.toolHtmlRenderer = renderer
    _ = try await context.session.exportToHtml(path, themeName: "dark")
    var data = try decodedHtmlData(path)
    #expect(data["renderedTools"]?["id0"]?["callHtml"]?.stringValue == "<b>default</b>")
    #expect(data["renderedTools"]?["id0"]?["resultHtmlCollapsed"]?.stringValue == "<i>short</i>")
    #expect(data["renderedTools"]?["id0"]?["resultHtmlExpanded"]?.stringValue == "<pre>default</pre>")
    _ = try await context.session.exportToHtml(path, toolRenderer: FakeHtmlRenderer("override"))
    data = try decodedHtmlData(path)
    #expect(data["renderedTools"]?["id0"]?["callHtml"]?.stringValue == "<b>override</b>")
    #expect(renderer.events.withLock { $0.count } == 2)
    _ = try await exportSessionToHtml(context.sessionManager, nil, ExportOptions(outputPath: path), toolRenderer: FakeHtmlRenderer("direct"))
    #expect(try decodedHtmlData(path)["renderedTools"]?["id0"]?["callHtml"]?.stringValue == "<b>direct</b>")
    _ = try await exportSessionToHtml(context.sessionManager, nil, ExportOptions(outputPath: path, toolRenderer: FakeHtmlRenderer("options")))
    #expect(try decodedHtmlData(path)["renderedTools"]?["id0"]?["callHtml"]?.stringValue == "<b>options</b>")
    context.session.toolHtmlRenderer = nil
    _ = try await context.session.exportToHtml(path)
    #expect(try decodedHtmlData(path)["renderedTools"] == nil)
    let fallbackPath = context.tempDir + "/fallback.html"
    let fallbackManager = SessionManager.create(context.tempDir, context.tempDir)
    fallbackManager.appendMessage(.user(UserMessage(content: .text("hello"))))
    _ = try await exportSessionToHtml(fallbackManager, nil, ExportOptions(outputPath: fallbackPath, toolRenderer: renderer))
    #expect(try decodedHtmlData(fallbackPath)["renderedTools"] == nil)
}

// Port of the CSS checks in export-html-whitespace.test.ts.
@Test func customHtmlTemplateUsesUpstreamWhitespaceRules() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let css = try String(contentsOf: root.appendingPathComponent("Sources/PiSwiftCodingAgent/Resources/export-html/template.css"), encoding: .utf8)
    #expect(css.range(of: #"\.output-preview > div:not\(\.expand-hint\),\s*\.output-full > div:not\(\.expand-hint\) \{[\s\S]*?white-space:\s*pre-wrap;"#, options: .regularExpression) != nil)
    #expect(css.range(of: #"\.ansi-line\s*\{[\s\S]*?white-space:\s*pre;"#, options: .regularExpression) != nil)
    #expect(css.range(of: #"\.output-preview,\s*\.output-full\s*\{[\s\S]*?white-space:\s*pre-wrap;"#, options: .regularExpression) == nil)
}

@MainActor
private final class MainActorHtmlRenderer: ToolHtmlRenderer {
    private(set) var calls: [String] = []

    func renderCall(toolCallId: String, name: String, arguments: OrderedJSON) async -> String? {
        calls.append("call:\(toolCallId)")
        return "<b>main actor</b>"
    }

    func renderResult(toolCallId: String, name: String, result: [ContentBlock], details: AnyCodable?, isError: Bool) async -> (collapsed: String?, expanded: String?)? {
        calls.append("result:\(toolCallId)")
        return (nil, "<pre>main actor</pre>")
    }
}

@Test func customHtmlRendererCanRunOnMainActorFromAnotherExecutor() async throws {
    let renderer = await MainActorHtmlRenderer()
    let rendered = try await preRenderCustomTools(entries: htmlEntries(["custom"]), toolRenderer: renderer)
    #expect(rendered["id0"]?.callHtml == "<b>main actor</b>")
    #expect(rendered["id0"]?.resultHtmlExpanded == "<pre>main actor</pre>")
    #expect(await renderer.calls == ["call:id0", "result:id0"])
}

@MainActor
@Test func customHtmlSessionExportCanAwaitMainActorDefault() async throws {
    let context = createTestSession()
    defer { context.cleanup() }
    for entry in try htmlEntries(["custom"]) {
        guard case .message(let entry) = entry else { continue }
        context.sessionManager.appendMessage(entry.message)
    }
    let renderer = MainActorHtmlRenderer()
    context.session.toolHtmlRenderer = renderer
    let path = context.tempDir + "/main-actor-export.html"
    _ = try await context.session.exportToHtml(path)
    #expect(try decodedHtmlData(path)["renderedTools"]?["id0"]?["callHtml"]?.stringValue == "<b>main actor</b>")
    #expect(renderer.calls == ["call:id0", "result:id0"])
}
