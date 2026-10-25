import Testing
@testable import PiSwiftDurable

private struct IgnoreExample: Sendable {
    let pattern: String
    let path: String
    let directory: Bool
    let matches: Bool
    init(_ pattern: String, _ path: String, _ matches: Bool, directory: Bool = false) {
        self.pattern = pattern; self.path = path; self.matches = matches; self.directory = directory
    }
}

struct GitIgnoreTests {
    // Shared syntax examples, with crate results for all known differences from Git.
    @Test("daemon ignore patterns", arguments: [
        IgnoreExample("# comment", "# comment", false), IgnoreExample("", "x", false),
        IgnoreExample("\\#hash", "a/#hash", true), IgnoreExample("\\!bang", "!bang", true),
        IgnoreExample("space   ", "space", true), IgnoreExample("space\\ ", "space ", true),
        IgnoreExample("space\\  ", "space ", false), IgnoreExample("space\\ ", "space", false),
        IgnoreExample("back\\\\ ", "back\\", false), IgnoreExample("x\\", "x", false),
        IgnoreExample("\\a", "a", true), IgnoreExample("\\*", "*", true),
        IgnoreExample("*.log", "a/b/drop.log", true), IgnoreExample("*.log", "a/b/drop.txt", false),
        IgnoreExample("/foo", "foo", true), IgnoreExample("/foo", "a/foo", false),
        IgnoreExample("doc/frotz/", "doc/frotz", true, directory: true),
        IgnoreExample("doc/frotz/", "a/doc/frotz", false, directory: true),
        IgnoreExample("frotz/", "a/frotz", true, directory: true),
        IgnoreExample("frotz/", "a/frotz", false), IgnoreExample("frotz/", "frotz/x", false),
        IgnoreExample("foo/*", "foo/test.json", true), IgnoreExample("foo/*", "foo/bar/hello.c", false),
        IgnoreExample("hello.*", "a/hello.txt", true), IgnoreExample("/hello.*", "a/hello.txt", false),
        IgnoreExample("foo/?", "foo/a", true), IgnoreExample("foo/?", "foo/ab", false),
        IgnoreExample("foo/?", "foo/é", false), IgnoreExample("foo/??", "foo/é", true),
        IgnoreExample("**/foo", "foo", true), IgnoreExample("**/foo", "a/b/foo", true),
        IgnoreExample("**/foo/bar", "a/foo/bar", true), IgnoreExample("**/foo", "xfoo", false),
        IgnoreExample("abc/**", "abc", false, directory: true), IgnoreExample("abc/**", "abc/a/b", true),
        IgnoreExample("a/**/b", "a/b", true), IgnoreExample("a/**/b", "a/x/y/b", true),
        IgnoreExample("a/**/b", "a/xb", false), IgnoreExample("a/**/b", "a/x/b/c", false),
        IgnoreExample("a**b", "axxb", true), IgnoreExample("a**b", "a/x/b", false),
        IgnoreExample("a/**b", "a/xxb", true), IgnoreExample("a/**b", "a/x/xxb", false),
        IgnoreExample("a/***/b", "a/b", false), IgnoreExample("a/***/b", "a/x/b", true),
        IgnoreExample("[a-cA-C0-2].txt", "B.txt", true), IgnoreExample("[a-c].txt", "d.txt", false),
        IgnoreExample("[!ab]", "c", true), IgnoreExample("[^ab]", "a", false),
        IgnoreExample("[!a]", "/", true), IgnoreExample("[]a]", "]", true),
        IgnoreExample("[-a]", "-", true), IgnoreExample("[a-]", "-", true),
        IgnoreExample("[a\\-c]", "-", false), IgnoreExample("[a\\-c]", "b", true),
        IgnoreExample("[abc", "[abc", true), IgnoreExample("[", "[", true),
        IgnoreExample("[[:", "[[:", true), IgnoreExample("[z-a]", "z", false),
        IgnoreExample("[[:digit:]][[:alpha:]]", "2Z", false),
        IgnoreExample("[[:space:]]", "\t", false), IgnoreExample("[[:xdigit:]]", "f", false),
        IgnoreExample("[[:upper:]]", "a", false), IgnoreExample("a\r", "a", true),
    ])
    fileprivate func pattern(_ example: IgnoreExample) {
        let rule = GitIgnoreRule(example.pattern)
        #expect((rule?.matches(Array(example.path.utf8), isDirectory: example.directory) ?? false) == example.matches)
    }

    // Crate-only vectors: these intentionally do not use Git as the oracle.
    // globset 0.4.20 glob.rs: cls1...cls21, err_range*, allow_unclosed_class*,
    // re31, matchrec*, matchescape, matchalt*, matchslash4.
    // ignore 0.4.33 gitignore.rs: ig21/22/29/30/38...44, ignot13/16,
    // and the add_line whitespace and escaped-suffix rules at lines 470...526.
    @Test("crate-only vectors and upstream globset examples", arguments: [
        IgnoreExample("tab\t", "tab", true), IgnoreExample("tab\t", "tab\t", false),
        IgnoreExample("name\u{85}\u{a0}\u{1680}\u{2003}\u{2028}\u{202f}\u{205f}\u{3000}", "name", true),
        IgnoreExample("space\\ ", "space ", true), IgnoreExample("space\\  ", "space ", false),
        IgnoreExample("back\\\\ ", "back\\ ", true), IgnoreExample("back\\\\ ", "back\\", false),
        IgnoreExample("foo\\/", "foo", true, directory: true), IgnoreExample("foo\\/", "foo", false),
        IgnoreExample("foo\\\\/", "foo\\", false, directory: true),
        IgnoreExample("a/***/b", "a/b", false), IgnoreExample("a/***/b", "a/x/b", true),
        IgnoreExample("a/***/b", "a/x/y/b", false),
        IgnoreExample("[abc", "[abc", true), IgnoreExample("[", "[", true),
        IgnoreExample("[]", "[]", true), IgnoreExample("[][", "[][", true),
        IgnoreExample("[!", "[!", true), IgnoreExample("[!]", "[!]", true),
        IgnoreExample("[z-a]", "z", false), IgnoreExample("[z-aZ]", "Z", false),
        IgnoreExample("[z--]", "-", false), IgnoreExample("[ê-é]", "é", false),
        IgnoreExample("[a\\-c]", "b", true), IgnoreExample("[a\\-c]", "-", false),
        IgnoreExample("[\\]", "\\", true), IgnoreExample("[[:digit:]]", "2", false),
        IgnoreExample("[[:digit:]]", "d]", true), IgnoreExample("[[:digit:]]", ":]", true),
        IgnoreExample("[![:bogus:]]", "a]", true), IgnoreExample("abc[/]def", "abc/def", true),
        IgnoreExample("abc[!x]def", "abc/def", true),
        IgnoreExample("a[0-9]b", "a0b", true), IgnoreExample("a[0-9]b", "a9b", true),
        IgnoreExample("a[!0-9]b", "a_b", true), IgnoreExample("[a-z123]", "1", true),
        IgnoreExample("[1a-z23]", "1", true), IgnoreExample("[123a-z]", "1", true),
        IgnoreExample("[abc-]", "-", true), IgnoreExample("[-abc]", "-", true),
        IgnoreExample("[-a-c]", "b", true), IgnoreExample("[a-c-]", "b", true),
        IgnoreExample("[-]", "-", true), IgnoreExample("[]]", "]", true),
        IgnoreExample("[*]", "*", true), IgnoreExample("[!!]", "a", true),
        IgnoreExample("[]-z]", "a", true), IgnoreExample("[--z]", "a", true),
        IgnoreExample("[ --]", "!", true), IgnoreExample("_[[]_[]]_[?]_[*]_!_", "_[_]_?_*_!_", true),
        IgnoreExample("some/**/needle.txt", "some/needle.txt", true),
        IgnoreExample("some/**/needle.txt", "some/one/two/needle.txt", true),
        IgnoreExample("some/**/**/needle.txt", "some/needle.txt", true),
        IgnoreExample("**/**/*", "a/foo.rs", true), IgnoreExample("**/", "foo/bar", true, directory: true),
        IgnoreExample("node_modules/ ", "node_modules", true, directory: true),
        IgnoreExample("foo/**", "foo", false, directory: true),
        IgnoreExample("{a,b}", "a", true), IgnoreExample("{a,b}", "b", true),
        IgnoreExample("{a,{b,c}}", "c", true), IgnoreExample("{{a,b},{c,d}}", "d", true),
        IgnoreExample("{**/src/**,foo}", "abc/src/bar", true),
        IgnoreExample("{**/src/**,foo}", "foo", true), IgnoreExample("{[}],foo}", "}", true),
        IgnoreExample("{foo}", "foo", true), IgnoreExample("foo{,.txt}", "foo.txt", true),
        IgnoreExample("foo{,.txt}", "foo", false), IgnoreExample("a{,}b", "ab", true),
        IgnoreExample("{a,b{c,d}}", "bc", true), IgnoreExample("{a,b{c,d}}", "bd", true),
        IgnoreExample("{[abc,xyz}", "[abc", true), IgnoreExample("{[abc,xyz}", "xyz", true),
        IgnoreExample("{[abc],[xyz}", "a", true), IgnoreExample("{[abc],[xyz}", "[xyz", true),
        IgnoreExample("{a,b", "a", false), IgnoreExample("a,b}", "a", false),
        IgnoreExample("{a,{b,c}", "a", false), IgnoreExample("{a,b}}", "a", false),
        IgnoreExample("a,b", "a,b", true), IgnoreExample("\\{a,b\\}", "{a,b}", true),
    ])
    fileprivate func cratePatterns(_ example: IgnoreExample) { pattern(example) }

    @Test("globset class members are bytes, including encoded Unicode ranges")
    func byteClasses() throws {
        let literal = try #require(GitIgnoreRule("/[é]"))
        #expect(literal.matches([0xc3], isDirectory: false))
        #expect(literal.matches([0xa9], isDirectory: false))
        #expect(!literal.matches(Array("é".utf8), isDirectory: false))
        let range = try #require(GitIgnoreRule("/[é-ê]"))
        #expect(range.matches([0xb0], isDirectory: false))
        #expect(!range.matches([0xa8], isDirectory: false))
        #expect(GitIgnoreRule("/[ê-é]") == nil)
        let slash = try #require(GitIgnoreRule("abc[!x]/def"))
        #expect(slash.matches(Array("abc//def".utf8), isDirectory: false))
        let all = try #require(GitIgnoreRule("!"))
        #expect(all.negated && all.matches(Array("a/b".utf8), isDirectory: false))
    }

    @Test("last matching rule wins, with comments, BOM, CRLF, and negation")
    func lastRule() {
        let rules = GitIgnore.rules("\u{feff}# comment\r\n*.log\r\n!keep.log\r\ndrop.log\n")
        #expect(GitIgnore.match(rules, path: Array("keep.log".utf8), isDirectory: false) == false)
        #expect(GitIgnore.match(rules, path: Array("drop.log".utf8), isDirectory: false) == true)
        #expect(GitIgnore.match(rules, path: Array("other.txt".utf8), isDirectory: false) == nil)
    }

    @Test("many stars do not cause recursive or exponential matching")
    func manyStars() throws {
        let rule = try #require(GitIgnoreRule(String(repeating: "*a", count: 200) + "b"))
        #expect(!rule.matches(Array(String(repeating: "a", count: 1000).utf8), isDirectory: false))
    }
}
