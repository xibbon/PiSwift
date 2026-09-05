import Foundation

/// A streaming HTTP response used by provider adapters.
public struct ProviderHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: AsyncThrowingStream<Data, Error>

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: AsyncThrowingStream<Data, Error>
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.init(
            statusCode: statusCode,
            headers: headers,
            body: AsyncThrowingStream { continuation in
                if !body.isEmpty {
                    continuation.yield(body)
                }
                continuation.finish()
            }
        )
    }
}

/// Executes one provider HTTP request. Implementations must be safe to call from concurrent tasks.
public protocol ProviderHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse
}

/// Default request executor. It preserves the existing environment-proxy behavior.
public struct DefaultProviderHTTPClient: ProviderHTTPClient {
    public init() {}

    public func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        let session = proxySession(for: request.url)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StreamError.invalidHTTPResponse
        }

        let body = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    var chunk = Data()
                    chunk.reserveCapacity(16_384)
                    for try await byte in bytes {
                        chunk.append(byte)
                        if chunk.count == 16_384 || byte == 10 || byte == 13 {
                            continuation.yield(chunk)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        return ProviderHTTPResponse(
            statusCode: http.statusCode,
            headers: responseHeaders(http),
            body: body
        )
    }
}

func collectProviderHTTPBody(_ body: AsyncThrowingStream<Data, Error>) async throws -> Data {
    var result = Data()
    for try await chunk in body {
        result.append(chunk)
    }
    return result
}

func providerHTTPError(from response: ProviderHTTPResponse) async throws -> StreamError {
    let data = try await collectProviderHTTPBody(response.body)
    let fallback = "HTTP \(response.statusCode)"
    let message = String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    return .providerRequest(statusCode: response.statusCode, headers: response.headers, message: message)
}
