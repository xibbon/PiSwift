import Foundation
import Testing
@testable import PiSwiftAI

@Suite("Codex session cleanup v1.5.2", .serialized)
struct CodexSessionCleanupV152Tests {
    // Suspended tasks test the cache without a network connection.
    private func acquire(_ cache: CodexWebSocketCache, sessionId: String, accountId: String) -> CodexWebSocketLease {
        let url = URL(string: "wss://example.invalid/codex")!
        return cache.acquire(
            url: url, headers: [:], sessionId: sessionId, accountId: accountId,
            connectTimeoutMs: nil, env: nil,
            connectionFactory: { URLSession.shared.webSocketTask(with: url) }
        )
    }

    @Test func registeredCleanupRemovesEveryAccountForOneSession() throws {
        let cache = CodexWebSocketCache.shared
        let sessionId = UUID().uuidString
        let otherSessionId = UUID().uuidString
        defer {
            closeOpenAICodexWebSocketSessions(sessionId)
            closeOpenAICodexWebSocketSessions(otherSessionId)
        }
        let first = acquire(cache, sessionId: sessionId, accountId: "a")
        let second = acquire(cache, sessionId: sessionId, accountId: "b")
        let other = acquire(cache, sessionId: otherSessionId, accountId: "a")
        #expect(cache.sessionKeys.contains(first.cacheKey!))
        #expect(cache.sessionKeys.contains(second.cacheKey!))

        try cleanupSessionResources(sessionId)

        #expect(!cache.sessionKeys.contains(first.cacheKey!))
        #expect(!cache.sessionKeys.contains(second.cacheKey!))
        #expect(cache.sessionKeys.contains(other.cacheKey!))
        // A stream can finish after cleanup. It must not restore its old entry.
        cache.release(first, keep: true)
        cache.release(second, keep: true)
        #expect(!cache.sessionKeys.contains(first.cacheKey!))
        #expect(!cache.sessionKeys.contains(second.cacheKey!))
        try cleanupSessionResources(sessionId)
    }

    @Test func closeAllRemovesAllSessionsAndAllowsNewConnections() {
        let cache = CodexWebSocketCache()
        let first = acquire(cache, sessionId: "first", accountId: "a")
        _ = acquire(cache, sessionId: "second", accountId: "b")
        cache.close(sessionId: nil)
        #expect(cache.sessionKeys.isEmpty)

        let replacement = acquire(cache, sessionId: "first", accountId: "a")
        #expect(replacement.task !== first.task)
        // An old lease must not remove a replacement for the same cache key.
        cache.release(first, keep: true)
        #expect(cache.sessionKeys == Set([replacement.cacheKey!]))
        cache.close(sessionId: nil)
        cache.close(sessionId: nil)
        #expect(cache.sessionKeys.isEmpty)
    }

    @Test func emptySessionIdClosesAllAsInUpstream() {
        let cache = CodexWebSocketCache()
        _ = acquire(cache, sessionId: "first", accountId: "a")
        _ = acquire(cache, sessionId: "second", accountId: "b")
        cache.close(sessionId: "")
        #expect(cache.sessionKeys.isEmpty)
    }
}
