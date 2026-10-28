import Foundation
import Testing
import PiSwiftAI
import PiSwiftCodingAgent

private struct UpstreamDefaultModelsFixture: Decodable {
    let tag: String
    let source: String
    let entries: [[String]]
}

private let unsupportedDefaultModelProviders: Set<String> = [
    // Radius is deferred. Swift has no Radius provider (upstream 9767ba275).
    "radius",
]

private func upstreamDefaultModelsFixture() throws -> UpstreamDefaultModelsFixture {
    let url = try #require(Bundle.module.url(
        forResource: "upstream-default-models", withExtension: "json", subdirectory: "fixtures"
    ))
    let fixture = try JSONDecoder().decode(UpstreamDefaultModelsFixture.self, from: Data(contentsOf: url))
    try #require(!fixture.tag.isEmpty)
    try #require(fixture.source == "packages/coding-agent/src/core/model-resolver.ts")
    try #require(!fixture.entries.isEmpty)
    try #require(fixture.entries.allSatisfy { $0.count == 2 && $0.allSatisfy { !$0.isEmpty } })
    try #require(Set(fixture.entries.map { $0[0] }).count == fixture.entries.count)
    return fixture
}

private func swiftDefaultModelEntries() -> [[String]] {
    defaultModelPerProvider.map { [$0.0.rawValue, $0.1] }
}

private func defaultModelDifference(expected: [[String]], actual: [[String]]) -> String {
    let expectedProviders = Set(expected.map { $0[0] })
    let actualProviders = Set(actual.map { $0[0] })
    let missing = expected.filter { !actualProviders.contains($0[0]) }
    let extra = actual.filter { !expectedProviders.contains($0[0]) }
    let changed = expected.compactMap { entry -> String? in
        guard let model = actual.first(where: { $0[0] == entry[0] })?[1], model != entry[1] else { return nil }
        return "\(entry[0]): expected \(entry[1]), got \(model)"
    }
    return """
        Missing: \(missing)
        Extra: \(extra)
        Changed: \(changed)
        Expected order: \(expected.map { $0[0] })
        Actual order: \(actual.map { $0[0] })
        """
}

@Test func defaultModelsMatchUpstreamFixtureInOrder() throws {
    let fixture = try upstreamDefaultModelsFixture()
    let expected = fixture.entries.filter { !unsupportedDefaultModelProviders.contains($0[0]) }
    let actual = swiftDefaultModelEntries()
    #expect(actual == expected, "Defaults differ from \(fixture.tag).\n\(defaultModelDifference(expected: expected, actual: actual))")
}

@Test func defaultModelProviderAllowlistHasNoStaleEntries() throws {
    let fixture = try upstreamDefaultModelsFixture()
    let upstreamProviders = Set(fixture.entries.map { $0[0] })
    let swiftProviders = Set(swiftDefaultModelEntries().map { $0[0] })
    for provider in unsupportedDefaultModelProviders.sorted() {
        #expect(upstreamProviders.contains(provider), "Remove stale allowlist entry: \(provider) is absent from \(fixture.tag).")
        #expect(KnownProvider(rawValue: provider) == nil, "Review allowlist entry: Swift now has the \(provider) provider.")
        #expect(!swiftProviders.contains(provider), "Remove stale allowlist entry: Swift now has a default for \(provider).")
    }
}

@Test func defaultModelIdsResolveInBundledCatalogWithoutTrapping() {
    for (provider, modelId) in defaultModelPerProvider {
        // The String overload returns nil. The KnownProvider overload traps on a missing id.
        let model = getModel(provider: provider.rawValue, modelId: modelId)
        #expect(model != nil, "Missing bundled default: \(provider.rawValue)/\(modelId)")
        #expect(model?.provider == provider.rawValue)
        #expect(model?.id == modelId)
    }
}

@Test func publicDefaultModelLookupUsesExactProviderIds() throws {
    let fixture = try upstreamDefaultModelsFixture()
    for entry in fixture.entries where !unsupportedDefaultModelProviders.contains(entry[0]) {
        #expect(defaultModelId(forProvider: entry[0]) == entry[1])
    }
    for provider in ["radius", "unknown-provider", "", "OpenAI", " openai", "openai "] {
        #expect(defaultModelId(forProvider: provider) == nil, "Unexpected default for \(provider)")
    }
}
