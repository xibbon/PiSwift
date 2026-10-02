import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

private let c3FederationEnv = [
    "ANTHROPIC_FEDERATION_RULE_ID": "fdrl_test",
    "ANTHROPIC_ORGANIZATION_ID": "org-test",
    "ANTHROPIC_SERVICE_ACCOUNT_ID": "svac_test",
    "ANTHROPIC_IDENTITY_TOKEN_FILE": "/tmp/c3-identity.jwt",
]

private func c3FederationRegistry(_ auth: AuthStorage = AuthStorage(":memory:")) -> ModelRegistry {
    ModelRegistry(auth, nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
}

private func c3FederationModel(provider: String = "anthropic") -> Model {
    Model(id: "claude-c3", name: "Claude C3", api: .anthropicMessages, provider: provider,
        baseUrl: "https://api.anthropic.com", reasoning: false, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 100_000, maxTokens: 4096)
}

// Port anthropic-federation.test.ts resolver precedence at v1.0.0.
@Test(.timeLimit(.minutes(1))) func c3FederationResolvesWithoutAKeyAndReportsAmbientSource() async {
    let registry = c3FederationRegistry()
    let resolved = await registry.getApiKeyAndHeaders(c3FederationModel(), env: c3FederationEnv)
    #expect(resolved.ok)
    #expect(resolved.apiKey == nil)
    #expect(resolved.env == c3FederationEnv)
    #expect(resolved.hasResolvedAuth)
    #expect(registry.authStorage.hasAuth("anthropic", env: c3FederationEnv))
    #expect(registry.getProviderAuthStatus("anthropic", env: c3FederationEnv) ==
        ProviderAuthStatus(configured: true, source: "environment", label: "workload identity federation"))
}

@Test(.timeLimit(.minutes(1))) func c3FederationRequiresAllRequiredVariablesAndKeepsOptionalVariables() async {
    let registry = c3FederationRegistry()
    var partial = c3FederationEnv
    partial.removeValue(forKey: "ANTHROPIC_IDENTITY_TOKEN_FILE")
    let missing = await registry.getApiKeyAndHeaders(c3FederationModel(), env: partial)
    #expect(!missing.hasResolvedAuth)
    #expect(missing.env == nil)
    #expect(!registry.authStorage.hasAuth("anthropic", env: partial))
    var optional = c3FederationEnv
    optional.removeValue(forKey: "ANTHROPIC_SERVICE_ACCOUNT_ID")
    optional["ANTHROPIC_WORKSPACE_ID"] = "wrkspc_test"
    let present = await registry.getApiKeyAndHeaders(c3FederationModel(), env: optional)
    #expect(present.apiKey == nil)
    #expect(present.env == optional)
    #expect(present.hasResolvedAuth)
    #expect(!registry.authStorage.hasAuth("kimi-coding", env: optional))
    #expect(!(await registry.getApiKeyAndHeaders(c3FederationModel(provider: "kimi-coding"), env: optional)).hasResolvedAuth)
}

@Test(.timeLimit(.minutes(1)), arguments: ["ANTHROPIC_API_KEY", "ANTHROPIC_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN"])
func c3FederationEnvironmentCredentialsTakePriority(name: String) async {
    let registry = c3FederationRegistry()
    let env = c3FederationEnv.merging([name: "env-credential"]) { _, last in last }
    let resolved = await registry.getApiKeyAndHeaders(c3FederationModel(), env: env)
    #expect(resolved.ok)
    #expect(resolved.hasResolvedAuth)
    #expect(resolved.env == nil)
    if name == "ANTHROPIC_AUTH_TOKEN" {
        #expect(resolved.apiKey == nil)
        #expect(resolved.headers?["Authorization"] == "Bearer env-credential")
    } else { #expect(resolved.apiKey == "env-credential") }
    #expect(registry.getProviderAuthStatus("anthropic", env: env).label == name)
}

@Test(.timeLimit(.minutes(1))) func c3FederationStoredConfiguredAndRuntimeCredentialsTakePriority() async {
    let auth = AuthStorage(":memory:")
    let registry = c3FederationRegistry(auth)
    registry.registerProvider(HookProviderConfig(provider: "anthropic", api: .anthropicMessages,
        baseUrl: "https://api.anthropic.com", apiKey: "configured-key", models: [HookProviderModel(id: "claude-c3")]), sourceId: "c3-auth")
    let configured = await registry.getApiKeyAndHeaders(c3FederationModel(), env: c3FederationEnv)
    #expect(configured.apiKey == "configured-key")
    #expect(configured.env == nil)
    auth.set("anthropic", credential: .apiKey(ApiKeyCredential(key: "stored-key")))
    #expect(await registry.getApiKeyAndHeaders(c3FederationModel(), env: c3FederationEnv).apiKey == "stored-key")
    auth.setRuntimeApiKey("anthropic", "runtime-key")
    #expect(await registry.getApiKeyAndHeaders(c3FederationModel(), env: c3FederationEnv).apiKey == "runtime-key")
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func c3FederationEnvironmentOnlyCredentialCanResolveFederation(emptyKey: Bool) async {
    let auth = AuthStorage(":memory:")
    auth.set("anthropic", credential: .apiKey(ApiKeyCredential(key: emptyKey ? "" : nil, env: c3FederationEnv)))
    let registry = c3FederationRegistry(auth)
    #expect(auth.hasAuth("anthropic"))
    let resolved = await registry.getApiKeyAndHeaders(c3FederationModel())
    #expect(resolved.apiKey == nil)
    #expect(resolved.env == c3FederationEnv)
    #expect(resolved.hasResolvedAuth)
}

@Test(.timeLimit(.minutes(1))) func c3FederationStreamReceivesBagAndExplicitKeyWins() async throws {
    let registry = c3FederationRegistry()
    let observed = LockedState<[SimpleStreamOptions]>([])
    registry.registerProvider(HookProviderConfig(provider: "anthropic", api: .anthropicMessages,
        baseUrl: "https://api.anthropic.com", streamSimple: { model, _, options in
            observed.withLock { $0.append(options ?? SimpleStreamOptions()) }
            let output = AssistantMessageEventStream()
            output.end(AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop))
            return output
        }, models: [HookProviderModel(id: "claude-c3")]), sourceId: "c3-auth")
    let model = try #require(registry.find("anthropic", "claude-c3"))
    _ = await registry.streamSimple(model: model, context: Context(messages: []), options: SimpleStreamOptions(env: c3FederationEnv)).result()
    _ = await registry.streamSimple(model: model, context: Context(messages: []), options: SimpleStreamOptions(env: c3FederationEnv, apiKey: "explicit-key")).result()
    let options = observed.withLock { $0 }
    #expect(options.count == 2)
    #expect(options.first?.env == c3FederationEnv)
    #expect(options.first?.apiKey == nil)
    #expect(options.last?.apiKey == "explicit-key")
}

private enum C3LoginCancelled: Error { case cancelled }

@Test(.timeLimit(.minutes(1))) func c3AnthropicStorageLoginUsesMethodDispatcher() async {
    let auth = AuthStorage(":memory:")
    let prompts = LockedState<[OAuthSelectPrompt]>([])
    do {
        try await auth.login(.anthropic, callbacks: OAuthLoginCallbacks(onAuth: { _ in Issue.record("Unexpected auth URL") },
            onPrompt: { _ in Issue.record("Unexpected prompt"); return "" }, onSelect: { prompt in
                prompts.withLock { $0.append(prompt) }
                throw C3LoginCancelled.cancelled
            }))
        Issue.record("Login selection must cancel")
    } catch { #expect(error is C3LoginCancelled) }
    #expect(prompts.withLock { $0.first?.message } == "Select Anthropic login method:")
    #expect(prompts.withLock { $0.first?.options.map(\.id) } == ["browser", "copy_code"])
    #expect(!auth.has("anthropic"))
}
