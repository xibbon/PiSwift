import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftAgent

private final class BooleanMetadataURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let literal = request.url!.host!.components(separatedBy: ".")[0]
        let body = """
            data: {"type":"start"}

            data: {"type":"done","reason":"stop","endTurn":\(literal),"usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}}}


            """
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test(.timeLimit(.minutes(1)), arguments: ["0", "1", "false", "true"])
func proxyEndTurnRequiresJSONBoolean(_ literal: String) async {
    let model = Model(id: "test", name: "test", api: .openAIResponses, provider: "openai",
        baseUrl: "https://example.invalid", reasoning: false, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 1000, maxTokens: 100)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BooleanMetadataURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let stream = streamProxy(model: model, context: normalizeContext(Context(messages: [])),
        options: ProxyStreamOptions(authToken: "test", proxyUrl: "https://\(literal).invalid"), session: session)
    for await _ in stream {}
    let result = await stream.result()
    let expected: Bool? = literal == "true" ? true : literal == "false" ? false : nil
    #expect(result.stopReason == .stop)
    #expect(result.endTurn == expected)
}
