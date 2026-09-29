import Foundation
import Testing
@testable import PiSwiftAI

private func a1ChatModel(id: String = "same") -> Model {
    Model(id: id, name: "Chat", api: .openAIResponses, provider: "openrouter",
          baseUrl: "https://example.test/v1", reasoning: true, input: [.text, .image],
          cost: ModelCost(input: 2, output: 4, cacheRead: 0.5, cacheWrite: 1),
          contextWindow: 8_000, maxTokens: 1_000,
          samplingParams: ["top_p": AnyCodable(0.8)],
          headers: ["X-Test": "set"], inputLimits: ModelInputLimits(maxRequestBytes: 99),
          promptCache: ModelPromptCache(short: 300, long: 3_600))
}

private func a1ImageModel(id: String = "same") -> ImageModel {
    ImageModel(id: id, name: "Image", api: .openrouterImages, provider: "openrouter",
               baseUrl: "https://example.test/v1", input: [.text, .image], output: [.image],
               cost: ModelCost(input: 3, output: 6, cacheRead: 0, cacheWrite: 0),
               inputLimits: ModelInputLimits(images: ModelImageInputLimits(maxPerRequest: 2)))
}

private func a1ClassifierModel(id: String = "same") -> ClassifierModel {
    ClassifierModel(id: id, name: "Classifier", api: .typesafeSystemOne,
                    provider: "openrouter", baseUrl: "https://example.test/v1",
                    input: [.text], cost: ModelCost(input: 7, output: 0, cacheRead: 0, cacheWrite: 0),
                    contextWindow: 32_000)
}

@Test func anyModelTypesDecodeAndRoundTrip() throws {
    let decoder = JSONDecoder()
    let chat = try decoder.decode(AnyModel.self, from: JSONEncoder().encode(a1ChatModel()))
    #expect(chat.type == .chat)

    for original in [AnyModel.image(a1ImageModel()), .classifier(a1ClassifierModel())] {
        let decoded = try decoder.decode(AnyModel.self, from: JSONEncoder().encode(original))
        #expect(decoded.type == original.type)
        #expect(decoded.id == "same")
    }

    let unknown = Data(#"{"type":"audio","id":"same"}"#.utf8)
    do {
        _ = try decoder.decode(AnyModel.self, from: unknown)
        Issue.record("Unknown model type was accepted")
    } catch let error as AnyModelCodingError {
        #expect(error == .unknownType("audio"))
    }
}

@Test func storeKeepsDistinctTypesAndDropsUnknownTypes() throws {
    let entry = ModelsStoreEntry(models: [
        .chat(a1ChatModel()), .image(a1ImageModel()), .classifier(a1ClassifierModel())
    ])
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
    var models = try #require(object["models"] as? [[String: Any]])
    models.append(["type": "future", "id": "same"])
    object["models"] = models
    let decoded = try JSONDecoder().decode(ModelsStoreEntry.self,
        from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.models.map(\.type) == [.chat, .image, .classifier])
    #expect(decoded.models.allSatisfy { $0.id == "same" })
    let merged = mergeCatalogModels(decoded.models, [.image(a1ImageModel(id: "same"))])
    #expect(merged.count == 3)
    #expect(merged.map(\.type) == [.chat, .image, .classifier])
}

@Test func catalogOperationsUseModelTypeAndSharedCost() {
    let chat = AnyModel.chat(a1ChatModel())
    let image = AnyModel.image(a1ImageModel())
    let classifier = AnyModel.classifier(a1ClassifierModel())
    #expect(!modelsAreEqual(chat, image))
    #expect(!modelsAreEqual(image, classifier))
    #expect(modelsAreEqual(chat, .chat(a1ChatModel())))
    #expect(hasApi(image, api: ImageApi.openrouterImages.rawValue))
    #expect(hasApi(classifier, api: ClassifierApi.typesafeSystemOne.rawValue))
    var usage = Usage(input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 1_000_000)
    #expect(calculateCost(model: a1ImageModel(), usage: &usage).input == 3)
    #expect(calculateCost(model: a1ClassifierModel(), usage: &usage).input == 7)
    #expect(getModelOfType(.image, provider: "openrouter", modelId: "google/gemini-3-pro-image")?.type == .image)
    #expect(getAllBuiltinModels(provider: "openrouter").contains { $0.type == .image })
    #expect(getBuiltinProviders().contains(.typesafe))
}

@Test func assistantThinkingAndNestedCallsJSONRoundTrip() throws {
    let assistant = AssistantMessage(content: [], api: .openAIResponses, provider: "openai",
        model: "gpt-test", usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .stop, thinkingLevel: .off)
    let encoded = assistantMessageToJSONObject(assistant)
    #expect(encoded["thinkingLevel"] as? String == "off")
    #expect(assistantMessageFromJSONObject(encoded).thinkingLevel == .off)

    let nested = NestedToolCalls(calls: [
        NestedToolCallRecord(id: "inner", name: "read", arguments: ["path": AnyCodable("a")],
                             status: .ok, durationMs: 12.5),
        NestedToolCallRecord(id: "large", name: "write", argumentsBytes: 2048,
                             status: .unfinished)
    ], complete: false)
    let restored = try #require(nestedToolCallsFromJSONObject(nestedToolCallsToJSONObject(nested)))
    #expect(restored.calls.count == 2)
    #expect(restored.calls[0].arguments?["path"] == AnyCodable("a"))
    #expect(restored.calls[1].argumentsBytes == 2048)
    #expect(!restored.complete)
}

@Test func cloudflareModelCopyKeepsEveryOptionalField() {
    let model = Model(id: "m", name: "m", api: .openAIResponses, provider: "cloudflare-workers-ai",
        baseUrl: "https://example.test/{CLOUDFLARE_ACCOUNT_ID}", reasoning: true, input: [.text],
        cost: ModelCost(input: 1, output: 2, cacheRead: 0, cacheWrite: 0),
        contextWindow: 1_000, maxTokens: 100, samplingParams: ["top_p": AnyCodable(0.8)],
        inputLimits: ModelInputLimits(maxRequestBytes: 123), promptCache: ModelPromptCache(short: 60))
    let resolved = resolveCloudflareModel(model, env: ["CLOUDFLARE_ACCOUNT_ID": "account"])
    #expect(resolved.baseUrl == "https://example.test/account")
    #expect(resolved.samplingParams == model.samplingParams)
    #expect(resolved.inputLimits == model.inputLimits)
    #expect(resolved.promptCache == model.promptCache)
}

@Test func missingImageProviderReturnsErrorResult() async {
    ensureBuiltInImageProviders()
    unregisterImageApiProviders(sourceId: "built-in")
    defer { registerBuiltInImageApiProviders() }
    let result = await generateImages(model: a1ImageModel(), context: ImagesContext(input: []),
                                      options: ImagesOptions(apiKey: "explicit"))
    #expect(result.stopReason == .error)
    #expect(result.output.isEmpty)
    #expect(result.provider == "openrouter")
    #expect(result.model == "same")
    #expect(result.errorMessage?.contains("No API provider") == true)
}
