import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

private struct HTTP085Client: ProviderHTTPClient {
    var handler: @Sendable () async throws -> ProviderHTTPResponse
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse { try await handler() }
}

@Test func management085RetriesAttemptTimeout() async throws {
    let attempts = LockedState(0)
    let cancelled = LockedState(false)
    let client = HTTP085Client {
        let attempt = attempts.withLock { $0 += 1; return $0 }
        if attempt == 1 {
            do { try await Task.sleep(for: .seconds(5)) }
            catch { cancelled.withLock { $0 = true }; throw error }
        }
        return ProviderHTTPResponse(statusCode: 200, body: Data("ok".utf8))
    }
    let response = try await fetchWithRetry(URLRequest(url: URL(string: "https://example.invalid")!), client: client, options: .init(maxRetries: 1, attemptTimeoutMs: 20))
    #expect(response.statusCode == 200)
    #expect(attempts.withLock { $0 } == 2)
    #expect(cancelled.withLock { $0 })
}

@Test func management085AttemptTimeoutCancelsResponseBody() async throws {
    let attempts = LockedState(0)
    let client = HTTP085Client {
        let attempt = attempts.withLock { $0 += 1; return $0 }
        if attempt == 1 {
            return ProviderHTTPResponse(statusCode: 200, body: AsyncThrowingStream<Data, Error> { _ in })
        }
        return ProviderHTTPResponse(statusCode: 200, body: Data())
    }
    let response = try await fetchWithRetry(URLRequest(url: URL(string: "https://example.invalid")!), client: client, options: .init(maxRetries: 1, attemptTimeoutMs: 20))
    #expect(response.statusCode == 200)
    #expect(attempts.withLock { $0 } == 2)
}

@Test func management085OverallTimeoutIsTerminal() async {
    let attempts = LockedState(0)
    let client = HTTP085Client {
        attempts.withLock { $0 += 1 }
        try await Task.sleep(for: .seconds(5))
        return ProviderHTTPResponse(statusCode: 200, body: Data())
    }
    do {
        _ = try await fetchWithRetry(URLRequest(url: URL(string: "https://example.invalid")!), client: client, options: .init(maxRetries: 5, timeoutMs: 30, attemptTimeoutMs: 200))
        Issue.record("Expected overall timeout")
    } catch {}
    #expect(attempts.withLock { $0 } == 1)
}

@Test func management085CallerCancellationIsTerminal() async {
    let attempts = LockedState(0)
    let signal = CancellationToken()
    let client = HTTP085Client {
        attempts.withLock { $0 += 1 }
        signal.cancel()
        try await Task.sleep(for: .seconds(5))
        return ProviderHTTPResponse(statusCode: 200, body: Data())
    }
    do {
        _ = try await fetchWithRetry(URLRequest(url: URL(string: "https://example.invalid")!), client: client, options: .init(maxRetries: 5, attemptTimeoutMs: 200), signal: signal)
        Issue.record("Expected caller cancellation")
    } catch {}
    #expect(attempts.withLock { $0 } == 1)
}

@Test func management085UnrelatedAbortIsTerminal() async {
    let attempts = LockedState(0)
    let client = HTTP085Client {
        attempts.withLock { $0 += 1 }
        throw StreamError.requestAborted
    }
    do {
        _ = try await fetchWithRetry(URLRequest(url: URL(string: "https://example.invalid")!), client: client, options: .init(maxRetries: 5, attemptTimeoutMs: 200))
        Issue.record("Expected request abort")
    } catch {}
    #expect(attempts.withLock { $0 } == 1)
}
