import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

private actor C1RefreshGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

// This consumer uses the protocol's default signal overload.
private final class C1ConsumerAuthBackend: AuthStorageBackend {
    let base = InMemoryAuthStorageBackend()
    let failCommit = LockedState(false)

    func withLock<R: Sendable>(_ body: @Sendable (String?) throws -> AuthStorageLockResult<R>) throws -> R {
        try base.withLock(body)
    }

    func withLockAsync<R: Sendable>(
        _ body: @escaping @Sendable (String?) async throws -> AuthStorageLockResult<R>
    ) async throws -> R {
        try await base.withLockAsync { current in
            let result = try await body(current)
            if result.next != nil, self.failCommit.withLock({ $0 }) {
                throw OAuthError.refreshFailed("test store failure")
            }
            return result
        }
    }
}

private func c1ExpiredAuth(_ backend: any AuthStorageBackend) -> AuthStorage {
    let storage = AuthStorage(storage: backend)
    storage.set("xai", credential: .oauth(OAuthCredential(
        access: "old-access", refresh: "old-refresh", expires: 0
    )))
    return storage
}

private func c1FreshCredentials() -> OAuthCredentials {
    OAuthCredentials(refresh: "rotated-refresh", access: "new-access",
                     expires: Date().timeIntervalSince1970 * 1000 + 3_600_000)
}

private func c1Await(_ predicate: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return predicate()
}

private func c1IsRotated(_ storage: AuthStorage) -> Bool {
    guard case .oauth(let credential) = storage.get("xai") else { return false }
    return credential.access == "new-access" && credential.refresh == "rotated-refresh"
}

// Upstream bde882c74 and model-runtime-auth-options.test.ts:266–299.
@Test(.timeLimit(.minutes(1)), arguments: ["memory", "file", "consumer"], [false, true])
func c1OAuthRefreshPersistsAfterCancellation(backendKind: String, cancelTask: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("c1-auth-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let backend: any AuthStorageBackend
    switch backendKind {
    case "file": backend = FileAuthStorageBackend(directory.appendingPathComponent("auth.json").path)
    case "consumer": backend = C1ConsumerAuthBackend()
    default: backend = InMemoryAuthStorageBackend()
    }
    let storage = c1ExpiredAuth(backend)
    let gate = C1RefreshGate()
    let started = LockedState(false)
    let refreshCount = LockedState(0)
    let callerSignal = CancellationToken()
    let capturedSignal = LockedState<CancellationToken?>(nil)
    storage.setOAuthOverridesForTesting(OAuthOverrides(
        getOAuthApiKey: nil, oauthApiKey: nil,
        getOAuthApiKeyWithSignal: { provider, credentials, refreshSignal in
            #expect(provider == .xai)
            #expect(credentials["xai"]?.refresh == "old-refresh")
            refreshCount.withLock { $0 += 1 }
            capturedSignal.withLock { $0 = refreshSignal }
            started.withLock { $0 = true }
            await gate.wait()
            #expect(!Task.isCancelled)
            #expect(!refreshSignal.isCancelled)
            return (c1FreshCredentials(), "new-access")
        }
    ))
    let first = Task { await storage.getApiKey("xai", signal: callerSignal) }
    #expect(await c1Await { started.withLock { $0 } })
    let second = Task { await storage.getApiKey("xai") }
    if cancelTask { first.cancel() } else { callerSignal.cancel() }
    // Return before the provider is released, as upstream's abort race does.
    #expect(await first.value == nil)
    let refreshSignal = try #require(capturedSignal.withLock { $0 })
    #expect(refreshSignal !== callerSignal)
    #expect(!refreshSignal.isCancelled)
    await gate.release()
    #expect(await second.value == "new-access")
    #expect(refreshCount.withLock { $0 } == 1)
    #expect(c1IsRotated(storage))
    let reloaded = AuthStorage.fromStorage(backend)
    #expect(c1IsRotated(reloaded))
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func c1OAuthCancellationBeforeStartDoesNotRefresh(cancelTask: Bool) async {
    let storage = c1ExpiredAuth(InMemoryAuthStorageBackend())
    let count = LockedState(0)
    storage.setOAuthOverridesForTesting(OAuthOverrides(getOAuthApiKey: { _, _ in
        count.withLock { $0 += 1 }
        return (c1FreshCredentials(), "new-access")
    }, oauthApiKey: nil))
    let signal = CancellationToken()
    if cancelTask {
        let gate = C1RefreshGate()
        let request = Task {
            await gate.wait()
            return await storage.getApiKey("xai")
        }
        request.cancel()
        await gate.release()
        #expect(await request.value == nil)
    } else {
        signal.cancel()
        #expect(await storage.getApiKey("xai", signal: signal) == nil)
    }
    #expect(count.withLock { $0 } == 0)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func c1OAuthLockedRecheckHonorsCancellationAndLogout(logout: Bool) async throws {
    let backend = InMemoryAuthStorageBackend()
    let storage = c1ExpiredAuth(backend)
    let gate = C1RefreshGate()
    let locked = LockedState(false)
    let count = LockedState(0)
    storage.setOAuthOverridesForTesting(OAuthOverrides(getOAuthApiKey: { _, _ in
        count.withLock { $0 += 1 }
        return (c1FreshCredentials(), "new-access")
    }, oauthApiKey: nil))
    let blocker = Task {
        try await backend.withLockAsync { _ in
            locked.withLock { $0 = true }
            await gate.wait()
            return AuthStorageLockResult(result: (), next: logout ? "{}" : nil)
        }
    }
    #expect(await c1Await { locked.withLock { $0 } })
    let signal = CancellationToken()
    let request = Task { await storage.getApiKey("xai", signal: signal) }
    try await Task.sleep(for: .milliseconds(40))
    if !logout {
        signal.cancel()
        #expect(await request.value == nil)
    }
    await gate.release()
    try await blocker.value
    if logout { _ = await request.value }
    #expect(count.withLock { $0 } == 0)
    if logout { #expect(storage.get("xai") == nil) }
}

@Test(.timeLimit(.minutes(1)))
func c1OAuthRefreshTimeoutDoesNotCommit() async {
    let storage = c1ExpiredAuth(InMemoryAuthStorageBackend())
    let timedOut = LockedState(false)
    storage.setOAuthOverridesForTesting(OAuthOverrides(
        getOAuthApiKey: nil, oauthApiKey: nil,
        getOAuthApiKeyWithSignal: { _, _, signal in
            while !signal.isCancelled { try await Task.sleep(for: .milliseconds(20)) }
            timedOut.withLock { $0 = true }
            throw OAuthError.cancelled
        }
    ))
    let start = ContinuousClock.now
    #expect(await storage.getApiKey("xai") == nil)
    #expect(timedOut.withLock { $0 })
    #expect(start.duration(to: .now) >= .seconds(14))
    #expect(!c1IsRotated(storage))
}

@Test(.timeLimit(.minutes(1)))
func c1OAuthStoreFailureDoesNotUpdateCache() async {
    let backend = C1ConsumerAuthBackend()
    let storage = c1ExpiredAuth(backend)
    backend.failCommit.withLock { $0 = true }
    storage.setOAuthOverridesForTesting(OAuthOverrides(getOAuthApiKey: { _, _ in
        (c1FreshCredentials(), "new-access")
    }, oauthApiKey: nil))
    #expect(await storage.getApiKey("xai") == nil)
    #expect(!c1IsRotated(storage))
    #expect(!c1IsRotated(AuthStorage.fromStorage(backend)))
}

// Upstream models-runtime.test.ts cancellation and supersession regressions.
@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func c1OAuthCatalogCancellationKeepsRotatedCredential(supersede: Bool) async throws {
    let storage = c1ExpiredAuth(InMemoryAuthStorageBackend())
    let gate = C1RefreshGate()
    let started = LockedState(false)
    let count = LockedState(0)
    storage.setOAuthOverridesForTesting(OAuthOverrides(getOAuthApiKey: { _, _ in
        count.withLock { $0 += 1 }
        started.withLock { $0 = true }
        await gate.wait()
        return (c1FreshCredentials(), "new-access")
    }, oauthApiKey: nil))
    let publications = LockedState(0)
    let firstProviderSignal = LockedState<CancellationToken?>(nil)
    let coordinator = ModelCatalogRefreshCoordinator(
        store: InMemoryCodingAgentModelsStore(),
        sources: [ModelsRefreshSource(id: "xai", readStoredCredential: { "old-access" },
            resolveCredential: { signal in
                firstProviderSignal.withLock { if $0 == nil { $0 = signal } }
                return await storage.getApiKey("xai", signal: signal)
            },
            refresh: { context in
                if context.allowNetwork {
                    #expect(context.credential == "new-access")
                    _ = await context.publish(ModelsPublication(update: { publications.withLock { $0 += 1 } }))
                }
            })]
    )
    let signal = CancellationToken()
    let first = Task { await coordinator.refresh(ModelsRefreshOptions(providers: ["xai"], signal: signal)) }
    #expect(await c1Await { started.withLock { $0 } })
    if supersede {
        let second = Task { await coordinator.refresh(ModelsRefreshOptions(providers: ["xai"])) }
        #expect(await c1Await { firstProviderSignal.withLock { $0?.isCancelled == true } })
        await gate.release()
        #expect(!(await second.value).aborted)
        _ = await first.value
        #expect(publications.withLock { $0 } == 1)
    } else {
        signal.cancel()
        #expect((await first.value).aborted)
        #expect(publications.withLock { $0 } == 0)
        await gate.release()
    }
    #expect(await c1Await { c1IsRotated(storage) })
    #expect(count.withLock { $0 } == 1)
}
