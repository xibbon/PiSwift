import Testing
import PiSwiftAI

private func a0EstimateAssistant(timestamp: Int64, totalTokens: Int) -> AssistantMessage {
    AssistantMessage(content: [.text(TextContent(text: "kept"))], api: .openAIResponses,
                     provider: "openai", model: "test-model",
                     usage: Usage(input: totalTokens, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: totalTokens),
                     stopReason: .stop, timestamp: timestamp)
}

@Suite struct A0EstimateTests {
    // Upstream context-estimate.test.ts: all four result fields.
    @Test func reservesThreePointFiveCharactersPerToken() {
        let context = normalizeContext(Context(messages: [
            .assistant(a0EstimateAssistant(timestamp: 100, totalTokens: 2_000)),
            .user(UserMessage(content: .text(String(repeating: "x", count: 3_500)), timestamp: 200)),
        ]))
        #expect(estimateContextTokens(context) == ContextUsageEstimate(
            tokens: 3_000, usageTokens: 2_000, trailingTokens: 1_000, lastUsageIndex: 0))
        #expect(estimateContextTokens(context.messages) == estimateContextTokens(context))
    }

    @Test func ignoresStaleUsageAfterInsertedMessage() {
        let context = normalizeContext(Context(systemPrompt: "system", messages: [
            .user(UserMessage(content: .text("summary"), timestamp: 200)),
            .assistant(a0EstimateAssistant(timestamp: 100, totalTokens: 9_500)),
            .user(UserMessage(content: .text(String(repeating: "x", count: 4_000)), timestamp: 300)),
        ]))
        #expect(estimateContextTokens(context) == ContextUsageEstimate(
            tokens: 1_149, usageTokens: 0, trailingTokens: 1_149, lastUsageIndex: nil))
    }

    @Test func usesUsageAfterResponseToInsertedContext() {
        let context = normalizeContext(Context(messages: [
            .user(UserMessage(content: .text("summary"), timestamp: 200)),
            .assistant(a0EstimateAssistant(timestamp: 100, totalTokens: 9_500)),
            .user(UserMessage(content: .text("new prompt"), timestamp: 300)),
            .assistant(a0EstimateAssistant(timestamp: 400, totalTokens: 2_000)),
            .user(UserMessage(content: .text("tail"), timestamp: 500)),
        ]))
        #expect(estimateContextTokens(context) == ContextUsageEstimate(
            tokens: 2_002, usageTokens: 2_000, trailingTokens: 2, lastUsageIndex: 3))
    }

    @Test func textUsesUTF16LengthAndRoundsUp() {
        #expect(estimateTextTokens("") == 0)
        #expect(estimateTextTokens("x") == 1)
        #expect(estimateTextTokens("1234567") == 2)
        #expect(estimateTextTokens("12345678") == 3)
        #expect(estimateTextTokens("😀") == 1)
        #expect(estimateTextTokens("😀😀") == 2)
        #expect(estimateTextAndImageContentTokens("12345678") == 3)
    }

    @Test func textAndImageHelperCountsOnlyTextAndImages() {
        let content: [ContentBlock] = [
            .text(TextContent(text: "abc")),
            .image(ImageContent(data: "abcd", mimeType: "image/png")),
            .thinking(ThinkingContent(thinking: "ignored")),
            .toolCall(ToolCall(id: "1", name: "ignored", arguments: [:])),
        ]
        #expect(estimateTextAndImageContentTokens(content) == 1_373)
        #expect(estimateTextAndImageContentTokens([]) == 0)
    }

    @Test func estimatesEachRole() {
        #expect(estimateMessageTokens(.user(UserMessage(content: .text("12345678")))) == 3)
        let blocks: [ContentBlock] = [.text(TextContent(text: "abc")),
                                     .image(ImageContent(data: "abcd", mimeType: "image/png"))]
        #expect(estimateMessageTokens(.user(UserMessage(content: .blocks(blocks)))) == 1_373)

        var assistant = a0EstimateAssistant(timestamp: 0, totalTokens: 0)
        assistant.content = [.text(TextContent(text: "abc")), .thinking(ThinkingContent(thinking: "def")),
                             .toolCall(ToolCall(id: "1", name: "g", arguments: [:]))]
        #expect(estimateMessageTokens(.assistant(assistant)) == 3) // ceil((3 + 3 + 1 + 2) / 3.5)
        #expect(estimateMessageTokens(.toolResult(ToolResultMessage(
            toolCallId: "1", toolName: "ignored", content: blocks, isError: false))) == 1_373)

        let system = SystemMessage(content: .text("abc"),
                                   toolsAdded: [AITool(name: "search", description: "Find", parameters: [:])],
                                   toolsRemoved: [ToolReference(name: "old")], timestamp: 0)
        #expect(estimateMessageTokens(.system(system)) == 22) // text 1 + toolsAdded 16 + toolsRemoved 5
        #expect(estimateMessageTokens(.system(SystemMessage(content: .text(""), toolsAdded: [], toolsRemoved: []))) == 0)
    }

    @Test func usesNonzeroUsageTotalsAndFallsBackForZero() {
        var usage = Usage(input: 10, output: 20, cacheRead: 30, cacheWrite: 40, totalTokens: 55)
        #expect(calculateContextTokens(usage) == 55)
        usage.totalTokens = 0
        #expect(calculateContextTokens(usage) == 100)
        usage.totalTokens = -1
        #expect(calculateContextTokens(usage) == -1)
    }

    @Test func preservesExistingSwiftBlockAndNegativeUsageEstimates() {
        let extraBlocks: [ContentBlock] = [.thinking(ThinkingContent(thinking: "abcd")),
                                          .toolCall(ToolCall(id: "1", name: "g", arguments: [:]))]
        #expect(estimateMessageTokens(.user(UserMessage(content: .blocks(extraBlocks)))) == 2)
        #expect(estimateMessageTokens(.toolResult(ToolResultMessage(
            toolCallId: "1", toolName: "ignored", content: extraBlocks, isError: false))) == 2)
        var assistant = a0EstimateAssistant(timestamp: 0, totalTokens: 0)
        assistant.content = [.image(ImageContent(data: "abcd", mimeType: "image/png"))]
        #expect(estimateMessageTokens(.assistant(assistant)) == 1_372)
        assistant.usage = Usage(input: 10, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: -1)
        #expect(estimateContextTokens([.assistant(assistant)]) == ContextUsageEstimate(
            tokens: 10, usageTokens: 10, trailingTokens: 0, lastUsageIndex: 0))
    }
}
