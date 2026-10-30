import CryptoKit
import Foundation
import Testing
@testable import PiSwiftAI

private let bedrockPayloadHost = "bedrock-payload-test.invalid"
private let bedrockPayloadRequests = LockedState<[(request: URLRequest, body: Data)]>([])

private final class BedrockPayloadProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == bedrockPayloadHost
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body: Data
        if let data = request.httpBody {
            body = data
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            body = data
        } else {
            body = Data()
        }
        bedrockPayloadRequests.withLock { $0.append((request, body)) }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["content-type": "application/vnd.amazon.eventstream"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func bedrockPayloadModel() -> Model {
    Model(id: "us.anthropic.claude-haiku-4-5-20251001-v1:0", name: "Haiku",
        api: .bedrockConverseStream, provider: "amazon-bedrock", baseUrl: "https://\(bedrockPayloadHost)",
        reasoning: false, input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 200_000, maxTokens: 100)
}

@Test(.timeLimit(.minutes(1)))
func bedrockSignsExactReplacementPayloadBytes() async throws {
    try await codexRequestLock.withLock {
        bedrockPayloadRequests.withLock { $0 = [] }
        #expect(URLProtocol.registerClass(BedrockPayloadProtocol.self))
        defer {
            URLProtocol.unregisterClass(BedrockPayloadProtocol.self)
            bedrockPayloadRequests.withLock { $0 = [] }
        }
        let replacement = LockedState<Data?>(nil)
        let calls = LockedState(0)
        _ = await streamBedrock(model: bedrockPayloadModel(),
            context: normalizeContext(Context(messages: [.user(UserMessage(content: .text("hello")))])),
            options: BedrockOptions(env: [:], region: "us-east-1", cacheRetention: CacheRetention.none,
                onPayload: { snapshot in
                    calls.withLock { $0 += 1 }
                    await Task.yield()
                    var object = try #require(JSONSerialization.jsonObject(with: Data(snapshot.json.utf8)) as? [String: Any])
                    object["speed"] = "fast"
                    object["custom_extension"] = ["enabled": true]
                    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                    replacement.withLock { $0 = data }
                    let json = try #require(String(data: data, encoding: .utf8))
                    return PayloadSnapshot(json: json)
                }, bearerToken: "fixture-token", timeoutMs: 5000, maxRetries: 0)).result()
        #expect(calls.withLock { $0 } == 1)
        let requests = bedrockPayloadRequests.withLock { $0 }
        #expect(requests.count == 1)
        let captured = try #require(requests.first)
        let expected = try #require(replacement.withLock { $0 })
        #expect(captured.body == expected)
        let object = try #require(JSONSerialization.jsonObject(with: captured.body) as? [String: Any])
        #expect(object["speed"] as? String == "fast")
        #expect(object["custom_extension"] as? [String: Bool] == ["enabled": true])
        let hash = SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined()
        #expect(captured.request.value(forHTTPHeaderField: "x-amz-content-sha256") == hash)
        #expect(captured.request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
    }
}

@Test(.timeLimit(.minutes(1)))
func bedrockCancellationDuringPayloadHookStopsBeforeTransport() async {
    await codexRequestLock.withLock {
        bedrockPayloadRequests.withLock { $0 = [] }
        #expect(URLProtocol.registerClass(BedrockPayloadProtocol.self))
        defer {
            URLProtocol.unregisterClass(BedrockPayloadProtocol.self)
            bedrockPayloadRequests.withLock { $0 = [] }
        }
        let signal = CancellationToken()
        let calls = LockedState(0)
        let result = await streamBedrock(model: bedrockPayloadModel(),
            context: normalizeContext(Context(messages: [.user(UserMessage(content: .text("hello")))])),
            options: BedrockOptions(env: [:], signal: signal, region: "us-east-1", cacheRetention: CacheRetention.none,
                onPayload: { _ in
                    calls.withLock { $0 += 1 }
                    await Task.yield()
                    signal.cancel()
                    return nil
                }, bearerToken: "fixture-token", timeoutMs: 5000, maxRetries: 0)).result()
        #expect(result.stopReason == .aborted)
        #expect(calls.withLock { $0 } == 1)
        #expect(bedrockPayloadRequests.withLock { $0.isEmpty })
    }
}
