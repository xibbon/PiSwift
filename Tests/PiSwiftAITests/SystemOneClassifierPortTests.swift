import Foundation
import Testing
@testable import PiSwiftAI

private actor SystemOneTestClient: ProviderHTTPClient {
    struct Reply: Sendable { let status: Int; let headers: [String: String]; let body: Data }
    private var replies: [Reply]
    private var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        let reply = replies.isEmpty ? Reply(status: 500, headers: [:], body: Data()) : replies.removeFirst()
        return ProviderHTTPResponse(statusCode: reply.status, headers: reply.headers, body: reply.body)
    }
    func captured() -> [URLRequest] { requests }
}

private func systemOneReply(_ json: String, status: Int = 200, headers: [String: String] = [:]) -> SystemOneTestClient.Reply {
    .init(status: status, headers: headers, body: Data(json.utf8))
}
private let systemOneAnswers = #"{"category":{"type":"choice","choice":"success","probabilities":{"success":0.9,"failure":0.1},"confidence":0.8},"satisfaction":{"type":"score","score":2,"confidence":0.7},"approved":{"type":"noul","noul":0.95}}"#
private func systemOneContext() -> ClassifierContext {
    ClassifierContext(state: ["text": AnyCodable("The deployment succeeded")], questions: [
        "category": .choice(instructions: "Classify", criteria: ["success": "Successful", "failure": "Failed"]),
        "satisfaction": .score(instructions: "Score", criteria: ["low", "high"]),
        "approved": .bool(instructions: "Approve?", trueCriterion: "Yes", falseCriterion: "No")
    ])
}
private func systemOneModel(api: ClassifierApi = .typesafeSystemOne, provider: String = "typesafe", baseURL: String = "https://api.typesafe.ai/v1/", headers: ProviderHeaders? = nil) -> ClassifierModel {
    ClassifierModel(id: "jev-latest", name: "Jev", api: api, provider: provider, baseUrl: baseURL,
                    input: [.text], cost: ModelCost(input: 0.042, output: 0, cacheRead: 0, cacheWrite: 0),
                    contextWindow: 64_000, headers: headers)
}

@Test func systemOneTypesafeRequestAnswerAndBilling() async throws {
    let client = SystemOneTestClient([systemOneReply(#"{"answers":\#(systemOneAnswers),"usage":{"input_tokens":308,"output_tokens":23}}"#)])
    let result = await classify(model: systemOneModel(), context: systemOneContext(),
                                options: ClassifierOptions(apiKey: "secret", httpClient: client, temperature: 1.5))
    #expect(result.stopReason == .stop)
    #expect(result.usage?.input == 308)
    #expect(result.usage?.totalTokens == 331)
    #expect(abs((result.usage?.cost.total ?? 0) - 0.000012936) < 0.000000000001)
    if case .bool(let probability)? = result.answers["approved"] { #expect(probability == 0.95) } else { Issue.record("Missing bool answer") }
    let request = try #require(await client.captured().first)
    #expect(request.url?.absoluteString == "https://api.typesafe.ai/v1/systemone")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    let bodyData = try #require(request.httpBody)
    let body = try #require(String(data: bodyData, encoding: .utf8))
    #expect(body == #"{"model":"jev-latest","state":{"text":"The deployment succeeded"},"questions":{"category":{"type":"choice","instructions":"Classify","criteria":{"success":"Successful","failure":"Failed"}},"satisfaction":{"type":"score","instructions":"Score","criteria":["low","high"]},"approved":{"type":"noul","instructions":"Approve?","criteria":{"true":"Yes","false":"No"}}}}"#)
    #expect(!body.contains("temperature"))
}

@Test func systemOneStrictParsingKeepsUsage() async {
    let client = SystemOneTestClient([systemOneReply(#"{"answers":{},"usage":{"input_tokens":10,"output_tokens":2}}"#)])
    let result = await classify(model: systemOneModel(), context: systemOneContext(),
                                options: ClassifierOptions(apiKey: "secret", httpClient: client))
    #expect(result.stopReason == .error)
    #expect(result.errorMessage?.contains("did not return an answer for category") == true)
    #expect(result.usage?.input == 10)
    #expect(result.answers.isEmpty)
}

@Test func systemOneCloudflareResolvesAccountAndParsesEnvelope() async throws {
    let reply = #"{"success":true,"result":{"state":"Completed","result":{"answers":\#(systemOneAnswers),"usage":{"input_tokens":4,"output_tokens":1}}}}"#
    let client = SystemOneTestClient([systemOneReply(reply)])
    let model = systemOneModel(api: .cloudflareWorkersAISystemOne, provider: "cloudflare-workers-ai",
        baseURL: "https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/ai")
    let result = await classify(model: model, context: systemOneContext(), options: ClassifierOptions(
        apiKey: "token", httpClient: client, env: ["CLOUDFLARE_ACCOUNT_ID": "account-1"]))
    #expect(result.stopReason == .stop)
    #expect(result.usage?.input == 4)
    let request = try #require(await client.captured().first)
    #expect(request.url?.absoluteString == "https://api.cloudflare.com/client/v4/accounts/account-1/ai/run")
    let bodyData = try #require(request.httpBody)
    let body = try #require(String(data: bodyData, encoding: .utf8))
    #expect(body.hasPrefix(#"{"model":"jev-latest","input":{"state":"#))
    #expect(body.contains(#""type":"noul""#))
}

@Test func systemOneHeadersRetryAndMissingKey() async throws {
    let client = SystemOneTestClient([
        systemOneReply("retry", status: 500, headers: ["retry-after-ms": "0"]),
        systemOneReply(#"{"answers":\#(systemOneAnswers)}"#)
    ])
    let model = systemOneModel(headers: ["Authorization": "Bearer model", "X-Source": "model"])
    let result = await classify(model: model, context: systemOneContext(), options: ClassifierOptions(
        apiKey: "secret", httpClient: client, headers: ["authorization": "Bearer request", "x-source": "request"], maxRetries: 1))
    #expect(result.stopReason == .stop)
    let requests = await client.captured()
    #expect(requests.count == 2)
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer request")
    #expect(requests[0].value(forHTTPHeaderField: "X-Source") == "request")
    let missing = await classifyTypeSafeSystemOne(model: model, context: systemOneContext(), options: ClassifierOptions(httpClient: client, env: [:]))
    #expect(missing.stopReason == .error)
    #expect(missing.errorMessage == "No API key for provider: typesafe")
    #expect(await client.captured().count == 2)
}

@Test func systemOneCatalogEntriesAndEnvironmentNames() {
    #expect(getClassifierModel(provider: "typesafe", modelId: "jev-latest")?.api == .typesafeSystemOne)
    #expect(getClassifierModel(provider: "cloudflare-workers-ai", modelId: "typesafe/jev")?.api == .cloudflareWorkersAISystemOne)
    #expect(getClassifierModels(provider: "openrouter").contains { $0.api == .typesafeSystemOne })
    #expect(getClassifierModel(provider: "unknown", modelId: "x") == nil)
    #expect(getModel(provider: "typesafe", modelId: "jev-latest") == nil)
    #expect(getAllBuiltinModels(provider: "typesafe").count == 1)
    #expect(getClassifierModels(provider: "openrouter").allSatisfy {
        $0.api == .typesafeSystemOne && $0.baseUrl == "https://openrouter.ai/api/v1"
    })
}

@Test func systemOneCatalogRoutesVercelAndOpenCode() async throws {
    let rows: [(String, String, String)] = [
        ("vercel-ai-gateway", "typesafe-ai/jev", "https://ai-gateway.vercel.sh/typesafe/v1/systemone"),
        ("opencode", "jev-1.13", "https://opencode.ai/zen/v1/systemone"),
        ("opencode", "jev-1.13-free", "https://opencode.ai/zen/v1/systemone")
    ]
    for (provider, id, expectedURL) in rows {
        let model = try #require(getClassifierModel(provider: provider, modelId: id))
        #expect(model.api == .typesafeSystemOne)
        #expect(model.contextWindow == 32_000)
        #expect(getModel(provider: provider, modelId: id) == nil)
        let client = SystemOneTestClient([systemOneReply(#"{"answers":{"approved":{"type":"noul","noul":0.8}}}"#)])
        let context = ClassifierContext(state: ["text": AnyCodable("yes")], questions: [
            "approved": .bool(instructions: "Approved?", trueCriterion: "Yes", falseCriterion: "No")
        ])
        let result = await classify(model: model, context: context,
            options: ClassifierOptions(apiKey: "secret", httpClient: client))
        #expect(result.stopReason == .stop)
        #expect(await client.captured().first?.url?.absoluteString == expectedURL)
        if case .bool(let probability)? = result.answers["approved"] {
            #expect(probability == 0.8)
        } else { Issue.record("Missing bool answer for \(provider)/\(id)") }
    }
}

@Test func systemOneDirectAPIMismatchAndOpenRouterEndpoint() async throws {
    let client = SystemOneTestClient([systemOneReply(#"{"answers":\#(systemOneAnswers)}"#)])
    let wrong = systemOneModel(api: .cloudflareWorkersAISystemOne)
    let rejected = await classifyTypeSafeSystemOne(model: wrong, context: systemOneContext(),
        options: ClassifierOptions(apiKey: "secret", httpClient: client))
    #expect(rejected.stopReason == .error)
    #expect(rejected.errorMessage?.contains("Unsupported classifier API") == true)
    #expect(await client.captured().isEmpty)
    let router = systemOneModel(provider: "openrouter", baseURL: "https://openrouter.ai/api/v1")
    let result = await classify(model: router, context: systemOneContext(),
        options: ClassifierOptions(apiKey: "secret", httpClient: client))
    #expect(result.stopReason == .stop)
    #expect(await client.captured().first?.url?.absoluteString == "https://openrouter.ai/api/v1/systemone")
}

@Test func systemOnePrototypeSensitiveIDAndMalformedUsage() async throws {
    let context = ClassifierContext(state: [:], questions: ClassifierQuestions([
        ("__proto__", .bool(instructions: "True?", trueCriterion: "Yes", falseCriterion: "No"))
    ]))
    let client = SystemOneTestClient([
        systemOneReply(#"{"answers":{"__proto__":{"type":"noul","noul":0.75}},"usage":{"input_tokens":"many","output_tokens":3}}"#),
        systemOneReply(#"{"answers":{"__proto__":{"type":"noul","noul":0.75}},"usage":{"cost":0.1}}"#)
    ])
    let first = await classify(model: systemOneModel(), context: context,
        options: ClassifierOptions(apiKey: "secret", httpClient: client))
    #expect(first.stopReason == .stop)
    #expect(first.answers.count == 1)
    if case .bool(let probability)? = first.answers["__proto__"] { #expect(probability == 0.75) } else { Issue.record("Missing prototype ID") }
    #expect(first.usage?.input == 0)
    #expect(first.usage?.output == 3)
    let second = await classify(model: systemOneModel(), context: context,
        options: ClassifierOptions(apiKey: "secret", httpClient: client))
    #expect(second.usage == nil)
}

@Test func systemOneCloudflareEnvelopeFailures() async {
    let model = systemOneModel(api: .cloudflareWorkersAISystemOne, provider: "cloudflare-workers-ai")
    let client = SystemOneTestClient([
        systemOneReply(#"{"success":true,"result":{"state":"Queued","result":null}}"#),
        systemOneReply(#"{"success":false,"errors":[{"message":"No such model"}],"result":null}"#)
    ])
    let options = ClassifierOptions(apiKey: "secret", httpClient: client)
    let queued = await classify(model: model, context: systemOneContext(), options: options)
    #expect(queued.stopReason == .error)
    #expect(queued.errorMessage?.contains("state: Queued") == true)
    let failed = await classify(model: model, context: systemOneContext(), options: options)
    #expect(failed.stopReason == .error)
    #expect(failed.errorMessage?.contains("No such model") == true)
}

@Test func systemOnePayloadResponseCallbacksAndSuppressedHeader() async throws {
    let client = SystemOneTestClient([systemOneReply(#"{"answers":\#(systemOneAnswers)}"#, headers: ["x-request-id": "one"])])
    let payloads = LockedState(0)
    let responses = LockedState(0)
    let result = await classify(model: systemOneModel(headers: ["Authorization": "Bearer model"]),
        context: systemOneContext(), options: ClassifierOptions(apiKey: "secret", httpClient: client,
        onPayload: { payload, _ in
            payloads.withLock { $0 += 1 }
            return .object((payload.objectEntries ?? []) + [("tag", .string("added"))])
        }, onResponse: { snapshot, _ in
            #expect(snapshot.statusCode == 200)
            responses.withLock { $0 += 1 }
        }, headers: ["Authorization": nil]))
    #expect(result.stopReason == .stop)
    #expect(payloads.withLock { $0 } == 1)
    #expect(responses.withLock { $0 } == 1)
    let request = try #require(await client.captured().first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    let bodyData = try #require(request.httpBody)
    #expect(String(data: bodyData, encoding: .utf8)?.contains(#""tag":"added""#) == true)
}

@Test func systemOneTwoCallsProduceIdenticalOrderedBodies() async throws {
    let client = SystemOneTestClient(Array(repeating: systemOneReply(#"{"answers":\#(systemOneAnswers)}"#), count: 2))
    let options = ClassifierOptions(apiKey: "secret", httpClient: client)
    let model = systemOneModel()
    let context = systemOneContext()
    _ = await classify(model: model, context: context, options: options)
    _ = await classify(model: model, context: context, options: options)
    let requests = await client.captured()
    #expect(requests.count == 2)
    #expect(requests[0].httpBody == requests[1].httpBody)
}

private actor SystemOneSlowClient: ProviderHTTPClient {
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        try await Task.sleep(for: .seconds(10))
        return ProviderHTTPResponse(statusCode: 200, body: Data())
    }
}

@Test func systemOneTimeoutIsAnError() async {
    let result = await classify(model: systemOneModel(), context: systemOneContext(),
        options: ClassifierOptions(apiKey: "secret", httpClient: SystemOneSlowClient(),
                                   timeoutMs: 5, maxRetries: 0))
    #expect(result.stopReason == .error)
    #expect(result.errorMessage == "Request timed out after 5ms")
}

@Test func systemOneTimeoutRestartsForRetry() async {
    let client = SystemOneTestClient([
        systemOneReply("retry", status: 500, headers: ["retry-after-ms": "0"]),
        systemOneReply(#"{"answers":\#(systemOneAnswers)}"#)
    ])
    let result = await classify(model: systemOneModel(), context: systemOneContext(),
        options: ClassifierOptions(apiKey: "secret", httpClient: client,
                                   timeoutMs: 1000, maxRetries: 1))
    #expect(result.stopReason == .stop)
    #expect(await client.captured().count == 2)
}
