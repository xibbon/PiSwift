import Foundation
import Testing
@testable import PiSwiftCodingAgent

@Test func exportHtmlCurrentTemplateSupportsHiddenMessagesAndNestedCalls() throws {
    let source = try currentExportResource("js")
    let css = try currentExportResource("css")
    #expect(source.contains("const hidden = entry.display === false;"))
    #expect(source.contains("document.body.classList.toggle('show-hidden-messages', visible);"))
    #expect(source.contains("else if (key === 'h')"))
    #expect(source.contains("setHiddenMessagesVisible(true);"))
    #expect(source.contains("setThinkingExpanded(thinkingExpanded);"))
    #expect(source.contains("setToolOutputsExpanded(toolOutputsExpanded);"))
    #expect(css.contains("body:not(.show-hidden-messages) .hook-message-hidden"))
    #expect(source.contains("const nested = result?.nestedCalls;"))
    #expect(source.contains("html += renderNestedCalls();"))
    #expect(source.contains("(incomplete record)"))
    #expect(source.contains("[arguments omitted, ${c.argumentsBytes} bytes]"))
}

@Test func exportHtmlCurrentTemplateKeepsUpstreamSkillAndSecuritySupport() throws {
    let source = try currentExportResource("js")
    #expect(source.contains("function parseSkillBlock(text)"))
    #expect(source.contains("strictStrikethroughRegex"))
    #expect(source.contains("escapeAttribute(href)"))
    #expect(source.contains("const href = sanitizeMarkdownUrl(token.href);"))
    #expect(source.contains("isEditableTarget(document.activeElement)"))
    #expect(source.contains("escapeHtml(globalStats.models.join"))
    #expect(source.contains("event.defaultPrevented || event.ctrlKey || event.metaKey || event.altKey"))
}

private func currentExportResource(_ ext: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(
        "Sources/PiSwiftCodingAgent/Resources/export-html/template.\(ext)"), encoding: .utf8)
}

@Test func exportHtmlJavascriptRunsHiddenToggleNestedCallsAndSkillCases() throws {
    let source = try currentExportResource("js")
    func section(_ start: String, _ end: String) throws -> String {
        let a = try #require(source.range(of: start))
        let b = try #require(source.range(of: end, range: a.upperBound..<source.endIndex))
        return String(source[a.lowerBound..<b.lowerBound])
    }
    let rendering = try section("      function renderCopyLinkButton(entryId)", "      const globalStats =")
    let tree = try section("      function getTreeNodeDisplayHtml(entry, label)", "      // ============================================================")
    let urls = try section("      function sanitizeMarkdownUrl(", "      function getTreeNodeDisplayHtml(")
    let helpers = try section("      function hasActiveTextSelection()", "      function renderToolCall(call)")
    let nested = try section("        const renderNestedCalls = () =>", "        const toolDomId =")
    let hidden = try section("      function setHiddenMessagesVisible(visible)", "      function setThinkingExpanded")
    let skill = try section("      function parseSkillBlock(text)", "      function getSearchableText")
    let editable = try section("      const isEditableTarget =", "      const canHandleSingleKeyShortcut")
    let keyboard = try section("      const canHandleSingleKeyShortcut = (event)", "      // Initial render")
    let script = #"""
    const assert = require('node:assert/strict');
    const classes = new Set(); const attrs = {}; let button = { setAttribute: (k,v) => attrs[k]=v };
    let handler; let showHiddenMessages = false; let thinkingExpanded = true; let toolOutputsExpanded = false;
    const document = { body: {classList: {toggle: (k,v) => v ? classes.add(k) : classes.delete(k)}},
      querySelector: () => button, activeElement: null, addEventListener: (name,fn) => handler=fn };
    class Element {}; const searchInput = {}; const leafId = 'leaf'; let searchQuery = '';
    const navigateTo = () => {}; const setThinkingExpanded = () => {}; const setToolOutputsExpanded = () => {};
    const escapeHtml = s => s.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('\"','&quot;');
    const safeMarkedParse = s => '<p>' + escapeHtml(s) + '</p>'; const formatTimestamp = () => '';
    const extractContent = s => typeof s === 'string' ? s : s.filter(c=>c.type==='text').map(c=>c.text).join('\n');
    const toolCallMap = new Map();
    const replaceTabs = s => s.replaceAll('\t','   '); const window = {};
    """# + urls + helpers + hidden + skill + rendering + tree + editable + keyboard + #"""
    for (const bad of ['javascript:alert(1)','java\nscript:alert(1)','java&#x09;script:alert(1)','vbscript:x']) assert.equal(sanitizeMarkdownUrl(bad),null);
    assert.equal(sanitizeMarkdownUrl('https://example.com'),'https://example.com');
    assert.equal(sanitizeMarkdownUrl('mailto:a@example.com'),'mailto:a@example.com');
    const plain = formatExpandableOutput('  first\n\n   last',1);
    assert(plain.includes('<pre>  first</pre>')); assert(plain.includes('<pre>  first\n\n   last</pre>'));
    assert.equal(sanitizeMarkdownUrl('ftp://example.com'),'ftp://example.com');
    assert.equal(sanitizeMarkdownUrl('https://exam\nple.com'),'https://example.com');
    const malicious = '\" onerror=\"alert(1)';
    const imageHtml = renderEntry({id:malicious,type:'message',message:{role:'user',content:[{type:'image',mimeType:malicious,data:malicious}]}});
    assert(!imageHtml.includes(malicious)); assert(imageHtml.includes('&quot; onerror=&quot;'));
    const rawSkill = '<skill name="demo" location="/tmp/SKILL.md">\n# Title\n</skill>\n\nRun it';
    const renderedSkill = renderEntry({id:'skill',type:'message',message:{role:'user',content:rawSkill}});
    assert(renderedSkill.includes('<p># Title</p>')); assert(renderedSkill.includes('<p>Run it</p>'));
    assert(renderedSkill.indexOf('skill-invocation') < renderedSkill.indexOf('user-message'));
    assert(!renderedSkill.includes('&lt;skill'));
    const treeSkill = getTreeNodeDisplayHtml({type:'message',message:{role:'user',content:rawSkill}});
    assert(treeSkill.includes('demo')); assert(treeSkill.includes('Run it'));
    const skillOnly = renderEntry({id:'skill',type:'message',message:{role:'user',content:rawSkill.split('\n\nRun it')[0]}});
    assert(!skillOnly.includes('class="user-message"'));
    for (const entry of [{type:'model_change',modelId:malicious},{type:'thinking_level_change',thinkingLevel:malicious},{type:malicious},{type:'message',message:{role:malicious}},{type:'message',message:{role:'toolResult',toolName:malicious}}]) {
      const html = getTreeNodeDisplayHtml(entry); assert(!html.includes(malicious));
    }
    let prevented = 0;
    const event = (key, mods={}) => ({key, preventDefault:()=>prevented++, ...mods});
    handler(event('H')); assert.equal(showHiddenMessages,true); assert(classes.has('show-hidden-messages')); assert.equal(attrs['aria-pressed'],'true');
    handler(event('h',{ctrlKey:true})); assert.equal(showHiddenMessages,true);
    handler(event('h')); assert.equal(showHiddenMessages,false); assert.equal(attrs['aria-pressed'],'false');
    assert.equal(prevented,2);
    const block = parseSkillBlock('<skill name="demo" location="/tmp/SKILL.md">\n# Title\n</skill>\n\nRun it');
    assert.equal(block.name,'demo'); assert.equal(block.content,'# Title'); assert.equal(block.userMessage,'Run it');
    const result = { nestedCalls: { complete:false, calls:[
      {name:'read', status:'ok', arguments:{path:'<x>'}, durationMs:12},
      {name:'bad', status:'error', argumentsBytes:32, error:'a\nb'},
      {name:'pending', status:'unfinished', argumentsBytes:0}
    ]}};
    """# + nested + #"""
    const html = renderNestedCalls();
    for (const value of ['Nested calls: 3 (incomplete record)','✓ read','✗ bad','… pending','32 bytes','12ms','&lt;x&gt;']) assert(html.includes(value),value);
    result.nestedCalls.calls=[]; assert.equal(renderNestedCalls(),'');
    console.log('H, modifier keys, skill block and nested call runtime cases passed');
    """#
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", "-e", script]
    let output = Pipe(); process.standardOutput = output; process.standardError = output
    try process.run(); process.waitUntilExit()
    let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0, Comment(rawValue: message))
}

@Test func exportHtmlFillsEveryTemplatePlaceholder() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("c6-export-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("session.jsonl")
    let output = directory.appendingPathComponent("export.html")
    let json = #"{"type":"session","version":3,"id":"export-test","timestamp":"2026-10-01T00:00:00Z","cwd":"/tmp"}"# + "\n"
    try json.write(to: input, atomically: true, encoding: .utf8)
    _ = try exportFromFile(input.path, ExportOptions(outputPath: output.path, themeName: "dark"))
    let html = try String(contentsOf: output, encoding: .utf8)
    for token in ["THEME_VARS", "BODY_BG", "CONTAINER_BG", "INFO_BG", "CSS", "JS", "SESSION_DATA", "MARKED_JS", "HIGHLIGHT_JS"] {
        #expect(!html.contains("{{\(token)}}"))
    }
    #expect(html.contains("sidebar-resizer"))
}
