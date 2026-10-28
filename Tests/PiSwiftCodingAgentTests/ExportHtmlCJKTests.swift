import Foundation
import Testing
@testable import PiSwiftCodingAgent

#if canImport(JavaScriptCore)
import JavaScriptCore
private let exportHtmlJavaScriptCoreAvailable = true
#else
private let exportHtmlJavaScriptCoreAvailable = false
#endif

@Suite(.enabled(if: exportHtmlJavaScriptCoreAvailable, "Requires JavaScriptCore"))
struct ExportHtmlCJKTests {
    @Test func rendersEmphasisDelimitedNextToCJKPunctuation() throws {
        #if canImport(JavaScriptCore)
        let parser = try ExportHtmlMarkdownParser()
        let cases = [
            ("**这是测试。**后面", "<p><strong>这是测试。</strong>后面</p>\n"),
            ("**一句话说清：**一台机器", "<p><strong>一句话说清：</strong>一台机器</p>\n"),
            ("**要点到此为止。**20 小时", "<p><strong>要点到此为止。</strong>20 小时</p>\n"),
            ("字**「引用」**字", "<p>字<strong>「引用」</strong>字</p>\n"),
            ("*斜体。*后面", "<p><em>斜体。</em>后面</p>\n"),
        ]
        for (input, expected) in cases {
            #expect(try parser.parse(input) == expected)
        }
        #endif
    }

    @Test func keepsCommonMarkFlankingRulesForNonCJKText() throws {
        #if canImport(JavaScriptCore)
        let parser = try ExportHtmlMarkdownParser()
        #expect(try parser.parse("**end.**Then next") == "<p>**end.**Then next</p>\n")
        #endif
    }

    @Test func keepsMarkdownURLAndHTMLSecurity() throws {
        #if canImport(JavaScriptCore)
        let parser = try ExportHtmlMarkdownParser()
        #expect(try parser.parse("[**blocked**](javascript:alert(1))") == "<p><strong>blocked</strong></p>\n")
        #expect(try parser.parse("![blocked](javascript:alert(1))") == "<p>blocked</p>\n")
        #expect(try parser.parse("<script>alert(1)</script>") == "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>\n")
        #expect(try parser.parse("<img src=x onerror=alert(1)>") == "<p>&lt;img src=x onerror=alert(1)&gt;</p>\n")
        #expect(try parser.parse("[safe](https://example.com \"a \\\"quote\\\"\")")
            == "<p><a href=\"https://example.com\" title=\"a &quot;quote&quot;\">safe</a></p>\n")
        #expect(try parser.parse("![safe](https://example.com/image.png \"title\")")
            == "<p><img src=\"https://example.com/image.png\" alt=\"safe\" title=\"title\"></p>\n")
        #endif
    }

    @Test func keepsStrictStrikethrough() throws {
        #if canImport(JavaScriptCore)
        let parser = try ExportHtmlMarkdownParser()
        #expect(try parser.parse("~single~") == "<p>~single~</p>\n")
        #expect(try parser.parse("~~double~~") == "<p><del>double</del></p>\n")
        #expect(try parser.parse("~~ space~~") == "<p>~~ space~~</p>\n")
        #expect(try parser.parse("~~space ~~") == "<p>~~space ~~</p>\n")
        #endif
    }

    @Test func keepsCodeRenderersAndLineBreaks() throws {
        #if canImport(JavaScriptCore)
        let parser = try ExportHtmlMarkdownParser()
        #expect(try parser.parse("`a & b`") == "<p><code>a &amp; b</code></p>\n")
        #expect(try parser.parse("first\nsecond") == "<p>first<br>second</p>\n")
        let code = try parser.parse("```javascript\nconst value = 1;\n```")
        #expect(code.hasPrefix("<pre><code class=\"hljs\">"))
        #expect(code.contains("<span class=\"hljs-keyword\">const</span>"))
        #expect(code.hasSuffix("</code></pre>"))
        #endif
    }
}

#if canImport(JavaScriptCore)
private enum ExportHtmlParserError: Error {
    case javascript(String)
}

private struct ExportHtmlMarkdownParser {
    let context: JSContext
    let parseFunction: JSValue

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("c2-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("session.jsonl")
        let output = directory.appendingPathComponent("export.html")
        let header: [String: Any] = [
            "type": "session", "version": CURRENT_SESSION_VERSION, "id": "cjk-test",
            "timestamp": "1970-01-01T00:00:00Z", "cwd": directory.path,
        ]
        var session = try JSONSerialization.data(withJSONObject: header)
        session.append(0x0a)
        try session.write(to: input)
        _ = try exportFromFile(input.path, ExportOptions(outputPath: output.path, themeName: "dark"))
        let html = try String(contentsOf: output, encoding: .utf8)
        let sessionData = try #require(exportHtmlScriptContents(
            #"<script id="session-data" type="application/json">([^<]+)</script>"#, in: html).first)
        var scripts = try exportHtmlScriptContents(#"<script>([\s\S]*?)</script>"#, in: html)
        try #require(scripts.count == 4)
        let viewer = scripts.removeLast()
        try #require(viewer.contains("function safeMarkedParse("))
        try #require(!html.contains("{{MARKED_CJK_FRIENDLY_JS}}"))

        let context = try #require(JSContext(virtualMachine: JSVirtualMachine()))
        context.setObject(sessionData, forKeyedSubscript: "exportedSessionData" as NSString)
        let atob: @convention(block) (String) -> String = { encoded in
            (Data(base64Encoded: encoded) ?? Data()).map { String(UnicodeScalar($0)) }.joined()
        }
        context.setObject(atob, forKeyedSubscript: "atob" as NSString)
        // Supply the browser APIs used before parser setup. The export has no URL query.
        _ = try evaluateExportScript(#"""
        const document = {
          getElementById: () => ({ textContent: exportedSessionData }),
          querySelector: () => null
        };
        const window = { location: { search: '' } };
        class URLSearchParams { get() { return null; } }
        class TextDecoder {
          decode(bytes) {
            return decodeURIComponent(Array.from(bytes, b => '%' + b.toString(16).padStart(2, '0')).join(''));
          }
        }
        """#, in: context)
        for script in scripts {
            _ = try evaluateExportScript(script, in: context)
        }
        // Return the viewer's parser after its real configuration, as in the upstream helper.
        let parseFunction = try evaluateExportScript(viewer.replacingOccurrences(
            of: "function safeMarkedParse(", with: "return safeMarkedParse; function safeMarkedParse("), in: context)
        try #require(parseFunction.isObject)
        self.context = context
        self.parseFunction = parseFunction
    }

    func parse(_ text: String) throws -> String {
        let result = parseFunction.call(withArguments: [text])
        try checkExportScriptException(in: context)
        let value = try #require(result)
        try #require(value.isString)
        return try #require(value.toString())
    }
}

private func exportHtmlScriptContents(_ pattern: String, in html: String) throws -> [String] {
    let regex = try NSRegularExpression(pattern: pattern)
    return try regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).map { match in
        let range = try #require(Range(match.range(at: 1), in: html))
        return String(html[range])
    }
}

private func evaluateExportScript(_ source: String, in context: JSContext) throws -> JSValue {
    let result = context.evaluateScript(source)
    try checkExportScriptException(in: context)
    return try #require(result)
}

private func checkExportScriptException(in context: JSContext) throws {
    if let exception = context.exception, !exception.isUndefined {
        throw ExportHtmlParserError.javascript(exception.toString() ?? "JavaScript exception")
    }
}
#endif
