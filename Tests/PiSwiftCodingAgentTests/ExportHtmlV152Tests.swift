import Foundation
import Testing
@testable import PiSwiftCodingAgent

#if canImport(JavaScriptCore)
import JavaScriptCore

private enum ViewerTestError: Error {
    case javascript(String)
}

private func viewerResource() throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(
        "Sources/PiSwiftCodingAgent/Resources/export-html/template.js"), encoding: .utf8)
}

private func checkViewer(_ context: JSContext) throws {
    if let error = context.exception, !error.isUndefined {
        throw ViewerTestError.javascript(error.toString() ?? "JavaScript exception")
    }
}

private func viewerAPI(_ viewer: String, data: String, at marker: String, returning members: String) throws -> JSContext {
    let context = try #require(JSContext(virtualMachine: JSVirtualMachine()))
    context.setObject(data, forKeyedSubscript: "exportedSessionJSON" as NSString)
    _ = context.evaluateScript("""
    const document = { getElementById: () => ({ textContent: '' }), querySelector: () => null };
    const window = { location: { search: '' } };
    class URLSearchParams { get() { return null; } }
    """)
    try checkViewer(context)
    let loaderStart = try #require(viewer.range(of: "      const base64 = document.getElementById('session-data').textContent;"))
    let loaderEnd = try #require(viewer.range(of: "      const { header, entries, leafId: defaultLeafId, systemPrompt, tools, renderedTools } = data;"))
    var executable = viewer.replacingCharacters(in: loaderStart.lowerBound..<loaderEnd.lowerBound,
        with: "      const data = JSON.parse(exportedSessionJSON);\n")
    let entry = try #require(executable.range(of: marker))
    executable.replaceSubrange(entry, with: "\(marker)\n      return { \(members) }; ")
    let api = context.evaluateScript(executable)
    try checkViewer(context)
    context.setObject(api, forKeyedSubscript: "viewerAPI" as NSString)
    return context
}

private func viewerValue(_ script: String, in context: JSContext) throws -> JSValue {
    let result = context.evaluateScript(script)
    try checkViewer(context)
    return try #require(result)
}

@Test("uses recorded totals while falling back to component sums for old sessions")
func exportHtmlV152UsesRecordedCostTotal() throws {
    let viewer = try viewerResource()
    let start = try #require(viewer.range(of: "function computeStats(entryList)"))
    let end = try #require(viewer.range(of: "const globalStats = computeStats(entries);", range: start.upperBound..<viewer.endIndex))
    let function = String(viewer[start.lowerBound..<end.lowerBound])
    let context = try #require(JSContext(virtualMachine: JSVirtualMachine()))
    let script = function + """
    const entries = [
      {type: 'message', message: {role: 'assistant', content: [], usage: {cost: {input: 0.1, output: 0.2, cacheRead: 0, cacheWrite: 0, total: 0.9}}}},
      {type: 'message', message: {role: 'assistant', content: [], usage: {cost: {input: 0.4, output: 0.1, cacheRead: 0, cacheWrite: 0}}}}
    ];
    computeStats(entries).cost;
    """
    let cost = try viewerValue(script, in: context)
    #expect(abs(cost.forProperty("input").toDouble() - 0.5) < 0.000001)
    #expect(abs(cost.forProperty("output").toDouble() - 0.3) < 0.000001)
    #expect(abs(cost.forProperty("total").toDouble() - 1.4) < 0.000001)
}

@Test("renders system message text the same way the model receives it")
func exportHtmlV152RendersSystemMessageText() throws {
    let data = #"{"header":{"id":"system-test"},"entries":[{"type":"message","id":"s1","parentId":null,"timestamp":"1970-01-01T00:00:00Z","message":{"role":"system","content":"You are a helpful assistant.","sections":{"rules":"<rules>\nbe concise\n</rules>","project_context":"<project_context>\nv1\n</project_context>"},"toolsAdded":[{"name":"read","description":"Read a file","parameters":{"type":"object","properties":{}}}]}},{"type":"message","id":"u1","parentId":"s1","timestamp":"1970-01-01T00:00:01Z","message":{"role":"user","content":"hi"}},{"type":"message","id":"s2","parentId":"u1","timestamp":"1970-01-01T00:00:02Z","message":{"role":"system","content":[{"type":"text","text":"Extra instructions"}],"sections":{"project_context":"<project_context>\nv2\n</project_context>","rules":null},"toolsAdded":[{"name":"bash","description":"Run a command","parameters":{"type":"object","properties":{}}}],"toolsRemoved":[{"name":"read"}]}}],"leafId":"s2","systemPrompt":"fallback","tools":[]}"#
    let viewer = try viewerResource()
    let context = try viewerAPI(viewer, data: data, at: "      // INITIALIZATION", returning:
        "data, getSystemMessageText, renderSystemMessageUpdate, isLeadingSystemEntry, describeSystemUpdate, renderEntry, getSearchableText, getTreeNodeDisplayHtml")
    #expect(try viewerValue("viewerAPI.getSystemMessageText(viewerAPI.data.entries[0].message)", in: context).toString()
        == "You are a helpful assistant.\n\n<rules>\nbe concise\n</rules>\n\n<project_context>\nv1\n</project_context>")
    #expect(try viewerValue("viewerAPI.renderSystemMessageUpdate(viewerAPI.data.entries[2].message)", in: context).toString()
        == "Extra instructions\n\nUpdated system prompt section \"project_context\":\n\n<project_context>\nv2\n</project_context>\n\nRemoved system prompt section \"rules\".")
    #expect(try viewerValue("viewerAPI.isLeadingSystemEntry(viewerAPI.data.entries[0])", in: context).toBool())
    #expect(try !viewerValue("viewerAPI.isLeadingSystemEntry(viewerAPI.data.entries[2])", in: context).toBool())
    #expect(try viewerValue("viewerAPI.describeSystemUpdate(viewerAPI.data.entries[2].message)", in: context).toString()
        == "instructions, project_context, -rules, tools +bash -read")
    let first = try #require(viewerValue("viewerAPI.renderEntry(viewerAPI.data.entries[0])", in: context).toString())
    let update = try #require(viewerValue("viewerAPI.renderEntry(viewerAPI.data.entries[2])", in: context).toString())
    #expect(first.contains("System Prompt"))
    #expect(first.contains("Available Tools"))
    #expect(update.contains("System Prompt Update: instructions, project_context, -rules, tools +bash -read"))
    #expect(update.contains("Tools Added"))
    #expect(update.contains("Tools Removed"))
    #expect(viewer.contains("if (!hasSystemEntries)"))
}

@Test("treats a compaction snapshot as earlier system state")
func exportHtmlV152CompactionIsEarlierSystemState() throws {
    let data = #"{"header":{"id":"compaction-test"},"entries":[{"type":"compaction","id":"c1","parentId":null,"systemMessage":{"role":"system","content":"initial"}},{"type":"message","id":"s2","parentId":"c1","message":{"role":"system","content":"update"}}],"leafId":"s2","systemPrompt":null,"tools":[]}"#
    let context = try viewerAPI(viewerResource(), data: data, at: "      // INITIALIZATION", returning: "data, isLeadingSystemEntry")
    #expect(try !viewerValue("viewerAPI.isLeadingSystemEntry(viewerAPI.data.entries[1])", in: context).toBool())
}

@Test("builds and flattens a single-child chain deeper than the call stack", .timeLimit(.minutes(5)))
func exportHtmlV152DeepTreeInRealViewer() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("c-sess-export-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("session.jsonl")
    let output = directory.appendingPathComponent("export.html")
    var lines = ["{\"type\":\"session\",\"version\":\(CURRENT_SESSION_VERSION),\"id\":\"deep-test\",\"timestamp\":\"1970-01-01T00:00:00Z\",\"cwd\":\"\(directory.path)\"}"]
    lines.reserveCapacity(20_001)
    for index in 0..<20_000 {
        let parent = index == 0 ? "null" : "\"e\(index - 1)\""
        lines.append("{\"type\":\"message\",\"id\":\"e\(index)\",\"parentId\":\(parent),\"timestamp\":\"1970-01-01T00:00:00Z\",\"message\":{\"role\":\"user\",\"content\":\"x\",\"timestamp\":\(index)}}")
    }
    try (lines.joined(separator: "\n") + "\n").write(to: input, atomically: true, encoding: .utf8)
    _ = try exportFromFile(input.path, ExportOptions(outputPath: output.path, themeName: "dark"))
    let html = try String(contentsOf: output, encoding: .utf8)
    let regex = try NSRegularExpression(pattern: #"<script id="session-data" type="application/json">([^<]+)</script>"#)
    let match = try #require(regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)))
    let encoded = String(html[try #require(Range(match.range(at: 1), in: html))])
    let data = try #require(Data(base64Encoded: encoded))
    let context = try viewerAPI(viewerResource(), data: String(decoding: data, as: UTF8.self), at:
        "      let treeNodeMap = null;", returning: "buildTree, buildActivePathIds, flattenTree, findNewestLeaf, getPath")
    #expect(try viewerValue("viewerAPI.buildTree().length", in: context).toInt32() == 1)
    #expect(try viewerValue("viewerAPI.flattenTree(viewerAPI.buildTree(), viewerAPI.buildActivePathIds('e19999')).length", in: context).toInt32() == 20_000)
    #expect(try viewerValue("viewerAPI.findNewestLeaf('e0')", in: context).toString() == "e19999")
    #expect(try viewerValue("viewerAPI.getPath('e19999').length", in: context).toInt32() == 20_000)
    #expect(try viewerValue("viewerAPI.getPath('e19999')[0].id", in: context).toString() == "e0")
}
#endif
