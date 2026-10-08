import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

private struct F5RegistryFixture {
    let directory: URL
    let auth = AuthStorage(":memory:")
    init(_ provider: [String: Any] = [:]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("f5-registry-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults: [String: Any] = ["baseUrl": "https://provider.test/v1", "api": "openai-completions", "models": [["id": "demo"]]]
        let config = defaults.merging(provider) { _, value in value }
        try JSONSerialization.data(withJSONObject: ["providers": ["f5-custom": config]])
            .write(to: directory.appendingPathComponent("models.json"))
    }
    func registry() -> ModelRegistry {
        ModelRegistry(auth, directory.path, modelsStore: InMemoryModelsStore(), networkEnabled: false)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

// Ports model-registry.test.ts request-time auth, uppercase literals, availability,
// and source-based provider-composer rules at v0.99.1.
@Test func f5RegistryLiteralsAndScopedTemplates() async throws {
    let fixture = try F5RegistryFixture(["apiKey": "TOKEN", "headers": ["Authorization": "BEARER"],
                                        "models": [["id": "demo", "headers": ["X-Token": "MODEL_TOKEN"]]]])
    defer { fixture.remove() }
    let registry = fixture.registry()
    let model = try #require(registry.find("f5-custom", "demo"))
    let literal = await registry.getApiKeyAndHeaders(model, env: ["TOKEN": "secret", "BEARER": "secret", "MODEL_TOKEN": "secret"])
    #expect(literal.ok)
    #expect(literal.apiKey == "TOKEN")
    #expect(literal.headers?["Authorization"] == "BEARER")
    #expect(literal.headers?["X-Token"] == "MODEL_TOKEN")
    #expect(literal.env == nil)
    #expect(registry.getProviderAuthStatus("f5-custom") == ProviderAuthStatus(configured: true, source: "models_json_key"))
    fixture.auth.set("f5-custom", credential: .apiKey(ApiKeyCredential(key: "$TOKEN", env: ["TOKEN": "stored", "ACCOUNT": "one"])))
    registry.registerProvider(HookProviderConfig(provider: "f5-custom", api: .openAICompletions, baseUrl: "https://provider.test/v1",
        apiKey: "ignored", headers: ["X-Account": "${ACCOUNT}"], models: [HookProviderModel(id: "demo", headers: ["X-Model": "$ACCOUNT"])]), sourceId: "f5")
    let extensionModel = try #require(registry.find("f5-custom", "demo"))
    #expect(extensionModel.headers?["X-Model"] == "$ACCOUNT")
    let first = await registry.getApiKeyAndHeaders(extensionModel)
    #expect(first.apiKey == "stored")
    #expect(first.headers?["X-Account"] == "one")
    #expect(first.headers?["X-Model"] == "one")
    #expect(first.env == ["TOKEN": "stored", "ACCOUNT": "one"])
    fixture.auth.set("f5-custom", credential: .apiKey(ApiKeyCredential(key: "$TOKEN", env: ["TOKEN": "next", "ACCOUNT": "two"])))
    let next = await registry.getApiKeyAndHeaders(extensionModel, env: ["ACCOUNT": "request"])
    #expect(next.apiKey == "next")
    #expect(next.headers?["X-Account"] == "request")
    #expect(next.headers?["X-Model"] == "request")
    #expect(next.env?["ACCOUNT"] == "request")
    fixture.auth.setRuntimeApiKey("f5-custom", "runtime")
    let runtime = await registry.getApiKeyAndHeaders(extensionModel, env: ["ACCOUNT": "runtime-account"])
    #expect(runtime.apiKey == "runtime")
    #expect(runtime.env == ["ACCOUNT": "runtime-account"])
}

@Test func f5RegistryCommandsRunOncePerRequestAndNeverForAvailability() async throws {
    let fixture = try F5RegistryFixture()
    defer { fixture.remove() }
    let keyCounter = fixture.directory.appendingPathComponent("keys")
    let providerCounter = fixture.directory.appendingPathComponent("providers")
    let modelCounter = fixture.directory.appendingPathComponent("models")
    let registry = fixture.registry()
    registry.registerProvider(HookProviderConfig(provider: "f5-custom", api: .openAICompletions, baseUrl: "https://provider.test/v1",
        apiKey: "!echo run >> '\(keyCounter.path)'; printf key", authHeader: true,
        headers: ["X-Provider": "!echo run >> '\(providerCounter.path)'; printf provider"],
        models: [HookProviderModel(id: "demo", headers: ["X-Model": "!echo run >> '\(modelCounter.path)'; printf model"])]), sourceId: "f5")
    let model = try #require(registry.find("f5-custom", "demo"))
    #expect(registry.hasConfiguredAuth(model))
    #expect(registry.getProviderAuthStatus("f5-custom") == ProviderAuthStatus(configured: true, source: "models_json_command"))
    #expect(await registry.isAvailable(model))
    #expect(!FileManager.default.fileExists(atPath: keyCounter.path))
    #expect(!FileManager.default.fileExists(atPath: providerCounter.path))
    for _ in 0..<2 {
        let auth = await registry.getApiKeyAndHeaders(model)
        #expect(auth.ok)
        #expect(auth.apiKey == "key")
        #expect(auth.headers?["Authorization"] == "Bearer key")
        #expect(auth.headers?["X-Provider"] == "provider")
        #expect(auth.headers?["X-Model"] == "model")
    }
    for url in [keyCounter, providerCounter, modelCounter] {
        #expect(try String(contentsOf: url, encoding: .utf8) == "run\nrun\n")
    }
    fixture.auth.set("f5-custom", credential: .apiKey(ApiKeyCredential(key: "stored")))
    #expect(await registry.getApiKeyAndHeaders(model).apiKey == "stored")
    #expect(try String(contentsOf: keyCounter, encoding: .utf8) == "run\nrun\n")
}

@Test func f5RegistryModelsJsonCommandsAreUncachedAcrossInstances() async throws {
    let fixture = try F5RegistryFixture()
    defer { fixture.remove() }
    let token = fixture.directory.appendingPathComponent("token")
    let counter = fixture.directory.appendingPathComponent("counter")
    try "one".write(to: token, atomically: true, encoding: .utf8)
    let config: [String: Any] = ["providers": ["f5-custom": ["baseUrl": "https://provider.test/v1", "api": "openai-completions", "authHeader": true,
        "apiKey": "!echo run >> '\(counter.path)'; cat '\(token.path)'", "models": [["id": "demo"]]]]]
    try JSONSerialization.data(withJSONObject: config).write(to: fixture.directory.appendingPathComponent("models.json"))
    let registry = fixture.registry()
    let model = try #require(registry.find("f5-custom", "demo"))
    let first = await registry.getApiKeyAndHeaders(model)
    #expect(first.apiKey == "one")
    #expect(first.headers?["Authorization"] == "Bearer one")
    try "two".write(to: token, atomically: true, encoding: .utf8)
    let secondRegistry = fixture.registry()
    let second = await secondRegistry.getApiKeyAndHeaders(model)
    #expect(second.apiKey == "two")
    #expect(second.headers?["Authorization"] == "Bearer two")
    #expect(try String(contentsOf: counter, encoding: .utf8) == "run\nrun\n")
}

@Test(arguments: ["key", "provider", "model", "compatibility"])
func f5RegistryStrictMissingVariableErrors(_ kind: String) async throws {
    let missing = "PI_F5_ABSENT_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
    let fixture = try F5RegistryFixture(kind == "key" ? ["apiKey": "$\(missing)"] : [:])
    defer { fixture.remove() }
    let registry = fixture.registry()
    if kind != "key" {
        if kind != "compatibility" { fixture.auth.set("f5-custom", credential: .apiKey(ApiKeyCredential(key: "stored"))) }
        registry.registerProvider(HookProviderConfig(provider: "f5-custom", api: .openAICompletions, baseUrl: "https://provider.test/v1",
            headers: kind == "provider" || kind == "compatibility" ? ["X-Missing": "$\(missing)"] : nil,
            models: [HookProviderModel(id: "demo", headers: kind == "model" ? ["X-Missing": "$\(missing)"] : nil)]), sourceId: "f5")
    }
    let model = try #require(registry.find("f5-custom", "demo"))
    let auth = await registry.getApiKeyAndHeaders(model)
    #expect(!auth.ok)
    let description = kind == "key" ? "API key for provider \"f5-custom\"" : kind == "provider" ? "provider \"f5-custom\" header \"X-Missing\"" : "model \"f5-custom/demo\" header \"X-Missing\""
    #expect(auth.error == "Failed to resolve \(description) from environment variable: \(missing)")
    if kind == "key" {
        #expect(!registry.hasConfiguredAuth(model))
        #expect(registry.getProviderAuthStatus("f5-custom") == ProviderAuthStatus(configured: false))
    }
}

@Test func f5RegistryFailedCommandsRetryAndReportSource() async throws {
    let fixture = try F5RegistryFixture()
    defer { fixture.remove() }
    let counter = fixture.directory.appendingPathComponent("failed")
    let command = "!echo run >> '\(counter.path)'; printf ignored; exit 1"
    let registry = fixture.registry()
    registry.registerProvider(HookProviderConfig(provider: "f5-custom", api: .openAICompletions, baseUrl: "https://provider.test/v1", apiKey: command,
        models: [HookProviderModel(id: "demo")]), sourceId: "f5")
    let model = try #require(registry.find("f5-custom", "demo"))
    for _ in 0..<2 {
        let auth = await registry.getApiKeyAndHeaders(model)
        #expect(!auth.ok)
        #expect(auth.error == "Failed to resolve API key for provider \"f5-custom\" from shell command: \(command.dropFirst())")
    }
    #expect(try String(contentsOf: counter, encoding: .utf8) == "run\nrun\n")
}

@Test func f5RegistryHeaderPrecedenceAndOAuthEnvironment() async throws {
    let fixture = try F5RegistryFixture(["apiKey": "configured", "headers": ["X-Provider": "json"],
        "models": [["id": "demo", "headers": ["X-Shared": "definition", "X-Empty": ""]]],
        "modelOverrides": ["demo": ["headers": ["X-Shared": "override", "X-Override": "override"]]]])
    defer { fixture.remove() }
    fixture.auth.set("f5-custom", credential: .oauth(OAuthCredential(access: "oauth-access", refresh: nil, expires: nil, env: ["ACCOUNT": "oauth-account"])))
    let registry = fixture.registry()
    registry.registerProvider(HookProviderConfig(provider: "f5-custom", api: .openAICompletions, baseUrl: "https://provider.test/v1",
        apiKey: "ignored", headers: ["X-Provider": "extension", "X-Account": "$ACCOUNT"],
        models: [HookProviderModel(id: "demo", headers: ["X-Shared": "extension-model", "X-Model": "$MODEL_ACCOUNT"])]), sourceId: "f5")
    let auth = await registry.getApiKeyAndHeaders(try #require(registry.find("f5-custom", "demo")), env: ["MODEL_ACCOUNT": "model-account"])
    #expect(auth.ok)
    #expect(auth.apiKey == "oauth-access")
    #expect(auth.env == nil)
    #expect(auth.headers?["X-Provider"] == "extension")
    #expect(auth.headers?["X-Shared"] == "extension-model")
    #expect(auth.headers?["X-Override"] == "override")
    #expect(auth.headers?["X-Empty"] == "")
    #expect(auth.headers?["X-Model"] == "model-account")
    let overridden = await registry.getApiKeyAndHeaders(try #require(registry.find("f5-custom", "demo")), env: ["ACCOUNT": "request-account", "MODEL_ACCOUNT": "request-model-account"])
    #expect(overridden.headers?["X-Account"] == "oauth-account")
    #expect(overridden.headers?["X-Model"] == "request-model-account")
    #expect(overridden.env == nil)
    registry.unregisterProvider("f5-custom", sourceId: "f5")
    let restored = await registry.getApiKeyAndHeaders(try #require(registry.find("f5-custom", "demo")))
    #expect(restored.headers?["X-Shared"] == "definition")
}

@Test func f5RegistryCompatibilityAndMissingAuthHeader() async throws {
    let fixture = try F5RegistryFixture(["authHeader": true])
    defer { fixture.remove() }
    let registry = fixture.registry()
    let auth = await registry.getApiKeyAndHeaders(try #require(registry.find("f5-custom", "demo")))
    #expect(auth.error == "No API key found for \"f5-custom\"")
    let staticModel = Model(id: "static", name: "static", api: .openAICompletions, provider: "unconfigured", baseUrl: "https://test.invalid",
        reasoning: false, input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 100, maxTokens: 10, headers: ["X-Static": "value"])
    let compatible = await registry.getApiKeyAndHeaders(staticModel)
    #expect(compatible.ok)
    #expect(compatible.headers == ["X-Static": "value"])
}

@Test func f5RegistryStreamReceivesScopedCredentialEnvironment() async throws {
    let fixture = try F5RegistryFixture()
    defer { fixture.remove() }
    fixture.auth.set("f5-custom", credential: .apiKey(ApiKeyCredential(key: "stored", env: ["ACCOUNT": "scoped"])))
    let received = LockedState<SimpleStreamOptions?>(nil)
    let registry = fixture.registry()
    registry.registerProvider(HookProviderConfig(provider: "f5-custom", api: .openAICompletions, baseUrl: "https://provider.test/v1",
        headers: ["X-Account": "$ACCOUNT"], streamSimple: { model, _, options in
            received.withLock { $0 = options }
            let stream = AssistantMessageEventStream()
            let message = AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
            stream.end(message)
            return stream
        }, models: [HookProviderModel(id: "demo")]), sourceId: "f5")
    let model = try #require(registry.find("f5-custom", "demo"))
    _ = await registry.streamSimple(model: model, context: Context(messages: []), options: SimpleStreamOptions(env: ["ACCOUNT": "request"])).result()
    let request = try #require(received.withLock { $0 })
    #expect(request.apiKey == "stored")
    #expect(request.env == ["ACCOUNT": "request"])
    #expect(request.headers?["X-Account"] == "request")
}

@Test func f5EnvironmentOnlyCloudCredentialAndRefreshRetainBag() async throws {
    let fixture = try F5RegistryFixture()
    defer { fixture.remove() }
    let path = fixture.directory.appendingPathComponent("auth.json")
    try #"{"amazon-bedrock":{"type":"api_key","env":{"AWS_PROFILE":"scoped-profile"}}}"#.write(to: path, atomically: true, encoding: .utf8)
    let auth = AuthStorage(path.path)
    #expect(await auth.getApiKey("amazon-bedrock") == "<authenticated>")
    #expect(auth.hasAuth("amazon-bedrock"))
    let registry = ModelRegistry(auth, nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
    let model = try #require(registry.getAll().first { $0.provider == "amazon-bedrock" })
    let resolved = await registry.getApiKeyAndHeaders(model)
    #expect(resolved.env == ["AWS_PROFILE": "scoped-profile"])
    #expect(resolved.apiKey == nil)
    #expect(resolved.hasResolvedAuth)
    let credentials = OAuthCredentials(refresh: "", access: "token", expires: 999_999_999_999_999, env: ["ACCOUNT": "scoped"])
    #expect(try await refreshOAuthToken(provider: .openRouter, credentials: credentials).env == credentials.env)
}

@Test func f5CloudflareCredentialEnvironmentAndGatewayAuth() async throws {
    let fixture = try F5RegistryFixture()
    defer { fixture.remove() }
    fixture.auth.set("cloudflare-ai-gateway", credential: .apiKey(ApiKeyCredential(key: "$CLOUDFLARE_API_KEY", env: [
        "CLOUDFLARE_API_KEY": "stored-cf-token", "CLOUDFLARE_ACCOUNT_ID": "stored-account", "CLOUDFLARE_GATEWAY_ID": "stored-gateway"
    ])))
    let registry = fixture.registry()
    registry.registerProvider(HookProviderConfig(provider: "cloudflare-ai-gateway", api: .openAICompletions, baseUrl: "https://gateway.test",
        headers: ["x-account": "$CLOUDFLARE_ACCOUNT_ID"], models: [HookProviderModel(id: "demo")]), sourceId: "f5")
    let auth = await registry.getApiKeyAndHeaders(try #require(registry.find("cloudflare-ai-gateway", "demo")))
    #expect(auth.ok)
    #expect(auth.apiKey == nil)
    #expect(auth.headers?["cf-aig-authorization"] == "Bearer stored-cf-token")
    #expect(providerHeadersContain(auth.headers, name: "Authorization"))
    #expect(providerHeaderValue(auth.headers, name: "Authorization") == nil)
    #expect(auth.headers?["x-account"] == "stored-account")
    #expect(auth.env == ["CLOUDFLARE_ACCOUNT_ID": "stored-account", "CLOUDFLARE_GATEWAY_ID": "stored-gateway"])
    let overridden = await registry.getApiKeyAndHeaders(try #require(registry.find("cloudflare-ai-gateway", "demo")), env: ["CLOUDFLARE_ACCOUNT_ID": "request-account", "EXTRA": "value"])
    #expect(overridden.headers?["x-account"] == "request-account")
    #expect(overridden.env == ["CLOUDFLARE_ACCOUNT_ID": "request-account", "CLOUDFLARE_GATEWAY_ID": "stored-gateway"])
}

private func f5DoneStream(_ model: Model) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()
    let message = AssistantMessage(content: [.text(TextContent(text: "summary"))], api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
    stream.push(.done(reason: .stop, message: message))
    stream.end(message)
    return stream
}

@Test(.timeLimit(.minutes(1))) func f5SDKSessionForwardsCredentialEnvironment() async throws {
    let fixture = try F5RegistryFixture(["headers": ["X-Account": "$ACCOUNT"]])
    defer { fixture.remove() }
    fixture.auth.set("f5-custom", credential: .apiKey(ApiKeyCredential(key: "$TOKEN", env: ["TOKEN": "stored", "ACCOUNT": "scoped"])))
    let registry = fixture.registry()
    let model = try #require(registry.find("f5-custom", "demo"))
    let received = LockedState<SimpleStreamOptions?>(nil)
    // C1 U3: SDK tool-list validation now throws.
    let result = try await createAgentSession(CreateAgentSessionOptions(cwd: fixture.directory.path,
        agentDir: fixture.directory.appendingPathComponent("agent").path, authStorage: fixture.auth, modelRegistry: registry, model: model,
        projectTrusted: true, offline: true, noTools: .all, resourceLoader: TestResourceLoader(), hooks: [], noExtensions: true,
        sessionManager: .inMemory(), settingsManager: .inMemory()))
    result.session.agent.streamFn = { model, _, options in
        received.withLock { $0 = options }
        return f5DoneStream(model)
    }
    try await result.session.prompt("Hi")
    let request = try #require(received.withLock { $0 })
    #expect(request.apiKey == "stored")
    #expect(request.env == ["TOKEN": "stored", "ACCOUNT": "scoped"])
    #expect(request.headers?["X-Account"] == "scoped")
}

@Test(.timeLimit(.minutes(1))) func f5SummaryForwardsCredentialEnvironment() async throws {
    let received = LockedState<[String: String]?>(nil)
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    _ = try await generateSummary(currentMessages: [.user(UserMessage(content: .text("Hi")))], model: model,
        reserveTokens: 4096, apiKey: "stored", env: ["ACCOUNT": "scoped"], streamFn: { model, _, options in
            received.withLock { $0 = options.env }
            return f5DoneStream(model)
        })
    #expect(received.withLock { $0 } == ["ACCOUNT": "scoped"])
}

@Test(.timeLimit(.minutes(1))) func f5SDKSessionAcceptsScopedAmbientCloudAuth() async throws {
    let fixture = try F5RegistryFixture()
    defer { fixture.remove() }
    fixture.auth.set("amazon-bedrock", credential: .apiKey(ApiKeyCredential(env: ["AWS_PROFILE": "scoped-profile"])))
    let registry = fixture.registry()
    let model = try #require(registry.getAll().first { $0.provider == "amazon-bedrock" })
    let received = LockedState<[SimpleStreamOptions]>([])
    var settings = Settings()
    settings.compaction = CompactionSettingsOverrides(enabled: true, reserveTokens: 10, keepRecentTokens: 1)
    // C1 U3: SDK tool-list validation now throws.
    let result = try await createAgentSession(CreateAgentSessionOptions(cwd: fixture.directory.path,
        agentDir: fixture.directory.appendingPathComponent("agent").path, authStorage: fixture.auth, modelRegistry: registry, model: model,
        projectTrusted: true, offline: true, noTools: .all, resourceLoader: TestResourceLoader(), hooks: [], noExtensions: true,
        sessionManager: .inMemory(), settingsManager: .inMemory(settings)))
    result.session.agent.streamFn = { model, _, options in
        received.withLock { $0.append(options) }
        return f5DoneStream(model)
    }
    try await result.session.prompt(String(repeating: "hello ", count: 50))
    try await result.session.prompt("second request")
    let compacted = try await result.session.compact()
    #expect(!compacted.summary.isEmpty)
    let requests = received.withLock { $0 }
    #expect(requests.count >= 3)
    #expect(requests.allSatisfy { $0.env == ["AWS_PROFILE": "scoped-profile"] })
}

@Test(.timeLimit(.minutes(1))) func f5SDKSessionResolvesConfiguredCommandsOncePerRequest() async throws {
    let fixture = try F5RegistryFixture()
    defer { fixture.remove() }
    let keyCounter = fixture.directory.appendingPathComponent("key-counter")
    let headerCounter = fixture.directory.appendingPathComponent("header-counter")
    let registry = fixture.registry()
    registry.registerProvider(HookProviderConfig(provider: "f5-custom", api: .openAICompletions, baseUrl: "https://provider.test/v1",
        apiKey: "!echo run >> '\(keyCounter.path)'; printf key", headers: ["X-Request": "!echo run >> '\(headerCounter.path)'; printf header"],
        models: [HookProviderModel(id: "demo")]), sourceId: "f5")
    let model = try #require(registry.find("f5-custom", "demo"))
    // C1 U3: SDK tool-list validation now throws.
    let result = try await createAgentSession(CreateAgentSessionOptions(cwd: fixture.directory.path,
        agentDir: fixture.directory.appendingPathComponent("agent").path, authStorage: fixture.auth, modelRegistry: registry, model: model,
        projectTrusted: true, offline: true, noTools: .all, resourceLoader: TestResourceLoader(), hooks: [], noExtensions: true,
        sessionManager: .inMemory(), settingsManager: .inMemory()))
    result.session.agent.streamFn = { model, _, options in
        #expect(options.apiKey == "key")
        #expect(options.headers?["X-Request"] == "header")
        return f5DoneStream(model)
    }
    #expect(!FileManager.default.fileExists(atPath: keyCounter.path))
    try await result.session.prompt("Hi")
    #expect(try String(contentsOf: keyCounter, encoding: .utf8) == "run\n")
    #expect(try String(contentsOf: headerCounter, encoding: .utf8) == "run\n")
}
