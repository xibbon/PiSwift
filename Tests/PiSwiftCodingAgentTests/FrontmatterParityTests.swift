import Testing
import PiSwiftCodingAgent

@Test func frontmatterDecodesYamlQuotedScalars() {
    let parsed = parseFrontmatter(#"""
        ---
        description: "Find \"X\" and include \\(.applicationName)."
        name: 'it''s-literal\n'
        ---
        Body
        """#)
    #expect(parsed.parseError == nil)
    #expect(parsed.frontmatter["description"] == #"Find "X" and include \(.applicationName)."#)
    #expect(parsed.frontmatter["name"] == #"it's-literal\n"#)
}

@Test func frontmatterDecodesYamlUnicodeAndControlEscapes() {
    let parsed = parseFrontmatter(#"""
        ---
        description: "a\nb\t\x41\u0042\U0001F600"
        ---
        """#)
    #expect(parsed.parseError == nil)
    #expect(parsed.frontmatter["description"] == "a\nb\tAB😀")
}

@Test func frontmatterRejectsInvalidQuotedEscape() {
    #expect(parseFrontmatter("---\ndescription: \"bad\\q\"\n---").parseError != nil)
}
