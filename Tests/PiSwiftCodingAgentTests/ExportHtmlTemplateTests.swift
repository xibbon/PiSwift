import Foundation
import Testing

@Test func exportHtmlTemplateSanitizesMarkdownLinks() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let templatePath = packageRoot
        .appendingPathComponent("Sources/PiSwiftCodingAgent/Resources/export-html/template.js")
    let template = try String(contentsOf: templatePath, encoding: .utf8)

    #expect(template.contains("function sanitizeMarkdownUrl"))
    #expect(template.contains("java\\nscript:"))
    #expect(template.contains("scheme === 'http' || scheme === 'https' || scheme === 'mailto' || scheme === 'tel'"))
    #expect(template.contains("link(token)"))
    #expect(template.contains("image(token)"))
    #expect(template.contains("sanitizeMarkdownUrl(token.href"))
}
