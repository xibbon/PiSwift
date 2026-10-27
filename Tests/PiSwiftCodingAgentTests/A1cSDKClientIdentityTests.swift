// Upstream v1.4.0 sdk-client-identity.test.ts, with final HTTP header checks.
import Foundation
import Testing
import TestEnvironmentSupport
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private struct A1cHTTPClient: ProviderHTTPClient {
    let requests: LockedState<[URLRequest]>

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.withLock { $0.append(request) }
        let body = """
        data: {"id":"a1c","object":"chat.completion.chunk","created":0,"model":"chat","choices":[{"index":0,"delta":{"role":"assistant","content":"summary"},"finish_reason":"stop"}]}

        data: [DONE]

        """
        return ProviderHTTPResponse(statusCode: 200, headers: ["content-type": "text/event-stream"], body: Data(body.utf8))
    }
}

private func a1cResponse(_ model: Model, failed: Bool = false) -> AssistantMessageEventStream {
    let message = AssistantMessage(content: [.text(TextContent(text: "summary"))], api: model.api,
        provider: model.provider, model: model.id,
        usage: Usage(input: 100, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 101),
        stopReason: failed ? .error : .stop, errorMessage: failed ? "503 unavailable" : nil)
    let stream = AssistantMessageEventStream()
    if failed { stream.push(.error(reason: .error, error: message)) }
    else { stream.push(.done(reason: .stop, message: message)) }
    stream.end(message)
    return stream
}

private struct A1cFixture: Sendable {
    let directory: URL
    let registry: ModelRegistry
    let auth: AuthStorage
    let settings: SettingsManager
    let provider: String
    let calls = LockedState<[SimpleStreamOptions]>([])
    let wire = LockedState<[URLRequest]>([])

    init(baseUrl: String = "https://openrouter.ai/api/v1", provider: String = "a1c-\(UUID().uuidString)",
         headers: ProviderHeaders? = nil, registryIdentity: ClientIdentityProvider? = nil,
         http: Bool = false, failFirst: Bool = false) throws {
        self.provider = provider
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("a1c-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        auth = .inMemory([provider: .apiKey(ApiKeyCredential(key: "test-key"))])
        var values = Settings()
        values.enableInstallTelemetry = true
        values.cacheWarming = .off
        values.compaction = CompactionSettingsOverrides(keepRecentTokens: 1)
        settings = .inMemory(values)
        registry = ModelRegistry(auth, directory.path, modelsStore: InMemoryCodingAgentModelsStore(),
                                 networkEnabled: false, clientIdentityProvider: registryIdentity)
        let calls = calls
        let client = A1cHTTPClient(requests: wire)
        registry.registerProvider(HookProviderConfig(provider: provider, api: .openAICompletions,
            baseUrl: baseUrl, headers: headers, streamSimple: { model, context, options in
                let options = options ?? SimpleStreamOptions()
                let count = calls.withLock { $0.append(options); return $0.count }
                if http {
                    var request = options
                    request.httpClient = client
                    do { return try PiSwiftAI.streamSimple(model: model, context: context, options: request) }
                    catch { Issue.record(error); return a1cResponse(model, failed: true) }
                }
                return a1cResponse(model, failed: failFirst && count == 1)
            }, models: [HookProviderModel(id: "chat", promptCache: ModelPromptCache(short: 11))]), sourceId: provider)
    }

    func model() throws -> Model { try #require(registry.find(provider, "chat")) }

    func session(identity: ClientIdentityProvider? = nil, hooks: [HookDefinition] = [],
                 settingsManager: SettingsManager? = nil,
                 customTools: [CustomToolDefinition]? = nil) async throws -> AgentSession {
        try await createAgentSession(CreateAgentSessionOptions(
            cwd: directory.path, agentDir: directory.path, authStorage: auth, modelRegistry: registry,
            model: try model(), offline: true, toolNames: customTools?.map { $0.tool.name },
            noTools: .all, customTools: customTools, resourceLoader: TestResourceLoader(),
            hooks: hooks, noExtensions: true, sessionManager: .inMemory(), settingsManager: settingsManager ?? settings,
            clientIdentityProvider: identity)).session
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

// The process-environment trait holds the shared gate for each complete async test.
private func a1cEnvironment<Result>(_ telemetry: String? = nil, offline: String? = nil,
                                    _ body: () async throws -> Result) async rethrows -> Result {
    let keys = ["PI_TELEMETRY", "PI_OFFLINE"]
    let previous = keys.map { ProcessInfo.processInfo.environment[$0] }
    for (key, value) in zip(keys, [telemetry, offline]) {
        if let value { setenv(key, value, 1) } else { unsetenv(key) }
    }
    defer {
        for (key, value) in zip(keys, previous) {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
    }
    return try await body()
}

private func a1cExpectPi(_ options: SimpleStreamOptions) {
    #expect(options.identity == ClientIdentity(userAgent: .detailed, attribution: .value(PI_ATTRIBUTION), version: VERSION))
}

@Suite("A1c SDK client identity", .serialized, .timeLimit(.minutes(1)))
struct A1cSDKClientIdentityTests {
    // Upstream sdk-client-identity.test.ts:142.
    @Test(.processEnvironment) func detailedIdentityAndLiteralOpenRouterWireHeaders() async throws {
        try await a1cEnvironment {
            let fixture = try A1cFixture(http: true)
            defer { fixture.remove() }
            let session = try await fixture.session()
            defer { session.dispose() }
            try await session.prompt("hello")
            a1cExpectPi(try #require(fixture.calls.withLock { $0.first }))
            let request = try #require(fixture.wire.withLock { $0.first })
            #if os(macOS) && arch(arm64)
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "pi/\(VERSION) (darwin; swift; arm64)")
            #else
            #expect(request.value(forHTTPHeaderField: "User-Agent") == formatUserAgent(identity: ClientIdentity(version: VERSION)))
            #endif
            #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == "https://pi.dev")
            #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Title") == "pi")
            #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Categories") == "cli-agent")
        }
    }

    // Upstream :158, :166, plus PI_OFFLINE and a live setting change.
    @Test(.processEnvironment) func settingsAndEnvironmentDisableAttributionPerRequest() async throws {
        try await a1cEnvironment {
            let fixture = try A1cFixture(http: true)
            defer { fixture.remove() }
            let session = try await fixture.session()
            defer { session.dispose() }
            for enabled in [true, false, true] {
                fixture.settings.setInstallTelemetryEnabled(enabled)
                try await session.prompt("hello")
                let options = try #require(fixture.calls.withLock { $0.last })
                #expect(options.identity?.attribution == (enabled ? .value(PI_ATTRIBUTION) : .disabled))
                let request = try #require(fixture.wire.withLock { $0.last })
                for name in ["HTTP-Referer", "X-OpenRouter-Title", "X-OpenRouter-Categories"] {
                    #expect((request.value(forHTTPHeaderField: name) != nil) == enabled)
                }
                #expect(request.value(forHTTPHeaderField: "User-Agent") == formatUserAgent(identity: ClientIdentity(version: VERSION)))
            }
            for (telemetry, offline) in [("0", "0"), ("1", "1")] {
                try await a1cEnvironment(telemetry, offline: offline) {
                    try await session.prompt("disabled by environment")
                    #expect(fixture.calls.withLock { $0.last?.identity?.attribution } == .disabled)
                    #expect(fixture.wire.withLock { $0.last?.value(forHTTPHeaderField: "HTTP-Referer") } == nil)
                }
            }
        }
    }

    // Upstream :173, :181. Attribution and session routing are independent.
    @Test(.processEnvironment, arguments: [false, true])
    func customOpenCodeSessionAndConfiguredHeaderWins(configured: Bool) async throws {
        try await a1cEnvironment {
            let headers: ProviderHeaders? = configured ? ["X-OpenCode-Session": "configured-session", "X-OpenCode-Client": "configured-client"] : nil
            let fixture = try A1cFixture(baseUrl: "https://opencode.ai/zen/v1", headers: headers, http: true)
            defer { fixture.remove() }
            let session = try await fixture.session()
            defer { session.dispose() }
            for enabled in [true, false] {
                fixture.settings.setInstallTelemetryEnabled(enabled)
                try await session.prompt("hello")
                let request = try #require(fixture.wire.withLock { $0.last })
                #expect(request.value(forHTTPHeaderField: "x-opencode-session") == (configured ? "configured-session" : session.sessionManager.getSessionId()))
                #expect(request.value(forHTTPHeaderField: "x-opencode-client") == (configured ? "configured-client" : enabled ? "pi" : nil))
            }
        }
    }

    @Test(.processEnvironment) func literalNvidiaAndSessionlessOpenCodeAttribution() async throws {
        try await a1cEnvironment {
            for (provider, baseUrl, name, value) in [
                ("custom-nvidia", "https://integrate.api.nvidia.com/v1", "X-BILLING-INVOKE-ORIGIN", "Pi"),
                ("nvidia", "https://provider.example/v1", "X-BILLING-INVOKE-ORIGIN", "Pi"),
                ("custom-opencode", "https://opencode.ai/zen/v1", "x-opencode-client", "pi")
            ] {
                let fixture = try A1cFixture(baseUrl: baseUrl, provider: provider, http: true)
                defer { fixture.remove() }
                let session = try await fixture.session()
                defer { session.dispose() }
                _ = await session.modelRegistry.streamSimple(model: try fixture.model(), context: Context(messages: []), options: SimpleStreamOptions(identity: session.resolveClientIdentity())).result()
                let request = try #require(fixture.wire.withLock { $0.last })
                #expect(request.value(forHTTPHeaderField: name) == value)
                #expect(request.value(forHTTPHeaderField: "x-opencode-session") == nil)
                fixture.settings.setInstallTelemetryEnabled(false)
                _ = await session.modelRegistry.streamSimple(model: try fixture.model(), context: Context(messages: []),
                    options: SimpleStreamOptions(identity: session.resolveClientIdentity())).result()
                #expect(fixture.wire.withLock { $0.last?.value(forHTTPHeaderField: name) } == nil)
            }
        }
    }

    @Test(.processEnvironment) func hookCanRemoveUnseenIdentityDefaultsWithMixedCaseNil() async throws {
        try await a1cEnvironment {
            let fixture = try A1cFixture(http: true)
            defer { fixture.remove() }
            let hook = HookDefinition { api in
                api.on("before_provider_headers") { (event: BeforeProviderHeadersEvent, _: HookContext) in
                    let headers = event.headers
                    #expect(!providerHeadersContain(headers, name: "User-Agent"))
                    #expect(!providerHeadersContain(headers, name: "HTTP-Referer"))
                    return BeforeProviderHeadersEventResult(headers: [
                        "uSeR-aGeNt": nil, "hTtP-rEfErEr": nil,
                        "x-oPeNrOuTeR-tItLe": nil, "X-OPENROUTER-CATEGORIES": nil
                    ])
                }
            }
            let session = try await fixture.session(hooks: [hook])
            defer { session.dispose() }
            try await session.prompt("hello")
            let request = try #require(fixture.wire.withLock { $0.first })
            for name in ["User-Agent", "HTTP-Referer", "X-OpenRouter-Title", "X-OpenRouter-Categories"] {
                #expect(request.value(forHTTPHeaderField: name) == nil)
            }
        }
    }

    @Test(.processEnvironment) func hostProviderChangesBetweenRequestsAndDisablesAttribution() async throws {
        try await a1cEnvironment {
            let host = LockedState(ClientIdentity(userAgent: .custom("Xogot/1"), attribution: .disabled))
            let fixture = try A1cFixture(registryIdentity: { ClientIdentity(version: "host-version") }, http: true)
            defer { fixture.remove() }
            let session = try await fixture.session(identity: { host.withLock { $0 } })
            defer { session.dispose() }
            for value in ["Xogot/1", "Xogot/2"] {
                host.withLock { $0.userAgent = .custom(value) }
                try await session.prompt("hello")
                #expect(fixture.calls.withLock { $0.last?.identity?.version } == "host-version")
                let request = try #require(fixture.wire.withLock { $0.last })
                #expect(request.value(forHTTPHeaderField: "User-Agent") == value)
                #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == nil)
            }
        }
    }

    @Test(.processEnvironment) func registryDefaultIsBelowFullSimpleAndPreparedRequestIdentity() async throws {
        try await a1cEnvironment {
            let fixture = try A1cFixture(baseUrl: "https://opencode.ai/zen/v1", registryIdentity: {
                ClientIdentity(userAgent: .short, attribution: .value(PI_ATTRIBUTION), version: "registry")
            })
            defer { fixture.remove() }
            let model = try fixture.model()
            let identity = ClientIdentity(userAgent: .custom("request"), attribution: .disabled)
            let expected = ClientIdentity(userAgent: .custom("request"), attribution: .disabled, version: "registry")
            let context = Context(messages: [])
            _ = await fixture.registry.stream(model: model, context: context, options: StreamOptions(identity: identity)).result()
            _ = await fixture.registry.streamSimple(model: model, context: context, options: SimpleStreamOptions(identity: identity)).result()
            _ = try await fixture.registry.streamSimplePrepared(model: model, context: context,
                options: SimpleStreamOptions(identity: identity, sessionId: "prepared-session")).result()
            #expect(fixture.calls.withLock { $0.map(\.identity) } == [expected, expected, expected])
            _ = await fixture.registry.streamSimple(model: model, context: context).result()
            #expect(fixture.calls.withLock { $0.last?.identity } == ClientIdentity(userAgent: .short, attribution: .value(PI_ATTRIBUTION), version: "registry"))
            #expect(fixture.calls.withLock { providerHeaderValue($0[2].headers, name: "x-opencode-session") } == "prepared-session")
            for headers: ProviderHeaders in [["X-OPENCODE-SESSION": "configured"], ["X-OpenCode-Session": nil]] {
                _ = try await fixture.registry.streamSimplePrepared(model: model, context: context,
                    options: SimpleStreamOptions(sessionId: "prepared-session", headers: headers)).result()
                #expect(fixture.calls.withLock { providerHeaderValue($0.last?.headers, name: "x-opencode-session") } == providerHeaderValue(headers, name: "x-opencode-session"))
                #expect(fixture.calls.withLock { providerHeadersContain($0.last?.headers, name: "x-opencode-session") })
            }
        }
    }

    @Test(.processEnvironment) func compactionAndBranchSummaryUseSDKIdentity() async throws {
        try await a1cEnvironment {
            let fixture = try A1cFixture()
            defer { fixture.remove() }
            let session = try await fixture.session()
            defer { session.dispose() }
            try await session.prompt("hello")
            let entries = session.sessionManager.getBranch()
            _ = try await session.compact()
            let branch = await generateBranchSummary(entries, GenerateBranchSummaryOptions(model: try fixture.model(),
                apiKey: "test-key", signal: nil, customInstructions: nil, reserveTokens: nil, streamFn: session.agent.streamFn))
            #expect(branch.error == nil)
            #expect(fixture.calls.withLock { $0.count } >= 3)
            for options in fixture.calls.withLock({ $0 }) { a1cExpectPi(options) }
        }
    }

    @Test(.processEnvironment) func summaryRetryReadsChangedTelemetry() async throws {
        try await a1cEnvironment {
            let fixture = try A1cFixture(failFirst: true)
            defer { fixture.remove() }
            let hooks = LockedState(0)
            let session = try await fixture.session(hooks: [HookDefinition { api in
                api.on("before_provider_headers") { (_: BeforeProviderHeadersEvent, _: HookContext) in
                    hooks.withLock { $0 += 1 }; return nil
                }
            }])
            defer { session.dispose() }
            let response = try await completeSummarization(model: fixture.model(), context: Context(messages: []),
                options: SimpleStreamOptions(apiKey: "test-key"), streamFn: session.agent.streamFn,
                retry: RetryPolicy(enabled: true, maxRetries: 1, baseDelayMs: 0),
                callbacks: RetryCallbacks(onRetryScheduled: { _, _, _, _ in fixture.settings.setInstallTelemetryEnabled(false) }))
            #expect(response.stopReason == .stop)
            #expect(hooks.withLock { $0 } == 2)
            #expect(fixture.calls.withLock { $0.map { $0.identity?.attribution } } == [.value(PI_ATTRIBUTION), .disabled])
        }
    }

    @Test(.processEnvironment) func sdkCacheWarmerReadsPolicyAtReplayTime() async throws {
        try await a1cEnvironment {
            let fixture = try A1cFixture(baseUrl: "https://opencode.ai/zen/v1")
            defer { fixture.remove() }
            let hooks = LockedState(0)
            let session = try await fixture.session(hooks: [HookDefinition { api in
                api.on("before_provider_headers") { (event: BeforeProviderHeadersEvent, _: HookContext) in
                    #expect(providerHeaderValue(event.headers, name: "x-opencode-session") != nil)
                    hooks.withLock { $0 += 1 }; return nil
                }
                api.on("cache_warming_decision") { (_: CacheWarmingDecisionEvent, _: HookContext) in CacheWarmingDecisionEventResult(action: .warm) }
            }])
            defer { session.dispose() }
            fixture.settings.setCacheWarmingMode(.streaming)
            let warmer = try #require(session.cacheWarmer)
            await warmer.start(CacheWarmRequest(model: try fixture.model(), context: Context(messages: []),
                options: SimpleStreamOptions(identity: ClientIdentity(attribution: .value(PI_ATTRIBUTION)), apiKey: "test-key", sessionId: session.sessionManager.getSessionId())), isCurrent: { true })
            fixture.settings.setInstallTelemetryEnabled(false)
            let deadline = ContinuousClock.now + .seconds(10)
            while fixture.calls.withLock({ $0.isEmpty }) && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            await warmer.cancel()
            let request = try #require(fixture.calls.withLock { $0.first })
            #expect(hooks.withLock { $0 } == 1)
            #expect(request.maxTokens == 1)
            #expect(request.identity == ClientIdentity(userAgent: .detailed, attribution: .disabled, version: VERSION))
        }
    }
}

extension A1cSDKClientIdentityTests {
    // The deleted v1.3.0 provider-attribution cases still define the wire values.
    @Test(.processEnvironment) func explicitHeadersAndGatewaysKeepTheirPrecedence() async throws {
        try await a1cEnvironment {
            let fixture = try A1cFixture(headers: ["HTTP-Referer": "https://provider.example", "X-OpenRouter-Categories": "provider-category"], http: true)
            defer { fixture.remove() }
            let session = try await fixture.session()
            defer { session.dispose() }
            _ = try await session.agent.streamFn(try fixture.model(), normalizeContext(Context(messages: [])),
                SimpleStreamOptions(apiKey: "test-key", headers: ["x-openrouter-title": "request-title"])).result()
            let request = try #require(fixture.wire.withLock { $0.last })
            #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == "https://provider.example")
            #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Title") == "request-title")
            #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Categories") == "provider-category")
            for baseUrl in ["https://openrouter.ai/api/v1", "https://ai-gateway.vercel.sh/v1"] {
                let gateway = try A1cFixture(baseUrl: baseUrl, provider: baseUrl.contains("openrouter.ai") ? "openrouter" : "vercel-ai-gateway", http: true)
                defer { gateway.remove() }
                let gatewaySession = try await gateway.session()
                defer { gatewaySession.dispose() }
                try await gatewaySession.prompt("hello")
                let wire = try #require(gateway.wire.withLock { $0.last })
                #expect(wire.value(forHTTPHeaderField: "X-BILLING-INVOKE-ORIGIN") == nil)
                #expect(wire.value(forHTTPHeaderField: "HTTP-Referer") == (baseUrl.contains("openrouter.ai") ? "https://pi.dev" : nil))
            }
            let nvidia = try A1cFixture(baseUrl: "https://integrate.api.nvidia.com/v1", http: true)
            defer { nvidia.remove() }
            let nvidiaSession = try await nvidia.session()
            defer { nvidiaSession.dispose() }
            _ = try await nvidiaSession.agent.streamFn(try nvidia.model(), normalizeContext(Context(messages: [])),
                SimpleStreamOptions(apiKey: "test-key", headers: ["x-billing-invoke-origin": "Request"])).result()
            #expect(nvidia.wire.withLock { $0.last?.value(forHTTPHeaderField: "X-BILLING-INVOKE-ORIGIN") } == "Request")
            #expect(attributionHeaders(provider: "custom", baseUrl: "not-a-url-openrouter.ai", identity: session.resolveClientIdentity()) == [
                "HTTP-Referer": "https://pi.dev", "X-OpenRouter-Title": "pi", "X-OpenRouter-Categories": "cli-agent"
            ])
        }
    }

    @Test(.processEnvironment) func sdkImageAndClassifierCallsUseLiveRegistryIdentity() async throws {
        try await a1cEnvironment {
            let fixture = try A1cFixture()
            defer { fixture.remove() }
            let session = try await fixture.session()
            defer { session.dispose() }
            let seen = LockedState<[ClientIdentity?]>([])
            fixture.registry.registerProvider(HookProviderConfig(provider: fixture.provider, api: .openAICompletions,
                baseUrl: "https://provider.example/v1", images: [.openrouterImages: { model, _, options in
                    seen.withLock { $0.append(options?.identity) }
                    return AssistantImages(api: model.api, provider: model.provider, model: model.id, stopReason: .stop)
                }], classifiers: [.typesafeSystemOne: { model, _, options in
                    seen.withLock { $0.append(options?.identity) }
                    return ClassifierResult(api: model.api, provider: model.provider, model: model.id)
                }], models: [
                    .image(HookProviderImageModel(id: "image", api: .openrouterImages)),
                    .classifier(HookProviderClassifierModel(id: "classifier", api: .typesafeSystemOne, contextWindow: 4096))
                ]), sourceId: "non-chat")
            guard case .image(let image) = try #require(fixture.registry.getModelOfType(.image, provider: fixture.provider, modelId: "image")),
                  case .classifier(let classifier) = try #require(fixture.registry.getModelOfType(.classifier, provider: fixture.provider, modelId: "classifier")) else {
                Issue.record("Missing non-chat models"); return
            }
            let context = ClassifierContext(state: [:], questions: [:])
            for enabled in [true, false] {
                fixture.settings.setInstallTelemetryEnabled(enabled)
                _ = await session.modelRegistry.generateImages(image, context: ImagesContext(input: []),
                    options: ImagesOptions(identity: session.resolveClientIdentity()))
                _ = await session.modelRegistry.classify(classifier, context: context,
                    options: ClassifierOptions(identity: session.resolveClientIdentity()))
                let expected = ClientIdentity(userAgent: .detailed, attribution: enabled ? .value(PI_ATTRIBUTION) : .disabled, version: VERSION)
                #expect(seen.withLock { Array($0.suffix(2)) } == [expected, expected])
            }
            let identity = ClientIdentity(userAgent: .custom("request"), attribution: .value(PI_ATTRIBUTION))
            _ = await session.modelRegistry.generateImages(image, context: ImagesContext(input: []), options: ImagesOptions(identity: session.resolveClientIdentity(identity)))
            _ = await session.modelRegistry.classify(classifier, context: context, options: ClassifierOptions(identity: session.resolveClientIdentity(identity)))
            let expected = ClientIdentity(userAgent: .custom("request"), attribution: .value(PI_ATTRIBUTION), version: VERSION)
            #expect(seen.withLock { Array($0.suffix(2)) } == [expected, expected])
        }
    }

    @Test(.processEnvironment) func standaloneSummaryUsesCodingAgentVersionAndEnvironment() async throws {
        try await a1cEnvironment {
            let fixture = try A1cFixture()
            defer { fixture.remove() }
            let previous = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"]
            setenv("PI_CODING_AGENT_DIR", fixture.directory.path, 1)
            defer {
                if let previous { setenv("PI_CODING_AGENT_DIR", previous, 1) }
                else { unsetenv("PI_CODING_AGENT_DIR") }
            }
            for telemetry in ["1", "0"] {
                setenv("PI_TELEMETRY", telemetry, 1)
                let result = try await completeSummarization(model: fixture.model(), context: Context(messages: []),
                    options: SimpleStreamOptions(apiKey: "test-key", httpClient: A1cHTTPClient(requests: fixture.wire)))
                #expect(result.stopReason == .stop)
                let request = try #require(fixture.wire.withLock { $0.last })
                #expect(request.value(forHTTPHeaderField: "User-Agent") == formatUserAgent(identity: ClientIdentity(version: VERSION)))
                #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == (telemetry == "1" ? "https://pi.dev" : nil))
            }
        }
    }
}

private struct A1cCatalogClient: ProviderHTTPClient {
    let requests: LockedState<[URLRequest]>
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.withLock { $0.append(request) }
        return ProviderHTTPResponse(statusCode: 404, body: Data())
    }
}

@Test(.timeLimit(.minutes(1))) func a1cCatalogUsesSharedCodingAgentUserAgent() async throws {
    let requests = LockedState<[URLRequest]>([])
    let registry = ModelRegistry(.inMemory(["openai": .apiKey(ApiKeyCredential(key: "test-key"))]), modelsStore: InMemoryCodingAgentModelsStore(),
        remoteHTTPClient: A1cCatalogClient(requests: requests))
    _ = await registry.refresh(ModelsRefreshOptions(providers: ["openai"], force: true))
    let request = try #require(requests.withLock { $0.first })
    #expect(request.value(forHTTPHeaderField: "User-Agent") == formatUserAgent(identity: ClientIdentity(userAgent: .detailed, version: VERSION)))
    // The old private formatter and the shared formatter have these same wire values.
    #if os(macOS)
    let platform = "darwin"
    #elseif os(iOS)
    let platform = "ios"
    #else
    let platform = "swift"
    #endif
    #if arch(arm64)
    let architecture = "arm64"
    #elseif arch(x86_64)
    let architecture = "x64"
    #else
    let architecture = "unknown"
    #endif
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "pi/\(VERSION) (\(platform); swift; \(architecture))")
}

extension A1cSDKClientIdentityTests {
    @Test(.processEnvironment) func sessionsShareCatalogButKeepSeparateIdentityPolicies() async throws {
        try await a1cEnvironment {
            let fixture = try A1cFixture(http: true)
            defer { fixture.remove() }
            fixture.settings.setInstallTelemetryEnabled(false)
            let first = try await fixture.session(identity: { ClientIdentity(userAgent: .custom("first")) })
            defer { first.dispose() }
            var secondSettings = Settings()
            secondSettings.enableInstallTelemetry = true
            secondSettings.cacheWarming = .off
            let second = try await fixture.session(identity: { ClientIdentity(userAgent: .custom("second")) },
                                                   settingsManager: .inMemory(secondSettings))
            defer { second.dispose() }
            #expect(first.modelRegistry === fixture.registry)
            #expect(second.modelRegistry === fixture.registry)
            #expect(fixture.registry.resolveClientIdentity() == nil)
            try await first.prompt("first")
            try await second.prompt("second")
            try await first.prompt("first again")
            let requests = fixture.wire.withLock { $0 }
            #expect(requests.map { $0.value(forHTTPHeaderField: "User-Agent") } == ["first", "second", "first"])
            #expect(requests.map { $0.value(forHTTPHeaderField: "HTTP-Referer") } == [nil, "https://pi.dev", nil])
            fixture.registry.unregisterProviders(sourceId: fixture.provider)
            #expect(first.modelRegistry.find(fixture.provider, "chat") == nil)
            #expect(second.modelRegistry.find(fixture.provider, "chat") == nil)
        }
    }

    @Test(.processEnvironment) func summaryHookRunsOnceAtTheFinalBoundary() async throws {
        try await a1cEnvironment {
            let fixture = try A1cFixture(baseUrl: "https://opencode.ai/zen/v1", http: true)
            defer { fixture.remove() }
            let calls = LockedState(0)
            let session = try await fixture.session(hooks: [HookDefinition { api in
                api.on("before_provider_headers") { (event: BeforeProviderHeadersEvent, _: HookContext) in
                    #expect(providerHeaderValue(event.headers, name: "x-opencode-session") != nil)
                    calls.withLock { $0 += 1 }
                    return BeforeProviderHeadersEventResult(headers: ["x-OPENCODE-session": nil])
                }
            }])
            defer { session.dispose() }
            try await session.prompt("hello")
            _ = try await session.compact()
            #expect(calls.withLock { $0 } == fixture.wire.withLock { $0.count })
            #expect(calls.withLock { $0 } >= 2)
            #expect(fixture.wire.withLock { $0.allSatisfy { $0.value(forHTTPHeaderField: "x-opencode-session") == nil } })
        }
    }
}

private struct A1cClassifierHTTPClient: ProviderHTTPClient {
    let requests: LockedState<[URLRequest]>
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.withLock { $0.append(request) }
        return ProviderHTTPResponse(statusCode: 400, body: Data(#"{"error":{"message":"captured"}}"#.utf8))
    }
}

extension A1cSDKClientIdentityTests {
    @Test(.processEnvironment) func cloudflareClassifierKeepsDetailedUserAgentWithoutAttribution() async throws {
        try await a1cEnvironment {
            let fixture = try A1cFixture()
            defer { fixture.remove() }
            let session = try await fixture.session()
            defer { session.dispose() }
            let model = ClassifierModel(id: "classifier", name: "Test", api: .cloudflareWorkersAISystemOne,
                provider: fixture.provider, baseUrl: "https://api.cloudflare.com/client/v4/accounts/test/ai/v1",
                input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 4096)
            let context = ClassifierContext(state: ["text": AnyCodable("hello")], questions: [
                "answer": .bool(instructions: "Yes?", trueCriterion: "yes", falseCriterion: "no")
            ])
            for enabled in [true, false] {
                fixture.settings.setInstallTelemetryEnabled(enabled)
                _ = await session.modelRegistry.classify(model, context: context,
                    options: ClassifierOptions(identity: session.resolveClientIdentity(), apiKey: "test-key", httpClient: A1cClassifierHTTPClient(requests: fixture.wire), maxRetries: 0))
                let request = try #require(fixture.wire.withLock { $0.last })
                #expect(request.value(forHTTPHeaderField: "User-Agent") == formatUserAgent(identity: ClientIdentity(version: VERSION)))
                #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == nil)
            }
            #expect(fixture.wire.withLock { $0.count } == 2)
        }
    }
}

extension A1cSDKClientIdentityTests {
    @Test(.processEnvironment) func replacedStreamReceivesHookHeadersForLoopAndSummary() async throws {
        try await a1cEnvironment {
            let fixture = try A1cFixture(baseUrl: "https://opencode.ai/zen/v1")
            defer { fixture.remove() }
            let hooks = LockedState(0)
            let calls = LockedState<[SimpleStreamOptions]>([])
            let session = try await fixture.session(hooks: [HookDefinition { api in
                api.on("before_provider_headers") { (event: BeforeProviderHeadersEvent, _: HookContext) in
                    #expect(providerHeaderValue(event.headers, name: "x-opencode-session") != nil)
                    #expect(!providerHeadersContain(event.headers, name: "User-Agent"))
                    hooks.withLock { $0 += 1 }
                    return BeforeProviderHeadersEventResult(headers: ["X-Extension": "hook"])
                }
            }])
            defer { session.dispose() }
            #expect(session.modelRegistry === fixture.registry)
            session.agent.streamFn = { model, _, options in
                calls.withLock { $0.append(options) }
                return a1cResponse(model)
            }
            try await session.prompt("hello")
            _ = try await session.compact()
            let requests = calls.withLock { $0 }
            #expect(requests.count >= 2)
            #expect(hooks.withLock { $0 } == requests.count)
            #expect(requests.allSatisfy { providerHeaderValue($0.headers, name: "X-Extension") == "hook" })
            a1cExpectPi(try #require(requests.last))
        }
    }

    @Test(.processEnvironment) func requestIdentityFieldsWinOverSDKAndRegistryDefaults() async throws {
        try await a1cEnvironment {
            let fixture = try A1cFixture(registryIdentity: {
                ClientIdentity(userAgent: .short, attribution: .disabled, version: "registry")
            }, http: true)
            defer { fixture.remove() }
            let session = try await fixture.session(identity: {
                ClientIdentity(userAgent: .custom("host"), attribution: .disabled, version: "host")
            })
            defer { session.dispose() }
            let identity = ClientIdentity(userAgent: .custom("request"), attribution: .value(PI_ATTRIBUTION), version: "request")
            _ = try await completeSummarization(model: fixture.model(), context: Context(messages: []),
                options: SimpleStreamOptions(identity: identity, apiKey: "test-key"), streamFn: session.agent.streamFn)
            #expect(fixture.calls.withLock { $0.last?.identity } == identity)
            #expect(fixture.wire.withLock { $0.last?.value(forHTTPHeaderField: "User-Agent") } == "request")
            #expect(fixture.wire.withLock { $0.last?.value(forHTTPHeaderField: "HTTP-Referer") } == "https://pi.dev")
        }
    }

    @Test(.processEnvironment) func codemodeUsesEachSDKSessionIdentityWithTheSameRegistry() async throws {
        try await a1cEnvironment {
            let fixture = try A1cFixture()
            defer { fixture.remove() }
            let contexts = LockedState<[CustomToolContext]>([])
            let capture = CustomToolDefinition(tool: CustomTool(name: "a1c_capture", label: "Capture", description: "Capture context",
                parameters: [:], execute: { _, _, _, context, _ in
                    contexts.withLock { $0.append(context) }
                    return AgentToolResult(content: [])
                }))
            let first = try await fixture.session(identity: { ClientIdentity(userAgent: .custom("first"), attribution: .disabled) },
                                                  customTools: [capture])
            defer { first.dispose() }
            let second = try await fixture.session(identity: { ClientIdentity(userAgent: .custom("second")) }, customTools: [capture])
            defer { second.dispose() }
            for session in [first, second] {
                let tool = try #require(session.getCallableTools().first { $0.name == "a1c_capture" })
                _ = try await tool.execute("capture", [:], nil, nil)
            }
            let seen = LockedState<[ClientIdentity?]>([])
            fixture.registry.registerProvider(HookProviderConfig(provider: fixture.provider, api: .openAICompletions,
                baseUrl: "https://provider.example/v1", images: [.openrouterImages: { model, _, options in
                    seen.withLock { $0.append(options?.identity) }
                    return AssistantImages(api: model.api, provider: model.provider, model: model.id, stopReason: .stop)
                }], classifiers: [.typesafeSystemOne: { model, _, options in
                    seen.withLock { $0.append(options?.identity) }
                    return ClassifierResult(api: model.api, provider: model.provider, model: model.id)
                }], models: [
                    .image(HookProviderImageModel(id: "image", api: .openrouterImages)),
                    .classifier(HookProviderClassifierModel(id: "classifier", api: .typesafeSystemOne, contextWindow: 4096))
                ]), sourceId: "non-chat")
            let captured = contexts.withLock { $0 }
            #expect(captured.count == 2)
            for (index, context) in captured.enumerated() {
                #expect(context.modelRegistry === fixture.registry)
                let code = """
                await models.classify({provider:'\(fixture.provider)',id:'classifier'}, {state:{},questions:{ok:{type:'bool',instructions:'Check',criteria:{true:'yes',false:'no'}}}});
                await models.generateImages({provider:'\(fixture.provider)',id:'image'}, {input:[{type:'text',text:'Draw'}]});
                """
                let result = try await executeCodemode(toolCallId: "identity-\(index)", params: ["code": AnyCodable(code)],
                    context: context, options: CodemodeToolOptions(models: true))
                #expect(result.isError != true)
                let expected = ClientIdentity(userAgent: .custom(index == 0 ? "first" : "second"),
                    attribution: index == 0 ? .disabled : .value(PI_ATTRIBUTION), version: VERSION)
                #expect(seen.withLock { Array($0.suffix(2)) } == [expected, expected])
            }
        }
    }
}
