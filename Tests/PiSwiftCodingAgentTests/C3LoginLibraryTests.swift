import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

private struct C3LoginFixture {
    let directory: URL
    let auth = AuthStorage(":memory:")

    init(_ providers: [String: Any] = [:]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("c3-login-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["providers": providers])
            .write(to: directory.appendingPathComponent("models.json"))
    }

    func registry() -> ModelRegistry {
        ModelRegistry(auth, directory.path, modelsStore: InMemoryModelsStore(), networkEnabled: false)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

// Port the provider-composer and model-registry login cases at v1.0.0.
@Test func c3LoginProviderDisplayNamesAndComposition() throws {
    let fixture = try C3LoginFixture([
        "c3-custom": ["name": "Custom Service", "baseUrl": "https://custom.invalid", "api": "openai-completions", "models": [["id": "demo"]]],
        "openai": ["name": "Configured OpenAI"],
        "c3-name-only": ["name": "Name Only"],
    ])
    defer { fixture.remove() }
    let registry = fixture.registry()
    #expect(registry.getProviderDisplayName("github-copilot") == "GitHub Copilot")
    #expect(registry.getProviderDisplayName("zai") == "Z.AI")
    #expect(registry.getProviderDisplayName("missing") == "missing")
    #expect(registry.getProviderDisplayName("openai") == "Configured OpenAI")
    #expect(registry.getProviderDisplayName("c3-custom") == "Custom Service")
    #expect(registry.getLoginProvider("c3-name-only")?.name == "Name Only")
    #expect(registry.getLoginProvider("typesafe")?.name == "TypeSafe")
    #expect(registry.getLoginProvider("c3-custom")?.apiKey?.name == "API key")
    #expect(registry.getLoginProvider("c3-custom")?.apiKey?.login != nil)
    #expect(registry.getLoginProvider("openai-codex")?.apiKey == nil)
    #expect(registry.getLoginProvider("openai-codex")?.oauth != nil)
    #expect(registry.getLoginProvider("anthropic")?.apiKey?.name == "Anthropic API key")
    #expect(registry.getLoginProvider("anthropic")?.oauth?.isSubscription == true)
    registry.registerProvider(HookProviderConfig(provider: "openai", api: .openAICompletions,
        baseUrl: "https://custom.invalid", name: "Extension OpenAI", models: [HookProviderModel(id: "demo")]), sourceId: "c3-login")
    #expect(registry.getProviderDisplayName("openai") == "Extension OpenAI")
    registry.registerProvider(HookProviderConfig(provider: "c3-extension", api: .openAICompletions,
        baseUrl: "https://custom.invalid", name: "Extension Service", models: [HookProviderModel(id: "demo")]), sourceId: "c3-login")
    #expect(registry.getProviderDisplayName("c3-extension") == "Extension Service")
    let ids = registry.getLoginProviders().map(\.id)
    #expect(ids == ids.sorted())
    #expect(Set(ids).count == ids.count)
    #expect(Set(getBuiltinProviderAuth().map(\.id)).isSubset(of: Set(ids)))
}

@Test func c3LoginBuiltinDisplayNameWithoutOverrides() {
    let registry = ModelRegistry(AuthStorage(":memory:"), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
    #expect(registry.getProviderDisplayName("openai") == "OpenAI")
    #expect(registry.getLoginProvider("unknown") == nil)
}

@Test(.timeLimit(.minutes(1))) func c3LoginCustomApiKeyStoresThenMakesModelAvailable() async throws {
    let fixture = try C3LoginFixture(["c3-custom": ["name": "Custom Service", "baseUrl": "https://custom.invalid", "api": "openai-completions", "models": [["id": "demo"]]]])
    defer { fixture.remove() }
    let registry = fixture.registry()
    let model = try #require(registry.find("c3-custom", "demo"))
    #expect(!(await registry.isAvailable(model)))
    let prompts = LockedState<[String]>([])
    let credential = try await registry.loginApiKey("c3-custom", interaction: ProviderAuthInteraction(prompt: { prompt in
        if case .secret(let message, _) = prompt { prompts.withLock { $0.append(message) } }
        else { Issue.record("Expected a secret key prompt") }
        return "saved-key"
    }, notify: { _ in Issue.record("Unexpected login event") }))
    guard case .apiKey(let result) = credential else { Issue.record("Expected API-key credential"); return }
    #expect(result.key == "saved-key")
    #expect(result.env == nil)
    #expect(prompts.withLock { $0 } == ["Enter API key"])
    #expect(await registry.isAvailable(model))
    #expect(await registry.getApiKeyAndHeaders(model).apiKey == "saved-key")
    #expect(registry.getProviderAuthStatus("c3-custom") == ProviderAuthStatus(configured: true, source: "stored"))
    #expect(!registry.isUsingOAuth("c3-custom"))
    await registry.logout("c3-custom")
    #expect(!fixture.auth.has("c3-custom"))
    #expect(!(await registry.isAvailable(model)))
}

@Test(.timeLimit(.minutes(1))) func c3LoginStoresKeyAndScopedEnvironment() async throws {
    let fixture = try C3LoginFixture()
    defer { fixture.remove() }
    let registry = fixture.registry()
    let answers = LockedState(["scoped-key", "account-123", "gateway-123"])
    let credential = try await registry.loginApiKey("cloudflare-ai-gateway", interaction: ProviderAuthInteraction(prompt: { _ in
        answers.withLock { $0.removeFirst() }
    }, notify: { _ in }))
    guard case .apiKey(let result) = credential else { Issue.record("Expected API-key credential"); return }
    #expect(result.key == "scoped-key")
    #expect(result.env == ["CLOUDFLARE_ACCOUNT_ID": "account-123", "CLOUDFLARE_GATEWAY_ID": "gateway-123"])
    let model = try #require(registry.getAll().first { $0.provider == "cloudflare-ai-gateway" })
    #expect(await registry.isAvailable(model))
    let auth = await registry.getApiKeyAndHeaders(model)
    #expect(auth.apiKey == nil)
    #expect(auth.env == result.env)
    #expect(auth.headers?["cf-aig-authorization"] == "Bearer scoped-key")
}

@Test(.timeLimit(.minutes(1))) func c3LoginStoresEnvironmentOnlyCredential() async throws {
    let fixture = try C3LoginFixture()
    defer { fixture.remove() }
    let registry = fixture.registry()
    let answers = LockedState(["aws-profile", "c3-profile"])
    let credential = try await registry.loginApiKey("amazon-bedrock", interaction: ProviderAuthInteraction(prompt: { _ in
        answers.withLock { $0.removeFirst() }
    }, notify: { _ in }))
    guard case .apiKey(let result) = credential else { Issue.record("Expected API-key credential"); return }
    #expect(result.key == nil)
    #expect(result.env == ["AWS_PROFILE": "c3-profile"])
    let model = try #require(registry.getAll().first { $0.provider == "amazon-bedrock" })
    #expect(await registry.isAvailable(model))
    #expect(await registry.getApiKeyAndHeaders(model).env == result.env)
}

@Test(.timeLimit(.minutes(1))) func c3LoginUnsupportedAndUnknownProvidersFailBeforePrompt() async {
    let registry = ModelRegistry(AuthStorage(":memory:"), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
    let interaction = ProviderAuthInteraction(prompt: { _ in Issue.record("Unexpected prompt"); return "key" }, notify: { _ in })
    do {
        _ = try await registry.loginApiKey("unknown", interaction: interaction)
        Issue.record("Unknown provider login must fail")
    } catch { #expect(error.localizedDescription == "Unknown provider: unknown") }
    do {
        _ = try await registry.loginApiKey("openai-codex", interaction: interaction)
        Issue.record("OAuth-only provider API-key login must fail")
    } catch { #expect(error.localizedDescription == "OpenAI Codex (legacy) does not support api_key login") }
}

@Test func c3CredentialListReportsTypesWithoutSecrets() {
    let auth = AuthStorage(":memory:")
    auth.set("z-key", credential: .apiKey(ApiKeyCredential(key: "secret")))
    auth.set("a-oauth", credential: .oauth(OAuthCredential(access: "secret", refresh: nil, expires: nil)))
    auth.set("m-env", credential: .apiKey(ApiKeyCredential(env: ["AWS_PROFILE": "profile"])))
    #expect(auth.listCredentials() == [CredentialInfo(providerId: "a-oauth", type: .oauth),
        CredentialInfo(providerId: "m-env", type: .apiKey), CredentialInfo(providerId: "z-key", type: .apiKey)])
    #expect(CredentialInfo.CredentialType.apiKey.rawValue == "api_key")
    let registry = ModelRegistry(auth, nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
    #expect(registry.isUsingOAuth("a-oauth"))
    #expect(!registry.isUsingOAuth("m-env"))
    // Keep the OAuthProvider logout overload for existing callers.
    auth.set("anthropic", credential: .oauth(OAuthCredential(access: "secret", refresh: nil, expires: nil)))
    auth.logout(.anthropic)
    #expect(!auth.has("anthropic"))
}

@Test func c3LoginStatusUsesAmbientLabel() {
    let registry = ModelRegistry(AuthStorage(":memory:"), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
    #expect(registry.getProviderAuthStatus("amazon-bedrock", env: ["AWS_PROFILE": "c3-profile"]) ==
        ProviderAuthStatus(configured: true, source: "environment", label: "AWS_PROFILE"))
}

@Test(arguments: [false, true]) func c3LoginRejectsInvalidConfiguredNames(nonString: Bool) throws {
    let name: Any = nonString ? 5 : ""
    let fixture = try C3LoginFixture(["c3-custom": ["name": name]])
    defer { fixture.remove() }
    #expect(fixture.registry().getError()?.contains("name must be a nonempty string") == true)
}
