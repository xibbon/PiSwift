import Foundation
import Testing
@testable import PiSwiftCodingAgent

@Test func c2bReadRangesRunInTheBundledHtmlViewer() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("c2b-html-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let vectors: [(Any?, Any?)] = [
        (25, 13), ("25", "13"), (NSNull(), "13"), ("25", NSNull()),
        (nil, nil), ("abc", 13), (25, ""), (25, "Infinity")
    ]
    let timestamp = "2026-10-01T00:00:00Z"
    var records: [[String: Any]] = [["type": "session", "version": CURRENT_SESSION_VERSION,
                                   "id": "range-test", "timestamp": timestamp, "cwd": root.path]]
    for (index, vector) in vectors.enumerated() {
        var args: [String: Any] = ["path": "notes.txt"]
        args["offset"] = vector.0
        args["limit"] = vector.1
        records.append(["type": "message", "id": "assistant-\(index)", "parentId": NSNull(), "timestamp": timestamp,
            "message": ["role": "assistant", "content": [["type": "toolCall", "id": "call-\(index)", "name": "read", "arguments": args]],
                        "api": "anthropic-messages", "provider": "anthropic", "model": "test-model",
                        "usage": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 0,
                                  "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0]],
                        "stopReason": "toolUse", "timestamp": 0]])
        records.append(["type": "message", "id": "result-\(index)", "parentId": "assistant-\(index)", "timestamp": timestamp,
            "message": ["role": "toolResult", "toolCallId": "call-\(index)", "toolName": "read",
                        "content": [], "isError": false, "timestamp": 0]])
    }
    let input = root.appendingPathComponent("session.jsonl")
    let output = root.appendingPathComponent("session.html")
    let jsonl = try records.map { record in
        String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
    }.joined(separator: "\n") + "\n"
    try jsonl.write(to: input, atomically: true, encoding: .utf8)
    _ = try exportFromFile(input.path, ExportOptions(outputPath: output.path, themeName: "dark"))
    let script = #"""
    const assert = require('node:assert/strict');
    const { runInNewContext } = require('node:vm');
    const html = require('node:fs').readFileSync(process.argv[1], 'utf8');
    const sessionData = html.match(/<script id="session-data" type="application\/json">([^<]+)<\/script>/)[1];
    const source = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].at(-1)[1];
    const marker = 'marked.use({';
    assert(source.includes(marker));
    const viewer = runInNewContext(source.replace(marker,
      'return { formatReadLineRange, getTreeNodeDisplayHtml, renderEntry }; ' + marker), {
      atob, TextDecoder, URLSearchParams,
      document: { getElementById: () => ({ textContent: sessionData }), querySelector: () => null },
      window: { location: { search: '' } }
    });
    const cases = [
      [25,13,':25-37'], ['25','13',':25-37'], [null,'13',':1-13'], ['25',null,':25'],
      [undefined,undefined,''], ['abc',13,''], [25,'',''], [25,'Infinity','']
    ];
    const { entries } = JSON.parse(Buffer.from(sessionData, 'base64').toString('utf8'));
    for (const [index, [offset,limit,range]] of cases.entries()) {
      assert.equal(viewer.formatReadLineRange(offset,limit),range);
      const assistant = entries.find(e => e.id === `assistant-${index}`);
      const result = entries.find(e => e.id === `result-${index}`);
      assert(assistant && result);
      assert.equal(viewer.getTreeNodeDisplayHtml(result),
        `<span class="tree-role-tool">[read: notes.txt${range}]</span>`);
      const rendered = viewer.renderEntry(assistant);
      if (range) assert(rendered.includes(`<span class="line-numbers">${range}</span>`),rendered);
      else assert(!rendered.includes('class="line-numbers"'),rendered);
      assert(!rendered.includes('NaN'));
    }
    for (const [offset,limit,range] of [[1,0,':1'],[-2,2,':-2--1'],[1.5,2.5,':1.5-3'],
      ['0x19','0b1101',':25-37'],[true,13,''],[25,false,''],[25,NaN,''],[Infinity,13,'']]) {
      assert.equal(viewer.formatReadLineRange(offset,limit),range);
    }
    console.log('Eight read range vectors passed in the bundled helper, tree, and HTML renderer');
    """#
    // Match ExportHtmlCurrentTemplateTests: run JavaScript with Node on the host.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", "-e", script, output.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let message = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, Comment(rawValue: message))
}
