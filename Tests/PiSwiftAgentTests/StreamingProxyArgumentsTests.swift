import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftAgent

private enum StreamingProxyTestError: Error { case missingURL, invalidResponse }

private final class StreamingProxyURLProtocol: URLProtocol {
    static let body = LockedState(Data())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: StreamingProxyTestError.missingURL)
            return
        }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                             headerFields: ["Content-Type": "text/event-stream"]) else {
            client?.urlProtocol(self, didFailWithError: StreamingProxyTestError.invalidResponse)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body.withLock { $0 })
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test("shows growing partial arguments without keeping the raw text on the block, in linear time", .timeLimit(.minutes(1)))
func proxyShowsGrowingPartialArgumentsInLinearTime() async throws {
    let content = String(repeating: "line \"quoted\" \\ end\n", count: 20_000)
    let argumentText = #"{"path":"a.ts","content":""# +
        content.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\"}"
    var body = "data: {\"type\":\"start\"}\n\n"
    body += "data: {\"type\":\"toolcall_start\",\"contentIndex\":0,\"id\":\"call_1\",\"toolName\":\"write\"}\n\n"
    var position = argumentText.startIndex
    while position < argumentText.endIndex {
        let end = argumentText.index(position, offsetBy: 32, limitedBy: argumentText.endIndex) ?? argumentText.endIndex
        let delta = String(argumentText[position..<end])
        let encoded = try JSONSerialization.data(withJSONObject: ["type":"toolcall_delta", "contentIndex":0, "delta":delta])
        body += "data: " + String(decoding: encoded, as: UTF8.self) + "\n\n"
        position = end
    }
    let final = try JSONSerialization.data(withJSONObject: ["type":"toolcall_end", "contentIndex":0,
        "toolCall":["type":"toolCall", "id":"call_1", "name":"write", "arguments":["path":"a.ts", "content":content]]])
    body += "data: " + String(decoding: final, as: UTF8.self) + "\n\n"
    body += "data: {\"type\":\"done\",\"reason\":\"toolUse\",\"usage\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"totalTokens\":0}}\n\n"
    StreamingProxyURLProtocol.body.withLock { $0 = Data(body.utf8) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StreamingProxyURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let model = Model(id: "port", name: "port", api: .openAIResponses, provider: "openai",
                      baseUrl: "https://example.invalid", reasoning: true, input: [.text],
                      cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                      contextWindow: 10000, maxTokens: 1000)
    let clock = ContinuousClock()
    let start = clock.now
    let stream = streamProxy(model: model, context: normalizeContext(Context(messages: [])),
                             options: ProxyStreamOptions(authToken: "token", proxyUrl: "https://proxy.invalid"),
                             session: session)
    var shown = 0
    var deltas = 0
    for await event in stream {
        guard case .toolCallDelta(_, _, let partial) = event,
              case .toolCall(let call) = partial.content.first else { continue }
        #expect(call.argumentsJSON == nil)
        let text = call.arguments["content"]?.value as? String ?? ""
        #expect(text.count >= shown)
        if deltas.isMultiple(of: 500) { #expect(content.hasPrefix(text)) }
        shown = text.count
        deltas += 1
    }
    let result = await stream.result()
    #expect(shown > content.count - 64)
    guard case .toolCall(let call) = result.content.first else { Issue.record("Missing final tool call"); return }
    #expect(call.arguments["content"]?.value as? String == content)
    #expect(start.duration(to: clock.now) < .seconds(10))
}
