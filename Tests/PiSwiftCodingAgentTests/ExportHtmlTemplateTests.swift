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

@Test func exportHtmlTemplateUsesBrowserSafeHeaderToggles() throws {
    let template = try loadExportHtmlTemplate()
    let styles = try loadExportHtmlStyles()

    #expect(template.contains("data-action=\"thinking\""))
    #expect(template.contains("data-action=\"tools\""))
    #expect(template.contains("T thinking · O tools"))
    #expect(template.contains("const canHandleSingleKeyShortcut = (event) =>"))
    #expect(template.contains("event.ctrlKey || event.metaKey || event.altKey"))
    #expect(template.contains("target.closest('input, textarea, select, [contenteditable=\"true\"]')"))
    #expect(template.contains("e.key.toLowerCase() === 't'"))
    #expect(template.contains("e.key.toLowerCase() === 'o'"))
    #expect(!template.contains("Ctrl+T toggle thinking"))
    #expect(!template.contains("Ctrl+O toggle tools"))

    #expect(styles.contains(".header-toggle"))
    #expect(styles.contains(".header-toggle[aria-pressed=\"true\"]"))
    #expect(styles.contains(".help-shortcuts"))
}

@Test func exportHtmlTemplatePreservesPlainTextToolOutputIndentation() throws {
    let template = try loadExportHtmlTemplate()
    let styles = try loadExportHtmlStyles()

    #expect(template.contains("const escapedText = escapeHtml(text);"))
    #expect(template.contains("const previewText = escapeHtml(displayLines.join('\\n'));"))
    #expect(template.contains("<div class=\"output-preview\"><pre>${previewText}</pre>"))
    #expect(template.contains("<div class=\"output-full\"><pre>${escapedText}</pre></div></div>`;"))
    #expect(template.contains("return `<div class=\"tool-output\"><pre>${escapedText}</pre></div>`;"))
    #expect(!template.contains("out += `<div>${escapeHtml(replaceTabs(line))}</div>`;"))

    #expect(styles.contains(".tool-output pre"))
    #expect(styles.contains("white-space: pre-wrap;"))
}

private func loadExportHtmlTemplate() throws -> String {
    try loadExportHtmlResource(named: "template", ext: "js")
}

private func loadExportHtmlStyles() throws -> String {
    try loadExportHtmlResource(named: "template", ext: "css")
}

private func loadExportHtmlResource(named name: String, ext: String) throws -> String {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let templatePath = packageRoot
        .appendingPathComponent("Sources/PiSwiftCodingAgent/Resources/export-html/\(name).\(ext)")
    return try String(contentsOf: templatePath, encoding: .utf8)
}
