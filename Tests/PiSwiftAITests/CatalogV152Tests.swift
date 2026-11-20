import Testing
@testable import PiSwiftAI

@Suite("v1.5.2 catalog")
struct CatalogV152Tests {
    @Test(arguments: ["gpt-5.6-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6.2-astra", "gpt-6.2-sol"])
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

    // supports-xhigh.test.ts:96-113,144-175; max-thinking.test.ts:88-106.
    @Test("does not support off for GPT-6.2", arguments: ["gpt-6.2-astra", "gpt-6.2-sol"])
    func gpt62ThinkingLevels(_ id: String) throws {
        for provider in ["openai", "azure", "openai-codex", "github-copilot"] {
            let model = try #require(getModel(provider: provider, modelId: id))
            #expect((model.thinkingLevelMap?[.off] ?? "unexpected") == nil)
            if provider == "openai-codex" {
                #expect(getSupportedThinkingLevels(model) == [.minimal, .low, .medium, .high, .xhigh, .max])
                #expect(model.thinkingLevelMap?[.minimal] == "low")
            } else {
                #expect(getSupportedThinkingLevels(model) == [.low, .medium, .high, .xhigh, .max])
                #expect((model.thinkingLevelMap?[.minimal] ?? "unexpected") == nil)
            }
        }
    }

    @Test("includes official metadata for OpenAI and Codex GPT-6.2", arguments: [
        ("gpt-6.2-astra", 8.0, 40.0, 0.4, 10.0, 272_000),
        ("gpt-6.2-sol", 2.0, 10.0, 0.1, 2.5, 500_000),
    ])
    func gpt62OfficialMetadata(_ id: String, _ input: Double, _ output: Double,
                               _ cacheRead: Double, _ cacheWrite: Double, _ codexWindow: Int) throws {
        for provider in ["openai", "openai-codex"] {
            let model = try #require(getModel(provider: provider, modelId: id))
            #expect(model.input == [.text, .image])
            #expect(model.cost.input == input)
            #expect(model.cost.output == output)
            #expect(model.cost.cacheRead == cacheRead)
            #expect(model.cost.cacheWrite == cacheWrite)
            let tier = try #require(model.cost.tiers?.first)
            #expect(tier.inputTokensAbove == 272_000)
            #expect(tier.input == input * 2)
            #expect(tier.output == output * 1.5)
            #expect(tier.cacheRead == cacheRead * 2)
            #expect(tier.cacheWrite == cacheWrite * 2)
            #expect(model.contextWindow == (provider == "openai" ? 272_000 : codexWindow))
            #expect(model.maxTokens == 128_000)
            #expect(model.compat?.supportsAdditionalTools == true)
            #expect(model.compat?.supportsToolSearch == true)
            #expect(model.compat?.supportsMidConvoEffort == true)
        }
    }

    @Test("uses the Azure Foundry 1.05M context window for GPT-6.2", arguments: ["gpt-6.2-astra", "gpt-6.2-sol"])
    func gpt62AzureWindow(_ id: String) throws {
        #expect(try #require(getModel(provider: "azure", modelId: id)).contextWindow == 1_050_000)
    }

    @Test("Copilot Claude supports strict tools", arguments: ["claude-fable-5", "claude-sonnet-4.6"])
    func copilotClaudeStrictTools(_ id: String) throws {
        let model = try #require(getModel(provider: "github-copilot", modelId: id))
        #expect(model.compat?.supportsStrictTools == true)
    }

    // together-models.test.ts: registers the default Kimi K3 model via OpenAI-compatible Chat Completions API.
    @Test func togetherKimiK3Catalog() throws {
        let model = try #require(getModel(provider: "together", modelId: "moonshotai/Kimi-K3"))
        #expect(model.api == .openAICompletions)
        #expect(model.baseUrl == "https://api.together.ai/v1")
        #expect(model.contextWindow == 1_048_576)
        #expect(model.maxTokens == 1_048_576)
        #expect(model.cost == ModelCost(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 0))
        #expect(model.compat?.supportsDeveloperRole == nil)
    }
}
