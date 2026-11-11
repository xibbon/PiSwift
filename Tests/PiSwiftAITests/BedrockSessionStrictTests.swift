import Foundation
import Testing
@testable import PiSwiftAI

private let aWireBedrockHost = "awire-bedrock.invalid"
private let aWireBedrockRequests = LockedState<[Data]>([])
private let aWireBedrockResponses = LockedState<[Int]>([])
private let aWireBedrockErrorMessage = LockedState("Too many strict tools (21 > 20)")

private final class AWireBedrockProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == aWireBedrockHost }
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
        aWireBedrockRequests.withLock { $0.append(body) }
        let status = aWireBedrockResponses.withLock { values -> Int in
            values.isEmpty ? 200 : values.removeFirst()
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["x-amzn-errortype": "ValidationException", "content-type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if status == 400 {
            let message = aWireBedrockErrorMessage.withLock { $0 }
            let data = (try? JSONSerialization.data(withJSONObject: ["message": message,
                "__type": "ValidationException"])) ?? Data()
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func aWireBedrockModel() -> Model {
    Model(id: "us.anthropic.claude-sonnet-test", name: "Claude", api: .bedrockConverseStream,
        provider: "amazon-bedrock", baseUrl: "https://\(aWireBedrockHost)", reasoning: false,
        input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 200_000, maxTokens: 100, compat: OpenAICompat(supportsStrictMode: true))
}


@Test(.timeLimit(.minutes(1))) func aWireBedrockRemembersStrictLimitsUntilCleanupV152() async throws {
    try await codexRequestLock.withLock {
        let sessionId = UUID().uuidString
        defer { cleanupStrictToolLimits(sessionId) }
        #expect(URLProtocol.registerClass(AWireBedrockProtocol.self))
        defer { URLProtocol.unregisterClass(AWireBedrockProtocol.self) }
        aWireBedrockRequests.withLock { $0 = [] }
        aWireBedrockResponses.withLock { $0 = [400, 200, 200, 200] }
        aWireBedrockErrorMessage.withLock { $0 = "Too many strict tools (21 > 20)" }
        let schema: [String: AnyCodable] = ["type": AnyCodable("object"), "properties": AnyCodable([String: Any]())]
        let preferred = AITool(name: "preferred", description: "Preferred", parameters: schema,
            constrainedSampling: .jsonSchema(strict: .prefer))
        let context = normalizeContext(Context(messages: [.user(UserMessage(content: .text("go")))], tools: [preferred]))
        var options = BedrockOptions(env: [:], region: "us-east-1", bearerToken: "fixture-token", timeoutMs: 5000, maxRetries: 0)
        options.sessionId = sessionId
        _ = await streamBedrock(model: aWireBedrockModel(), context: context, options: options).result()
        #expect(hasExceededStrictToolLimits(sessionId))
        _ = await streamBedrock(model: aWireBedrockModel(), context: context, options: options).result()
        try cleanupSessionResources(sessionId)
        _ = await streamBedrock(model: aWireBedrockModel(), context: context, options: options).result()
        let requests = aWireBedrockRequests.withLock { $0 }
        #expect(requests.count == 4)
        let strict = try requests.map { body -> Bool? in
            let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let config = payload["toolConfig"] as? [String: Any]
            let tools = config?["tools"] as? [[String: Any]]
            return (tools?.first?["toolSpec"] as? [String: Any])?["strict"] as? Bool
        }
        #expect(strict == [true, nil, nil, true])
    }
}
