import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

// Upstream v1.3.0 codemode/test/source.test.ts:33-51.
@Test(arguments: [
    ("// count things\n// @options: {\"timeout_ms\": 1000}\nwhile (true) {}", 2),
    ("\n  // @options: {\"timeout_ms\": 1000}\nwhile (true) {}", 2),
    ("text(1)\r\n// @options: {\"timeout_ms\": 1}", 2),
    ("// @options: {\"timeout_ms\": 1}\ntext(1)\n// @options: {\"timeout_ms\": 2}", 3),
]) func codemodeCM1RejectsMisplacedOptions(input: String, line: Int) {
    #expect(throws: CodemodeSourceError("The // @options: line must be the first line of the input; found one on line \(line)")) {
        try parseCodemodeSource(input)
    }
}

@Test func codemodeCM1KeepsOptionsLineNumbersAndStringLiterals() throws {
    let parsed = try parseCodemodeSource("// @options: {\"timeout_ms\": 10}\nconst a = 1;\ntext(a)")
    #expect(parsed.code == "\nconst a = 1;\ntext(a)")
    #expect(parsed.options == .init(timeoutMs: 10))
    let literal = "text(\"// @options: {}\")"
    #expect(try parseCodemodeSource(literal) == .init(code: literal, options: .init()))
    #expect(try parseCodemodeSource("// @optionsx {}\ntext(1)").options == .init())
}

// Upstream v1.3.0 agent-session-codemode.test.ts:499-508; use the agent-loop tool boundary.
@Test(.timeLimit(.minutes(1))) func codemodeCM1MisplacedOptionsReturnOneErrorBlock() async throws {
    let tool = createCodemodeTool()
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let assistant = AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse)
    let outcome = await runToolCall(AgentToolCall(id: "cm1-source", name: "codemode",
        arguments: ["code": AnyCodable("// count\n// @options: {\"timeout_ms\": 200}\nwhile (true) {}")]),
        options: RunToolCallOptions(tools: [tool], assistantMessage: assistant,
            context: AgentContext(messages: [], tools: [tool])))
    #expect(outcome.isError)
    try #require(outcome.result.content.count == 1)
    guard case .text(let block) = outcome.result.content[0] else {
        Issue.record("Expected one text error block")
        return
    }
    #expect(block.text == "The // @options: line must be the first line of the input; found one on line 2")
}

@Test(.timeLimit(.minutes(1)), arguments: [
    ("image(undefined)", #"image expects a non-empty image URL string, an object with image_url, or an image block { type: "image", data, mimeType }"#),
    ("image(null)", #"image expects a non-empty image URL string, an object with image_url, or an image block { type: "image", data, mimeType }"#),
    ("image([])", #"image expects a non-empty image URL string, an object with image_url, or an image block { type: "image", data, mimeType }"#),
    ("image({image_url:1})", #"image expects a non-empty image URL string, an object with image_url, or an image block { type: "image", data, mimeType }"#),
    ("image({})", #"image expects a non-empty image URL string, an object with image_url, or an image block { type: "image", data, mimeType }"#),
    ("image('')", #"image expects a non-empty image URL string, an object with image_url, or an image block { type: "image", data, mimeType }"#),
    ("image({type:'text',text:'hello'})", #"image only accepts image blocks, got "text""#),
    ("image({type:'image'})", "image expected image block data"),
    ("image({type:'image',data:''})", "image expected image block data"),
]) func codemodeCM1ImageErrorsUseGenericBlockNames(script: String, expected: String) async {
    let result = await CodemodeSandbox.execute(code: script, tools: [],
        onCall: { _ in .init(ok: false, payloadJSON: "unexpected call") })
    #expect(result.execution.failure?.name == "TypeError")
    #expect(result.execution.failure?.message == expected)
    #expect(result.execution.output.isEmpty)
}
