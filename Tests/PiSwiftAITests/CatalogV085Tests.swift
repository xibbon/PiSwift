import Foundation
import Testing
@testable import PiSwiftAI

@Test func catalogV085PreservesTransportAndEffortGates() throws {
    let direct = try #require(getModel(provider: "anthropic", modelId: "claude-fable-5-1"))
    let routed = try #require(getModel(provider: "openrouter", modelId: "anthropic/claude-fable-5.1"))
    #expect(direct.compat?.supportsMidConvoEffort == true)
    #expect(direct.thinkingLevelMap?[.off] != nil)
    #expect((direct.thinkingLevelMap?[.off] ?? nil) == nil)
    #expect(routed.api == .anthropicMessages)
    #expect(routed.baseUrl == "https://openrouter.ai/api")
    #expect(routed.compat?.supportsMidConvoEffort == true)
    #expect(getModel(provider: "anthropic", modelId: "claude-opus-4-8")?.compat?.supportsMidConvoEffort == nil)
    #expect(getModel(provider: "anthropic", modelId: "claude-opus-5")?.compat?.allowedFallbackModels == nil)
    let models = getProviders().flatMap { getModels(provider: $0) }
    #expect(models.filter { $0.compat?.supportsMidConvoEffort == true }.count == 4)
    let fallbacks = models.filter { $0.compat?.allowedFallbackModels?.isEmpty == false }
    #expect(fallbacks.count == 1)
    #expect(fallbacks.first?.id == "claude-fable-5")
    #expect(fallbacks.first?.compat?.allowedFallbackModels?.map(\.model) == ["claude-opus-4-8", "claude-opus-5"])
}

@Test func catalogV085ProviderCorrections() throws {
    #expect(getModel(provider: "github-copilot", modelId: "claude-fable-5")?.api == .anthropicMessages)
    let xai = getModels(provider: .xai)
    #expect(!xai.isEmpty)
    #expect(xai.allSatisfy { $0.api == .openAIResponses })
    #expect(!xai.contains { $0.id.contains("grok-build") })
    let fireworks = getModels(provider: .fireworks).filter { $0.id.lowercased().contains("glm") }
    #expect(!fireworks.isEmpty)
    #expect(fireworks.allSatisfy { $0.api == .openAICompletions })
    #expect(getModel(provider: "qwen-token-plan-individual", modelId: "qwen3.8-flash") != nil)
    let baseten = getModels(provider: .baseten).filter { $0.id.lowercased().contains("glm-5.2") }
    #expect(!baseten.isEmpty)
    #expect(baseten.allSatisfy { !$0.input.contains(.image) })
}

@Test func allSimpleOptionsForwardToolChoice() throws {
    let model = getModel(provider: .anthropic, modelId: "claude-sonnet-4-6")
    for choice in [ToolChoice.auto, .none] {
        let options = SimpleStreamOptions(toolChoice: choice)
        let context = Context(messages: [])
        if choice == .auto {
            guard case .auto? = mapAnthropicSimpleOptions(model: model, context: context, options: options, apiKey: "test").toolChoice,
                  case .auto? = mapOpenAICompletionsSimpleOptions(model: model, options: options, apiKey: "test").toolChoice,
                  case .auto? = mapOpenAIResponsesSimpleOptions(model: model, options: options, apiKey: "test").toolChoice,
                  case .auto? = mapOpenAICodexResponsesSimpleOptions(model: model, options: options, apiKey: "test").toolChoice,
                  case .auto? = mapAzureOpenAIResponsesSimpleOptions(model: model, options: options, apiKey: "test").toolChoice,
                  case .auto? = mapBedrockSimpleOptions(model: model, options: options).toolChoice else {
                Issue.record("auto was not forwarded")
                return
            }
        } else {
            guard case .none? = mapAnthropicSimpleOptions(model: model, context: context, options: options, apiKey: "test").toolChoice,
                  case .none? = mapOpenAICompletionsSimpleOptions(model: model, options: options, apiKey: "test").toolChoice,
                  case .none? = mapOpenAIResponsesSimpleOptions(model: model, options: options, apiKey: "test").toolChoice,
                  case .none? = mapOpenAICodexResponsesSimpleOptions(model: model, options: options, apiKey: "test").toolChoice,
                  case .none? = mapAzureOpenAIResponsesSimpleOptions(model: model, options: options, apiKey: "test").toolChoice,
                  case .none? = mapBedrockSimpleOptions(model: model, options: options).toolChoice else {
                Issue.record("none was not forwarded")
                return
            }
        }
        #expect(try mapGoogleSimpleOptionsValidated(model: model, options: options, apiKey: "test").toolChoice == choice.rawValue)
        #expect(try mapGoogleVertexSimpleOptionsValidated(model: model, options: options, apiKey: "test").toolChoice == choice.rawValue)
        #expect(mapMistralSimpleOptions(model: model, options: options, apiKey: "test").toolChoice?.value as? String == choice.rawValue)
    }
}
