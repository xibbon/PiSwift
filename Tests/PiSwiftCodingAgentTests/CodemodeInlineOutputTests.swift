import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func inlineOutputTool() -> AgentTool {
    AgentTool(
        label: "sample",
        name: "sample",
        description: "Read a sample.",
        parameters: ["type": AnyCodable("object"), "properties": AnyCodable(["path": ["type": "string"]]), "required": AnyCodable(["path"])],
        execute: { _, _, _, _ in
            AgentToolResult(content: [], structuredContent: AnyCodable(["result": "ok"]))
        },
        outputSchema: ["type": AnyCodable("object"), "properties": AnyCodable(["result": ["type": "string"]]), "required": AnyCodable(["result"])]
    )
}

@Test func codemodeInlineOutputOmissionIsOptIn() {
    let tool = inlineOutputTool()
    let complete = createCodemodeDescription([tool])
    let lean = createCodemodeDescription([tool], options: .init(omitInlineOutputSchemas: true))
    #expect(complete.contains("Promise<{ result: string; }>"))
    #expect(lean.contains("sample(args: { path: string; }): Promise<unknown>"))
    #expect(lean.utf16.count < complete.utf16.count)
    #expect(tool.outputSchema != nil)
}

@Test func codemodeInlineOutputOmissionRemovesOnlySharedReturnTypes() {
    var tool = inlineOutputTool()
    tool.outputSchema = ["type": AnyCodable("object"), "properties": AnyCodable([
        "content": ["type": "array", "items": ["type": "object"]],
        "isError": ["type": "boolean"], "_meta": ["type": "object"]
    ])]
    // Upstream 24382bedd removed the shared MCP preamble.
    #expect(!createCodemodeDescription([tool]).contains("Shared MCP Types"))
    let lean = createCodemodeDescription([tool], options: .init(omitInlineOutputSchemas: true))
    #expect(!lean.contains("Shared MCP Types"))
    #expect(lean.contains("path: string"))
}

@Test(.timeLimit(.minutes(1))) func codemodeInlineOutputOmissionKeepsDiscoveryAndCalls() async throws {
    let tool = inlineOutputTool()
    let calls = LockedState(0)
    var context = CustomToolContext(sessionManager: .inMemory(), modelRegistry: ModelRegistry(AuthStorage(":memory:")), model: nil,
        isIdle: { true }, hasPendingMessages: { false }, abort: {}, events: createEventBus(), sendMessage: { _, _ in })
    context.setNestedToolHost(tools: [tool]) { name, arguments, _ in
        calls.withLock { $0 += 1 }
        return AgentToolCallOutcome(toolCall: AgentToolCall(id: "nested", name: name, arguments: arguments),
            result: AgentToolResult(content: [], structuredContent: AnyCodable(["result": "ok"])), isError: false)
    }
    let result = try await executeCodemode(toolCallId: "outer", params: ["code": AnyCodable("""
        text(await describeTool('sample'));
        text(await tools.sample({path:'x'}));
        """)],
        context: context, options: .init(omitInlineOutputSchemas: true))
    let text = result.content.compactMap { block -> String? in
        if case .text(let value) = block {
            return value.text
        }
        return nil
    }.joined(separator: "\n")
    #expect(result.isError != true)
    #expect(text.contains("Promise<{ result: string; }>"))
    #expect(text.contains("ok"))
    #expect(calls.withLock { $0 } == 1)
}

@Test func codemodeInlineEnumLimitKeepsInputShape() {
    var tool = inlineOutputTool()
    tool.parameters = ["type": AnyCodable("object"), "properties": AnyCodable([
        "path": ["type": "string", "enum": ["a", "b", "c"]],
        "small": ["enum": ["x", "y"]]
    ]), "required": AnyCodable(["path"])]
    let lean = createCodemodeDescription([tool], options: .init(inlineEnumValueLimit: 2))
    #expect(lean.contains("path: string"))
    #expect(lean.contains("small?: \"x\" | \"y\""))
    #expect(renderToolSample(CodemodeDeclaration(tool: tool)).contains("path: \"a\" | \"b\" | \"c\""))
    #expect(CodemodeDescriptionOptions().inlineEnumValueLimit == nil)
    #expect(CodemodeToolOptions().inlineEnumValueLimit == nil)
    #expect(CodemodeExtensionOptions().inlineEnumValueLimit == nil)
}
