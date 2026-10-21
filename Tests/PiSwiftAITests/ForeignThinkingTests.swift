import Testing
@testable import PiSwiftAI

struct ForeignThinkingTests {
    private let model = getModel(provider: .openai, modelId: "gpt-4o-mini")

    private func message(_ blocks: [ContentBlock], modelID: String? = nil, provider: String? = nil, api: Api? = nil) -> AssistantMessage {
        AssistantMessage(content: blocks, api: api ?? model.api, provider: provider ?? model.provider,
                         model: modelID ?? model.id, usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
    }

    @Test func foreignReadableThinkingDoesNotBecomeText() throws {
        let call = ToolCall(id: "call", name: "bash", arguments: ["command": AnyCodable("curl -v")])
        let input = message([.thinking(ThinkingContent(thinking: "Check proxy, IPv6, TLS.", thinkingSignature: "reasoning_content")),
                             .text(TextContent(text: "Let me check the TLS versions.")), .toolCall(call)], modelID: "other")
        let result = transformMessages([.assistant(input)], model: model)
        guard case .assistant(let output) = result.first else { Issue.record("Missing assistant"); return }
        #expect(output.content.count == 2)
        guard case .text(let text) = output.content.first, case .toolCall(let tool) = output.content.last else {
            Issue.record("Expected text and tool call"); return
        }
        #expect(text.text == "Let me check the TLS versions.")
        #expect(tool.id == call.id)
        #expect(tool.arguments == call.arguments)
    }

    @Test func alternatingModelsKeepOnlyTargetThinking() {
        let input: [Message] = (0..<4).map { index in
            .assistant(message([.thinking(ThinkingContent(thinking: "thinking \(index)", thinkingSignature: "signed")),
                                .text(TextContent(text: "reply \(index)"))], modelID: index.isMultiple(of: 2) ? nil : "other"))
        }
        let output = transformMessages(input, model: model)
        let thinkingCounts = output.compactMap { message -> Int? in
            guard case .assistant(let assistant) = message else { return nil }
            return assistant.content.filter { if case .thinking = $0 { true } else { false } }.count
        }
        #expect(thinkingCounts == [1, 0, 1, 0])
    }

    @Test func eachModelIdentityFieldControlsThinking() {
        let content: [ContentBlock] = [.thinking(ThinkingContent(thinking: "private", thinkingSignature: "signed")),
                                       .thinking(ThinkingContent(thinking: "", thinkingSignature: "encrypted", redacted: true))]
        for input in [message(content, modelID: "other"), message(content, provider: "other"), message(content, api: .anthropicMessages)] {
            guard case .assistant(let output) = transformMessages([.assistant(input)], model: model).first else {
                Issue.record("Missing assistant"); continue
            }
            #expect(output.content.isEmpty)
        }
    }

    @Test func sameModelPreservesSignedAndRedactedButDropsUnsignedWhitespace() {
        let input = message([
            .thinking(ThinkingContent(thinking: "")),
            .thinking(ThinkingContent(thinking: " \n\t", thinkingSignature: "")),
            .thinking(ThinkingContent(thinking: "", thinkingSignature: "signed")),
            .thinking(ThinkingContent(thinking: "", redacted: true)),
            .thinking(ThinkingContent(thinking: "readable")),
            .thinking(ThinkingContent(thinking: "\u{FEFF}")),
            .thinking(ThinkingContent(thinking: "\u{85}")),
        ])
        guard case .assistant(let output) = transformMessages([.assistant(input)], model: model).first else {
            Issue.record("Missing assistant"); return
        }
        #expect(output.content.count == 4)
        #expect(output.content.map(contentBlockToJSONObject).compactMap { $0["thinking"] as? String } == ["", "", "readable", "\u{85}"])
    }
}
