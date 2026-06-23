import Foundation
import Testing

@Test func exportHtmlTemplateSanitizesMarkdownLinks() throws {
    let template = try loadExportHtmlTemplate()

    #expect(template.contains("function sanitizeMarkdownUrl"))
    #expect(template.contains("java\\nscript:"))
    #expect(template.contains("scheme === 'http' || scheme === 'https' || scheme === 'mailto' || scheme === 'tel'"))
    #expect(template.contains("link(token)"))
    #expect(template.contains("image(token)"))
    #expect(template.contains("sanitizeMarkdownUrl(token.href"))
}

@Test func exportHtmlTemplateShowsHtmlLikeMarkdownContentVerbatim() throws {
    let template = try loadExportHtmlTemplate()

    #expect(template.contains("function escapeHtmlLikeTags"))
    #expect(template.contains("return text.replace(/<(?=[a-zA-Z\\/])/g, '&lt;');"))
    #expect(template.contains("html(token)"))
    #expect(template.contains("return escapeHtml(token.text);"))
    #expect(template.contains("return marked.parse(escapeHtmlLikeTags(text));"))
}

@Test func exportHtmlTemplateDoesNotToggleExpandableBlocksWhileSelectingText() throws {
    let template = try loadExportHtmlTemplate()

    #expect(template.contains("function hasActiveTextSelection()"))
    #expect(template.contains("function toggleExpandableFromClick(event, element)"))
    #expect(template.contains("if (hasActiveTextSelection()) return;"))
    #expect(template.contains("onclick=\"toggleExpandableFromClick(event, this)\""))
    #expect(!template.contains("onclick=\"this.classList.toggle('expanded')\""))
    #expect(!template.contains("onclick=\"this.classList.toggle(\\'expanded\\')\""))
}

private func loadExportHtmlTemplate() throws -> String {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let templatePath = packageRoot
        .appendingPathComponent("Sources/PiSwiftCodingAgent/Resources/export-html/template.js")
    return try String(contentsOf: templatePath, encoding: .utf8)
}
