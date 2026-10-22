import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

private struct A3CatalogClient: ProviderHTTPClient {
    let handler: @Sendable (URLRequest) async throws -> ProviderHTTPResponse

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        try await handler(request)
    }
}

private enum A3CatalogFailure: Error { case personalization }

private func a3Chat(_ id: String, name: String? = nil, provider: String = "openrouter") -> Model {
    Model(id: id, name: name ?? id, api: .openAICompletions, provider: provider,
        baseUrl: "https://openrouter.ai/api/v1", reasoning: false, input: [.text],
        cost: ModelCost(input: 1, output: 2, cacheRead: 0, cacheWrite: 0),
        contextWindow: 32_000, maxTokens: 4_000)
}

private func a3Image(_ id: String, provider: String = "openrouter") -> AnyModel {
    .image(ImageModel(id: id, name: id, api: .openrouterImages, provider: provider,
        baseUrl: "https://openrouter.ai/api/v1", input: [.text], output: [.image],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)))
}

private func a3Classifier(_ id: String) -> AnyModel {
    .classifier(ClassifierModel(id: id, name: id, api: .typesafeSystemOne, provider: "openrouter",
        baseUrl: "https://openrouter.ai/api/v1", input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 1_000))
}

private func a3PublicResponse(_ models: [AnyModel], lastModified: String? = nil) throws -> ProviderHTTPResponse {
    var headers = ["ETag": "\"public-etag\""]
    if let lastModified { headers["Last-Modified"] = lastModified }
    return ProviderHTTPResponse(statusCode: 200, headers: headers, body: try JSONEncoder().encode(models))
}

private func a3UserResponse(_ ids: [String]) throws -> ProviderHTTPResponse {
    ProviderHTTPResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: [
        "data": ids.map { ["id": $0] }
    ]))
}

private func a3JSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}

private func a3ModelJSON(_ models: [AnyModel]) throws -> Data {
    try a3JSON(models.sorted { "\($0.type.rawValue)\0\($0.id)" < "\($1.type.rawValue)\0\($1.id)" })
}

private func a3Directory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-a3-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func a3Registry(_ store: any ModelsStore, client: any ProviderHTTPClient,
                        directory: URL? = nil, auth: AuthStorage? = nil,
                        networkEnabled: Bool = true) -> ModelRegistry {
    ModelRegistry(auth ?? AuthStorage.inMemory(["openrouter": .apiKey(ApiKeyCredential(key: "a3-key"))]),
        directory?.path, modelsStore: store, catalogBaseURL: "https://catalog.example.invalid",
        remoteHTTPClient: client, networkEnabled: networkEnabled, now: { 2_200_000_000_000 })
}

private func a3Coordinator(_ store: any ModelsStore, client: any ProviderHTTPClient,
                           overlay: LockedState<[AnyModel]>, builtins: [AnyModel] = [.chat(a3Chat("static"))],
                           personalize: @escaping @Sendable ([AnyModel], RefreshModelsContext) async throws -> [AnyModel]) -> ModelCatalogRefreshCoordinator {
    let remote = RemoteCatalogProvider(providerId: "openrouter", localGeneratedAt: 1_000,
        httpClient: client, now: { 2_000 }, builtinModels: { builtins }, personalize: personalize,
        updateOverlay: { models in overlay.withLock { $0 = models } })
    return ModelCatalogRefreshCoordinator(store: store, sources: [ModelsRefreshSource(id: "openrouter",
        readStoredCredential: { "key" }, resolveCredential: { _ in "key" }, refresh: remote.refresh)])
}

// Port v1.3.0 remote-catalog-provider.test.ts:313. A failed key request must not save a public list.
@Test(.timeLimit(.minutes(1)), arguments: [404, 501])
func a3PersonalizationFailureKeepsSavedListAndFile(status: Int) async throws {
    let directory = try a3Directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("models-store.json")
    let saved = ModelsStoreEntry(models: [a3Chat("allowed")], lastModified: 1, checkedAt: 1, etag: "old")
    let store = FileModelsStore(path.path)
    try await store.write(providerId: "openrouter", entry: saved)
    let original = try Data(contentsOf: path)
    let overlay = LockedState<[AnyModel]>([])
    let coordinator = a3Coordinator(store, client: A3CatalogClient { _ in
        ProviderHTTPResponse(statusCode: status, body: Data())
    }, overlay: overlay, personalize: { _, _ in throw A3CatalogFailure.personalization })

    let result = await coordinator.refresh()
    #expect(result.errors["openrouter"] != nil)
    #expect(overlay.withLock { $0.map(\.id) } == ["allowed"])
    #expect(try a3JSON(try await store.read(providerId: "openrouter")) == a3JSON(saved))
    #expect(try Data(contentsOf: path) == original)
}

@Test(.timeLimit(.minutes(1)), arguments: [304, 400, 404, 501])
func a3PublicFailureDoesNotWriteUnpersonalizedCatalog(status: Int) async throws {
    let saved = ModelsStoreEntry(models: [a3Chat("allowed")], checkedAt: 1)
    let store = InMemoryCodingAgentModelsStore(entries: ["openrouter": saved])
    let overlay = LockedState<[AnyModel]>([])
    let called = LockedState(false)
    let coordinator = a3Coordinator(store, client: A3CatalogClient { _ in
        ProviderHTTPResponse(statusCode: status, body: Data())
    }, overlay: overlay, personalize: { _, _ in
        called.withLock { $0 = true }
        throw A3CatalogFailure.personalization
    })
    let result = await coordinator.refresh()
    #expect(result.errors["openrouter"] != nil)
    #expect(called.withLock { $0 } == (status == 404 || status == 501))
    #expect(overlay.withLock { $0.map(\.id) } == ["allowed"])
    #expect(try a3JSON(try await store.read(providerId: "openrouter")) == a3JSON(saved))
}

// Port v1.3.0 remote-catalog-provider.test.ts:329; a saved image list has no chat fallback.
@Test(.timeLimit(.minutes(1))) func a3OfflineRestoreKeepsStaleSavedListAndFiltersOtherProviders() async throws {
    let saved = ModelsStoreEntry(models: [a3Image("only-image"), .chat(a3Chat("wrong", provider: "openai"))],
        lastModified: 1, checkedAt: 1)
    let store = InMemoryCodingAgentModelsStore(entries: ["openrouter": saved])
    let registry = a3Registry(store, client: A3CatalogClient { _ in
        Issue.record("Offline restore sent an HTTP request")
        return ProviderHTTPResponse(statusCode: 400, body: Data())
    })
    let result = await registry.refresh(.init(allowNetwork: false, providers: ["openrouter"]))
    #expect(result.errors.isEmpty)
    #expect(registry.getAll().filter { $0.provider == "openrouter" }.isEmpty)
    #expect(registry.getAllModels(provider: "openrouter").map(\.id) == ["only-image"])
    #expect(await registry.getAvailable().filter { $0.provider == "openrouter" }.isEmpty)
    #expect(await registry.getAllAvailable(provider: "openrouter").map(\.id) == ["only-image"])
    #expect(try a3JSON(try await store.read(providerId: "openrouter")) == a3JSON(saved))
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func a3MissingOrEmptySavedListUsesAllBuiltins(hasEntry: Bool) async throws {
    let store = InMemoryCodingAgentModelsStore(entries: hasEntry ? [
        "openrouter": ModelsStoreEntry(models: [AnyModel](), checkedAt: 1)
    ] : [:])
    let registry = a3Registry(store, client: A3CatalogClient { _ in
        Issue.record("Offline restore sent an HTTP request")
        return ProviderHTTPResponse(statusCode: 400, body: Data())
    })
    let result = await registry.refresh(.init(allowNetwork: false, providers: ["openrouter"]))
    #expect(result.errors.isEmpty)
    let builtin = PiSwiftAI.getAllModels().filter { $0.provider == "openrouter" }
    #expect(!builtin.isEmpty)
    #expect(try a3ModelJSON(registry.getAllModels(provider: "openrouter")) == a3ModelJSON(builtin))
    #expect(Set(registry.getAll().filter { $0.provider == "openrouter" }.map(\.id)) == Set(builtin.compactMap { model in
        if case .chat(let chat) = model { return chat.id }
        return nil
    }))
}

@Test(.timeLimit(.minutes(1))) func a3SavedCatalogReplacesAllTypesAndKeepsOtherProviders() async throws {
    let saved: [AnyModel] = [.chat(a3Chat("saved-chat")), a3Image("saved-image"), a3Classifier("saved-classifier")]
    let registry = a3Registry(InMemoryCodingAgentModelsStore(entries: [
        "openrouter": ModelsStoreEntry(models: saved, lastModified: 1)
    ]), client: A3CatalogClient { _ in
        Issue.record("Offline restore sent an HTTP request")
        return ProviderHTTPResponse(statusCode: 400, body: Data())
    })
    let other = registry.getAllModels(provider: "openai")
    _ = await registry.refresh(.init(allowNetwork: false, providers: ["openrouter"]))
    #expect(try a3ModelJSON(registry.getAllModels(provider: "openrouter")) == a3ModelJSON(saved))
    #expect(registry.getAll().filter { $0.provider == "openrouter" }.map(\.id) == ["saved-chat"])
    #expect(registry.getModelsOfType(.image, provider: "openrouter").map(\.id) == ["saved-image"])
    #expect(registry.getModelsOfType(.classifier, provider: "openrouter").map(\.id) == ["saved-classifier"])
    #expect(try a3ModelJSON(registry.getAllModels(provider: "openai")) == a3ModelJSON(other))
}

@Test(.timeLimit(.minutes(1)), arguments: ["Thu, 01 Jan 1970 00:00:02 GMT", "Thu, 01 Jan 1970 00:00:01 GMT"])
func a3PersonalizationGetsBuiltinsMergedOnlyWithNewerPublicModels(lastModified: String) async throws {
    let observed = LockedState<[AnyModel]>([])
    let overlay = LockedState<[AnyModel]>([])
    let store = InMemoryCodingAgentModelsStore()
    let builtins: [AnyModel] = [.chat(a3Chat("static")), a3Image("image"), a3Classifier("classifier")]
    let remote: [AnyModel] = [.chat(a3Chat("static", name: "Remote static")), .chat(a3Chat("new"))]
    let coordinator = a3Coordinator(store, client: A3CatalogClient { _ in
        try a3PublicResponse(remote, lastModified: lastModified)
    }, overlay: overlay, builtins: builtins, personalize: { models, context in
        #expect(context.credential == "key")
        observed.withLock { $0 = models }
        return [a3Image("personal")]
    })
    let result = await coordinator.refresh()
    #expect(result.errors.isEmpty)
    let newer = lastModified.contains("00:00:02")
    #expect(observed.withLock { $0.map(\.id) } == (newer ? ["static", "image", "classifier", "new"] : ["static", "image", "classifier"]))
    #expect(observed.withLock { $0.first?.catalog.name } == (newer ? "Remote static" : "static"))
    #expect(overlay.withLock { $0.map(\.id) } == ["personal"])
    let entry = try #require(try await store.read(providerId: "openrouter"))
    #expect(entry.models.map(\.id) == ["personal"])
    #expect(entry.checkedAt == 2_000)
    #expect(entry.etag == nil)
    #expect(entry.lastModified == nil)
}

@Test(.timeLimit(.minutes(1))) func a3RefreshRepeatsBothRequestsWithoutThrottleOrValidator() async throws {
    let allowed = try #require(getModels(provider: .openrouter).first)
    let requests = LockedState<[URLRequest]>([])
    let store = InMemoryCodingAgentModelsStore(entries: ["openrouter": ModelsStoreEntry(
        models: [allowed], lastModified: 2_100_000_000_000, checkedAt: 2_200_000_000_000, etag: "old-public")])
    let registry = a3Registry(store, client: A3CatalogClient { request in
        requests.withLock { $0.append(request) }
        if request.url?.path.hasSuffix("/models/user") == true { return try a3UserResponse([allowed.id]) }
        return try a3PublicResponse([], lastModified: "Wed, 12 Aug 2037 12:00:00 GMT")
    })
    for _ in 0..<2 {
        let result = await registry.refresh(.init(providers: ["openrouter"]))
        #expect(result.errors.isEmpty)
    }
    let recorded = requests.withLock { $0 }
    #expect(recorded.count == 4)
    #expect(recorded.filter { $0.url?.path.hasSuffix("/models/user") == true }.count == 2)
    #expect(recorded.allSatisfy { $0.value(forHTTPHeaderField: "If-None-Match") == nil })
    #expect(registry.getAll().filter { $0.provider == "openrouter" }.map(\.id) == [allowed.id])
    #expect(try await store.read(providerId: "openrouter")?.etag == nil)
}

@Test(.timeLimit(.minutes(1))) func a3RegionalConfiguredURLAndChangedKeyApplyOnEachRefresh() async throws {
    let directory = try a3Directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appendingPathComponent("models.json")
    try Data(#"{"providers":{"openrouter":{"baseUrl":"https://us.openrouter.example.invalid/api/v1///"}}}"#.utf8).write(to: config)
    let models = Array(getModels(provider: .openrouter).prefix(2))
    #expect(models.count == 2)
    let first = try #require(models.first)
    let second = try #require(models.last)
    let requests = LockedState<[URLRequest]>([])
    let auth = AuthStorage.inMemory(["openrouter": .apiKey(ApiKeyCredential(key: "first-key"))])
    let registry = a3Registry(InMemoryCodingAgentModelsStore(), client: A3CatalogClient { request in
        requests.withLock { $0.append(request) }
        if request.url?.path.hasSuffix("/models/user") == true {
            let id = request.value(forHTTPHeaderField: "Authorization") == "Bearer first-key" ? first.id : second.id
            return try a3UserResponse([id])
        }
        return ProviderHTTPResponse(statusCode: 404, body: Data())
    }, directory: directory, auth: auth)
    #expect((await registry.refresh(.init(providers: ["openrouter"]))).errors.isEmpty)
    #expect(registry.getAll().filter { $0.provider == "openrouter" }.map(\.id) == [first.id])
    auth.set("openrouter", credential: .apiKey(ApiKeyCredential(key: "second-key")))
    try Data(#"{"providers":{"openrouter":{"baseUrl":"https://eu.openrouter.example.invalid/api/v1/"}}}"#.utf8).write(to: config)
    #expect((await registry.refresh(.init(providers: ["openrouter"]))).errors.isEmpty)
    #expect(registry.getAll().filter { $0.provider == "openrouter" }.map(\.id) == [second.id])
    let userRequests = requests.withLock { $0.filter { $0.url?.path.hasSuffix("/models/user") == true } }
    #expect(userRequests.map { $0.url?.absoluteString } == [
        "https://us.openrouter.example.invalid/api/v1/models/user", "https://eu.openrouter.example.invalid/api/v1/models/user"
    ])
    #expect(userRequests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer first-key", "Bearer second-key"])
}

@Test(.timeLimit(.minutes(1))) func a3OfflineRestoreDoesNotResolveConfiguredKeyCommand() async throws {
    let directory = try a3Directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("key-command-ran")
    let config: [String: Any] = ["providers": ["openrouter": ["apiKey": "!touch '\(marker.path)'; printf key"]]]
    try JSONSerialization.data(withJSONObject: config).write(to: directory.appendingPathComponent("models.json"))
    let registry = a3Registry(InMemoryCodingAgentModelsStore(entries: ["openrouter": ModelsStoreEntry(models: [a3Chat("saved")])]),
        client: A3CatalogClient { _ in
            Issue.record("Offline restore sent an HTTP request")
            return ProviderHTTPResponse(statusCode: 400, body: Data())
        }, directory: directory, auth: AuthStorage.inMemory(), networkEnabled: false)
    #expect((await registry.refresh(.init(providers: ["openrouter"]))).errors.isEmpty)
    #expect(registry.getAll().filter { $0.provider == "openrouter" }.map(\.id) == ["saved"])
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test(.timeLimit(.minutes(1))) func a3ConfiguredModelsAndOverridesApplyAfterSavedReplacement() async throws {
    let directory = try a3Directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = #"{"providers":{"openrouter":{"baseUrl":"https://regional.example.invalid/v1","modelOverrides":{"saved":{"name":"Configured saved","contextWindow":777}},"models":[{"id":"custom","name":"Custom","api":"openai-completions","contextWindow":2048,"maxTokens":256}]}}}"#
    try Data(config.utf8).write(to: directory.appendingPathComponent("models.json"))
    let registry = a3Registry(InMemoryCodingAgentModelsStore(entries: ["openrouter": ModelsStoreEntry(models: [a3Chat("saved")])]),
        client: A3CatalogClient { _ in ProviderHTTPResponse(statusCode: 400, body: Data()) }, directory: directory)
    #expect((await registry.refresh(.init(allowNetwork: false, providers: ["openrouter"]))).errors.isEmpty)
    let chats = registry.getAll().filter { $0.provider == "openrouter" }
    #expect(chats.map(\.id) == ["saved", "custom"])
    #expect(registry.find("openrouter", "saved")?.name == "Configured saved")
    #expect(registry.find("openrouter", "saved")?.contextWindow == 777)
    #expect(chats.allSatisfy { $0.baseUrl == "https://regional.example.invalid/v1" })
    #expect(registry.getAllModels(provider: "openrouter").map(\.id) == ["saved", "custom"])
}

@Test(.timeLimit(.minutes(1))) func a3SDKAndEnabledModelsUseTheSavedReplacement() async throws {
    let directory = try a3Directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let auth = AuthStorage.inMemory(["openrouter": .apiKey(ApiKeyCredential(key: "key"))])
    let registry = a3Registry(InMemoryCodingAgentModelsStore(entries: ["openrouter": ModelsStoreEntry(models: [a3Chat("allowed")])]),
        client: A3CatalogClient { _ in
            Issue.record("Offline SDK sent an HTTP request")
            return ProviderHTTPResponse(statusCode: 400, body: Data())
        }, auth: auth, networkEnabled: false)
    _ = await registry.refresh(.init(allowNetwork: false, providers: ["openrouter"]))
    var settings = Settings()
    settings.enabledModels = ["openrouter/*"]
    let manager = SettingsManager.inMemory(settings)
    let scoped = await resolveModelScope(manager.getEnabledModels() ?? [], registry)
    #expect(scoped.map { $0.model.id } == ["allowed"])
    let created = try await createAgentSession(CreateAgentSessionOptions(cwd: directory.path, agentDir: directory.path,
        authStorage: auth, modelRegistry: registry, scopedModels: scoped, offline: true, noTools: .all,
        resourceLoader: TestResourceLoader(), hooks: [], inlineExtensions: [], noExtensions: true,
        sessionManager: .inMemory(), settingsManager: manager))
    defer { created.session.dispose() }
    #expect(await created.session.getAvailableModels().filter { $0.provider == "openrouter" }.map(\.id) == ["allowed"])
    #expect(created.session.agent.state.model.id == "allowed")
}

private actor A3CatalogGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@Test(.timeLimit(.minutes(1))) func a3OldPersonalizationCannotReplaceANewerRefresh() async throws {
    let gate = A3CatalogGate()
    let calls = LockedState(0)
    let started = LockedState(false)
    let overlay = LockedState<[AnyModel]>([])
    let store = InMemoryCodingAgentModelsStore()
    let coordinator = a3Coordinator(store, client: A3CatalogClient { _ in
        ProviderHTTPResponse(statusCode: 404, body: Data())
    }, overlay: overlay, personalize: { _, _ in
        let call = calls.withLock { value in value += 1; return value }
        if call == 1 {
            started.withLock { $0 = true }
            await gate.wait()
            return [.chat(a3Chat("old-key-list"))]
        }
        return [.chat(a3Chat("new-key-list"))]
    })
    let first = Task { await coordinator.refresh() }
    while !started.withLock({ $0 }) { await Task.yield() }
    let latest = await coordinator.refresh()
    #expect(latest.errors.isEmpty)
    #expect(overlay.withLock { $0.map(\.id) } == ["new-key-list"])
    await gate.release()
    _ = await first.value
    #expect(overlay.withLock { $0.map(\.id) } == ["new-key-list"])
    #expect(try await store.read(providerId: "openrouter")?.models.map(\.id) == ["new-key-list"])
}

@Test(.timeLimit(.minutes(1))) func a3EmptyPersonalizationPublishesAndSavesAnEmptyList() async throws {
    let store = InMemoryCodingAgentModelsStore(entries: ["openrouter": ModelsStoreEntry(models: [a3Chat("old")])])
    let overlay = LockedState<[AnyModel]>([])
    let coordinator = a3Coordinator(store, client: A3CatalogClient { _ in
        ProviderHTTPResponse(statusCode: 404, body: Data())
    }, overlay: overlay, personalize: { _, _ in [] })
    #expect((await coordinator.refresh()).errors.isEmpty)
    #expect(overlay.withLock { $0.isEmpty })
    let entry = try #require(try await store.read(providerId: "openrouter"))
    #expect(entry.models.isEmpty)
    #expect(entry.checkedAt == 2_000)
    #expect(entry.lastModified == nil)
    #expect(entry.etag == nil)
}

@Test(.timeLimit(.minutes(1)), arguments: ["null", "{", #"[{"id":"broken"}]"#])
func a3InvalidPublicCatalogKeepsSavedList(payload: String) async throws {
    let saved = ModelsStoreEntry(models: [a3Chat("saved")], checkedAt: 1)
    let store = InMemoryCodingAgentModelsStore(entries: ["openrouter": saved])
    let overlay = LockedState<[AnyModel]>([])
    let called = LockedState(false)
    let coordinator = a3Coordinator(store, client: A3CatalogClient { _ in
        ProviderHTTPResponse(statusCode: 200, body: Data(payload.utf8))
    }, overlay: overlay, personalize: { models, _ in
        called.withLock { $0 = true }
        return models
    })
    #expect((await coordinator.refresh()).errors["openrouter"] != nil)
    #expect(!called.withLock { $0 })
    #expect(overlay.withLock { $0.map(\.id) } == ["saved"])
    #expect(try a3JSON(try await store.read(providerId: "openrouter")) == a3JSON(saved))
}
