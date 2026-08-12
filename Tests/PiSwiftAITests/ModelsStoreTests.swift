import Foundation
import Testing
@testable import PiSwiftAI

private func storeTestModel(id: String = "dynamic-model") -> Model {
    Model(
        id: id,
        name: "Dynamic Model",
        api: .openAIResponses,
        provider: "openai",
        baseUrl: "https://example.invalid/v1",
        reasoning: true,
        input: [.text, .image],
        cost: ModelCost(input: 1, output: 2, cacheRead: 0.1, cacheWrite: 0.2),
        contextWindow: 128_000,
        maxTokens: 16_384,
        samplingParams: ["top_p": AnyCodable(0.8)],
        headers: ["x-test": "yes"],
        compat: OpenAICompat(supportsStrictMode: true),
        thinkingLevelMap: [.off: nil, .high: "high"]
    )
}

@Test func modelsStoreEntryCodableRoundTrip() throws {
    let entry = ModelsStoreEntry(
        models: [storeTestModel()],
        lastModified: 1_800_000_000_000,
        checkedAt: 1_800_000_001_000,
        etag: "\"catalog-v1\""
    )
    let decoded = try JSONDecoder().decode(
        ModelsStoreEntry.self,
        from: JSONEncoder().encode(entry)
    )

    #expect(decoded.models.count == 1)
    #expect(decoded.models[0].id == "dynamic-model")
    #expect(decoded.models[0].samplingParams?["top_p"] == AnyCodable(0.8))
    #expect(decoded.models[0].thinkingLevelMap?[.off] == .some(nil))
    #expect(decoded.lastModified == entry.lastModified)
    #expect(decoded.checkedAt == entry.checkedAt)
    #expect(decoded.etag == "\"catalog-v1\"")
}

@Test func inMemoryModelsStoreRoundTripAndCancellation() async throws {
    let store = InMemoryModelsStore()
    let entry = ModelsStoreEntry(models: [storeTestModel()], etag: "etag")
    try await store.write(providerId: "openai", entry: entry, signal: nil)
    let restored = try #require(try await store.read(providerId: "openai", signal: nil))
    #expect(restored.models.first?.id == "dynamic-model")

    let cancelled = CancellationToken()
    cancelled.cancel()
    await #expect(throws: (any Error).self) {
        try await store.write(
            providerId: "openai",
            entry: ModelsStoreEntry(models: [storeTestModel(id: "must-not-commit")]),
            signal: cancelled
        )
    }
    let unchanged = try #require(try await store.read(providerId: "openai", signal: nil))
    #expect(unchanged.models.first?.id == "dynamic-model")

    await #expect(throws: (any Error).self) {
        try await store.read(providerId: "openai", signal: cancelled)
    }
    await #expect(throws: (any Error).self) {
        try await store.delete(providerId: "openai", signal: cancelled)
    }
}

@Test func builtinModelTimestampAccessorUsesUnixMilliseconds() {
    let timestamp = getBuiltinModelDataGeneratedAt()
    #expect(timestamp != nil)
    #expect((timestamp ?? 0) > 1_000_000_000_000)
}
