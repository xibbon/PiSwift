import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

private func c3MergeChat(_ id: String, _ name: String, provider: String = "c3-catalog") -> Model {
    Model(id: id, name: name, api: .openAICompletions, provider: provider,
        baseUrl: "https://catalog.invalid", reasoning: false, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 1000, maxTokens: 100)
}

private func c3MergeImage(_ id: String, _ name: String, provider: String = "c3-catalog") -> AnyModel {
    .image(ImageModel(id: id, name: name, api: .openrouterImages, provider: provider,
        baseUrl: "https://catalog.invalid", input: [.text], output: [.image],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)))
}

private func c3MergeClassifier(_ id: String, _ name: String) -> AnyModel {
    .classifier(ClassifierModel(id: id, name: name, api: .typesafeSystemOne, provider: "c3-catalog",
        baseUrl: "https://catalog.invalid", input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 1000))
}

// Port remote-catalog-provider.ts mergeModels at v1.0.0. The Map replaces duplicate
// baseline entries too. The last value keeps the position of the first occurrence.
@Test func c3RemoteCatalogChatMergeKeepsFirstPositionAndLastValue() {
    let catalog = RemoteCatalogProvider(providerId: "c3-catalog", updateOverlay: { _ in })
    let merged = catalog.mergeModels(baseline: [
        c3MergeChat("first", "First baseline"), c3MergeChat("second", "Second baseline"),
        c3MergeChat("first", "Duplicate baseline"),
    ], dynamic: [
        c3MergeChat("second", "Second dynamic"), c3MergeChat("third", "Third dynamic"),
        c3MergeChat("first", "First dynamic"), c3MergeChat("third", "Last third dynamic"),
    ])
    #expect(merged.map(\.id) == ["first", "second", "third"])
    #expect(merged.map(\.name) == ["First dynamic", "Second dynamic", "Last third dynamic"])
}

@Test func c3RemoteCatalogTypedMergeKeysByTypeAndId() {
    let catalog = RemoteCatalogProvider(providerId: "c3-catalog", updateOverlay: { _ in })
    let baseline: [AnyModel] = [
        .chat(c3MergeChat("same", "Chat baseline")), c3MergeImage("same", "Image baseline"),
        c3MergeClassifier("same", "Classifier baseline"), c3MergeImage("same", "Duplicate image baseline"),
        .chat(c3MergeChat("image\0same", "NUL chat id")),
    ]
    let dynamic: [AnyModel] = [
        c3MergeClassifier("same", "Classifier dynamic"), c3MergeImage("same", "Image dynamic"),
        .chat(c3MergeChat("same", "Chat dynamic", provider: "replacement-provider")),
        c3MergeImage("new", "New image"), c3MergeImage("new", "Last new image"),
    ]
    let merged = catalog.mergeModels(baseline: baseline, dynamic: dynamic)
    #expect(merged.map(\.type) == [.chat, .image, .classifier, .chat, .image])
    #expect(merged.map(\.id) == ["same", "same", "same", "image\0same", "new"])
    #expect(merged.map { $0.catalog.name } == ["Chat dynamic", "Image dynamic", "Classifier dynamic", "NUL chat id", "Last new image"])
    // Upstream has no provider in the key. A later provider replaces the same type/id.
    #expect(merged.first?.provider == "replacement-provider")
}

@Test func c3RemoteCatalogMergeHandlesEmptyAndBaselineOnlyInputs() {
    let catalog = RemoteCatalogProvider(providerId: "c3-catalog", updateOverlay: { _ in })
    let chatEmpty = catalog.mergeModels(baseline: [Model](), dynamic: [Model]())
    let typedEmpty = catalog.mergeModels(baseline: [AnyModel](), dynamic: [AnyModel]())
    #expect(chatEmpty.isEmpty)
    #expect(typedEmpty.isEmpty)
    let baseline = [c3MergeChat("a", "First"), c3MergeChat("b", "Second"), c3MergeChat("a", "Last")]
    #expect(catalog.mergeModels(baseline: baseline, dynamic: []).map(\.name) == ["Last", "Second"])
    #expect(catalog.mergeModels(baseline: [], dynamic: baseline).map(\.name) == ["Last", "Second"])
    let typed: [AnyModel] = [c3MergeImage("a", "First"), c3MergeClassifier("b", "Second"), c3MergeImage("a", "Last")]
    #expect(catalog.mergeModels(baseline: typed, dynamic: []).map { $0.catalog.name } == ["Last", "Second"])
    #expect(catalog.mergeModels(baseline: [], dynamic: typed).map { $0.catalog.name } == ["Last", "Second"])
}
