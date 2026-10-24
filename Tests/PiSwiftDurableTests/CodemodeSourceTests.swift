import Testing
@testable import PiSwiftDurable

struct CodemodeSourceTests {
    @Test func directiveKeepsLineNumbersAndLimits() throws {
        let parsed = try parseCodemodeSource("\u{FEFF} // @options: {\"timeout_ms\":2147483647,\"max_output_tokens\":0}\r\nreturn 1")
        #expect(parsed.code == "\nreturn 1")
        #expect(parsed.options.timeoutMs == 2_147_483_647)
        #expect(parsed.options.maxOutputTokens == 0)
        #expect(try parseCodemodeSource("return 1").code == "return 1")
        #expect(try parseCodemodeSource("// @options: {\"max_output_tokens\":9007199254740991}\nreturn 1").options.maxOutputTokens == 9_007_199_254_740_991)
    }
    @Test(arguments: ["", " \n\t", "\u{FEFF}", "// @options: {}", "\n// @options: {}\nreturn 1", "// @options: []\nreturn 1", "// @options: nope\nreturn 1", "// @options:\nreturn 1", "// @options: {\"unknown\":1}\nreturn 1", "// @options: {\"max_output_tokens\":-1}\nreturn 1", "// @options: {\"max_output_tokens\":true}\nreturn 1", "// @options: {\"max_output_tokens\":9007199254740992}\nreturn 1", "// @options: {\"timeout_ms\":0}\nreturn 1", "// @options: {\"timeout_ms\":2147483648}\nreturn 1", "// @options: {\"timeout_ms\":1.5}\nreturn 1"])
    func invalidSourceOrOptions(_ input: String) {
        #expect(throws: CodemodeSourceError.self) { try parseCodemodeSource(input) }
    }
}
