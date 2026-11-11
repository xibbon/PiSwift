import Testing
@testable import PiSwiftAI

@Suite("v1.5.2 catalog")
struct CatalogV152Tests {
    @Test(arguments: ["gpt-5.6-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-6.1-sol", "gpt-6.1-terra"])
    func codexMaxThinkingLevel(_ id: String) {
        let model = getModel(provider: .openaiCodex, modelId: id)
        let options = mapOpenAICodexResponsesSimpleOptions(model: model,
            options: SimpleStreamOptions(reasoning: .max), apiKey: "test")
        #expect(options.reasoningEffort == .max)
    }

    @Test func azureAndCodexWindows() throws {
        #expect(try #require(getModel(provider: "azure", modelId: "gpt-6.1-sol")).contextWindow == 1_050_000)
        #expect(try #require(getModel(provider: "openai-codex", modelId: "gpt-6.1-terra")).contextWindow == 500_000)
        for provider in ["openai", "openai-codex"] {
            let model = try #require(getModel(provider: provider, modelId: "gpt-6.1-terra"))
            #expect((model.thinkingLevelMap?[.off] ?? nil) == "none")
        }
    }

    @Test func anthropicCatalogFlags() throws {
        let sonnet = try #require(getModel(provider: "anthropic", modelId: "claude-sonnet-5"))
        #expect(sonnet.compat?.supportsTemperature == false)
        let fable = try #require(getModel(provider: "anthropic", modelId: "claude-fable-5-2"))
        #expect(fable.compat?.allowedFallbackModels?.map(\.model) == ["claude-opus-5"])
    }

    @Test func openCodeProtocolAndRetention() throws {
        let model = try #require(getModel(provider: "opencode", modelId: "deepseek-v4.1-flash"))
        #expect(model.api == .openAICompletions)
        #expect(model.baseUrl == "https://opencode.ai/inference/openai/v1")
        #expect(model.compat?.supportsLongCacheRetention == false)
        let go = try #require(getModel(provider: "opencode-go", modelId: "kimi-k3.1-pro"))
        #expect(go.baseUrl == "https://opencode.ai/inference/go/openai/v1")
    }

    @Test func copilotClassifierIsCatalogued() throws {
        let model = try #require(getClassifierModel(provider: "github-copilot", modelId: "microsoft-decision-1"))
        #expect(model.api == .typesafeSystemOne)
    }
}
