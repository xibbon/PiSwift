import Foundation
import Testing
@testable import PiSwiftMCP

private actor M3ServerStore: McpOAuthServerStore {
    var value: McpOAuthState?
    var busy = false
    var held = false
    var refreshes = 0
    var savedUnderLock = false

    init(expired: Bool = false) {
        value = McpOAuthState(serverURL: "https://example.com/mcp",
            tokens: .init(accessToken: "old", tokenType: "Bearer", refreshToken: "refresh"),
            tokensExpireAt: expired ? .distantPast : .distantFuture)
    }
    func load() -> McpOAuthState? { value }
    func save(_ state: McpOAuthState) { value = state; savedUnderLock = held }
    func setBusy() { busy = true }
    func withRefreshLock<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        if busy { throw McpRefreshLockBusyError() }
        while held { try await Task.sleep(for: .milliseconds(1)) }
        held = true
        defer { held = false }
        return try await operation()
    }
    func rotate(_ state: McpOAuthState) async throws -> McpOAuthFlowResult {
        refreshes += 1
        try await Task.sleep(for: .milliseconds(20))
        var state = state
        state.tokens = .init(accessToken: "new", tokenType: "Bearer", refreshToken: "rotated")
        state.tokensExpireAt = .distantFuture
        save(state)
        return .authorized
    }
    func results() -> (Int, Bool) { (refreshes, savedUnderLock) }
}

@Test(.timeLimit(.minutes(1)))
func m3AuthProvidersRecheckTokensUnderSharedLock() async throws {
    let store = M3ServerStore()
    let first = McpStoredAuthProvider(store: store) { state, _ in try await store.rotate(state) }
    let second = McpStoredAuthProvider(store: store) { state, _ in try await store.rotate(state) }
    let url = URL(string: "https://example.com/mcp")!
    async let a: Void = first.onUnauthorized(challenge: nil, serverURL: url, rejectedToken: "old")
    async let b: Void = second.onUnauthorized(challenge: nil, serverURL: url, rejectedToken: "old")
    _ = try await (a, b)
    let result = await store.results()
    #expect(result.0 == 1)
    #expect(result.1)
    #expect(try await first.token() == "new")
}

@Test(.timeLimit(.minutes(1)))
func m3AuthBusyRefreshReturnsOldTokenAndUnauthorizedThrows() async throws {
    let store = M3ServerStore(expired: true)
    await store.setBusy()
    let provider = McpStoredAuthProvider(store: store) { state, _ in try await store.rotate(state) }
    #expect(try await provider.token() == "old")
    await #expect(throws: McpRefreshLockBusyError.self) {
        try await provider.onUnauthorized(challenge: nil,
            serverURL: URL(string: "https://example.com/mcp")!, rejectedToken: "old")
    }
    #expect(await store.results().0 == 0)
}

@Test(.timeLimit(.minutes(1)))
func m3AuthInsufficientScopeDoesNotRefresh() async throws {
    let store = M3ServerStore()
    let provider = McpStoredAuthProvider(store: store) { state, _ in try await store.rotate(state) }
    do {
        try await provider.onUnauthorized(challenge: "Bearer error=\"insufficient_scope\", scope=\"write\"",
            serverURL: URL(string: "https://example.com/mcp")!, rejectedToken: "old")
        Issue.record("Expected sign-in requirement")
    } catch let error as McpOAuthError {
        guard case .authorizationRequired = error else { throw error }
    }
    #expect(await store.results().0 == 0)
    #expect(await provider.challenge?.scope == "write")
}

private actor M3RefreshBarrier {
    private var started = false
    private var released = false
    func wait() async throws {
        started = true
        while !released { try await Task.sleep(for: .milliseconds(1)) }
    }
    func hasStarted() -> Bool { started }
    func release() { released = true }
}

@Test(.timeLimit(.minutes(1)))
func m3AuthCancellationKeepsRotatedTokenBeforeSettledReturns() async throws {
    let store = M3ServerStore()
    let barrier = M3RefreshBarrier()
    let provider = McpStoredAuthProvider(store: store) { state, _ in
        try await barrier.wait()
        return try await store.rotate(state)
    }
    let caller = Task {
        try await provider.onUnauthorized(challenge: nil,
            serverURL: URL(string: "https://example.com/mcp")!, rejectedToken: "old")
    }
    while !(await barrier.hasStarted()) { try await Task.sleep(for: .milliseconds(1)) }
    caller.cancel()
    await #expect(throws: CancellationError.self) { try await caller.value }
    #expect(await store.load()?.tokens?.accessToken == "old")
    await barrier.release()
    await provider.settled()
    #expect(await store.load()?.tokens?.refreshToken == "rotated")
    #expect(await store.results().1)
}
