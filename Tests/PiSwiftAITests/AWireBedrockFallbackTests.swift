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

// bedrock-strict-tool-fallback.test.ts:117,174,183, #11416.
@Test(.timeLimit(.minutes(1))) func aWireBedrockRetriesPreferredToolOnceAndKeepsRequiredStrict() async throws {
    try await codexRequestLock.withLock {
        aWireBedrockRequests.withLock { $0 = [] }
        aWireBedrockResponses.withLock { $0 = [400, 200] }
        #expect(URLProtocol.registerClass(AWireBedrockProtocol.self))
        defer { URLProtocol.unregisterClass(AWireBedrockProtocol.self) }
        let schema: [String: AnyCodable] = ["type": AnyCodable("object"), "properties": AnyCodable([String: Any]())]
        let preferred = AITool(name: "preferred", description: "Preferred", parameters: schema,
            constrainedSampling: .jsonSchema(strict: .prefer))
        let required = AITool(name: "required", description: "Required", parameters: schema,
            constrainedSampling: .jsonSchema(strict: .require))
        _ = await streamBedrock(model: aWireBedrockModel(),
            context: normalizeContext(Context(messages: [.user(UserMessage(content: .text("go")))],
                tools: [preferred, required])),
            options: BedrockOptions(env: [:], region: "us-east-1", bearerToken: "fixture-token",
                timeoutMs: 5000, maxRetries: 0)).result()
        let requests = aWireBedrockRequests.withLock { $0 }
        #expect(requests.count == 2)
        let first = try #require(JSONSerialization.jsonObject(with: requests[0]) as? [String: Any])
        let second = try #require(JSONSerialization.jsonObject(with: requests[1]) as? [String: Any])
        func strictValues(_ payload: [String: Any]) -> [Bool?] {
            let config = payload["toolConfig"] as? [String: Any]
            let tools = config?["tools"] as? [[String: Any]] ?? []
            return tools.map { ($0["toolSpec"] as? [String: Any])?["strict"] as? Bool }
        }
        #expect(strictValues(first) == [true, true])
        #expect(strictValues(second) == [nil, true])
    }
}

// bedrock-strict-tool-fallback.test.ts:155,165,174,183.
@Test(.timeLimit(.minutes(1))) func aWireBedrockFallbackIsBoundedAndPerRequest() async throws {
    try await codexRequestLock.withLock {
        #expect(URLProtocol.registerClass(AWireBedrockProtocol.self))
        defer { URLProtocol.unregisterClass(AWireBedrockProtocol.self) }
        let schema: [String: AnyCodable] = ["type": AnyCodable("object"), "properties": AnyCodable([String: Any]())]
        let preferred = AITool(name: "preferred", description: "Preferred", parameters: schema,
            constrainedSampling: .jsonSchema(strict: .prefer))
        let required = AITool(name: "required", description: "Required", parameters: schema,
            constrainedSampling: .jsonSchema(strict: .require))
        func call(_ tools: [AITool]) async {
            _ = await streamBedrock(model: aWireBedrockModel(),
                context: normalizeContext(Context(messages: [.user(UserMessage(content: .text("go")))], tools: tools)),
                options: BedrockOptions(env: [:], region: "us-east-1", bearerToken: "fixture-token",
                    timeoutMs: 5000, maxRetries: 0)).result()
        }
        aWireBedrockRequests.withLock { $0 = [] }
        aWireBedrockResponses.withLock { $0 = [400] }
        aWireBedrockErrorMessage.withLock { $0 = "Too many strict tools (21 > 20)" }
        await call([required])
        #expect(aWireBedrockRequests.withLock { $0.count } == 1)

        aWireBedrockRequests.withLock { $0 = [] }
        aWireBedrockResponses.withLock { $0 = [400] }
        aWireBedrockErrorMessage.withLock { $0 = "Invalid tool schema" }
        await call([preferred])
        #expect(aWireBedrockRequests.withLock { $0.count } == 1)

        aWireBedrockRequests.withLock { $0 = [] }
        aWireBedrockResponses.withLock { $0 = [400, 400] }
        aWireBedrockErrorMessage.withLock { $0 = "Too many strict tools (21 > 20)" }
        await call([preferred])
        #expect(aWireBedrockRequests.withLock { $0.count } == 2)

        aWireBedrockRequests.withLock { $0 = [] }
        aWireBedrockResponses.withLock { $0 = [400, 200, 400, 200] }
        await call([preferred])
        await call([preferred])
        let requests = aWireBedrockRequests.withLock { $0 }
        #expect(requests.count == 4)
        for index in [0, 2] {
            let payload = try #require(JSONSerialization.jsonObject(with: requests[index]) as? [String: Any])
            let config = try #require(payload["toolConfig"] as? [String: Any])
            let tools = try #require(config["tools"] as? [[String: Any]])
            #expect((tools[0]["toolSpec"] as? [String: Any])?["strict"] as? Bool == true)
        }
    }
}
