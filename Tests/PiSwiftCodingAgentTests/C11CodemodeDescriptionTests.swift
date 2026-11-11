import Foundation
import PiSwiftAI
import PiSwiftAgent
import Testing
@testable import PiSwiftCodingAgent
@testable import PiSwiftCodemodeRuntime

private func c11Description(_ name: String, schema: [String: Any], description: String = "Get a result.") -> String {
    let tool = AgentTool(label: name, name: name, description: description, parameters: [:],
        execute: { _, _, _, _ in AgentToolResult(content: []) },
        outputSchema: schema.mapValues(AnyCodable.init))
    let loadout = ToolLoadout(declared: [tool], callable: [tool], registered: [tool],
        getExposure: { _ in .direct }, getNamespace: { _ in nil })
    return prepareCodemodeLoadout(loadout).descriptions?[name] ?? ""
}

// v1.5.2 C-CM: coding-agent/test/suite/agent-session-codemode.test.ts:191.
@Test("summarizes union and multi-line output types instead of inlining them")
func c11UpstreamUnionAndMultilineDescriptionCases() {
    let process: [String: Any] = ["anyOf": [
        ["type": "object", "properties": ["action": ["const": "start"],
                                             "process": ["type": "object", "properties": ["id": ["type": "string"], "pid": ["type": "integer"]]]],
         "required": ["action", "process"]],
        ["type": "object", "properties": ["action": ["const": "list"],
                                             "processes": ["type": "array", "items": ["type": "object", "properties": ["id": ["type": "string"]]]],
                                             "truncated": ["type": "boolean"]],
         "required": ["action", "processes"]]
    ]]
    #expect(c11Description("process", schema: process, description: "process tool") ==
        "process tool\n\nCodemode: `tools.process(args)` resolves to `{ action: \"start\", process } | { action: \"list\", processes, truncated? }`.")
    let entries: [String: Any] = ["type": "array", "items": ["type": "object", "properties":
        ["id": ["type": "string"], "size": ["type": "integer"]]]]
    #expect(c11Description("entries", schema: entries, description: "entries tool") ==
        "entries tool\n\nCodemode: `tools.entries(args)` resolves to a value; `await describeTool(\"entries\")` shows its type.")
    #expect(c11Description("count", schema: ["type": "number"], description: "count tool") ==
        "count tool\n\nCodemode: `tools.count(args)` resolves to `number`.")
}

// v1.5.2 C-CM: coding-agent/test/suite/agent-session-codemode.test.ts:233.
@Test("summarizes output fields behind local schema references")
func c11UpstreamReferencedDescriptionCases() {
    let report: [String: Any] = ["$ref": "#/$defs/Report", "$defs": [
        "Report": ["type": "object", "properties": ["kind": ["$ref": "#/$defs/Kind"],
                                                  "summary": ["$ref": "#/$defs/Summary"]], "required": ["kind", "summary"]],
        "Kind": ["const": "ledger"],
        "Summary": ["type": "object", "properties": ["total": ["type": "number"]], "required": ["total"]]
    ]]
    #expect(c11Description("report", schema: report, description: "report tool") ==
        "report tool\n\nCodemode: `tools.report(args)` resolves to `{ kind: \"ledger\", summary: { total } }`.")
    let result: [String: Any] = ["anyOf": [["$ref": "#/$defs/Ok"], ["$ref": "#/$defs/Failed"]], "$defs": [
        "Ok": ["type": "object", "properties": ["value": ["type": "string"]], "required": ["value"]],
        "Failed": ["type": "object", "properties": ["error": ["type": "string"]], "required": ["error"]]
    ]]
    #expect(c11Description("result", schema: result, description: "result tool") ==
        "result tool\n\nCodemode: `tools.result(args)` resolves to `{ value } | { error }`.")
}

@Test func c11CodemodeDescribesReferencedFieldsAndConstants() {
    let schema: [String: Any] = [
        "$ref": "#/$defs/result",
        "$defs": ["result": ["type": "object", "properties": [
            "action": ["$ref": "#/$defs/action"],
            "payload": ["$ref": "#/$defs/payload"],
        ], "required": ["action", "payload"]],
                  "action": ["const": "start"],
                  "payload": ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]]],
    ]
    #expect(c11Description("begin", schema: schema) ==
        "Get a result.\n\nCodemode: `tools.begin(args)` resolves to `{ action: \"start\", payload: { id } }`.")
}

@Test func c11CodemodeDescribesObjectUnionVariants() {
    let schema: [String: Any] = [
        "oneOf": [
            ["type": "object", "properties": ["action": ["const": "start"], "id": ["type": "string"]], "required": ["action", "id"]],
            ["type": "object", "properties": ["action": ["const": "stop"], "reason": ["type": "string"]], "required": ["action"]],
        ]
    ]
    #expect(c11Description("dispatch", schema: schema) ==
        "Get a result.\n\nCodemode: `tools.dispatch(args)` resolves to `{ action: \"start\", id } | { action: \"stop\", reason? }`.")
}

@Test func c11CodemodePointsToMultilineTypes() {
    let schema: [String: Any] = ["type": "array", "items": ["type": "object", "properties": [
        "result": ["type": "string", "description": "A result field"]]]]
    #expect(c11Description("large", schema: schema) ==
        "Get a result.\n\nCodemode: `tools.large(args)` resolves to a value; `await describeTool(\"large\")` shows its type.")
}

@Test func c11CodemodePreviewDoesNotSplitSurrogatePairs() {
    #expect(CodemodeNestedCall.preview("abcd😀xyz", limit: 8) == "abcd...")
    let result = formatCodemodeResult(
        CodemodeExecutionResult(output: [.text("abcdefg😀MID😀uvwxyzq", console: false)]),
        wallTimeSeconds: 0, maxOutputTokens: 4)
    let text = result.content.compactMap { block -> String? in
        if case .text(let value) = block { return value.text }
        return nil
    }.joined(separator: "\n")
    #expect(text.contains("abcdefg…"))
    #expect(text.contains("…uvwxyzq"))
    #expect(!text.contains("\u{FFFD}"))
}
