import Foundation
import Testing
@testable import PiSwiftAI

private actor DecisionsV110Client: ProviderHTTPClient {
    struct Reply: Sendable {
        let body: String
        var status: Int = 200
        var headers: [String: String] = [:]
    }
    private var replies: [Reply]
    private var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        let reply = replies.isEmpty ? Reply(body: "unexpected request", status: 400) : replies.removeFirst()
        return ProviderHTTPResponse(statusCode: reply.status, headers: reply.headers, body: Data(reply.body.utf8))
    }
    func captured() -> [URLRequest] { requests }
}

private func decisionsV110Model(api: ClassifierApi = .openAIDecisions, input: [ModelInput] = [.text, .image],
                               baseURL: String = "https://api.openai.com/v1") -> ClassifierModel {
    ClassifierModel(id: "gpt-6-luna", name: "GPT-6 Luna", api: api, provider: "openai",
        baseUrl: baseURL, input: input,
        cost: ModelCost(input: 0.1, output: 0, cacheRead: 0, cacheWrite: 0,
            tiers: [ModelCostTier(inputTokensAbove: 272000, input: 0.2, output: 0, cacheRead: 0, cacheWrite: 0)]),
        contextWindow: 922000)
}
private func decisionsV110Context(images: [ImageContent]? = nil) -> ClassifierContext {
    ClassifierContext(state: ["text": AnyCodable("The deployment succeeded, thank you.")], questions: [
        "category": .choice(instructions: "Classify the message", criteria: ["success": "Successful", "failure": ""]),
        "satisfaction": .score(instructions: "Score satisfaction", criteria: ["low", "neutral", "high"]),
        "approved": .bool(instructions: "Does the user approve?", trueCriterion: "Approval", falseCriterion: "No approval")
    ], images: images)
}
private let decisionsV110Choice = #"{"type":"choice","name":"category","choice":"success","probabilities":[{"value":"success","probability":0.9},{"value":"failure","probability":0.1}],"confidence":0.8}"#
private let decisionsV110Score = #"{"type":"score","name":"satisfaction","score":1.8,"probabilities":[{"value":0,"label":"low","probability":0.05},{"value":1,"label":"neutral","probability":0.1},{"value":2,"label":"high","probability":0.85}],"confidence":0.7}"#
private let decisionsV110Predicate = #"{"type":"predicate","name":"approved","probability":0.95}"#
private let decisionsV110Usage = #"{"input_tokens":164,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":0,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":164}"#
private let decisionsV110Image = ImageContent(data: "aW1hZ2U=", mimeType: "image/png")
private func decisionsV110Success() -> String {
    #"{"answers":[\#(decisionsV110Choice),\#(decisionsV110Score),\#(decisionsV110Predicate)]}"#
}
private func decisionsV110Run(_ client: DecisionsV110Client, context: ClassifierContext = decisionsV110Context()) async -> ClassifierResult {
    await classifyOpenAIDecisions(model: decisionsV110Model(), context: context,
        options: ClassifierOptions(apiKey: "secret", httpClient: client))
}

@Suite(.timeLimit(.minutes(1))) struct OpenAIDecisionsV110Tests {
    @Test func mapsQuestionsAndAnswersByName() async throws {
        let client = DecisionsV110Client([.init(body: #"{"model":"gpt-6-luna","answers":[\#(decisionsV110Predicate),\#(decisionsV110Score),\#(decisionsV110Choice)],"usage":\#(decisionsV110Usage)}"#)])
        let result = await classifyOpenAIDecisions(model: decisionsV110Model(), context: decisionsV110Context(),
            options: ClassifierOptions(apiKey: "secret", httpClient: client, temperature: 1.5))
        let requests = await client.captured()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/decisions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer secret")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
        let body = try #require(request.httpBody)
        #expect(String(data: body, encoding: .utf8) == #"{"model":"gpt-6-luna","input":"{\"text\":\"The deployment succeeded, thank you.\"}","questions":[{"type":"choice","name":"category","instructions":"Classify the message","choices":[{"value":"success","description":"Successful"},{"value":"failure"}]},{"type":"score","name":"satisfaction","instructions":"Score satisfaction","levels":[{"label":"low"},{"label":"neutral"},{"label":"high"}]},{"type":"predicate","name":"approved","instructions":"Does the user approve?\n\nTrue means: Approval\nFalse means: No approval"}]}"#)
        #expect(result.stopReason == .stop)
        #expect(result.answers.count == 3)
        if case .choice(let choice, let probabilities, let confidence)? = result.answers["category"] {
            #expect(choice == "success")
            #expect(probabilities == ["success": 0.9, "failure": 0.1])
            #expect(confidence == 0.8)
        } else { Issue.record("Missing choice") }
        if case .score(let score, let confidence)? = result.answers["satisfaction"] {
            #expect(score == 1.8)
            #expect(confidence == 0.7)
        } else { Issue.record("Missing score") }
        if case .bool(let probability)? = result.answers["approved"] { #expect(probability == 0.95) }
        else { Issue.record("Missing predicate") }
        #expect(result.usage?.input == 164)
        #expect(result.usage?.output == 0)
        #expect(result.usage?.cacheRead == 0)
        #expect(result.usage?.cacheWrite == 0)
        #expect(result.usage?.totalTokens == 164)
        #expect(abs((result.usage?.cost.total ?? 0) - 0.0000164) < 1e-12)
    }

    @Test func pricesLongContext() async {
        let client = DecisionsV110Client([.init(body: #"{"answers":[\#(decisionsV110Choice),\#(decisionsV110Score),\#(decisionsV110Predicate)],"usage":{"input_tokens":300000,"output_tokens":0}}"#)])
        let result = await decisionsV110Run(client)
        #expect(abs((result.usage?.cost.total ?? 0) - 0.06) < 1e-12)
    }

    @Test func sendsImagesAfterStateInOneUserMessage() async throws {
        let client = DecisionsV110Client([.init(body: decisionsV110Success())])
        let result = await decisionsV110Run(client, context: decisionsV110Context(images: [decisionsV110Image, ImageContent(data: "aW1hZ2U=", mimeType: "image/jpeg")]))
        #expect(result.stopReason == .stop)
        let request = try #require(await client.captured().first)
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let expected = #"[{"role":"user","content":[{"type":"input_text","text":"{\"text\":\"The deployment succeeded, thank you.\"}"},{"type":"input_image","image_url":"data:image/png;base64,aW1hZ2U="},{"type":"input_image","image_url":"data:image/jpeg;base64,aW1hZ2U="}]}]"#
        #expect(AnyCodable(try #require(json["input"])) == AnyCodable(try JSONSerialization.jsonObject(with: Data(expected.utf8))))
    }

    @Test func rejectsMoreThan128ImagesBeforeSending() async {
        let client = DecisionsV110Client([.init(body: decisionsV110Success())])
        let result = await decisionsV110Run(client, context: decisionsV110Context(images: Array(repeating: decisionsV110Image, count: 129)))
        #expect(await client.captured().isEmpty)
        #expect(result.stopReason == .error)
        #expect(result.errorMessage == "OpenAI Decisions accepts at most 128 images, got 129")
    }

    @Test func refusalKeepsBilledUsageAndClearsAnswers() async {
        let client = DecisionsV110Client([.init(body: #"{"answers":[\#(decisionsV110Choice),\#(decisionsV110Score),{"type":"refusal","name":"approved"}],"usage":\#(decisionsV110Usage)}"#)])
        let result = await decisionsV110Run(client)
        #expect(result.stopReason == .error)
        #expect(result.answers.isEmpty)
        #expect(result.errorMessage == "OpenAI Decisions refused to answer approved")
        #expect(result.usage?.input == 164)
    }

    @Test func missingAndMistypedAnswersAreErrors() async {
        let client = DecisionsV110Client([
            .init(body: #"{"answers":[\#(decisionsV110Choice),\#(decisionsV110Score)]}"#),
            .init(body: #"{"answers":[\#(decisionsV110Choice),\#(decisionsV110Score),{"type":"score","name":"approved"}]}"#)
        ])
        let missing = await decisionsV110Run(client)
        let mistyped = await decisionsV110Run(client)
        #expect(missing.stopReason == .error)
        #expect(missing.errorMessage == "OpenAI Decisions did not return an answer for approved")
        #expect(mistyped.stopReason == .error)
        #expect(mistyped.errorMessage == "OpenAI Decisions did not return a predicate answer for approved")
        #expect(missing.answers.isEmpty && mistyped.answers.isEmpty)
    }

    @Test func preservesPrototypeSensitiveIDs() async {
        let context = ClassifierContext(state: [:], questions: ["__proto__": .bool(instructions: "Is this true?", trueCriterion: "Yes", falseCriterion: "No")])
        let result = await decisionsV110Run(DecisionsV110Client([.init(body: #"{"answers":[{"type":"predicate","name":"__proto__","probability":0.75}]}"#)]), context: context)
        #expect(result.stopReason == .stop)
        #expect(result.answers.count == 1)
        if case .bool(let probability)? = result.answers["__proto__"] { #expect(probability == 0.75) }
        else { Issue.record("Missing prototype-sensitive ID") }
    }

    @Test func gatewayTimeoutIsNotRetried() async {
        let client = DecisionsV110Client([.init(body: "<!DOCTYPE html><html>Gateway time-out</html>", status: 504, headers: ["retry-after-ms": "0", "x-should-retry": "true"])])
        let result = await decisionsV110Run(client)
        #expect(await client.captured().count == 1)
        #expect(result.stopReason == .error)
        #expect(result.errorMessage == "OpenAI Decisions error (504): the request timed out at the gateway. Very large inputs (above roughly 600K tokens) currently exceed its time limit.")
    }

    @Test func retriesOtherServerErrors() async {
        let client = DecisionsV110Client([.init(body: "busy", status: 503, headers: ["retry-after-ms": "0"]), .init(body: decisionsV110Success())])
        let result = await decisionsV110Run(client)
        #expect(await client.captured().count == 2)
        #expect(result.stopReason == .stop)
    }

    @Test func includesOtherHTTPErrorBody() async {
        let body = #"{"error":{"message":"Decision input exceeds the token limit.","type":"invalid_request_error"}}"#
        let result = await classifyOpenAIDecisions(model: decisionsV110Model(), context: decisionsV110Context(),
            options: ClassifierOptions(apiKey: "secret", httpClient: DecisionsV110Client([.init(body: body, status: 400)]), maxRetries: 0))
        #expect(result.stopReason == .error)
        #expect(result.errorMessage == "OpenAI Decisions error (400): " + body)
    }

    @Test func rejectsOtherAPIsAndMissingKeys() async {
        let client = DecisionsV110Client([.init(body: decisionsV110Success())])
        let wrong = decisionsV110Model(api: .typesafeSystemOne)
        let rejected = await classifyOpenAIDecisions(model: wrong, context: decisionsV110Context(), options: ClassifierOptions(apiKey: "secret", httpClient: client))
        let missing = await classifyOpenAIDecisions(model: decisionsV110Model(), context: decisionsV110Context(), options: ClassifierOptions(httpClient: client))
        #expect(await client.captured().isEmpty)
        #expect(rejected.errorMessage == "Unsupported classifier API: typesafe-system-one")
        #expect(missing.errorMessage == "No API key for provider: openai")
    }

    @Test func catalogRoutesLunaWithImagesAndEnvironmentKey() async throws {
        let model = try #require(getClassifierModel(provider: "openai", modelId: "gpt-6-luna"))
        #expect(model.api == .openAIDecisions)
        #expect(model.input == [.text, .image])
        #expect(model.contextWindow == 922000)
        #expect(getModel(provider: "openai", modelId: "gpt-6-luna")?.api == .openAIResponses)
        let client = DecisionsV110Client([.init(body: #"{"answers":[{"type":"predicate","name":"approved","probability":0.8}]}"#)])
        let result = await classify(model: model, context: ClassifierContext(state: [:], questions: [
            "approved": .bool(instructions: "Approved?", trueCriterion: "Yes", falseCriterion: "No")
        ], images: [decisionsV110Image]), options: ClassifierOptions(httpClient: client, env: ["OPENAI_API_KEY": "secret"]))
        #expect(await client.captured().map { $0.url?.absoluteString } == ["https://api.openai.com/v1/decisions"])
        #expect(await client.captured().first?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(result.stopReason == .stop)
        if case .bool(let probability)? = result.answers["approved"] { #expect(probability == 0.8) }
        else { Issue.record("Missing catalog answer") }
    }

    @Test func entryPointRejectsImagesBeforeProviderAndAllowsEmptyImages() async {
        let model = decisionsV110Model(input: [.text])
        let calls = LockedState(0)
        let client = DecisionsV110Client([.init(body: decisionsV110Success())])
        let options = ClassifierOptions(apiKey: "secret", httpClient: client, onPayload: { _, _ in calls.withLock { $0 += 1 }; return nil })
        let rejected = await classify(model: model, context: decisionsV110Context(images: [decisionsV110Image]), options: options)
        #expect(rejected.stopReason == .error)
        #expect(rejected.errorMessage == "Model openai/gpt-6-luna does not accept image input")
        #expect(await client.captured().isEmpty)
        #expect(calls.withLock { $0 } == 0)
        let accepted = await classify(model: model, context: decisionsV110Context(images: []), options: options)
        #expect(accepted.stopReason == .stop)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func sortedCompactStateAndEmptyMeanings() async throws {
        let client = DecisionsV110Client([.init(body: #"{"answers":[{"name":"b","type":"predicate","probability":0.5}]}"#)])
        let context = ClassifierContext(state: ["z": AnyCodable("https://example.test/a"), "a": AnyCodable(["z": 2, "a": 1])], questions: [
            "b": .bool(instructions: "Question", trueCriterion: "", falseCriterion: "")
        ])
        _ = await decisionsV110Run(client, context: context)
        let data = try #require(await client.captured().first?.httpBody)
        let body = try OrderedJSON.parse(String(decoding: data, as: UTF8.self))
        #expect(body["input"]?.stringValue == #"{"a":{"a":1,"z":2},"z":"https://example.test/a"}"#)
        #expect(body["questions"]?[0]?["instructions"]?.stringValue == "Question")
        #expect(!String(decoding: data, as: UTF8.self).contains("\\/"))
    }
}

private struct DecisionsV110InvalidAnswer: Sendable {
    let question: ClassifierQuestion
    let answer: String
    let error: String
}
private let decisionsV110ChoiceQuestion = ClassifierQuestion.choice(instructions: "Choice", criteria: ["x": "X"])
private let decisionsV110ScoreQuestion = ClassifierQuestion.score(instructions: "Score", criteria: ["low", "high"])
private let decisionsV110BoolQuestion = ClassifierQuestion.bool(instructions: "Bool", trueCriterion: "", falseCriterion: "")
private let decisionsV110InvalidAnswers: [DecisionsV110InvalidAnswer] = [
    .init(question: decisionsV110ChoiceQuestion, answer: #"{"name":"q","type":"predicate"}"#, error: "did not return a choice answer for q"),
    .init(question: decisionsV110ChoiceQuestion, answer: #"{"name":"q","type":"choice","choice":1}"#, error: "did not return a choice answer for q"),
    .init(question: decisionsV110ChoiceQuestion, answer: #"{"name":"q","type":"choice","choice":"x","probabilities":{}}"#, error: "returned invalid probabilities for q"),
    .init(question: decisionsV110ChoiceQuestion, answer: #"{"name":"q","type":"choice","choice":"x","probabilities":[true]}"#, error: "returned invalid probabilities for q"),
    .init(question: decisionsV110ChoiceQuestion, answer: #"{"name":"q","type":"choice","choice":"x","probabilities":[{"value":1,"probability":0.5}]}"#, error: "returned invalid probabilities for q"),
    .init(question: decisionsV110ChoiceQuestion, answer: #"{"name":"q","type":"choice","choice":"x","probabilities":[{"value":"x","probability":false}]}"#, error: "returned an invalid probability for q.x"),
    .init(question: decisionsV110ChoiceQuestion, answer: #"{"name":"q","type":"choice","choice":"x","probabilities":[],"confidence":"0.5"}"#, error: "returned an invalid confidence for q"),
    .init(question: decisionsV110ScoreQuestion, answer: #"{"name":"q","type":"choice"}"#, error: "did not return a score answer for q"),
    .init(question: decisionsV110ScoreQuestion, answer: #"{"name":"q","type":"score","score":true,"confidence":0.5}"#, error: "returned an invalid score for q"),
    .init(question: decisionsV110ScoreQuestion, answer: #"{"name":"q","type":"score","score":1,"confidence":null}"#, error: "returned an invalid confidence for q"),
    .init(question: decisionsV110BoolQuestion, answer: #"{"name":"q","type":"noul","noul":0.5}"#, error: "did not return a predicate answer for q"),
    .init(question: decisionsV110BoolQuestion, answer: #"{"name":"q","type":"predicate","probability":false}"#, error: "returned an invalid probability for q"),
    .init(question: decisionsV110BoolQuestion, answer: #"{"name":"q","type":"predicate"}"#, error: "returned an invalid probability for q")
]

extension OpenAIDecisionsV110Tests {
    @Test(arguments: decisionsV110InvalidAnswers)
    fileprivate func validatesEveryAnswerField(_ invalid: DecisionsV110InvalidAnswer) async {
        let context = ClassifierContext(state: [:], questions: ["q": invalid.question])
        let result = await decisionsV110Run(DecisionsV110Client([.init(body: #"{"answers":[\#(invalid.answer)],"usage":{"input_tokens":17}}"#)]), context: context)
        #expect(result.stopReason == .error)
        #expect(result.errorMessage == "OpenAI Decisions " + invalid.error)
        #expect(result.answers.isEmpty)
        #expect(result.usage?.input == 17)
    }

    @Test(arguments: ["null", "[]", "42", #""string""#, #"{"answers":{}}"#, #"{"answers":null}"#])
    func rejectsUnexpectedResponseShapes(body: String) async {
        let result = await decisionsV110Run(DecisionsV110Client([.init(body: body)]))
        #expect(result.stopReason == .error)
        #expect(result.errorMessage == "OpenAI Decisions returned an unexpected response")
        #expect(result.answers.isEmpty)
    }

    @Test func ignoresUnusableNamesAndUsesLastDuplicateValues() async {
        let context = ClassifierContext(state: [:], questions: ["q": decisionsV110ChoiceQuestion])
        let body = #"{"answers":[null,1,{"name":1,"type":"choice"},{"name":"unknown","type":"refusal"},{"name":"q","type":"refusal"},{"name":"q","type":"choice","choice":"unlisted","probabilities":[{"value":"x","probability":0.3},{"value":"x","probability":1.3}],"confidence":-1}]}"#
        let result = await decisionsV110Run(DecisionsV110Client([.init(body: body)]), context: context)
        #expect(result.stopReason == .stop)
        #expect(result.answers.count == 1)
        if case .choice(let choice, let probabilities, let confidence)? = result.answers["q"] {
            #expect(choice == "unlisted")
            #expect(probabilities == ["x": 1.3])
            #expect(confidence == -1)
        } else { Issue.record("Missing duplicate answer") }
        let missing = await decisionsV110Run(DecisionsV110Client([.init(body: #"{"answers":[null,1,{"name":1}]}"#)]), context: context)
        #expect(missing.errorMessage == "OpenAI Decisions did not return an answer for q")
    }

    @Test func accepts128Images() async throws {
        let client = DecisionsV110Client([.init(body: decisionsV110Success())])
        let result = await decisionsV110Run(client, context: decisionsV110Context(images: Array(repeating: decisionsV110Image, count: 128)))
        #expect(result.stopReason == .stop)
        let data = try #require(await client.captured().first?.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let input = try #require(json["input"] as? [[String: Any]])
        let content = try #require(input.first?["content"] as? [[String: Any]])
        #expect(content.count == 129)
        #expect(content.first?["type"] as? String == "input_text")
    }

    @Test(arguments: [true, false]) func appendsOnlyNonemptyPredicateMeaning(trueMeaning: Bool) async throws {
        let client = DecisionsV110Client([.init(body: #"{"answers":[{"name":"q","type":"predicate","probability":0.5}]}"#)])
        let context = ClassifierContext(state: [:], questions: ["q": .bool(instructions: "Q", trueCriterion: trueMeaning ? "Yes" : "", falseCriterion: trueMeaning ? "" : "No")])
        let result = await decisionsV110Run(client, context: context)
        #expect(result.stopReason == .stop)
        let data = try #require(await client.captured().first?.httpBody)
        let json = try OrderedJSON.parse(String(decoding: data, as: UTF8.self))
        #expect(json["questions"]?[0]?["instructions"]?.stringValue == (trueMeaning ? "Q\n\nTrue means: Yes" : "Q\n\nFalse means: No"))
    }

    @Test func normalizesEmbeddedHTTPBodyAndResolvesRelativeURL() async {
        let client = DecisionsV110Client([.init(body: "OpenAI Decisions", status: 400), .init(body: decisionsV110Success())])
        let failed = await decisionsV110Run(client)
        #expect(failed.errorMessage == "OpenAI Decisions error (400): OpenAI Decisions returned 400")
        let model = decisionsV110Model(baseURL: "https://api.openai.com/v1/?query=value#fragment")
        let result = await classifyOpenAIDecisions(model: model, context: decisionsV110Context(), options: ClassifierOptions(apiKey: "secret", httpClient: client))
        #expect(result.stopReason == .stop)
        #expect(await client.captured().last?.url?.absoluteString == "https://api.openai.com/v1/decisions")
    }

    @Test func requiredNumbersRejectBooleanAndNonfiniteValues() {
        for value in [AnyCodable(true), AnyCodable(Double.infinity), AnyCodable(Double.nan), AnyCodable("1")] {
            do {
                _ = try requiredNumber(value.value, label: "OpenAI Decisions", field: "probability for q")
                Issue.record("Accepted invalid number")
            } catch {
                #expect(error.localizedDescription == "OpenAI Decisions returned an invalid probability for q")
            }
        }
    }

    @Test func payloadCanBeNullAndResponseHookErrorIsReturned() async {
        let client = DecisionsV110Client([.init(body: decisionsV110Success())])
        let result = await classifyOpenAIDecisions(model: decisionsV110Model(), context: decisionsV110Context(),
            options: ClassifierOptions(apiKey: "secret", httpClient: client, onPayload: { _, _ in .null },
                onResponse: { _, _ in throw ClassifierError(message: "response hook failed") }))
        #expect(await client.captured().first?.httpBody == Data("null".utf8))
        #expect(result.stopReason == .error)
        #expect(result.errorMessage == "response hook failed")
        #expect(result.answers.isEmpty)
        #expect(result.usage == nil)
    }
}


extension OpenAIDecisionsV110Tests {
    @Test func retryDelayCapKeepsUpstreamStatusMessage() async {
        let client = DecisionsV110Client([.init(body: "busy", status: 503, headers: ["retry-after-ms": "2000"])])
        let result = await classifyOpenAIDecisions(model: decisionsV110Model(), context: decisionsV110Context(),
            options: ClassifierOptions(apiKey: "secret", httpClient: client, maxRetryDelayMs: 1000))
        #expect(result.stopReason == .error)
        #expect(result.errorMessage == "Server requested 2s retry delay (max: 1s). OpenAI Decisions returned 503")
        #expect(await client.captured().count == 1)
    }
}
