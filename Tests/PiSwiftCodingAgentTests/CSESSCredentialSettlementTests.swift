import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private actor CSESSSaveGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

private final class CSESSDelayedAuthBackend: AuthStorageBackend {
    let base: FileAuthStorageBackend
    let gate = CSESSSaveGate()
    let saveStarted = LockedState(false)

    init(_ path: String) { base = FileAuthStorageBackend(path) }

    func withLock<R: Sendable>(_ body: @Sendable (String?) throws -> AuthStorageLockResult<R>) throws -> R {
        try base.withLock(body)
    }

    func withLockAsync<R: Sendable>(
        _ body: @escaping @Sendable (String?) async throws -> AuthStorageLockResult<R>
    ) async throws -> R {
        try await base.withLockAsync { current in
            let result = try await body(current)
            if result.next != nil {
                self.saveStarted.withLock { $0 = true }
                await self.gate.wait()
            }
            return result
        }
    }
}

private enum CSESSCredentialTestError: Error { case unusedFactory }

private func credentialRuntime(_ auth: AuthStorage, cwd: String) -> AgentSessionRuntime {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "Test", model: model, tools: [])))
    let session = AgentSession(config: AgentSessionConfig(agent: agent,
        sessionManager: .inMemory(cwd), settingsManager: .inMemory(),
        resourceLoader: TestResourceLoader(), modelRegistry: ModelRegistry(auth)))
    return AgentSessionRuntime(agentDir: cwd, factory: { _ in throw CSESSCredentialTestError.unusedFactory },
                               initialSession: session)
}

private func waitForSaveStart(_ flag: LockedState<Bool>) async -> Bool {
    for _ in 0..<200 {
        if flag.withLock({ $0 }) { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return flag.withLock { $0 }
}

// v1.5.2 C-SESS b2cb62923, runtime-credentials.test.ts:76 and
// suite/regressions/11692-dispose-waits-for-oauth-refresh.test.ts.
@Test("dispose waits until the rotated token from a background catalog refresh is saved", .timeLimit(.minutes(1)))
func disposeWaitsForStartedOAuthSaveOnDisk() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("csess-auth-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("auth.json").path
    let backend = CSESSDelayedAuthBackend(path)
    let auth = AuthStorage(storage: backend)
    auth.set("xai", credential: .oauth(OAuthCredential(access: "old-access", refresh: "old-refresh", expires: 0)))
    auth.setOAuthOverridesForTesting(OAuthOverrides(getOAuthApiKeyWithSignal: { _, _, _ in
        (OAuthCredentials(refresh: "new-refresh", access: "new-access",
                          expires: Date().timeIntervalSince1970 * 1000 + 3_600_000), "new-access")
    }))
    let runtime = credentialRuntime(auth, cwd: dir.path)
    let refresh = Task { await auth.getApiKey("xai") }
    #expect(await waitForSaveStart(backend.saveStarted))
    let finished = LockedState(false)
    let closing = Task {
        await runtime.disposeAndWait()
        finished.withLock { $0 = true }
    }
    try await Task.sleep(for: .milliseconds(30))
    #expect(!finished.withLock { $0 })
    await backend.gate.release()
    await closing.value
    #expect(await refresh.value == "new-access")
    guard case .oauth(let saved) = AuthStorage(path).get("xai") else {
        Issue.record("Expected saved OAuth credential")
        return
    }
    #expect(saved.access == "new-access")
    #expect(saved.refresh == "new-refresh")
}

// v1.5.2 C-SESS b2cb62923, runtime-credentials.test.ts:109.
@Test("settled resolves after a pending modification fails", .timeLimit(.minutes(1)))
func settledReturnsAfterFailedOAuthRefresh() async {
    let auth = AuthStorage(":memory:")
    auth.set("xai", credential: .oauth(OAuthCredential(access: "old-access", refresh: "old-refresh", expires: 0)))
    let started = LockedState(false)
    auth.setOAuthOverridesForTesting(OAuthOverrides(getOAuthApiKeyWithSignal: { _, _, _ in
        started.withLock { $0 = true }
        throw OAuthError.refreshFailed("invalid_grant")
    }))
    let refresh = Task { await auth.getApiKey("xai") }
    #expect(await waitForSaveStart(started))
    await auth.settled()
    #expect(await refresh.value == nil)
}

@Test(.timeLimit(.minutes(1))) func disposalDoesNotStartAnOAuthRefresh() async throws {
    let auth = AuthStorage(":memory:")
    auth.set("xai", credential: .oauth(OAuthCredential(access: "old-access", refresh: "old-refresh", expires: 0)))
    let count = LockedState(0)
    auth.setOAuthOverridesForTesting(OAuthOverrides(getOAuthApiKeyWithSignal: { _, _, _ in
        count.withLock { $0 += 1 }
        return nil
    }))
    let runtime = credentialRuntime(auth, cwd: FileManager.default.temporaryDirectory.path)
    await runtime.disposeAndWait()
    #expect(count.withLock { $0 } == 0)
}
