import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

private struct CatalogStubHTTPClient: ProviderHTTPClient {
    let handler: @Sendable (URLRequest) async throws -> ProviderHTTPResponse

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        try await handler(request)
    }
}

private actor CatalogGate {
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

private func catalogModel(
    id: String,
    name: String,
    provider: String = "openai"
) -> Model {
    Model(
        id: id,
        name: name,
        api: .openAIResponses,
        provider: provider,
        baseUrl: "https://api.example.invalid/v1",
        reasoning: false,
        input: [.text],
        cost: ModelCost(input: 1, output: 2, cacheRead: 0, cacheWrite: 0),
        contextWindow: 128_000,
        maxTokens: 16_384
    )
}

private func catalogBody(_ models: [Model]) throws -> Data {
    try JSONEncoder().encode(models)
}

private func catalogResponse(
    status: Int,
    models: [Model] = [],
    etag: String? = nil,
    lastModified: String? = nil
) throws -> ProviderHTTPResponse {
    var headers: [String: String] = [:]
    if let etag { headers["ETag"] = etag }
    if let lastModified { headers["Last-Modified"] = lastModified }
    return ProviderHTTPResponse(
        statusCode: status,
        headers: headers,
        body: status == 200 ? try catalogBody(models) : Data()
    )
}

private func catalogAuth() -> AuthStorage {
    AuthStorage.inMemory(["openai": .apiKey(ApiKeyCredential(key: "test-key"))])
}

private func catalogRegistry(
    store: any ModelsStore,
    client: any ProviderHTTPClient,
    modelsDir: String? = nil,
    networkEnabled: Bool = true,
    now: @escaping @Sendable () -> Double = { 2_200_000_000_000 }
) -> ModelRegistry {
    ModelRegistry(
        catalogAuth(),
        modelsDir,
        modelsStore: store,
        catalogBaseURL: "https://catalog.example.invalid",
        remoteHTTPClient: client,
        networkEnabled: networkEnabled,
        now: now
    )
}

@Test func fileModelsStoreRoundTripConcurrentWritesAndCancellation() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-model-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("models-store.json").path
    let backend = FileAuthStorageBackend(path)
    let store = FileModelsStore(path: path, storage: backend)

    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<24 {
            group.addTask {
                try await store.write(
                    providerId: "provider-\(index)",
                    entry: ModelsStoreEntry(models: [catalogModel(id: "model-\(index)", name: "Model \(index)")]),
                    signal: nil
                )
            }
        }
        try await group.waitForAll()
    }
    let rawEntries = try JSONDecoder().decode(
        [String: ModelsStoreEntry].self,
        from: Data(contentsOf: URL(fileURLWithPath: path))
    )
    #expect(rawEntries.count == 24)
    for index in 0..<24 {
        let entry = try #require(try await store.read(providerId: "provider-\(index)", signal: nil))
        #expect(entry.models.first?.id == "model-\(index)")
    }

    let cancelled = CancellationToken()
    cancelled.cancel()
    await #expect(throws: (any Error).self) {
        try await store.write(
            providerId: "cancelled",
            entry: ModelsStoreEntry(models: [catalogModel(id: "bad", name: "Bad")]),
            signal: cancelled
        )
    }
    #expect(try await store.read(providerId: "cancelled", signal: nil) == nil)
    await #expect(throws: (any Error).self) {
        try await store.read(providerId: "provider-0", signal: cancelled)
    }

    let gate = CatalogGate()
    let lockHeld = LockedState(false)
    let blocker = Task {
        try await backend.withLockAsync { _ in
            lockHeld.withLock { $0 = true }
            await gate.wait()
            return AuthStorageLockResult(result: ())
        }
    }
    while !lockHeld.withLock({ $0 }) { await Task.yield() }
    let inFlightSignal = CancellationToken()
    let inFlightWrite = Task {
        try await store.write(
            providerId: "cancelled-in-flight",
            entry: ModelsStoreEntry(models: [catalogModel(id: "late", name: "Late")]),
            signal: inFlightSignal
        )
    }
    try? await Task.sleep(for: .milliseconds(30))
    inFlightSignal.cancel()
    await gate.release()
    try await blocker.value
    await #expect(throws: (any Error).self) { try await inFlightWrite.value }
    #expect(try await store.read(providerId: "cancelled-in-flight", signal: nil) == nil)
}

@Test func managementFetchRetriesTransientStatusesWithSharedRetryDriver() async throws {
    let attempts = LockedState(0)
    let client = CatalogStubHTTPClient { _ in
        let attempt = attempts.withLock { value -> Int in
            value += 1
            return value
        }
        return ProviderHTTPResponse(
            statusCode: attempt == 1 ? 425 : 200,
            body: Data("ok".utf8)
        )
    }
    let response = try await fetchWithRetry(
        URLRequest(url: URL(string: "https://catalog.example.invalid/test")!),
        client: client
    )
    #expect(response.statusCode == 200)
    #expect(response.body == Data("ok".utf8))
    #expect(attempts.withLock { $0 } == 2)
}

@Test func remoteCatalog200PublishesAndPersistsMetadata() async throws {
    let store = InMemoryCodingAgentModelsStore()
    let requests = LockedState<[URLRequest]>([])
    let client = CatalogStubHTTPClient { request in
        requests.withLock { $0.append(request) }
        return try catalogResponse(
            status: 200,
            models: [catalogModel(id: "remote-new", name: "Remote New")],
            etag: "\"v1\"",
            lastModified: "Wed, 12 Aug 2037 12:00:00 GMT"
        )
    }
    let registry = catalogRegistry(store: store, client: client)
    let result = await registry.refresh(ModelsRefreshOptions(providers: ["openai"], force: true))

    #expect(!result.aborted)
    #expect(result.errors.isEmpty)
    #expect(registry.find("openai", "remote-new")?.name == "Remote New")
    let persisted = try #require(try await store.read(providerId: "openai", signal: nil))
    #expect(persisted.etag == "\"v1\"")
    #expect((persisted.lastModified ?? 0) > (getBuiltinModelDataGeneratedAt() ?? 0))
    #expect(persisted.checkedAt == 2_200_000_000_000)
    #expect(requests.withLock { $0.first?.value(forHTTPHeaderField: "Accept") } == "application/json")
    #expect(requests.withLock { $0.first?.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("pi/") } == true)
}

@Test func remoteCatalogAcceptsAllUpstreamPayloadShapesAndForcesProvider() async throws {
    let model = """
    {
      "id": "shape-model",
      "name": "Shape Model",
      "api": "openai-responses",
      "provider": "wrong-provider",
      "baseUrl": "https://api.example.invalid/v1",
      "reasoning": true,
      "thinkingLevelMap": {"off": null, "high": "high"},
      "input": ["text"],
      "cost": {"input": 1, "output": 2, "cacheRead": 0, "cacheWrite": 0},
      "contextWindow": 128000,
      "maxTokens": 16384,
      "compat": {"openRouterRouting": {"max_price": {"prompt": "1.5"}}}
    }
    """
    let payloads = [
        "[\(model)]",
        "{\"models\":[\(model)]}",
        "{\"shape\":\(model),\"metadata\":\"ignored\"}"
    ]

    for payload in payloads {
        let store = InMemoryCodingAgentModelsStore()
        let client = CatalogStubHTTPClient { _ in
            ProviderHTTPResponse(
                statusCode: 200,
                headers: ["Last-Modified": "Wed, 12 Aug 2037 12:00:00 GMT"],
                body: Data(payload.utf8)
            )
        }
        let registry = catalogRegistry(store: store, client: client)
        let result = await registry.refresh(ModelsRefreshOptions(providers: ["openai"], force: true))
        #expect(result.errors.isEmpty)
        let parsed = try #require(registry.find("openai", "shape-model"))
        #expect(parsed.provider == "openai")
        #expect(parsed.thinkingLevelMap?[.off] == .some(nil))
        #expect(parsed.compat?.openRouterRouting?.maxPrice?.prompt == 1.5)
    }
}

@Test func remoteCatalog304PreservesOverlayAndAdvancesCheckedAt() async throws {
    let model = catalogModel(id: "cached", name: "Cached")
    let store = InMemoryCodingAgentModelsStore(entries: [
        "openai": ModelsStoreEntry(
            models: [model],
            lastModified: 2_100_000_000_000,
            checkedAt: 2_000_000_000_000,
            etag: "\"cached\""
        )
    ])
    let requests = LockedState<[URLRequest]>([])
    let client = CatalogStubHTTPClient { request in
        requests.withLock { $0.append(request) }
        return ProviderHTTPResponse(statusCode: 304, body: Data())
    }
    let registry = catalogRegistry(store: store, client: client)
    let result = await registry.refresh(ModelsRefreshOptions(providers: ["openai"], force: true))

    #expect(result.errors.isEmpty)
    #expect(registry.find("openai", "cached")?.name == "Cached")
    let persisted = try #require(try await store.read(providerId: "openai", signal: nil))
    #expect(persisted.models.first?.id == "cached")
    #expect(persisted.checkedAt == 2_200_000_000_000)
    #expect(persisted.etag == "\"cached\"")
    #expect(requests.withLock { $0.first?.value(forHTTPHeaderField: "If-None-Match") } == "\"cached\"")
}

@Test(arguments: [404, 501])
func missingRemoteCatalogZerosFreshnessAndDropsValidator(status: Int) async throws {
    let store = InMemoryCodingAgentModelsStore(entries: [
        "openai": ModelsStoreEntry(
            models: [catalogModel(id: "cached", name: "Cached")],
            lastModified: 2_100_000_000_000,
            checkedAt: 2_000_000_000_000,
            etag: "\"cached\""
        )
    ])
    let registry = catalogRegistry(
        store: store,
        client: CatalogStubHTTPClient { _ in ProviderHTTPResponse(statusCode: status, body: Data()) }
    )
    let result = await registry.refresh(ModelsRefreshOptions(providers: ["openai"], force: true))

    #expect(result.errors.isEmpty)
    let persisted = try #require(try await store.read(providerId: "openai", signal: nil))
    #expect(persisted.lastModified == 0)
    #expect(persisted.etag == nil)
    #expect(persisted.checkedAt == 2_200_000_000_000)
}

@Test func remoteCatalogNonOKRetainsValidatorAndReturnsError() async throws {
    let store = InMemoryCodingAgentModelsStore(entries: [
        "openai": ModelsStoreEntry(
            models: [catalogModel(id: "cached", name: "Cached")],
            lastModified: 2_100_000_000_000,
            checkedAt: 2_000_000_000_000,
            etag: "\"cached\""
        )
    ])
    let registry = catalogRegistry(
        store: store,
        client: CatalogStubHTTPClient { _ in ProviderHTTPResponse(statusCode: 418, body: Data()) }
    )
    let result = await registry.refresh(ModelsRefreshOptions(providers: ["openai"], force: true))

    #expect(result.errors["openai"] != nil)
    #expect(registry.find("openai", "cached") != nil)
    let persisted = try #require(try await store.read(providerId: "openai", signal: nil))
    #expect(persisted.etag == "\"cached\"")
    #expect(persisted.checkedAt == 2_200_000_000_000)
}

@Test func remoteCatalogThrottleAndForce() async throws {
    let store = InMemoryCodingAgentModelsStore()
    let requestCount = LockedState(0)
    let clock = LockedState(2_200_000_000_000.0)
    let client = CatalogStubHTTPClient { _ in
        let count = requestCount.withLock { value -> Int in
            value += 1
            return value
        }
        return try catalogResponse(
            status: 200,
            models: [catalogModel(id: "remote", name: "Remote \(count)")],
            etag: "\"v\(count)\"",
            lastModified: "Wed, 12 Aug 2037 12:00:00 GMT"
        )
    }
    let registry = catalogRegistry(store: store, client: client, now: { clock.withLock { $0 } })

    _ = await registry.refresh(ModelsRefreshOptions(providers: ["openai"]))
    clock.withLock { $0 += 60_000 }
    _ = await registry.refresh(ModelsRefreshOptions(providers: ["openai"]))
    #expect(requestCount.withLock { $0 } == 1)

    _ = await registry.refresh(ModelsRefreshOptions(providers: ["openai"], force: true))
    #expect(requestCount.withLock { $0 } == 2)
}

@Test func conditionalValidatorRequiresCachedBody() async throws {
    let requests = LockedState<[URLRequest]>([])
    let client = CatalogStubHTTPClient { request in
        requests.withLock { $0.append(request) }
        return try catalogResponse(
            status: 200,
            models: [catalogModel(id: "remote", name: "Remote")],
            lastModified: "Wed, 12 Aug 2037 12:00:00 GMT"
        )
    }
    let emptyStore = InMemoryCodingAgentModelsStore(entries: [
        "openai": ModelsStoreEntry(
            models: [],
            lastModified: 2_100_000_000_000,
            checkedAt: 2_000_000_000_000,
            etag: "\"bodyless\""
        )
    ])
    let registry = catalogRegistry(store: emptyStore, client: client)
    _ = await registry.refresh(ModelsRefreshOptions(providers: ["openai"], force: true))
    #expect(requests.withLock { $0.first?.value(forHTTPHeaderField: "If-None-Match") } == nil)
}

@Test func newerRefreshGenerationWinsOverLateOlderPublication() async throws {
    let store = InMemoryCodingAgentModelsStore()
    let gate = CatalogGate()
    let attempts = LockedState(0)
    let client = CatalogStubHTTPClient { _ in
        let attempt = attempts.withLock { value -> Int in
            value += 1
            return value
        }
        if attempt == 1 {
            await gate.wait()
            return try catalogResponse(
                status: 200,
                models: [catalogModel(id: "winner", name: "Old")],
                lastModified: "Wed, 12 Aug 2037 12:00:00 GMT"
            )
        }
        return try catalogResponse(
            status: 200,
            models: [catalogModel(id: "winner", name: "New")],
            lastModified: "Wed, 12 Aug 2037 12:00:01 GMT"
        )
    }
    let registry = catalogRegistry(store: store, client: client)
    let old = Task {
        await registry.refresh(ModelsRefreshOptions(providers: ["openai"], force: true))
    }
    while attempts.withLock({ $0 }) == 0 {
        await Task.yield()
    }
    let newer = await registry.refresh(ModelsRefreshOptions(providers: ["openai"], force: true))
    #expect(newer.errors.isEmpty)
    await gate.release()
    _ = await old.value
    try? await Task.sleep(for: .milliseconds(20))

    #expect(registry.find("openai", "winner")?.name == "New")
    let persisted = try #require(try await store.read(providerId: "openai", signal: nil))
    #expect(persisted.models.first?.name == "New")
}

@Test func staleStoredCatalogIsIgnored() async throws {
    let generatedAt = try #require(getBuiltinModelDataGeneratedAt())
    let store = InMemoryCodingAgentModelsStore(entries: [
        "openai": ModelsStoreEntry(
            models: [catalogModel(id: "stale-only", name: "Stale")],
            lastModified: generatedAt,
            checkedAt: generatedAt,
            etag: "\"stale\""
        )
    ])
    let registry = catalogRegistry(
        store: store,
        client: CatalogStubHTTPClient { _ in Issue.record("Unexpected network request"); return ProviderHTTPResponse(statusCode: 500, body: Data()) },
        networkEnabled: false
    )
    let result = await registry.refresh(ModelsRefreshOptions(allowNetwork: false, providers: ["openai"]))

    #expect(result.errors.isEmpty)
    #expect(registry.find("openai", "stale-only") == nil)
    #expect(registry.find("openai", "gpt-4o-mini") != nil)
}

@Test func remoteMergeReplacesBuiltInAppendsUnknownAndUserConfigWins() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-catalog-order-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let modelsJSON = """
    {
      "providers": {
        "openai": {
          "models": [{
            "id": "gpt-4o-mini",
            "name": "User Wins",
            "reasoning": false,
            "input": ["text"],
            "contextWindow": 9000,
            "maxTokens": 1000,
            "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}
          }]
        }
      }
    }
    """
    try modelsJSON.write(
        to: directory.appendingPathComponent("models.json"),
        atomically: true,
        encoding: .utf8
    )
    let store = InMemoryCodingAgentModelsStore(entries: [
        "openai": ModelsStoreEntry(
            models: [
                catalogModel(id: "gpt-4o-mini", name: "Remote Replacement"),
                catalogModel(id: "remote-unknown", name: "Remote Unknown")
            ],
            lastModified: 2_100_000_000_000,
            checkedAt: 2_100_000_000_000
        )
    ])
    let registry = catalogRegistry(
        store: store,
        client: CatalogStubHTTPClient { _ in Issue.record("Unexpected network request"); return ProviderHTTPResponse(statusCode: 500, body: Data()) },
        modelsDir: directory.path,
        networkEnabled: false
    )
    _ = await registry.refresh(ModelsRefreshOptions(allowNetwork: false, providers: ["openai"]))

    #expect(registry.find("openai", "gpt-4o-mini")?.name == "User Wins")
    #expect(registry.find("openai", "remote-unknown")?.name == "Remote Unknown")
}

@Test func refreshProviderRestrictionAndUnknownIdsAreIgnored() async throws {
    let store = InMemoryCodingAgentModelsStore(entries: [
        "openai": ModelsStoreEntry(
            models: [catalogModel(id: "openai-remote", name: "OpenAI Remote")],
            lastModified: 2_100_000_000_000
        ),
        "anthropic": ModelsStoreEntry(
            models: [catalogModel(id: "anthropic-remote", name: "Anthropic Remote", provider: "anthropic")],
            lastModified: 2_100_000_000_000
        )
    ])
    let registry = catalogRegistry(
        store: store,
        client: CatalogStubHTTPClient { _ in Issue.record("Unexpected network request"); return ProviderHTTPResponse(statusCode: 500, body: Data()) },
        networkEnabled: false
    )
    let result = await registry.refresh(
        ModelsRefreshOptions(allowNetwork: false, providers: ["openai", "not-a-provider"])
    )

    #expect(result.errors.isEmpty)
    #expect(registry.find("openai", "openai-remote") != nil)
    #expect(registry.find("anthropic", "anthropic-remote") == nil)
}

@Test func callerCancellationAbortsWithoutCatalogCommit() async throws {
    let store = InMemoryCodingAgentModelsStore()
    let gate = CatalogGate()
    let started = LockedState(false)
    let client = CatalogStubHTTPClient { _ in
        started.withLock { $0 = true }
        await gate.wait()
        return try catalogResponse(
            status: 200,
            models: [catalogModel(id: "must-not-commit", name: "Cancelled")],
            lastModified: "Wed, 12 Aug 2037 12:00:00 GMT"
        )
    }
    let registry = catalogRegistry(store: store, client: client)
    let signal = CancellationToken()
    let task = Task {
        await registry.refresh(ModelsRefreshOptions(providers: ["openai"], force: true, signal: signal))
    }
    while !started.withLock({ $0 }) {
        await Task.yield()
    }
    signal.cancel()
    let result = await task.value
    #expect(result.aborted)
    #expect(try await store.read(providerId: "openai", signal: nil) == nil)
    await gate.release()
}
