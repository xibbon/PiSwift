import PiSwiftSyntaxHighlight
import Testing

private struct RecordingSyntaxTheme: SyntaxTheme {
    func plain(_ text: String) -> String { "<plain>\(text)</plain>" }
    func keyword(_ text: String) -> String { "<keyword>\(text)</keyword>" }
    func builtIn(_ text: String) -> String { "<builtIn>\(text)</builtIn>" }
    func literal(_ text: String) -> String { "<literal>\(text)</literal>" }
    func number(_ text: String) -> String { "<number>\(text)</number>" }
    func string(_ text: String) -> String { "<string>\(text)</string>" }
    func comment(_ text: String) -> String { "<comment>\(text)</comment>" }
    func function(_ text: String) -> String { "<function>\(text)</function>" }
    func type(_ text: String) -> String { "<type>\(text)</type>" }
    func variable(_ text: String) -> String { "<variable>\(text)</variable>" }
    func operatorToken(_ text: String) -> String { "<operator>\(text)</operator>" }
    func punctuation(_ text: String) -> String { "<punctuation>\(text)</punctuation>" }
}

struct SyntaxHighlighterTests {
    @Test func swiftStringBody() {
        let lines = SyntaxHighlighter.highlight(
            code: "let s = \"hello world\"", lang: "swift", theme: RecordingSyntaxTheme()
        )
        #expect(lines == [
            "<keyword>let</keyword><plain> </plain><plain>s</plain><plain> </plain>"
                + "<operator>=</operator><plain> </plain><string>\"hello world\"</string>"
        ])
    }

    @Test func pythonStringBody() {
        let lines = SyntaxHighlighter.highlight(
            code: "x = 'a b'", lang: "python", theme: RecordingSyntaxTheme()
        )
        #expect(lines == [
            "<plain>x</plain><plain> </plain><operator>=</operator><plain> </plain><string>'a b'</string>"
        ])
    }

    // Adapted from pi-mono b9ab918c6, regression test for #10143.
    @Test func pythonDocstringLines() {
        let lines = SyntaxHighlighter.highlight(
            code: "\"\"\"\nline one\n\nline two\n\"\"\"\nafter", lang: "python", theme: RecordingSyntaxTheme()
        )
        #expect(lines == [
            "<string>\"\"\"</string>",
            "<string>line one</string>",
            "",
            "<string>line two</string>",
            "<string>\"\"\"</string>",
            "<plain>after</plain>"
        ])
    }

    @Test func pythonSingleQuoteDocstringLines() {
        let lines = SyntaxHighlighter.highlight(
            code: "'''\nline one\n\nline two\n'''\nafter", lang: "python", theme: RecordingSyntaxTheme()
        )
        #expect(lines == [
            "<string>'''</string>", "<string>line one</string>", "",
            "<string>line two</string>", "<string>'''</string>", "<plain>after</plain>"
        ])
    }

    @Test(arguments: ["\"say \\\"hi\\\" end\"", "'say \\'hi\\' end'", "\"path\\\\\"", "\"🙂 return // 42\""])
    func stringEscapesAndContents(code: String) {
        let lines = SyntaxHighlighter.highlight(code: code, lang: "python", theme: RecordingSyntaxTheme())
        #expect(lines == ["<string>\(code)</string>"])
    }

    @Test(arguments: ["swift", "python", "javascript", "typescript", "c", "cpp", "csharp", "java", "kotlin", "go", "rust", "bash", "sh", "zsh", "json", "sql", "unknown"])
    func unclosedDoubleQuoteEndsAtLineEnd(lang: String) {
        let lines = SyntaxHighlighter.highlight(
            code: "\"unclosed\\\nnext = 42", lang: lang, theme: RecordingSyntaxTheme()
        )
        #expect(lines == [
            "<string>\"unclosed\\</string>",
            "<plain>next</plain><plain> </plain><operator>=</operator><plain> </plain><number>42</number>"
        ])
    }

    @Test(arguments: ["swift", "python", "javascript", "typescript", "c", "bash", "sql"])
    func unclosedSingleQuoteEndsAtLineEnd(lang: String) {
        let lines = SyntaxHighlighter.highlight(
            code: "'unclosed\nnext", lang: lang, theme: RecordingSyntaxTheme()
        )
        #expect(lines == ["<string>'unclosed</string>", "<plain>next</plain>"])
    }

    @Test(arguments: ["javascript", "typescript", "js", "jsx", "ts", "tsx"])
    func templateLiteralLines(lang: String) {
        let lines = SyntaxHighlighter.highlight(
            code: "`first\n${value} // 42\nlast` + after", lang: lang, theme: RecordingSyntaxTheme()
        )
        #expect(lines == [
            "<string>`first</string>", "<string>${value} // 42</string>",
            "<string>last`</string><plain> </plain><operator>+</operator><plain> </plain><plain>after</plain>"
        ])
    }

    @Test(arguments: ["c", "cpp", "csharp", "java", "kotlin", "go", "rust", "unknown", ""])
    func sharedBacktickModeLines(lang: String) {
        let lines = SyntaxHighlighter.highlight(code: "`first\n\nlast`", lang: lang, theme: RecordingSyntaxTheme())
        #expect(lines == ["<string>`first</string>", "", "<string>last`</string>"])
    }

    @Test func swiftMultilineStringLines() {
        let lines = SyntaxHighlighter.highlight(
            code: "\"\"\"\nhello world\n\"\"\"", lang: "swift", theme: RecordingSyntaxTheme()
        )
        #expect(lines == ["<string>\"\"\"</string>", "<string>hello world</string>", "<string>\"\"\"</string>"])
    }

    @Test(arguments: ["swift", "python"])
    func tripleQuoteCloseRequiresAnUnescapedFullDelimiter(lang: String) {
        let lines = SyntaxHighlighter.highlight(
            code: "\"\"\"one \" two \"\" \\\"\"\" end\n\"\"\" next", lang: lang, theme: RecordingSyntaxTheme()
        )
        #expect(lines == [
            "<string>\"\"\"one \" two \"\" \\\"\"\" end</string>",
            "<string>\"\"\"</string><plain> </plain><plain>next</plain>"
        ])
    }

    @Test(arguments: ["\"\"", "''", "\"\"\"\"\"\"", "''''''", "\"\"\"one\"\"\""])
    func emptyAndClosedStringsStayOneToken(code: String) {
        let lines = SyntaxHighlighter.highlight(code: code, lang: "python", theme: RecordingSyntaxTheme())
        #expect(lines == ["<string>\(code)</string>"])
    }

    @Test func blockCommentLines() {
        let lines = SyntaxHighlighter.highlight(
            code: "/* first\n\n\"quoted\" return\nlast */ next", lang: "swift", theme: RecordingSyntaxTheme()
        )
        #expect(lines == [
            "<comment>/* first</comment>", "", "<comment>\"quoted\" return</comment>",
            "<comment>last */</comment><plain> </plain><plain>next</plain>"
        ])
    }

    @Test func lineCommentAfterClosedString() {
        let lines = SyntaxHighlighter.highlight(
            code: "\"body // text\" // comment", lang: "swift", theme: RecordingSyntaxTheme()
        )
        #expect(lines == ["<string>\"body // text\"</string><plain> </plain><comment>// comment</comment>"])
    }

    @Test func multilineStringAtEndOfInputKeepsEmptyLines() {
        let lines = SyntaxHighlighter.highlight(
            code: "\"\"\"\nbody\\\n\n", lang: "python", theme: RecordingSyntaxTheme()
        )
        #expect(lines == ["<string>\"\"\"</string>", "<string>body\\</string>", "", ""])
    }

    @Test func plainThemePreservesInput() {
        let code = "let s = \"\"\"\n🙂 \\\" // text\n\n\"\"\" // comment\n"
        #expect(SyntaxHighlighter.highlight(code: code, lang: "swift").joined(separator: "\n") == code)
    }
}
