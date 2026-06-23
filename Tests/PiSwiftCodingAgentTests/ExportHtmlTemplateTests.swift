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

@Test func exportHtmlTemplateUsesTightToolSpacingRules() throws {
    let styles = try loadExportHtmlStyles()

    #expect(styles.contains(".assistant-text + .tool-execution"))
    #expect(styles.contains(".output-preview > div,"))
    #expect(styles.contains(".output-full > div"))
    #expect(styles.contains(".tool-output > div:not(.output-preview):not(.output-full),"))
    #expect(styles.contains(".output-preview > div:not(.expand-hint),"))
    #expect(styles.contains(".output-full > div:not(.expand-hint)"))
    #expect(!styles.contains(".output-preview,\n    .output-full"))
}

@Test func exportHtmlTemplateRendersFindLsAndGrepWithStructuredRows() throws {
    let template = try loadExportHtmlTemplate()
    let styles = try loadExportHtmlStyles()

    #expect(template.contains("function renderExpandableHtmlOutput(previewHtml, fullHtml, remaining, extraClass = '')"))
    #expect(template.contains("function formatPathListOutput(text, maxLines)"))
    #expect(template.contains("function formatGrepOutput(text, maxLines)"))
    #expect(template.contains("html += formatPathListOutput(output, 20);"))
    #expect(template.contains("html += formatGrepOutput(output, 20);"))
    #expect(template.contains("path-list-entry${isDirectory ? ' directory' : ''}"))
    #expect(template.contains("const match = line.match(/^(.*)([:\\-])(\\d+)([:\\-]) (.*)$/);"))
    #expect(template.contains("const isMatch = match[2] === ':' && match[4] === ':';"))

    #expect(styles.contains(".path-list-entry"))
    #expect(styles.contains(".path-list-entry.directory"))
    #expect(styles.contains(".grep-line.match .grep-content"))
    #expect(styles.contains(".grep-line.context .grep-content"))
    #expect(styles.contains(".tool-notice"))
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
