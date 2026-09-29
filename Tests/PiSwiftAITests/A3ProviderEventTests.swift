import Foundation
import Testing
@testable import PiSwiftAI

private struct A3ProviderEventClient: ProviderHTTPClient {
    let body: Data

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        ProviderHTTPResponse(statusCode: 200, body: body)
    }
}

private func a3ProviderEventModel(api: Api, provider: String) -> Model {
    Model(id: "test-model", name: "Test", api: api, provider: provider,
          baseUrl: "https://example.invalid/v1", reasoning: false, input: [.text],
          cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
          contextWindow: 8192, maxTokens: 1024)
}

private func a3ProviderEventSSE(_ events: [[String: Any]]) throws -> Data {
    let frames = try events.map { "data: " + String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n\n" }
    return Data(frames.joined().utf8)
}

// Port of openai-completions-provider-stream-event.test.ts: unknown fields survive before typed decoding.
@Test func a3CompletionsObservesRawProviderJSONInOrder() async throws {
    let model = a3ProviderEventModel(api: .openAICompletions, provider: "custom")
    let events: [[String: Any]] = [
        ["id": "chunk_1", "created": 0, "model": model.id, "object": "chat.completion.chunk",
         "provider_extra": ["marker": "first"],
         "choices": [["index": 0, "delta": ["content": "Hi"], "finish_reason": NSNull()]]],
        ["id": "chunk_2", "created": 0, "model": model.id, "object": "chat.completion.chunk",
         "provider_extra": ["marker": "second"],
         "choices": [["index": 0, "delta": [:], "finish_reason": "stop"]]],
    ]
    let observed = LockedState<[String]>([])
    let options = OpenAICompletionsOptions(apiKey: "test", httpClient: A3ProviderEventClient(body: try a3ProviderEventSSE(events)),
        onProviderStreamEvent: { event, receivedModel in
            let root = event.value as? [String: Any]
            let extra = root?["provider_extra"] as? [String: Any]
            observed.withLock { $0.append("\(receivedModel.id):\(extra?["marker"] as? String ?? "")") }
        })
    let result = await streamOpenAICompletions(model: model, context: normalizeContext(Context(messages: [])), options: options).result()
    #expect(result.stopReason == .stop)
    #expect(observed.withLock { $0 } == ["test-model:first", "test-model:second"])
}

// Port of openai-responses-terminal-event.test.ts callback coverage: observer failures fail the stream.
@Test func a3ResponsesObserverFailureStopsAtFirstEvent() async throws {
    let model = a3ProviderEventModel(api: .openAIResponses, provider: "openai")
    let events: [[String: Any]] = [
        ["type": "response.created", "provider_extra": 7, "response": ["id": "resp_1"]],
        ["type": "response.completed", "response": ["status": "completed"]],
    ]
    let calls = LockedState<Int>(0)
    let options = OpenAIResponsesOptions(apiKey: "test", httpClient: A3ProviderEventClient(body: try a3ProviderEventSSE(events)),
        onProviderStreamEvent: { event, _ in
            #expect((event.value as? [String: Any])?["provider_extra"] as? Int == 7)
            calls.withLock { $0 += 1 }
            throw A3ProviderObserverFailure.observer
        })
    let result = await streamOpenAIResponses(model: model, context: normalizeContext(Context(messages: [])), options: options).result()
    #expect(result.stopReason == .error)
    #expect(calls.withLock { $0 } == 1)
}

private enum A3ProviderObserverFailure: Error { case observer }

// Port of anthropic-sse-parsing.test.ts observer case: observe the unmodified event object.
@Test func a3AnthropicObserverSeesUnknownFields() async throws {
    let model = a3ProviderEventModel(api: .anthropicMessages, provider: "anthropic")
    let events: [[String: Any]] = [
        ["type": "message_start", "provider_extra": ["token": "kept"],
         "message": ["type": "message", "role": "assistant", "content": [], "id": "msg_1",
                     "model": model.id, "usage": ["input_tokens": 1, "output_tokens": 0]]],
        ["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 1]],
        ["type": "message_stop"],
    ]
    let body = try events.map { event in
        "event: \(event["type"] as? String ?? "")\ndata: "
            + String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self) + "\n\n"
    }.joined()
    let observed = LockedState<[String]>([])
    let options = AnthropicOptions(apiKey: "test", httpClient: A3ProviderEventClient(body: Data(body.utf8)),
        onProviderStreamEvent: { event, _ in
            let root = event.value as? [String: Any]
            let extra = root?["provider_extra"] as? [String: Any]
            observed.withLock { $0.append(extra?["token"] as? String ?? "ordinary") }
        })
    let result = await streamAnthropic(model: model, context: normalizeContext(Context(messages: [])), options: options).result()
    #expect(result.stopReason == .stop)
    #expect(observed.withLock { $0 } == ["kept", "ordinary", "ordinary"])
}

// Port of google-raw-stop-reason.test.ts observer case; both adapters use the same raw SSE payload.
@Test(arguments: [false, true])
func a3GoogleObserversSeeRawProviderJSON(vertex: Bool) async throws {
    let model = a3ProviderEventModel(api: vertex ? .googleVertex : .googleGenerativeAI,
                                     provider: vertex ? "vertex" : "google")
    let body = try a3ProviderEventSSE([[
        "provider_extra": ["flag": true], "responseId": "response-1",
        "candidates": [["content": ["parts": [["text": "hello"]]], "finishReason": "STOP"]],
    ]])
    let observed = LockedState<Bool>(false)
    let callback: ProviderStreamEventHandler = { event, _ in
        let extra = (event.value as? [String: Any])?["provider_extra"] as? [String: Any]
        observed.withLock { $0 = extra?["flag"] as? Bool == true }
    }
    let context = normalizeContext(Context(messages: [.user(UserMessage(content: .text("Hi")))]))
    let result: AssistantMessage
    if vertex {
        result = await streamGoogleVertex(model: model, context: context,
            options: GoogleVertexOptions(apiKey: "test", httpClient: A3ProviderEventClient(body: body),
                project: "test-project", location: "us-central1", onProviderStreamEvent: callback)).result()
    } else {
        result = await streamGoogle(model: model, context: context,
            options: GoogleOptions(apiKey: "test", httpClient: A3ProviderEventClient(body: body),
                onProviderStreamEvent: callback)).result()
    }
    #expect(result.stopReason == .stop)
    #expect(observed.withLock { $0 })
}

// Port of openai-codex-stream.test.ts observer case: a callback failure ends SSE immediately.
@Test func a3CodexObserverFailureDoesNotConsumeLaterEvents() async throws {
    let model = a3ProviderEventModel(api: .openAICodexResponses, provider: "openai-codex")
    let tokenPayload = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"acc_test"}}"#.utf8).base64EncodedString()
    let events: [[String: Any]] = [
        ["type": "response.created", "provider_extra": "first", "response": ["id": "resp_1"]],
        ["type": "response.completed", "response": ["status": "completed"]],
    ]
    let calls = LockedState<Int>(0)
    let result = await streamOpenAICodexResponses(model: model, context: normalizeContext(Context(messages: [])),
        options: OpenAICodexResponsesOptions(apiKey: "e30.\(tokenPayload).sig",
            httpClient: A3ProviderEventClient(body: try a3ProviderEventSSE(events)), transport: .sse,
            onProviderStreamEvent: { event, _ in
                #expect((event.value as? [String: Any])?["provider_extra"] as? String == "first")
                calls.withLock { $0 += 1 }
                throw A3ProviderObserverFailure.observer
            })).result()
    #expect(result.stopReason == .error)
    #expect(calls.withLock { $0 } == 1)
}

// Port of azure-openai-base-url.test.ts observer case: Azure exposes raw Responses fields.
@Test func a3AzureResponsesObserverSeesUnknownFields() async throws {
    let model = a3ProviderEventModel(api: .azureOpenAIResponses, provider: "azure-openai-responses")
    let events: [[String: Any]] = [
        ["type": "response.created", "provider_extra": "azure-field", "response": ["id": "resp_1"]],
        ["type": "response.completed", "response": ["id": "resp_1", "status": "completed"]],
    ]
    let observed = LockedState<[String]>([])
    var options = AzureOpenAIResponsesOptions(apiKey: "test", httpClient: A3ProviderEventClient(body: try a3ProviderEventSSE(events)))
    options.azureBaseUrl = "https://azure.example.invalid"
    options.azureApiVersion = "v1"
    options.azureDeploymentName = "test"
    options.onProviderStreamEvent = { event, _ in
        let root = event.value as? [String: Any]
        observed.withLock { $0.append(root?["provider_extra"] as? String ?? "ordinary") }
    }
    let result = await streamAzureOpenAIResponses(model: model, context: normalizeContext(Context(messages: [])), options: options).result()
    #expect(result.stopReason == .stop)
    #expect(observed.withLock { $0 } == ["azure-field", "ordinary"])
}

// The Swift-only Gemini CLI adapter shares the provider event observer through its SSE stream.
@Test func a3GeminiCliObserverSeesUnknownFields() async throws {
    await codexRequestLock.withLock {
        let observed = LockedState<String?>(nil)
        GeminiRetryMockURLProtocol.requestHandler.withLock { $0 = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["content-type": "text/event-stream"])!
            let payload = #"{"provider_extra":"cli-field","response":{"candidates":[{"content":{"parts":[{"text":"pong"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1,"totalTokenCount":2}}}"#
            return (response, Data("data: \(payload)\n\n".utf8))
        } }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GeminiRetryMockURLProtocol.self]
        let testSession = URLSession(configuration: sessionConfig)
        setGoogleGeminiCliSessionOverrideForTesting(testSession)
        defer {
            setGoogleGeminiCliSessionOverrideForTesting(nil)
            testSession.invalidateAndCancel()
            GeminiRetryMockURLProtocol.requestHandler.withLock { $0 = nil }
        }
        let model = Model(id: "gemini-test", name: "Test", api: .googleGeminiCli,
            provider: "google-gemini-cli", baseUrl: "http://cloudcode-pa.googleapis.com",
            reasoning: false, input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 8192, maxTokens: 1024)
        var options = GoogleGeminiCliOptions(apiKey: #"{"token":"test","projectId":"test-project"}"#)
        options.maxRetries = 0
        options.onProviderStreamEvent = { event, _ in
            let root = event.value as? [String: Any]
            observed.withLock { $0 = root?["provider_extra"] as? String }
        }
        let result = await streamGoogleGeminiCli(model: model,
            context: normalizeContext(Context(messages: [.user(UserMessage(content: .text("ping")))])),
            options: options).result()
        #expect(result.stopReason == .stop)
        #expect(observed.withLock { $0 } == "cli-field")
    }
}

private final class A3BedrockEventProtocol: URLProtocol {
    static let body = LockedState<Data>(Data())
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "bedrock-a3.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                  headerFields: ["content-type": "application/vnd.amazon.eventstream"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body.withLock { $0 })
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func a3BedrockFrame(type: String, event: [String: Any]) throws -> Data {
    let payload = try JSONSerialization.data(withJSONObject: event)
    let name = Data(":event-type".utf8)
    let value = Data(type.utf8)
    var headers = Data([UInt8(name.count)])
    headers.append(name)
    headers.append(7)
    headers.append(UInt8((value.count >> 8) & 0xff))
    headers.append(UInt8(value.count & 0xff))
    headers.append(value)
    let total = UInt32(12 + headers.count + payload.count + 4)
    let headerLength = UInt32(headers.count)
    func bytes(_ number: UInt32) -> [UInt8] {
        [UInt8((number >> 24) & 0xff), UInt8((number >> 16) & 0xff), UInt8((number >> 8) & 0xff), UInt8(number & 0xff)]
    }
    var frame = Data(bytes(total) + bytes(headerLength) + [0, 0, 0, 0])
    frame.append(headers)
    frame.append(payload)
    frame.append(contentsOf: [0, 0, 0, 0])
    return frame
}

// Port of bedrock-raw-stop-reason.test.ts observer case: the decoded event-stream JSON is exposed.
@Test func a3BedrockObserverSeesDecodedEventStreamJSON() async throws {
    try await codexRequestLock.withLock {
        var body = try a3BedrockFrame(type: "messageStart", event: ["role": "assistant", "provider_extra": "bedrock-field"])
        body.append(try a3BedrockFrame(type: "messageStop", event: ["stopReason": "end_turn"]))
        A3BedrockEventProtocol.body.withLock { $0 = body }
        #expect(URLProtocol.registerClass(A3BedrockEventProtocol.self))
        defer { URLProtocol.unregisterClass(A3BedrockEventProtocol.self) }
        let model = Model(id: "test-bedrock", name: "Test", api: .bedrockConverseStream,
            provider: "amazon-bedrock", baseUrl: "https://bedrock-a3.invalid", reasoning: false,
            input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 8192, maxTokens: 1024)
        let observed = LockedState<[String]>([])
        let result = await streamBedrock(model: model,
            context: normalizeContext(Context(messages: [.user(UserMessage(content: .text("Hi")))])),
            options: BedrockOptions(region: "us-east-1", bearerToken: "test",
                onProviderStreamEvent: { event, _ in
                    let root = event.value as? [String: Any]
                    observed.withLock { $0.append(root?["provider_extra"] as? String ?? "ordinary") }
                }, maxRetries: 0)).result()
        #expect(result.stopReason == .stop)
        #expect(observed.withLock { $0 } == ["bedrock-field", "ordinary"])
    }
}

@Test func a3SimpleOptionsForwardProviderObserverToCompletions() async throws {
    let model = a3ProviderEventModel(api: .openAICompletions, provider: "custom")
    let observed = LockedState<Int>(0)
    let client = A3ProviderEventClient(body: try a3ProviderEventSSE([[
        "id": "chunk", "created": 0, "model": model.id, "object": "chat.completion.chunk",
        "choices": [["index": 0, "delta": [:], "finish_reason": "stop"]],
    ]]))
    let simple = SimpleStreamOptions(apiKey: "test", httpClient: client,
        onProviderStreamEvent: { _, _ in observed.withLock { $0 += 1 } })
    let direct = mapOpenAICompletionsSimpleOptions(model: model, options: simple, apiKey: "test")
    let result = await streamOpenAICompletions(model: model, context: normalizeContext(Context(messages: [])), options: direct).result()
    #expect(result.stopReason == .stop)
    #expect(observed.withLock { $0 } == 1)
}
