import Foundation
import Testing
@testable import PiSwiftAI

private enum SharedV110Transport: CaseIterable, Sendable {
    case typesafe, cloudflare, decisions

    var api: ClassifierApi {
        switch self {
        case .typesafe: .typesafeSystemOne
        case .cloudflare: .cloudflareWorkersAISystemOne
        case .decisions: .openAIDecisions
        }
    }

    var label: String {
        switch self {
        case .typesafe: "System One API"
        case .cloudflare: "Cloudflare Workers AI"
        case .decisions: "OpenAI Decisions"
        }
    }

    func model(headers: ProviderHeaders? = nil,
               baseURL: String = "https://classifier.example/v1") -> ClassifierModel {
        ClassifierModel(id: "test-classifier", name: "Test", api: api, provider: "test-provider",
            baseUrl: baseURL, input: [.text, .image],
            cost: ModelCost(input: 1, output: 2, cacheRead: 0, cacheWrite: 0),
            contextWindow: 64_000, headers: headers)
    }

    func classify(_ context: ClassifierContext = sharedV110Context(),
                  model: ClassifierModel? = nil, options: ClassifierOptions) async -> ClassifierResult {
        let model = model ?? self.model()
        switch self {
        case .typesafe:
            return await classifyTypeSafeSystemOne(model: model, context: context, options: options)
        case .cloudflare:
            return await classifyCloudflareWorkersAISystemOne(model: model, context: context, options: options)
        case .decisions:
            return await classifyOpenAIDecisions(model: model, context: context, options: options)
        }
    }

    func success(usage: String? = nil) -> String {
        let answers = self == .decisions
            ? #"[{"type":"predicate","name":"approved","probability":0.75}]"#
            : #"{"approved":{"type":"noul","noul":0.75}}"#
        let usageField = usage.map { ",\"usage\":\($0)" } ?? ""
        let result = "{\"answers\":\(answers)\(usageField)}"
        return self == .cloudflare ? "{\"success\":true,\"result\":\(result)}" : result
    }
}

private func sharedV110Context(images: [ImageContent]? = nil) -> ClassifierContext {
    ClassifierContext(state: ["text": AnyCodable("Approved")], questions: [
        "approved": .bool(instructions: "Approved?", trueCriterion: "Yes", falseCriterion: "No")
    ], images: images)
}

private actor SharedV110Client: ProviderHTTPClient {
    struct Reply: Sendable {
        let body: String
        var status: Int = 200
        var headers: [String: String] = [:]
        var delayMs: Int = 0
    }
    private var replies: [Reply]
    private var requests: [URLRequest] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        let reply = replies.isEmpty ? Reply(body: "unexpected request", status: 400) : replies.removeFirst()
        if reply.delayMs > 0 { try await Task.sleep(for: .milliseconds(reply.delayMs)) }
        return ProviderHTTPResponse(statusCode: reply.status, headers: reply.headers, body: Data(reply.body.utf8))
    }

    func captured() -> [URLRequest] { requests }

    func waitUntilStarted() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
}

private struct SharedV110HookError: LocalizedError, Sendable {
    var errorDescription: String? { "Payload hook failed" }
}

@Test(.timeLimit(.minutes(1)), arguments: SharedV110Transport.allCases)
private func classifierSharedV110HTTPBodyUsesUTF16Limit(_ transport: SharedV110Transport) async {
    // The excerpt ends at a complete surrogate pair. The discarded emoji uses two UTF-16 units.
    let excerpt = String(repeating: "a", count: 3998) + "😀"
    let client = SharedV110Client([.init(body: " \n\(excerpt)😀xyz\t ", status: 400)])
    let result = await transport.classify(options: ClassifierOptions(apiKey: "secret", httpClient: client, maxRetries: 0))
    #expect(result.stopReason == .error)
    #expect(result.errorMessage == "\(transport.label) error (400): \(excerpt)... [truncated 5 chars]")
    #expect(await client.captured().count == 1)
}

@Test(.timeLimit(.minutes(1)), arguments: SharedV110Transport.allCases)
private func classifierSharedV110HTTPBodyTrimsAndHandlesEmpty(_ transport: SharedV110Transport) async {
    let client = SharedV110Client([.init(body: " \n reason \t", status: 400), .init(body: " \n\t ", status: 400)])
    let options = ClassifierOptions(apiKey: "secret", httpClient: client, maxRetries: 0)
    let trimmed = await transport.classify(options: options)
    #expect(trimmed.errorMessage == "\(transport.label) error (400): reason")
    let empty = await transport.classify(options: options)
    #expect(empty.errorMessage == "\(transport.label) error (400): \(transport.label) returned 400")
}

@Test(.timeLimit(.minutes(1)), arguments: [SharedV110Transport.typesafe, .cloudflare])
private func classifierSharedV110SystemOneChecksAPIBeforeImagesBeforeKey(_ transport: SharedV110Transport) async {
    let image = ImageContent(data: "aW1hZ2U=", mimeType: "image/png")
    let client = SharedV110Client([])
    let options = ClassifierOptions(httpClient: client, env: [:])
    let mismatch = await transport.classify(sharedV110Context(images: [image]),
        model: SharedV110Transport.decisions.model(), options: options)
    #expect(mismatch.errorMessage == "Unsupported classifier API: openai-decisions")
    let images = await transport.classify(sharedV110Context(images: [image]), options: options)
    #expect(images.errorMessage == "\(transport.label) does not support image input")
    let emptyImages = await transport.classify(sharedV110Context(images: []), options: options)
    #expect(emptyImages.errorMessage == "No API key for provider: test-provider")
    #expect(await client.captured().isEmpty)
}

@Test(.timeLimit(.minutes(1)), arguments: [SharedV110Transport.typesafe, .cloudflare])
private func classifierSharedV110SystemOneRejectsImagesBeforePayloadHook(_ transport: SharedV110Transport) async {
    let client = SharedV110Client([])
    let payloadCalls = LockedState(0)
    let image = ImageContent(data: "aW1hZ2U=", mimeType: "image/png")
    let result = await transport.classify(sharedV110Context(images: [image]), options: ClassifierOptions(
        apiKey: "secret", httpClient: client, onPayload: { _, _ in
            payloadCalls.withLock { $0 += 1 }
            return nil
        }))
    #expect(result.stopReason == .error)
    #expect(result.errorMessage == "\(transport.label) does not support image input")
    #expect(payloadCalls.withLock { $0 } == 0)
    #expect(await client.captured().isEmpty)
}

@Test(.timeLimit(.minutes(1)), arguments: [SharedV110Transport.typesafe, .cloudflare])
private func classifierSharedV110SystemOneKeepsSlashEscaping(_ transport: SharedV110Transport) async throws {
    let client = SharedV110Client([.init(body: transport.success())])
    var context = sharedV110Context()
    context.state = ["url": AnyCodable("https://example.test/a/b")]
    let result = await transport.classify(context, options: ClassifierOptions(apiKey: "secret", httpClient: client))
    #expect(result.stopReason == .stop)
    let request = try #require(await client.captured().first)
    let data = try #require(request.httpBody)
    let body = try #require(String(data: data, encoding: .utf8))
    #expect(body.contains(#""url":"https:\/\/example.test\/a\/b""#))
}

@Test(.timeLimit(.minutes(1)), arguments: [SharedV110Transport.typesafe, .cloudflare])
private func classifierSharedV110SystemOneKeepsKeyAndHookChecksBeforeURL(_ transport: SharedV110Transport) async {
    let client = SharedV110Client([])
    let model = transport.model(baseURL: "not a URL")
    let payloadCalls = LockedState(0)
    let failingHook: ClassifierPayloadHandler = { _, _ in
        payloadCalls.withLock { $0 += 1 }
        throw SharedV110HookError()
    }
    let missingKey = await transport.classify(model: model, options: ClassifierOptions(
        httpClient: client, env: [:], onPayload: failingHook))
    #expect(missingKey.errorMessage == "No API key for provider: test-provider")
    #expect(payloadCalls.withLock { $0 } == 0)
    let hookFailure = await transport.classify(model: model, options: ClassifierOptions(
        apiKey: "secret", httpClient: client, onPayload: failingHook))
    #expect(hookFailure.stopReason == .error)
    #expect(hookFailure.errorMessage == "Payload hook failed")
    #expect(payloadCalls.withLock { $0 } == 1)
    let invalidURL = await transport.classify(model: model, options: ClassifierOptions(
        apiKey: "secret", httpClient: client, onPayload: { _, _ in
            payloadCalls.withLock { $0 += 1 }
            return nil
        }))
    #expect(invalidURL.stopReason == .error)
    #expect(invalidURL.errorMessage == "Invalid classifier base URL: not a URL")
    #expect(payloadCalls.withLock { $0 } == 2)
    #expect(await client.captured().isEmpty)
}

@Test(.timeLimit(.minutes(1)), arguments: [SharedV110Transport.typesafe, .cloudflare])
private func classifierSharedV110SystemOneStillRetries504(_ transport: SharedV110Transport) async {
    let client = SharedV110Client([
        .init(body: "Gateway timed out", status: 504, headers: ["retry-after-ms": "0"]),
        .init(body: transport.success())
    ])
    let result = await transport.classify(options: ClassifierOptions(apiKey: "secret", httpClient: client, maxRetries: 1))
    #expect(result.stopReason == .stop)
    #expect(await client.captured().count == 2)
}

@Test(.timeLimit(.minutes(1)), arguments: SharedV110Transport.allCases)
private func classifierSharedV110HooksAndHeadersAcrossRetries(_ transport: SharedV110Transport) async throws {
    let client = SharedV110Client([
        .init(body: "busy", status: 503, headers: ["retry-after-ms": "0"]),
        .init(body: transport.success(), headers: ["x-request-id": "second"])
    ])
    let payloadCalls = LockedState(0)
    let responseCalls = LockedState(0)
    let model = transport.model(headers: ["Authorization": "Bearer model", "Content-Type": "model/type", "X-Source": "model"])
    let result = await transport.classify(model: model, options: ClassifierOptions(
        apiKey: "secret", httpClient: client,
        onPayload: { payload, callbackModel in
            #expect(callbackModel.id == "test-classifier")
            payloadCalls.withLock { $0 += 1 }
            return .object((payload.objectEntries ?? []) + [("tag", .string("hook"))])
        }, onResponse: { snapshot, callbackModel in
            #expect(snapshot.statusCode == 200)
            #expect(snapshot.headers["x-request-id"] == "second")
            #expect(callbackModel.id == "test-classifier")
            responseCalls.withLock { $0 += 1 }
        }, headers: ["authorization": nil, "content-type": "request/type", "x-source": "request"], maxRetries: 1))
    #expect(result.stopReason == .stop)
    #expect(payloadCalls.withLock { $0 } == 1)
    #expect(responseCalls.withLock { $0 } == 1)
    let requests = await client.captured()
    #expect(requests.count == 2)
    for request in requests {
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "request/type")
        #expect(request.value(forHTTPHeaderField: "X-Source") == "request")
        let body = try #require(request.httpBody)
        #expect(String(data: body, encoding: .utf8)?.contains(#""tag":"hook""#) == true)
    }
    #expect(requests.first?.httpBody == requests.last?.httpBody)
}

@Test(.timeLimit(.minutes(1)), arguments: SharedV110Transport.allCases)
private func classifierSharedV110ModelHeadersOverrideDefaults(_ transport: SharedV110Transport) async throws {
    let client = SharedV110Client([.init(body: transport.success()), .init(body: transport.success())])
    let options = ClassifierOptions(apiKey: "secret", httpClient: client)
    let defaults = await transport.classify(options: options)
    #expect(defaults.stopReason == .stop)
    let model = transport.model(headers: ["authorization": "Bearer model", "content-type": "model/type"])
    let overridden = await transport.classify(model: model, options: options)
    #expect(overridden.stopReason == .stop)
    let requests = await client.captured()
    #expect(requests.count == 2)
    let first = try #require(requests.first)
    let last = try #require(requests.last)
    #expect(first.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    #expect(first.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(last.value(forHTTPHeaderField: "Authorization") == "Bearer model")
    #expect(last.value(forHTTPHeaderField: "Content-Type") == "model/type")
}

@Test(.timeLimit(.minutes(1)), arguments: SharedV110Transport.allCases)
private func classifierSharedV110MalformedJSONDoesNotCallResponseHook(_ transport: SharedV110Transport) async {
    let client = SharedV110Client([.init(body: "{broken")])
    let responseCalls = LockedState(0)
    let result = await transport.classify(options: ClassifierOptions(apiKey: "secret", httpClient: client,
        onResponse: { _, _ in responseCalls.withLock { $0 += 1 } }, maxRetries: 0))
    #expect(result.stopReason == .error)
    #expect(result.answers.isEmpty)
    #expect(result.usage == nil)
    #expect(responseCalls.withLock { $0 } == 0)
    #expect(await client.captured().count == 1)
}

@Test(.timeLimit(.minutes(1)), arguments: SharedV110Transport.allCases)
private func classifierSharedV110CancellationBeforeAndDuringSend(_ transport: SharedV110Transport) async {
    let cancelled = CancellationToken()
    cancelled.cancel()
    let unusedClient = SharedV110Client([])
    let before = await transport.classify(options: ClassifierOptions(signal: cancelled, apiKey: "secret", httpClient: unusedClient))
    #expect(before.stopReason == .aborted)
    #expect(await unusedClient.captured().isEmpty)

    let signal = CancellationToken()
    let client = SharedV110Client([.init(body: transport.success(), delayMs: 10_000)])
    let responseCalls = LockedState(0)
    let task = Task {
        await transport.classify(options: ClassifierOptions(signal: signal, apiKey: "secret", httpClient: client,
            onResponse: { _, _ in responseCalls.withLock { $0 += 1 } }, maxRetries: 2))
    }
    await client.waitUntilStarted()
    signal.cancel()
    let during = await task.value
    #expect(during.stopReason == .aborted)
    #expect(await client.captured().count == 1)
    #expect(responseCalls.withLock { $0 } == 0)
}

@Test(.timeLimit(.minutes(1)), arguments: SharedV110Transport.allCases)
private func classifierSharedV110TimeoutIsPerAttempt(_ transport: SharedV110Transport) async {
    let slow = SharedV110Client([.init(body: transport.success(), delayMs: 10_000)])
    let timedOut = await transport.classify(options: ClassifierOptions(apiKey: "secret", httpClient: slow,
        timeoutMs: 20, maxRetries: 0))
    #expect(timedOut.stopReason == .error)
    #expect(timedOut.errorMessage == "Request timed out after 20ms")
    #expect(await slow.captured().count == 1)

    // The delay between attempts exceeds the timeout. Each send has its own timer.
    let client = SharedV110Client([
        .init(body: "busy", status: 503, headers: ["retry-after-ms": "150"]),
        .init(body: transport.success(), delayMs: 5)
    ])
    let retried = await transport.classify(options: ClassifierOptions(apiKey: "secret", httpClient: client,
        timeoutMs: 100, maxRetries: 1))
    #expect(retried.stopReason == .stop)
    #expect(await client.captured().count == 2)
}

@Test(.timeLimit(.minutes(1)), arguments: SharedV110Transport.allCases)
private func classifierSharedV110InvalidUsageRemainsUnbilledOrZero(_ transport: SharedV110Transport) async {
    let cases: [(String, Int?, Int?)] = [
        ("null", nil, nil), ("[]", nil, nil), ("{}", nil, nil),
        (#"{"cost":3}"#, nil, nil),
        (#"{"input_tokens":true,"output_tokens":false}"#, 0, 0),
        (#"{"input_tokens":"8","output_tokens":3}"#, 0, 3),
        (#"{"input_tokens":null,"output_tokens":2}"#, 0, 2),
        (#"{"input_tokens":-5,"output_tokens":0}"#, 0, 0),
        (#"{"input_tokens":2.75,"output_tokens":1.25}"#, 2, 1)
    ]
    for (usage, input, output) in cases {
        let client = SharedV110Client([.init(body: transport.success(usage: usage))])
        let result = await transport.classify(options: ClassifierOptions(apiKey: "secret", httpClient: client))
        #expect(result.stopReason == .stop)
        #expect(result.usage?.input == input)
        #expect(result.usage?.output == output)
        if let input, let output {
            #expect(result.usage?.totalTokens == input + output)
            #expect(result.usage?.cacheRead == 0)
            #expect(result.usage?.cacheWrite == 0)
        } else {
            #expect(result.usage == nil)
        }
    }
}
