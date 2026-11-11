import Foundation

/// Sends stored tokens and shares refresh work for one server.
/// The refresh operation must save its result before it returns. It must not start sign-in.
public actor McpStoredAuthProvider: McpAuthProvider {
    private let store: any McpOAuthServerStore
    private let refreshOperation: @Sendable (McpOAuthState, McpOAuthChallenge?) async throws -> McpOAuthFlowResult
    private var refreshTask: Task<Void, any Error>?
    public private(set) var challenge: McpOAuthChallenge?

    public init(
        store: any McpOAuthServerStore,
        refresh: @escaping @Sendable (McpOAuthState, McpOAuthChallenge?) async throws -> McpOAuthFlowResult
    ) {
        self.store = store
        self.refreshOperation = refresh
    }

    public func token() async throws -> String? {
        try? await waitForRefresh(refreshTask)
        try Task.checkCancellation()
        let state = try await store.load()
        let token = state?.tokens?.accessToken
        if let expiry = state?.tokensExpireAt, expiry.timeIntervalSinceNow <= 30,
           state?.tokens?.refreshToken != nil {
            try? await refresh(staleToken: token, challenge: nil)
            try Task.checkCancellation()
            return try await store.load()?.tokens?.accessToken
        }
        return token
    }

    public func onUnauthorized(challenge: String?, serverURL: URL, rejectedToken: String?) async throws {
        let parsed = McpOAuthDiscovery.parseWWWAuthenticate(challenge)
        self.challenge = parsed
        if parsed.error == "insufficient_scope" { throw McpOAuthError.authorizationRequired }
        try await refresh(staleToken: rejectedToken, challenge: parsed)
    }

    /// Wait until a refresh has saved any rotated token, including after caller cancellation.
    public func settled() async { _ = try? await refreshTask?.value }

    private func refresh(staleToken: String?, challenge: McpOAuthChallenge?) async throws {
        try Task.checkCancellation()
        if refreshTask == nil {
            let store = self.store
            let operation = refreshOperation
            refreshTask = Task {
                defer { self.refreshTask = nil }
                try await store.withRefreshLock {
                    let state = try await store.load()
                    if state?.tokens?.accessToken != staleToken { return }
                    guard let state, state.tokens?.refreshToken != nil else {
                        throw McpOAuthError.authorizationRequired
                    }
                    if try await operation(state, challenge) == .redirect {
                        throw McpOAuthError.authorizationRequired
                    }
                }
            }
        }
        try await waitForRefresh(refreshTask)
    }
}

private actor McpStoredRefreshWaiter {
    private var result: Result<Void, any Error>?
    private var continuation: CheckedContinuation<Void, any Error>?

    func complete(_ value: Result<Void, any Error>) {
        guard result == nil else { return }
        result = value
        continuation?.resume(with: value)
        continuation = nil
    }

    func wait() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                if let result { continuation.resume(with: result) }
                else { self.continuation = continuation }
            }
        } onCancel: {
            Task { await self.complete(.failure(CancellationError())) }
        }
    }
}

private func waitForRefresh(_ task: Task<Void, any Error>?) async throws {
    try Task.checkCancellation()
    guard let task else { return }
    let waiter = McpStoredRefreshWaiter()
    Task { await waiter.complete(await task.result) }
    try await waiter.wait()
}
