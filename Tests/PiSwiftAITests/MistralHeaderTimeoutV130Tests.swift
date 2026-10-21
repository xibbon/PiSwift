import Foundation
import Testing
@testable import PiSwiftAI

private let mistral130ThinkingChunk = Data(#"data: {"choices":[{"index":0,"delta":{"content":[{"type":"thinking","thinking":[{"type":"text","text":"x"}]}]}}]}"#.utf8) + Data("\n\n".utf8)
private let mistral130EndChunk = Data(#"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#.utf8) + Data("\n\ndata: [DONE]\n\n".utf8)

private func mistral130LongBody() -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
        let writer = Task {
            do {
                for _ in 0..<5 {
                    continuation.yield(mistral130ThinkingChunk)
                    try await Task.sleep(for: .milliseconds(20))
                }
                continuation.yield(mistral130EndChunk)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in writer.cancel() }
    }
}

actor Mistral130LongStreamClient: ProviderHTTPClient {
    private var usesHeaderTimeoutPolicy = false
    private let headerDelayMs: Int
    private let statusCode: Int
    private let errorBody: Bool

    init(headerDelayMs: Int = 0, statusCode: Int = 200, errorBody: Bool = false) {
        self.headerDelayMs = headerDelayMs
        self.statusCode = statusCode
        self.errorBody = errorBody
    }

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        if headerDelayMs > 0 { try await Task.sleep(for: .milliseconds(headerDelayMs)) }
        if errorBody {
            let body = AsyncThrowingStream<Data, Error> { continuation in
                let writer = Task {
                    do {
                        try await Task.sleep(for: .milliseconds(100))
                        continuation.yield(Data("blocked".utf8))
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in writer.cancel() }
            }
            return ProviderHTTPResponse(statusCode: statusCode, body: body)
        }
        return ProviderHTTPResponse(statusCode: statusCode, body: mistral130LongBody())
    }

    func send(_ request: URLRequest, timeoutPolicy: ProviderHTTPTimeoutPolicy) async throws -> ProviderHTTPResponse {
        if case .responseHeadersOnly = timeoutPolicy { usesHeaderTimeoutPolicy = true }
        return try await send(request)
    }

    func receivedHeaderTimeoutPolicy() -> Bool { usesHeaderTimeoutPolicy }
}

private func mistral130Model() -> Model {
    Model(id: "mistral-large-latest", name: "Mistral", api: .mistralConversations,
        provider: "mistral", baseUrl: "https://api.mistral.ai", reasoning: true, input: [.text],
        cost: ModelCost(input: 1, output: 2, cacheRead: 0, cacheWrite: 0),
        contextWindow: 128_000, maxTokens: 4096)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func mistral130TimesOutWaitingForHeaders(hasCallerSignal: Bool) async {
    let client = Mistral130LongStreamClient(headerDelayMs: 10_000)
    let signal = hasCallerSignal ? CancellationToken() : nil
    let message = await streamMistral(model: mistral130Model(), context: normalizeContext(Context(messages: [])),
        options: MistralOptions(signal: signal, apiKey: "test", httpClient: client, timeoutMs: 20)).result()
    #expect(message.stopReason == .error)
    #expect(message.errorMessage == "Mistral response headers timed out after 20ms")
    #expect(signal?.isCancelled != true)
    #expect(await client.receivedHeaderTimeoutPolicy())
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func mistral130KeepsAllThinkingAfterHeaderTimeout(hasCallerSignal: Bool) async {
    let client = Mistral130LongStreamClient()
    let signal = hasCallerSignal ? CancellationToken() : nil
    let message = await streamMistral(model: mistral130Model(), context: normalizeContext(Context(messages: [])),
        options: MistralOptions(signal: signal, apiKey: "test", httpClient: client, timeoutMs: 40)).result()
    #expect(message.stopReason == .stop)
    #expect(message.errorMessage == nil)
    #expect(message.content.count == 1)
    if case .thinking(let thinking)? = message.content.first {
        #expect(thinking.thinking == "xxxxx")
    } else { Issue.record("Missing thinking block") }
    #expect(signal?.isCancelled != true)
    #expect(await client.receivedHeaderTimeoutPolicy())
}

@Test(.timeLimit(.minutes(1)))
func mistral130StopsHeaderTimeoutBeforeReadingHTTPErrorBody() async {
    let client = Mistral130LongStreamClient(statusCode: 403, errorBody: true)
    let message = await streamMistral(model: mistral130Model(), context: normalizeContext(Context(messages: [])),
        options: MistralOptions(apiKey: "test", httpClient: client, timeoutMs: 40)).result()
    #expect(message.stopReason == .error)
    #expect(message.errorMessage == "Mistral API error (403): blocked")
}

@Test(.timeLimit(.minutes(1)))
func mistral130KeepsCallerCancellationAfterHeaderDeadline() async {
    let signal = CancellationToken()
    let client = Mistral130LongStreamClient()
    let stream = streamMistral(model: mistral130Model(), context: normalizeContext(Context(messages: [])),
        options: MistralOptions(signal: signal, apiKey: "test", httpClient: client, timeoutMs: 30))
    var thinkingCount = 0
    for await event in stream {
        if case .thinkingDelta = event {
            thinkingCount += 1
            if thinkingCount == 4 { signal.cancel() }
        }
    }
    let message = await stream.result()
    #expect(thinkingCount == 4)
    #expect(message.stopReason == .aborted)
}

#if canImport(Network)
import Network

private enum Mistral130ServerError: Error { case missingPort }

@Test(.timeLimit(.minutes(1)))
func mistral130DefaultHTTPClientKeepsBodyPastNominalRequestTimeout() async throws {
    let listener = try NWListener(using: .tcp, on: .any)
    defer { listener.cancel() }
    listener.newConnectionHandler = { connection in
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, error in
            guard error == nil else { connection.cancel(); return }
            let headers = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: headers, completion: .contentProcessed { error in
                guard error == nil else { connection.cancel(); return }
                Task {
                    do {
                        try await Task.sleep(for: .milliseconds(150))
                        connection.send(content: Data("ok".utf8), completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                    } catch { connection.cancel() }
                }
            })
        }
    }
    let ready = LockedState(false)
    let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard ready.withLock({ value in
                    guard !value else { return false }; value = true; return true
                }) else { return }
                if let port = listener.port?.rawValue { continuation.resume(returning: port) }
                else { continuation.resume(throwing: Mistral130ServerError.missingPort) }
            case .failed(let error):
                guard ready.withLock({ value in
                    guard !value else { return false }; value = true; return true
                }) else { return }
                continuation.resume(throwing: error)
            default: break
            }
        }
        listener.start(queue: .global())
    }
    let url = try #require(URL(string: "http://127.0.0.1:\(port)/stream"))
    var request = URLRequest(url: url)
    request.timeoutInterval = 0.02
    let client = DefaultProviderHTTPClient(env: ["NO_PROXY": "*"])
    let response = try await client.send(request, timeoutPolicy: .responseHeadersOnly)
    let body = try await collectProviderHTTPBody(response.body)
    #expect(response.statusCode == 200)
    #expect(String(decoding: body, as: UTF8.self) == "ok")
}
#endif
