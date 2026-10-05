import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

private func c1AzureResolverRegistry(_ authenticated: [String]) -> ModelRegistry {
    let auth = AuthStorage.inMemory()
    // A missing stored reference suppresses ambient keys without changing the process environment.
    let missing = "PI_C1_MISSING_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
    for provider in getProviders() {
        auth.set(provider.rawValue, credential: .apiKey(ApiKeyCredential(key: "$" + missing)))
    }
    for provider in authenticated { auth.setRuntimeApiKey(provider, "test-key") }
    let registry = ModelRegistry(auth)
    let candidates = Set(registry.getAll().filter { $0.id == "gpt-5.6-sol" }.map(\.provider))
        .union(["openai", "azure", "openai-codex"])
    for provider in candidates {
        registry.registerProvider(HookProviderConfig(
            provider: provider, api: .openAICompletions,
            baseUrl: "https://example.invalid/v1", apiKey: "$" + missing,
            models: [HookProviderModel(id: "gpt-5.6-sol")]
        ), sourceId: "<c1-azure-test>")
    }
    return registry
}

// Upstream v1.0.3 model-resolver.test.ts:435,463,483 uses the Azure provider id.
@Test func c1AzureResolverUsesOnlyAuthenticatedProvider() {
    let registry = c1AzureResolverRegistry(["openai"])
    let result = resolveCliModel(cliModel: "gpt-5.6-sol", modelRegistry: registry)
    #expect(result.error == nil)
    #expect(result.model?.provider == "openai")
}

@Test func c1AzureResolverNamesAuthenticatedAzureAndCodex() {
    let registry = c1AzureResolverRegistry(["azure", "openai-codex"])
    let result = resolveCliModel(cliModel: "gpt-5.6-sol", modelRegistry: registry)
    #expect(result.model == nil)
    #expect(result.error?.contains("azure/gpt-5.6-sol") == true)
    #expect(result.error?.contains("openai-codex/gpt-5.6-sol") == true)
}

@Test func c1AzureDefaultAndReleaseVersion() {
    #expect(defaultModelPerProvider.first { $0.0 == .azure }?.1 == "gpt-5.4")
    #expect(VERSION == "1.0.3")
}
