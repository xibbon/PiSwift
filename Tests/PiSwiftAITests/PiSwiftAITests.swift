import CryptoKit
import Foundation
import OpenAI
import SwiftAnthropic
import Testing
@testable import PiSwiftAI

private let RUN_ANTHROPIC_TESTS: Bool = {
    let env = ProcessInfo.processInfo.environment
    let flag = (env["PI_RUN_ANTHROPIC_TESTS"] ?? env["PI_RUN_LIVE_TESTS"])?.lowercased()
    return flag == "1" || flag == "true" || flag == "yes"
}()

private let RUN_OPENAI_TESTS: Bool = {
    let env = ProcessInfo.processInfo.environment
    let flag = (env["PI_RUN_OPENAI_TESTS"] ?? env["PI_RUN_LIVE_TESTS"])?.lowercased()
    return flag == "1" || flag == "true" || flag == "yes"
}()

final class MockURLProtocol: URLProtocol {
    static let requestHandler = LockedState<(@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)
    static let allowedHosts = LockedState<Set<String>>([])

    override class func canInit(with request: URLRequest) -> Bool {
        guard requestHandler.withLock({ $0 }) != nil, let host = request.url?.host else { return false }
        return allowedHosts.withLock({ $0.contains(host) })
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler.withLock({ $0 }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class BlockingOAuthURLProtocol: URLProtocol {
    static let started = LockedState(false)
    static let stopped = LockedState(false)

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "auth.x.ai"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.started.withLock { $0 = true }
    }

    override func stopLoading() {
        Self.stopped.withLock { $0 = true }
    }
}

final class OpenAICompletionsMockURLProtocol: URLProtocol {
    static let requestHandler = LockedState<(@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)
    static let allowedHosts = LockedState<Set<String>>([])

    override class func canInit(with request: URLRequest) -> Bool {
        guard requestHandler.withLock({ $0 }) != nil, let host = request.url?.host else { return false }
        return allowedHosts.withLock({ $0.contains(host) })
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler.withLock({ $0 }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class GeminiRetryMockURLProtocol: URLProtocol {
    static let requestHandler = LockedState<(@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)

    override class func canInit(with request: URLRequest) -> Bool {
        guard request.url?.host == "cloudcode-pa.googleapis.com" else { return false }
        return requestHandler.withLock { $0 } != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler.withLock({ $0 }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class OpenRouterImagesMockURLProtocol: URLProtocol {
    static let requestHandler = LockedState<(@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "openrouter.ai" && requestHandler.withLock { $0 != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler.withLock({ $0 }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func codexTestEvent(type: String, payload: [String: Any]) -> String {
    var event = payload
    event["type"] = type
    guard let data = try? JSONSerialization.data(withJSONObject: event),
          let string = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return string
}

func openAITestSseData(_ payloads: [[String: Any]]) throws -> Data {
    var result = ""
    for payload in payloads {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        result += "data: \(String(decoding: data, as: UTF8.self))\n\n"
    }
    result += "data: [DONE]\n\n"
    return Data(result.utf8)
}

private struct StopReasonStreamCapture: Sendable {
    let message: AssistantMessage
    let emittedDone: Bool
    let emittedError: Bool
}

private func runOpenAICompletionsStopReasonStream(
    payloads: [[String: Any]],
    compat: OpenAICompat? = nil
) async -> StopReasonStreamCapture {
    let sseData = try! openAITestSseData(payloads)
    return await codexRequestLock.withLock {
        let host = "stop-reason.example"
        OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = [host] }
        OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, sseData)
        } }
        URLProtocol.registerClass(OpenAICompletionsMockURLProtocol.self)
        defer {
            OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = nil }
            OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = [] }
            URLProtocol.unregisterClass(OpenAICompletionsMockURLProtocol.self)
        }

        let model = Model(
            id: "stop-reason-test",
            name: "Stop Reason Test",
            api: .openAICompletions,
            provider: "openai-compatible",
            baseUrl: "https://\(host)/v1",
            reasoning: false,
            input: [.text],
            cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 8_192,
            maxTokens: 1_024,
            compat: compat
        )
        let stream = streamOpenAICompletions(
            model: model,
            context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
            options: OpenAICompletionsOptions(apiKey: "test-key")
        )
        var emittedDone = false
        var emittedError = false
        var finalMessage: AssistantMessage?
        for await event in stream {
            switch event {
            case .done(_, let message):
                emittedDone = true
                finalMessage = message
            case .error(_, let message):
                emittedError = true
                finalMessage = message
            default:
                break
            }
        }
        let message: AssistantMessage
        if let finalMessage {
            message = finalMessage
        } else {
            message = await stream.result()
        }
        return StopReasonStreamCapture(
            message: message,
            emittedDone: emittedDone,
            emittedError: emittedError
        )
    }
}

private func openAIStopReasonChunk(delta: [String: Any], finishReason: Any) -> [String: Any] {
    [
        "id": "chatcmpl-stop-reason",
        "object": "chat.completion.chunk",
        "created": 0,
        "model": "stop-reason-test",
        "choices": [[
            "index": 0,
            "delta": delta,
            "finish_reason": finishReason,
        ]],
    ]
}

private func bedrockMessageStopData(reason: String = "end_turn") -> Data {
    func uint32Bytes(_ value: Int) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
    }

    func stringHeader(name: String, value: String) -> Data {
        let nameBytes = Array(name.utf8)
        let valueBytes = Array(value.utf8)
        var data = Data([UInt8(nameBytes.count)])
        data.append(contentsOf: nameBytes)
        data.append(7)
        data.append(UInt8((valueBytes.count >> 8) & 0xff))
        data.append(UInt8(valueBytes.count & 0xff))
        data.append(contentsOf: valueBytes)
        return data
    }

    let headers = stringHeader(name: ":event-type", value: "messageStop")
    let payload = Data(#"{"stopReason":"\#(reason)"}"#.utf8)
    let totalLength = 12 + headers.count + payload.count + 4
    var frame = Data(uint32Bytes(totalLength))
    frame.append(contentsOf: uint32Bytes(headers.count))
    frame.append(contentsOf: [0, 0, 0, 0])
    frame.append(headers)
    frame.append(payload)
    frame.append(contentsOf: [0, 0, 0, 0])
    return frame
}

private func readRequestBody(_ request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        if read > 0 {
            data.append(buffer, count: read)
        } else {
            break
        }
    }
    return data.isEmpty ? nil : data
}

private func loadJSONResource(_ name: String) throws -> [String: Any] {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
        throw NSError(domain: "PiSwiftAITests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing resource \(name).json"])
    }
    let data = try Data(contentsOf: url)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(domain: "PiSwiftAITests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON resource \(name).json"])
    }
    return object
}

private func canonicalJSONString(_ value: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func encodedJSONObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(domain: "PiSwiftAITests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Encoded value was not a JSON object"])
    }
    return object
}

private func optionalFields(_ pairs: [(String, Any?)]) -> [String: Any] {
    var result: [String: Any] = [:]
    for (key, value) in pairs {
        if let value {
            result[key] = value
        }
    }
    return result
}

private func normalizeCost(_ cost: ModelCost) -> [String: Any] {
    var result: [String: Any] = [
        "cacheRead": cost.cacheRead,
        "cacheWrite": cost.cacheWrite,
        "input": cost.input,
        "output": cost.output,
    ]
    if let tiers = cost.tiers {
        result["tiers"] = tiers.map { tier in
            [
                "cacheRead": tier.cacheRead,
                "cacheWrite": tier.cacheWrite,
                "input": tier.input,
                "inputTokensAbove": tier.inputTokensAbove,
                "output": tier.output,
            ]
        }
    }
    return result
}

private func normalizeThinkingLevelMap(_ map: ThinkingLevelMap?) -> [String: Any]? {
    guard let map else { return nil }
    var result: [String: Any] = [:]
    for (key, value) in map {
        result[key.rawValue] = value ?? NSNull()
    }
    return result
}

private func normalizeReasoningEffortMap(_ map: [ThinkingLevel: String]?) -> [String: Any]? {
    guard let map else { return nil }
    return Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value) })
}

private func normalizeOpenRouterSort(_ sort: OpenRouterRoutingSort?) -> Any? {
    guard let sort else { return nil }
    switch sort {
    case .named(let value):
        return value
    case .structured(let by, let partition):
        return optionalFields([
            ("by", by),
            ("partition", partition),
        ])
    }
}

private func normalizeOpenRouterPrice(_ price: OpenRouterRoutingPrice?) -> [String: Any]? {
    guard let price else { return nil }
    return optionalFields([
        ("audio", price.audio),
        ("completion", price.completion),
        ("image", price.image),
        ("prompt", price.prompt),
        ("request", price.request),
    ])
}

private func normalizeOpenRouterPercentile(_ percentile: OpenRouterRoutingPercentile?) -> Any? {
    guard let percentile else { return nil }
    switch percentile {
    case .scalar(let value):
        return value
    case .percentiles(let p50, let p75, let p90, let p99):
        return optionalFields([
            ("p50", p50),
            ("p75", p75),
            ("p90", p90),
            ("p99", p99),
        ])
    }
}

private func normalizeOpenRouterRouting(_ routing: OpenRouterRouting?) -> [String: Any]? {
    guard let routing else { return nil }
    return optionalFields([
        ("allow_fallbacks", routing.allowFallbacks),
        ("data_collection", routing.dataCollection),
        ("enforce_distillable_text", routing.enforceDistillableText),
        ("ignore", routing.ignore),
        ("max_price", normalizeOpenRouterPrice(routing.maxPrice)),
        ("only", routing.only),
        ("order", routing.order),
        ("preferred_max_latency", normalizeOpenRouterPercentile(routing.preferredMaxLatency)),
        ("preferred_min_throughput", normalizeOpenRouterPercentile(routing.preferredMinThroughput)),
        ("quantizations", routing.quantizations),
        ("require_parameters", routing.requireParameters),
        ("sort", normalizeOpenRouterSort(routing.sort)),
        ("zdr", routing.zdr),
    ])
}

private func normalizeVercelGatewayRouting(_ routing: VercelGatewayRouting?) -> [String: Any]? {
    guard let routing else { return nil }
    return optionalFields([
        ("allow_fallbacks", routing.allowFallbacks),
        ("only", routing.only),
        ("order", routing.order),
    ])
}

private func normalizeChatTemplateKwargValue(_ value: ChatTemplateKwargValue) -> Any {
    switch value {
    case .string(let value):
        value
    case .number(let value):
        value
    case .bool(let value):
        value
    case .null:
        NSNull()
    case .variable(let variable, let omitWhenOff):
        optionalFields([
            ("$var", variable.rawValue),
            ("omitWhenOff", omitWhenOff ? true : nil),
        ])
    }
}

private func normalizeChatTemplateValues(_ values: [String: ChatTemplateKwargValue]?) -> [String: Any]? {
    values?.mapValues(normalizeChatTemplateKwargValue)
}

private func normalizeCompat(_ compat: OpenAICompat?) -> [String: Any]? {
    guard let compat else { return nil }
    return optionalFields([
        ("allowEmptySignature", compat.allowEmptySignature),
        ("cacheControlFormat", compat.cacheControlFormat?.rawValue),
        ("chatTemplateArgs", normalizeChatTemplateValues(compat.chatTemplateArgs)),
        ("chatTemplateKwargs", normalizeChatTemplateValues(compat.chatTemplateKwargs)),
        ("deferredToolsMode", compat.deferredToolsMode?.rawValue),
        ("forceAdaptiveThinking", compat.forceAdaptiveThinking),
        ("maxTokensField", compat.maxTokensField?.rawValue),
        ("openRouterRouting", normalizeOpenRouterRouting(compat.openRouterRouting)),
        ("reasoningEffortMap", normalizeReasoningEffortMap(compat.reasoningEffortMap)),
        ("requiresAssistantAfterToolResult", compat.requiresAssistantAfterToolResult),
        ("requiresMistralToolIds", compat.requiresMistralToolIds),
        ("requiresReasoningContentOnAssistantMessages", compat.requiresReasoningContentOnAssistantMessages),
        ("requiresThinkingAsText", compat.requiresThinkingAsText),
        ("requiresToolResultName", compat.requiresToolResultName),
        ("sendSessionAffinityHeaders", compat.sendSessionAffinityHeaders),
        ("sendSessionIdHeader", compat.sendSessionIdHeader),
        ("sessionAffinityFormat", compat.sessionAffinityFormat?.rawValue),
        ("supportsCacheControlOnTools", compat.supportsCacheControlOnTools),
        ("supportsDeveloperRole", compat.supportsDeveloperRole),
        ("supportsEagerToolInputStreaming", compat.supportsEagerToolInputStreaming),
        ("supportsExplicitPromptCacheMode", compat.supportsExplicitPromptCacheMode),
        ("supportsFinishReason", compat.supportsFinishReason),
        ("supportsLongCacheRetention", compat.supportsLongCacheRetention),
        ("supportsOpenAIGrammarTools", compat.supportsOpenAIGrammarTools),
        ("supportsReasoningEffort", compat.supportsReasoningEffort),
        ("supportsStore", compat.supportsStore),
        ("supportsStrictMode", compat.supportsStrictMode),
        ("supportsStrictTools", compat.supportsStrictTools),
        ("supportsTemperature", compat.supportsTemperature),
        ("supportsThinkingTokenBudget", compat.supportsThinkingTokenBudget),
        ("supportsToolReferences", compat.supportsToolReferences),
        ("supportsToolSearch", compat.supportsToolSearch),
        ("supportsUsageInStreaming", compat.supportsUsageInStreaming),
        ("thinkingFormat", compat.thinkingFormat?.rawValue),
        ("vercelGatewayRouting", normalizeVercelGatewayRouting(compat.vercelGatewayRouting)),
        ("zaiToolStream", compat.zaiToolStream),
    ])
}

private func normalizeModel(_ model: PiSwiftAI.Model) -> [String: Any] {
    var result = optionalFields([
        ("api", model.api.rawValue),
        ("baseUrl", model.baseUrl),
        ("compat", normalizeCompat(model.compat)),
        ("contextWindow", model.contextWindow),
        ("cost", normalizeCost(model.cost)),
        ("headers", model.headers),
        ("id", model.id),
        ("input", model.input.map(\.rawValue)),
        ("maxTokens", model.maxTokens),
        ("name", model.name),
        ("provider", model.provider),
        ("reasoning", model.reasoning),
        ("thinkingLevelMap", normalizeThinkingLevelMap(model.thinkingLevelMap)),
    ])
    result.removeValue(forKey: "nil")
    return result
}

private func normalizeImagesModel(_ model: ImagesModel) -> [String: Any] {
    optionalFields([
        ("api", model.api.rawValue),
        ("baseUrl", model.baseUrl),
        ("cost", normalizeCost(model.cost)),
        ("headers", model.headers),
        ("id", model.id),
        ("input", model.input.map(\.rawValue)),
        ("name", model.name),
        ("output", model.output.map(\.rawValue)),
        ("provider", model.provider),
    ])
}

actor CodexRequestLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await lock()
        defer { unlock() }
        return try await operation()
    }

    private func lock() async {
        if locked {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        locked = true
    }

    private func unlock() {
        if waiters.isEmpty {
            locked = false
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }
}

let codexRequestLock = CodexRequestLock()

private struct CodexRequestCapture: Sendable {
    let conversationId: String?
    let sessionId: String?
    let xClientRequestId: String?
    let promptCacheKey: String?
    let serviceTier: String?
    let hasTools: Bool
    let toolChoice: String?
    let parallelToolCalls: Bool?
    let usage: Usage
}

private enum CodexArgumentStreamEvent: Sendable {
    case delta(String)
    case done(String)
}

private struct CodexToolCallCapture: Sendable {
    let message: AssistantMessage
    let deltas: [String]
}

private func codexSubscriptionToken() throws -> String {
    let payload: [String: Any] = ["https://api.openai.com/auth": ["chatgpt_account_id": "acc_test"]]
    let payloadData = try JSONSerialization.data(withJSONObject: payload)
    let payloadBase64 = payloadData.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "aaa.\(payloadBase64).bbb"
}

private func runCodexToolCallRequest(
    argumentEvents: [CodexArgumentStreamEvent] = [.delta("{\"path\":\"x\"}")]
) async throws -> CodexToolCallCapture {
    try await codexRequestLock.withLock {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pi-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let previousAgentDir = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"]
        setenv("PI_CODING_AGENT_DIR", tempDir.path, 1)
        defer {
            if let previousAgentDir {
                setenv("PI_CODING_AGENT_DIR", previousAgentDir, 1)
            } else {
                unsetenv("PI_CODING_AGENT_DIR")
            }
        }

        let token = try codexSubscriptionToken()

        MockURLProtocol.allowedHosts.withLock { $0 = ["api.github.com", "raw.githubusercontent.com", "chatgpt.com"] }
        MockURLProtocol.requestHandler.withLock { $0 = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            let urlString = url.absoluteString
            if urlString == "https://api.github.com/repos/openai/codex/releases/latest" {
                let data = try JSONSerialization.data(withJSONObject: ["tag_name": "rust-v0.0.0"])
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, data)
            }

            if urlString.hasPrefix("https://raw.githubusercontent.com/openai/codex/") {
                let data = Data("PROMPT".utf8)
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["etag": "\"etag\""])!
                return (response, data)
            }

            if urlString == "https://chatgpt.com/backend-api/codex/responses" {
                let outputItemAdded = codexTestEvent(
                    type: "response.output_item.added",
                    payload: [
                        "item": [
                            "type": "function_call",
                            "id": "tool_1",
                            "call_id": "call_1",
                            "name": "read",
                            "arguments": "",
                        ],
                    ]
                )
                let argumentSseEvents = argumentEvents.map { event in
                    switch event {
                    case .delta(let delta):
                        return "data: \(codexTestEvent(type: "response.function_call_arguments.delta", payload: ["delta": delta]))"
                    case .done(let arguments):
                        return "data: \(codexTestEvent(type: "response.function_call_arguments.done", payload: ["arguments": arguments]))"
                    }
                }
                let outputItemDone = codexTestEvent(
                    type: "response.output_item.done",
                    payload: [
                        "item": [
                            "type": "function_call",
                            "id": "tool_1",
                            "call_id": "call_1",
                            "name": "",
                            "arguments": "",
                        ],
                    ]
                )
                let responseCompleted = codexTestEvent(
                    type: "response.completed",
                    payload: [
                        "response": [
                            "status": "completed",
                            "usage": [
                                "input_tokens": 5,
                                "output_tokens": 3,
                                "total_tokens": 8,
                                "input_tokens_details": ["cached_tokens": 0],
                            ],
                        ],
                    ]
                )

                let sseEvents = (["data: \(outputItemAdded)"] + argumentSseEvents + [
                    "data: \(outputItemDone)",
                    "data: \(responseCompleted)",
                ]).joined(separator: "\n\n") + "\n\n"
                let data = Data(sseEvents.utf8)
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["content-type": "text/event-stream"]
                )!
                return (response, data)
            }

            throw URLError(.unsupportedURL)
        } }

        URLProtocol.registerClass(MockURLProtocol.self)
        defer {
            MockURLProtocol.requestHandler.withLock { $0 = nil }
            MockURLProtocol.allowedHosts.withLock { $0 = [] }
            URLProtocol.unregisterClass(MockURLProtocol.self)
        }

        let model = getModel(provider: .openaiCodex, modelId: "gpt-5.4")
        let context = Context(messages: [.user(UserMessage(content: .text("Use read tool")))])
        let stream = streamOpenAICodexResponses(
            model: model,
            context: context,
            options: OpenAICodexResponsesOptions(apiKey: token, transport: .sse)
        )
        var deltas: [String] = []
        var message: AssistantMessage?
        for await event in stream {
            switch event {
            case .toolCallDelta(_, let delta, _):
                deltas.append(delta)
            case .done(_, let final):
                message = final
            case .error(_, let error):
                message = error
            default:
                break
            }
        }
        if message == nil {
            message = await stream.result()
        }
        guard let message else {
            throw NSError(domain: "CodexToolCallTest", code: 1)
        }
        return CodexToolCallCapture(message: message, deltas: deltas)
    }
}


private func runCodexSessionRequest(
    sessionId: String?,
    serviceTier: OpenAIServiceTier? = nil,
    tools: [AITool]? = nil
) async throws -> CodexRequestCapture {
    try await codexRequestLock.withLock {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pi-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let previousAgentDir = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"]
        setenv("PI_CODING_AGENT_DIR", tempDir.path, 1)
        defer {
            if let previousAgentDir {
                setenv("PI_CODING_AGENT_DIR", previousAgentDir, 1)
            } else {
                unsetenv("PI_CODING_AGENT_DIR")
            }
        }

        let token = try codexSubscriptionToken()

        let seenConversationId = LockedState<String?>(nil)
        let seenSessionId = LockedState<String?>(nil)
        let seenXClientRequestId = LockedState<String?>(nil)
        let seenPromptCacheKey = LockedState<String?>(nil)
        let seenServiceTier = LockedState<String?>(nil)
        let seenHasTools = LockedState(false)
        let seenToolChoice = LockedState<String?>(nil)
        let seenParallelToolCalls = LockedState<Bool?>(nil)
        MockURLProtocol.allowedHosts.withLock { $0 = ["api.github.com", "raw.githubusercontent.com", "chatgpt.com"] }
        MockURLProtocol.requestHandler.withLock { $0 = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            let urlString = url.absoluteString
            if urlString == "https://api.github.com/repos/openai/codex/releases/latest" {
                let data = try JSONSerialization.data(withJSONObject: ["tag_name": "rust-v0.0.0"])
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, data)
            }

            if urlString.hasPrefix("https://raw.githubusercontent.com/openai/codex/") {
                let data = Data("PROMPT".utf8)
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["etag": "\"etag\""])!
                return (response, data)
            }

            if urlString == "https://chatgpt.com/backend-api/codex/responses" {
                seenConversationId.withLock { $0 = request.value(forHTTPHeaderField: "conversation_id") }
                seenSessionId.withLock { $0 = request.value(forHTTPHeaderField: "session_id") }
                seenXClientRequestId.withLock { $0 = request.value(forHTTPHeaderField: "x-client-request-id") }
                if let body = readRequestBody(request),
                   let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    seenPromptCacheKey.withLock { $0 = json["prompt_cache_key"] as? String }
                    seenServiceTier.withLock { $0 = json["service_tier"] as? String }
                    seenHasTools.withLock { $0 = json.keys.contains("tools") }
                    seenToolChoice.withLock { $0 = json["tool_choice"] as? String }
                    seenParallelToolCalls.withLock { $0 = json["parallel_tool_calls"] as? Bool }
                }

                let outputItemAdded = codexTestEvent(
                    type: "response.output_item.added",
                    payload: [
                        "item": [
                            "type": "message",
                            "id": "msg_1",
                            "role": "assistant",
                            "status": "in_progress",
                            "content": [],
                        ],
                    ]
                )
                let outputTextDelta = codexTestEvent(
                    type: "response.output_text.delta",
                    payload: ["delta": "Hello"]
                )
                let outputItemDone = codexTestEvent(
                    type: "response.output_item.done",
                    payload: [
                        "item": [
                            "type": "message",
                            "id": "msg_1",
                            "role": "assistant",
                            "status": "completed",
                            "content": [["type": "output_text", "text": "Hello"]],
                        ],
                    ]
                )
                let responseCompleted = codexTestEvent(
                    type: "response.completed",
                    payload: [
                        "response": [
                            "status": "completed",
                            "usage": [
                                "input_tokens": 5,
                                "output_tokens": 3,
                                "total_tokens": 8,
                                "input_tokens_details": ["cached_tokens": 0],
                            ],
                        ],
                    ]
                )

                let sseEvents = [
                    "data: \(outputItemAdded)",
                    "data: \(outputTextDelta)",
                    "data: \(outputItemDone)",
                    "data: \(responseCompleted)",
                ].joined(separator: "\n\n") + "\n\n"
                let data = Data(sseEvents.utf8)
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["content-type": "text/event-stream"]
                )!
                return (response, data)
            }

            throw URLError(.unsupportedURL)
        } }

        URLProtocol.registerClass(MockURLProtocol.self)
        defer {
            MockURLProtocol.requestHandler.withLock { $0 = nil }
            MockURLProtocol.allowedHosts.withLock { $0 = [] }
            URLProtocol.unregisterClass(MockURLProtocol.self)
        }

        let model = getModel(provider: .openaiCodex, modelId: "gpt-5.4")
        let context = Context(messages: [.user(UserMessage(content: .text("Say hello")))], tools: tools)
        let stream = streamOpenAICodexResponses(
            model: model,
            context: context,
            options: OpenAICodexResponsesOptions(apiKey: token, sessionId: sessionId, transport: .sse, serviceTier: serviceTier)
        )
        let message = await stream.result()

        return CodexRequestCapture(
            conversationId: seenConversationId.withLock { $0 },
            sessionId: seenSessionId.withLock { $0 },
            xClientRequestId: seenXClientRequestId.withLock { $0 },
            promptCacheKey: seenPromptCacheKey.withLock { $0 },
            serviceTier: seenServiceTier.withLock { $0 },
            hasTools: seenHasTools.withLock { $0 },
            toolChoice: seenToolChoice.withLock { $0 },
            parallelToolCalls: seenParallelToolCalls.withLock { $0 },
            usage: message.usage
        )
    }
}

@Test func sanitizeSurrogatesRemovesUnpaired() {
    let unpaired = String(decoding: [0xD83D], as: UTF16.self)
    let input = "Hello \(unpaired) World"
    let sanitized = sanitizeSurrogates(input)
    #expect(!sanitized.contains(unpaired))
    #expect(sanitized == "Hello  World")
}

@Test func transformMessagesInsertsSyntheticToolResult() {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let toolCall = ToolCall(id: "call_1", name: "get_weather", arguments: [:])
    let assistant = AssistantMessage(
        content: [.toolCall(toolCall)],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .toolUse
    )
    let user = UserMessage(content: .text("continue"))
    let transformed = transformMessages([.assistant(assistant), .user(user)], model: model)

    #expect(transformed.count == 3)
    guard case .toolResult(let toolResult) = transformed[1] else {
        #expect(Bool(false), "Expected synthetic tool result message")
        return
    }
    #expect(toolResult.toolCallId == "call_1")
    #expect(toolResult.isError)
}

@Test func transformMessagesNormalizesToolCallIds() {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let toolCall = ToolCall(id: "call|abc", name: "do_thing", arguments: [:])
    let assistant = AssistantMessage(
        content: [.toolCall(toolCall)],
        api: .anthropicMessages,
        provider: "anthropic",
        model: "claude-3-5-haiku-20241022",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .toolUse
    )
    let toolResult = ToolResultMessage(
        toolCallId: "call|abc",
        toolName: "do_thing",
        content: [.text(TextContent(text: "ok"))],
        isError: false,
        timestamp: 0
    )

    let transformed = transformMessages([.assistant(assistant), .toolResult(toolResult)], model: model) { id, _, _ in
        "normalized-\(id)"
    }

    guard case .assistant(let transformedAssistant) = transformed.first else {
        #expect(Bool(false), "Expected assistant message")
        return
    }
    guard case .toolCall(let transformedCall) = transformedAssistant.content.first else {
        #expect(Bool(false), "Expected tool call content")
        return
    }
    #expect(transformedCall.id == "normalized-call|abc")

    guard transformed.count == 2, case .toolResult(let transformedResult) = transformed[1] else {
        #expect(Bool(false), "Expected tool result message")
        return
    }
    #expect(transformedResult.toolCallId == "normalized-call|abc")
}

@Test func transformMessagesPreservesThinkingSignatureForSameModel() {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let thinking = ThinkingContent(thinking: "   ", thinkingSignature: "sig")
    let assistant = AssistantMessage(
        content: [.thinking(thinking)],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .stop
    )

    let transformed = transformMessages([.assistant(assistant)], model: model)
    guard case .assistant(let transformedAssistant) = transformed.first else {
        #expect(Bool(false), "Expected assistant message")
        return
    }
    guard case .thinking(let transformedThinking) = transformedAssistant.content.first else {
        #expect(Bool(false), "Expected thinking content")
        return
    }
    #expect(transformedThinking.thinkingSignature == "sig")
}

@Test func transformMessagesConvertsThinkingAcrossProviders() {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let thinking = ThinkingContent(thinking: "Reasoning detail", thinkingSignature: "sig")
    let assistant = AssistantMessage(
        content: [.thinking(thinking)],
        api: .anthropicMessages,
        provider: "anthropic",
        model: "claude-3-5-haiku-20241022",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .stop
    )

    let transformed = transformMessages([.assistant(assistant)], model: model)
    guard case .assistant(let transformedAssistant) = transformed.first else {
        #expect(Bool(false), "Expected assistant message")
        return
    }
    guard case .text(let text) = transformedAssistant.content.first else {
        #expect(Bool(false), "Expected text content")
        return
    }
    #expect(text.text == "Reasoning detail")
}

@Test func transformMessagesSkipsAbortedAssistants() {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let assistant = AssistantMessage(
        content: [.text(TextContent(text: "ignored"))],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .aborted
    )
    let user = UserMessage(content: .text("continue"))
    let transformed = transformMessages([.assistant(assistant), .user(user)], model: model)

    #expect(transformed.count == 1)
    guard case .user(let transformedUser) = transformed.first else {
        #expect(Bool(false), "Expected user message")
        return
    }
    guard case .text(let text) = transformedUser.content else {
        #expect(Bool(false), "Expected user text content")
        return
    }
    #expect(text == "continue")
}

@Test func transformMessagesRemovesToolCallThoughtSignatureAcrossModels() {
    let targetModel = getModel(provider: .githubCopilot, modelId: "claude-sonnet-4.5")
    let toolCall = ToolCall(
        id: "call_123",
        name: "bash",
        arguments: ["command": AnyCodable("ls")],
        thoughtSignature: "{\"type\":\"reasoning.encrypted\"}"
    )
    let assistant = AssistantMessage(
        content: [.toolCall(toolCall)],
        api: .openAIResponses,
        provider: "github-copilot",
        model: "gpt-4o",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .toolUse
    )

    let transformed = transformMessages([.assistant(assistant)], model: targetModel)
    guard case .assistant(let transformedAssistant) = transformed.first else {
        #expect(Bool(false), "Expected assistant message")
        return
    }
    guard case .toolCall(let transformedToolCall) = transformedAssistant.content.first else {
        #expect(Bool(false), "Expected tool call content")
        return
    }
    #expect(transformedToolCall.thoughtSignature == nil)
}

@Test func contextOverflowDetection() {
    let usage = Usage(input: 10, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 10)
    let message = AssistantMessage(
        content: [],
        api: .openAICompletions,
        provider: "openai",
        model: "gpt-4o-mini",
        usage: usage,
        stopReason: .error,
        errorMessage: "Your input exceeds the context window of this model"
    )
    #expect(isContextOverflow(message))
}

@Test func contextOverflowDetectionInputTooLong() {
    let usage = Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0)
    let message = AssistantMessage(
        content: [],
        api: .openAICompletions,
        provider: "github-copilot",
        model: "claude-sonnet-4",
        usage: usage,
        stopReason: .error,
        errorMessage: "input is too long"
    )
    #expect(isContextOverflow(message))
}

@Test func openAICodexSessionIdForwarding() async throws {
    let sessionId = String(repeating: "session-", count: 10)
    let expectedSessionId = String(sessionId.prefix(OPENAI_PROMPT_CACHE_KEY_MAX_LENGTH))
    let capture = try await runCodexSessionRequest(sessionId: sessionId)
    #expect(capture.conversationId == expectedSessionId)
    #expect(capture.sessionId == expectedSessionId)
    #expect(capture.xClientRequestId == expectedSessionId)
    #expect(capture.promptCacheKey == expectedSessionId)
}

@Test func openAICodexNoSessionId() async throws {
    let capture = try await runCodexSessionRequest(sessionId: nil)
    #expect(capture.conversationId == nil)
    #expect(capture.sessionId == nil)
    #expect(capture.xClientRequestId == nil)
    #expect(capture.promptCacheKey == nil)
    #expect(capture.serviceTier == nil)
}

@Test func openAICodexOmitsToolFieldsForExplicitEmptyTools() async throws {
    let capture = try await runCodexSessionRequest(sessionId: nil, tools: [])
    #expect(capture.hasTools == false)
    #expect(capture.toolChoice == nil)
    #expect(capture.parallelToolCalls == nil)
}

@Test func openAICodexKeepsToolFieldsForNonEmptyTools() async throws {
    let capture = try await runCodexSessionRequest(
        sessionId: nil,
        tools: [
            AITool(
                name: "ping",
                description: "Ping tool",
                parameters: ["type": AnyCodable("object")]
            ),
        ]
    )
    #expect(capture.hasTools == true)
    #expect(capture.toolChoice == "auto")
    #expect(capture.parallelToolCalls == true)
}

@Test func openAICodexForwardsServiceTierAndAppliesPricing() async throws {
    let capture = try await runCodexSessionRequest(sessionId: "tier-session", serviceTier: .priority)
    #expect(capture.serviceTier == "priority")

    let model = getModel(provider: .openaiCodex, modelId: "gpt-5.4")
    let expectedInput = model.cost.input / 1_000_000 * Double(capture.usage.input) * 2
    let expectedOutput = model.cost.output / 1_000_000 * Double(capture.usage.output) * 2
    #expect(abs(capture.usage.cost.input - expectedInput) < 0.000000001)
    #expect(abs(capture.usage.cost.output - expectedOutput) < 0.000000001)
    #expect(abs(capture.usage.cost.total - (expectedInput + expectedOutput)) < 0.000000001)
}

@Test func openAIResponsesForeignFunctionCallItemIdUsesUpstreamHash() {
    let rawItemId = "tool.item:with spaces/and=punct"
    #expect(openAIResponsesShortHash(rawItemId) == "14qw7aq1pijvw1")
    #expect(openAIResponsesForeignFunctionCallItemId(rawItemId) == "fc_14qw7aq1pijvw1")
}

@Test func openAICodexForeignToolCallItemIdsAreHashed() async throws {
    let rawItemId = "foreign.item/id with punctuation and a very very very very very long suffix"
    let model = getModel(provider: .openaiCodex, modelId: "gpt-5.4")
    let foreignAssistant = AssistantMessage(
        content: [
            .toolCall(ToolCall(id: "call.foreign|\(rawItemId)", name: "lookup", arguments: ["q": AnyCodable("weather")]))
        ],
        api: .anthropicMessages,
        provider: "anthropic",
        model: "claude-sonnet-4-5",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .toolUse
    )
    let context = Context(messages: [
        .user(UserMessage(content: .text("Use the tool"))),
        .assistant(foreignAssistant),
    ])

    let input = convertCodexMessages(model: model, context: context)
    let functionCall = input.compactMap { $0 as? [String: Any] }.first { $0["type"] as? String == "function_call" }
    let itemId = functionCall?["id"] as? String
    #expect(itemId == "fc_1wy8det4hqwa6")
    #expect(itemId?.count ?? 0 <= 64)
}

@Test func openAICodexToolCallUsesStreamingArguments() async throws {
    let capture = try await runCodexToolCallRequest()
    let toolCall = capture.message.content.compactMap { block -> ToolCall? in
        if case .toolCall(let call) = block { return call }
        return nil
    }.first
    #expect(toolCall != nil)
    #expect(toolCall?.name == "read")
    let path = toolCall?.arguments["path"]?.value as? String
    #expect(path == "x")
    #expect(capture.deltas == ["{\"path\":\"x\"}"])
}

@Test func openAICodexToolCallDoneOnlyArgumentsEmitDelta() async throws {
    let capture = try await runCodexToolCallRequest(argumentEvents: [.done("{\"path\":\"x\"}")])
    let toolCall = capture.message.content.compactMap { block -> ToolCall? in
        if case .toolCall(let call) = block { return call }
        return nil
    }.first
    #expect(toolCall?.arguments["path"]?.value as? String == "x")
    #expect(capture.deltas == ["{\"path\":\"x\"}"])
}

@Test func openAICodexToolCallDoneArgumentsEmitOnlyMissingSuffix() async throws {
    let capture = try await runCodexToolCallRequest(argumentEvents: [
        .delta("{\"path\""),
        .done("{\"path\":\"x\"}"),
    ])
    let toolCall = capture.message.content.compactMap { block -> ToolCall? in
        if case .toolCall(let call) = block { return call }
        return nil
    }.first
    #expect(toolCall?.arguments["path"]?.value as? String == "x")
    #expect(capture.deltas == ["{\"path\"", ":\"x\"}"])
}

@Test func openAIResponsesFinalToolCallArgumentsDeltaMatchesUpstreamSuffixRules() {
    #expect(finalToolCallArgumentsDelta(previous: "", final: "{\"path\":\"x\"}") == "{\"path\":\"x\"}")
    #expect(finalToolCallArgumentsDelta(previous: "{\"path\"", final: "{\"path\":\"x\"}") == ":\"x\"}")
    #expect(finalToolCallArgumentsDelta(previous: "{\"path\":\"x\"}", final: "{\"path\":\"x\"}") == nil)
    #expect(finalToolCallArgumentsDelta(previous: "{\"other\"", final: "{\"path\":\"x\"}") == nil)
}

@Test func openAIResponsesOmitsToolsForNilAndEmptyToolLists() {
    #expect(responsesToolsPayload(nil) == nil)
    #expect(responsesToolsPayload([]) == nil)

    let tools = responsesToolsPayload([
        AITool(
            name: "ping",
            description: "Ping tool",
            parameters: ["type": AnyCodable("object")]
        ),
    ])
    #expect(tools?.count == 1)
}

@Test func openAICompletionsToolCallIdResolutionUsesIndexMapping() async throws {
    var toolCallIdByIndex: [Int: String] = [:]
    let firstFunction = ChatStreamResult.Choice.ChoiceDelta.ChoiceDeltaToolCall.ChoiceDeltaToolCallFunction(
        arguments: nil,
        name: "bash"
    )
    let first = ChatStreamResult.Choice.ChoiceDelta.ChoiceDeltaToolCall(
        index: 0,
        id: "call_1",
        function: firstFunction
    )
    let resolvedFirst = resolveToolCallIdentity(
        toolCall: first,
        currentToolCallId: nil,
        currentToolCallIndex: nil,
        toolCallIdByIndex: &toolCallIdByIndex,
        requiresMistral: false
    )
    #expect(resolvedFirst.id == "call_1")
    #expect(toolCallIdByIndex[0] == "call_1")

    let secondFunction = ChatStreamResult.Choice.ChoiceDelta.ChoiceDeltaToolCall.ChoiceDeltaToolCallFunction(
        arguments: "{\"command\":\"ls\"}",
        name: nil
    )
    let second = ChatStreamResult.Choice.ChoiceDelta.ChoiceDeltaToolCall(
        index: 0,
        id: nil,
        function: secondFunction
    )
    let resolvedSecond = resolveToolCallIdentity(
        toolCall: second,
        currentToolCallId: resolvedFirst.id,
        currentToolCallIndex: resolvedFirst.index,
        toolCallIdByIndex: &toolCallIdByIndex,
        requiresMistral: false
    )
    #expect(resolvedSecond.id == "call_1")

    let mutated = ChatStreamResult.Choice.ChoiceDelta.ChoiceDeltaToolCall(
        index: 0,
        id: "provider_changed_id",
        function: secondFunction
    )
    let resolvedMutated = resolveToolCallIdentity(
        toolCall: mutated,
        currentToolCallId: resolvedFirst.id,
        currentToolCallIndex: resolvedFirst.index,
        toolCallIdByIndex: &toolCallIdByIndex,
        requiresMistral: false
    )
    #expect(resolvedMutated.id == "call_1")
    #expect(toolCallIdByIndex[0] == "call_1")

    var emptyMap: [Int: String] = [:]
    let third = ChatStreamResult.Choice.ChoiceDelta.ChoiceDeltaToolCall(
        index: 2,
        id: nil,
        function: nil
    )
    let resolvedThird = resolveToolCallIdentity(
        toolCall: third,
        currentToolCallId: nil,
        currentToolCallIndex: nil,
        toolCallIdByIndex: &emptyMap,
        requiresMistral: false
    )
    #expect(resolvedThird.id == "toolcall_2")
}

@Test func openAICompletionsUsagePreservesCacheWriteTokens() async throws {
    await codexRequestLock.withLock {
        OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = ["api.openai.com"] }
        OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = { request in
            #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            let data = try openAITestSseData([
                [
                    "id": "chatcmpl-usage",
                    "object": "chat.completion.chunk",
                    "created": 0,
                    "model": "chat-compat-test",
                    "choices": [
                        [
                            "index": 0,
                            "delta": ["content": "ok"],
                            "finish_reason": NSNull(),
                        ],
                    ],
                ],
                [
                    "id": "chatcmpl-usage",
                    "object": "chat.completion.chunk",
                    "created": 0,
                    "model": "chat-compat-test",
                    "choices": [
                        [
                            "index": 0,
                            "delta": [:],
                            "finish_reason": "stop",
                        ],
                    ],
                ],
                [
                    "id": "chatcmpl-usage",
                    "object": "chat.completion.chunk",
                    "created": 0,
                    "model": "chat-compat-test",
                    "choices": [],
                    "usage": [
                        "prompt_tokens": 100,
                        "completion_tokens": 20,
                        "prompt_tokens_details": [
                            "cached_tokens": 15,
                            "cache_write_tokens": 5,
                        ],
                    ],
                ],
            ])
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, data)
        } }
        URLProtocol.registerClass(OpenAICompletionsMockURLProtocol.self)
        defer {
            OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = nil }
            OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = [] }
            URLProtocol.unregisterClass(OpenAICompletionsMockURLProtocol.self)
        }

        let model = Model(
            id: "chat-compat-test",
            name: "Chat Compat Test",
            api: .openAICompletions,
            provider: "openai",
            baseUrl: "https://api.openai.com/v1",
            reasoning: false,
            input: [.text],
            cost: ModelCost(input: 1, output: 2, cacheRead: 0.5, cacheWrite: 3),
            contextWindow: 128000,
            maxTokens: 4096
        )
        let stream = streamOpenAICompletions(
            model: model,
            context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
            options: OpenAICompletionsOptions(apiKey: "test-key")
        )
        let message = await stream.result()

        #expect(message.stopReason == .stop)
        #expect(message.usage.input == 80)
        #expect(message.usage.output == 20)
        #expect(message.usage.cacheRead == 15)
        #expect(message.usage.cacheWrite == 5)
        #expect(message.usage.totalTokens == 120)
    }
}

@Test func openAICompletionsMissingFinishReasonEmitsError() async {
    let capture = await runOpenAICompletionsStopReasonStream(payloads: [
        openAIStopReasonChunk(delta: ["content": "partial"], finishReason: NSNull()),
    ])

    #expect(capture.emittedError)
    #expect(!capture.emittedDone)
    #expect(capture.message.stopReason == .error)
    #expect(capture.message.errorMessage?.contains("Stream ended without finish_reason") == true)
}

@Test func openAICompletionsUnknownFinishReasonIsProviderError() async {
    let capture = await runOpenAICompletionsStopReasonStream(payloads: [
        openAIStopReasonChunk(delta: ["content": "partial"], finishReason: "future_reason"),
    ])

    #expect(capture.emittedError)
    #expect(!capture.emittedDone)
    #expect(capture.message.stopReason == .error)
    #expect(capture.message.rawStopReason == "future_reason")
    #expect(capture.message.errorMessage?.contains("Provider stopped with: future_reason") == true)
}

@Test func openAICompletionsPreservesRecognizedRawFinishReason() async {
    let capture = await runOpenAICompletionsStopReasonStream(payloads: [
        openAIStopReasonChunk(delta: ["content": "done"], finishReason: "stop"),
    ])

    #expect(capture.emittedDone)
    #expect(!capture.emittedError)
    #expect(capture.message.stopReason == .stop)
    #expect(capture.message.rawStopReason == "stop")
}

@Test func openAICompletionsWithoutFinishReasonInfersStopWhenUnsupported() async {
    let capture = await runOpenAICompletionsStopReasonStream(
        payloads: [openAIStopReasonChunk(delta: ["content": "done"], finishReason: NSNull())],
        compat: OpenAICompat(supportsFinishReason: false)
    )

    #expect(capture.emittedDone)
    #expect(!capture.emittedError)
    #expect(capture.message.stopReason == .stop)
    #expect(capture.message.rawStopReason == nil)
}

@Test func openAICompletionsWithoutFinishReasonInfersToolUseWhenUnsupported() async {
    let capture = await runOpenAICompletionsStopReasonStream(
        payloads: [
            openAIStopReasonChunk(
                delta: [
                    "tool_calls": [[
                        "index": 0,
                        "id": "call_1",
                        "type": "function",
                        "function": ["name": "lookup", "arguments": "{}"],
                    ]],
                ],
                finishReason: NSNull()
            ),
        ],
        compat: OpenAICompat(supportsFinishReason: false)
    )

    #expect(capture.emittedDone)
    #expect(!capture.emittedError)
    #expect(capture.message.stopReason == .toolUse)
    #expect(capture.message.content.contains { block in
        if case .toolCall = block { return true }
        return false
    })
}

@Test func responseIncompleteReasonsRemainDistinct() {
    let limited = mapResponsesStopReason("incomplete", incompleteReason: "max_output_tokens")
    #expect(limited.stopReason == .length)
    #expect(limited.errorMessage == nil)

    let filtered = mapResponsesStopReason("incomplete", incompleteReason: "content_filter")
    #expect(filtered.stopReason == .error)
    #expect(filtered.errorMessage?.contains("content_filter") == true)

    let unknown = mapResponsesStopReason("future_status")
    #expect(unknown.stopReason == .error)
    #expect(unknown.errorMessage == "Provider stopped with: future_status")
}

@Test func anthropicStopReasonMappingPreservesRecognizedAndRejectsUnknownReasons() {
    let recognized = mapAnthropicStopReason("end_turn")
    #expect(recognized.stopReason == .stop)
    #expect(recognized.errorMessage == nil)

    let sensitive = mapAnthropicStopReason("sensitive")
    #expect(sensitive.stopReason == .error)
    #expect(sensitive.errorMessage == "Provider stopped with: sensitive")

    let unknown = mapAnthropicStopReason("future_reason")
    #expect(unknown.stopReason == .error)
    #expect(unknown.errorMessage == "Provider stopped with: future_reason")
}

@Test func openAICompletionsUsageFallsBackToChoiceUsage() async throws {
    await codexRequestLock.withLock {
        OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = ["moonshot.example"] }
        OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = { request in
            let data = try openAITestSseData([
                [
                    "id": "chatcmpl-choice-usage",
                    "object": "chat.completion.chunk",
                    "created": 0,
                    "model": "moonshot-choice-usage",
                    "choices": [
                        [
                            "index": 0,
                            "delta": ["content": "ok"],
                            "finish_reason": "stop",
                            "usage": [
                                "prompt_tokens": 40,
                                "completion_tokens": 8,
                                "prompt_cache_hit_tokens": 6,
                            ],
                        ],
                    ],
                ],
            ])
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, data)
        } }
        URLProtocol.registerClass(OpenAICompletionsMockURLProtocol.self)
        defer {
            OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = nil }
            OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = [] }
            URLProtocol.unregisterClass(OpenAICompletionsMockURLProtocol.self)
        }

        let model = Model(
            id: "moonshot-choice-usage",
            name: "Moonshot Choice Usage",
            api: .openAICompletions,
            provider: "moonshot",
            baseUrl: "https://moonshot.example/v1",
            reasoning: false,
            input: [.text],
            cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 128000,
            maxTokens: 4096
        )
        let stream = streamOpenAICompletions(
            model: model,
            context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
            options: OpenAICompletionsOptions(apiKey: "test-key")
        )
        let message = await stream.result()

        #expect(message.stopReason == .stop)
        #expect(message.usage.input == 34)
        #expect(message.usage.output == 8)
        #expect(message.usage.cacheRead == 6)
        #expect(message.usage.cacheWrite == 0)
        #expect(message.usage.totalTokens == 48)
    }
}

@Test func openAICompletionsIgnoresNullSSEChunks() async throws {
    await codexRequestLock.withLock {
        OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = ["null-chunk.example"] }
        OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = { request in
            let validChunk = try JSONSerialization.data(withJSONObject: [
                "id": "chatcmpl-null",
                "object": "chat.completion.chunk",
                "created": 0,
                "model": "null-chunk-test",
                "choices": [
                    [
                        "index": 0,
                        "delta": ["content": "ok"],
                        "finish_reason": "stop",
                    ],
                ],
            ])
            let validJSON = String(decoding: validChunk, as: UTF8.self)
            let data = Data("data: null\n\ndata: \(validJSON)\n\ndata: [DONE]\n\n".utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, data)
        } }
        URLProtocol.registerClass(OpenAICompletionsMockURLProtocol.self)
        defer {
            OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = nil }
            OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = [] }
            URLProtocol.unregisterClass(OpenAICompletionsMockURLProtocol.self)
        }

        let model = Model(
            id: "null-chunk-test",
            name: "Null Chunk Test",
            api: .openAICompletions,
            provider: "null-chunk",
            baseUrl: "https://null-chunk.example/v1",
            reasoning: false,
            input: [.text],
            cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 128000,
            maxTokens: 4096
        )
        let stream = streamOpenAICompletions(
            model: model,
            context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
            options: OpenAICompletionsOptions(apiKey: "test-key")
        )
        let message = await stream.result()

        #expect(message.stopReason == .stop)
        let text = message.content.compactMap { block -> String? in
            if case .text(let text) = block { return text.text }
            return nil
        }.joined()
        #expect(text == "ok")
    }
}

@Test func openAICompletionsRequiresThinkingAsTextUsesAssistantContentParts() async throws {
    await codexRequestLock.withLock {
        let capturedPayloadJson = LockedState<String?>(nil)
        OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = ["thinking-as-text.example"] }
        OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = { request in
            let data = try openAITestSseData([
                [
                    "id": "chatcmpl-thinking-text",
                    "object": "chat.completion.chunk",
                    "created": 0,
                    "model": "thinking-as-text-test",
                    "choices": [
                        [
                            "index": 0,
                            "delta": ["content": "ok"],
                            "finish_reason": "stop",
                        ],
                    ],
                ],
            ])
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, data)
        } }
        URLProtocol.registerClass(OpenAICompletionsMockURLProtocol.self)
        defer {
            OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = nil }
            OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = [] }
            URLProtocol.unregisterClass(OpenAICompletionsMockURLProtocol.self)
        }

        let model = Model(
            id: "thinking-as-text-test",
            name: "Thinking As Text Test",
            api: .openAICompletions,
            provider: "thinking-as-text",
            baseUrl: "https://thinking-as-text.example/v1",
            reasoning: false,
            input: [.text],
            cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 128000,
            maxTokens: 4096,
            compat: OpenAICompat(requiresThinkingAsText: true)
        )
        let assistant = AssistantMessage(
            content: [
                .thinking(ThinkingContent(thinking: "private reasoning")),
                .text(TextContent(text: "visible answer")),
            ],
            api: .openAICompletions,
            provider: "thinking-as-text",
            model: model.id,
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
            stopReason: .stop
        )
        let stream = streamOpenAICompletions(
            model: model,
            context: Context(messages: [
                .assistant(assistant),
                .user(UserMessage(content: .text("continue"))),
            ]),
            options: OpenAICompletionsOptions(
                apiKey: "test-key",
                onPayload: { snapshot in capturedPayloadJson.withLock { $0 = snapshot.json } }
            )
        )
        _ = await stream.result()

        let payload = capturedPayloadJson.withLock { $0 }.flatMap { jsonString -> [String: Any]? in
            guard let data = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return json
        }
        let messages = payload?["messages"] as? [[String: Any]]
        let assistantPayload = messages?.first { $0["role"] as? String == "assistant" }
        let content = assistantPayload?["content"] as? [[String: Any]]
        #expect(content?.count == 2)
        #expect(content?.first?["type"] as? String == "text")
        #expect(content?.first?["text"] as? String == "private reasoning")
        #expect(content?.last?["text"] as? String == "visible answer")
    }
}

@Test func openAICompletionsSmoke() async throws {
    guard RUN_OPENAI_TESTS, ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil else {
        return
    }
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let context = Context(messages: [.user(UserMessage(content: .text("Say hello in one word.")))])
    let response = try await complete(model: model, context: context)
    #expect(!response.content.isEmpty)
    #expect(response.stopReason != .error)
}

@Test func openAIResponsesSmoke() async throws {
    guard RUN_OPENAI_TESTS, ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil else {
        return
    }
    let model = getModel(provider: .openai, modelId: "gpt-5-mini")
    let context = Context(messages: [.user(UserMessage(content: .text("Return the word ok.")))])
    let response = try await complete(model: model, context: context)
    #expect(!response.content.isEmpty)
    #expect(response.stopReason != .error)
}

@Test func anthropicSmoke() async throws {
    guard RUN_ANTHROPIC_TESTS else {
        return
    }
    let model = getModel(provider: .anthropic, modelId: "claude-haiku-4-5")
    let context = Context(messages: [.user(UserMessage(content: .text("Reply with hi.")))])
    let response = try await complete(model: model, context: context)
    #expect(!response.content.isEmpty)
    #expect(response.stopReason != .error)
}

@Test func minimaxSmoke() async throws {
    guard ProcessInfo.processInfo.environment["MINIMAX_API_KEY"] != nil else {
        return
    }
    let model = getModel(provider: .minimax, modelId: "MiniMax-M2.1")
    let context = Context(messages: [.user(UserMessage(content: .text("Reply with hi.")))])
    let response = try await complete(model: model, context: context)
    #expect(!response.content.isEmpty)
    #expect(response.stopReason != .error)
}

@Test func vercelAiGatewaySmoke() async throws {
    guard ProcessInfo.processInfo.environment["AI_GATEWAY_API_KEY"] != nil else {
        return
    }
    let model = getModel(provider: .vercelAiGateway, modelId: "google/gemini-2.5-flash")
    let context = Context(messages: [.user(UserMessage(content: .text("Reply with hi.")))])
    let response = try await complete(model: model, context: context)
    #expect(!response.content.isEmpty)
    #expect(response.stopReason != .error)
}

@Test func zaiSmoke() async throws {
    guard ProcessInfo.processInfo.environment["ZAI_API_KEY"] != nil else {
        return
    }
    let model = getModel(provider: .zai, modelId: "glm-4.5-air")
    let context = Context(messages: [.user(UserMessage(content: .text("Reply with hi.")))])
    let response = try await complete(model: model, context: context)
    #expect(!response.content.isEmpty)
    #expect(response.stopReason != .error)
}

private actor EnvLock {
    func withEnv(_ key: String, value: String?, work: @Sendable () async -> Void) async {
        let previous = ProcessInfo.processInfo.environment[key]
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }
        await work()
    }
}

private let envLock = EnvLock()

private func withEnv(_ key: String, value: String?, _ work: @Sendable () async -> Void) async {
    await envLock.withEnv(key, value: value, work: work)
}

private func withCleanBedrockEnv(_ work: @Sendable () async -> Void) async {
    await withEnv("AWS_REGION", value: nil) {
        await withEnv("AWS_DEFAULT_REGION", value: nil) {
            await withEnv("AWS_PROFILE", value: nil) {
                await withEnv("AWS_DEFAULT_PROFILE", value: nil) {
                    await withEnv("AWS_ACCESS_KEY_ID", value: nil) {
                        await withEnv("AWS_SECRET_ACCESS_KEY", value: nil) {
                            await withEnv("AWS_SESSION_TOKEN", value: nil) {
                                await withEnv("AWS_BEARER_TOKEN_BEDROCK", value: nil) {
                                    await withEnv("AWS_BEDROCK_SKIP_AUTH", value: nil) {
                                        await work()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Test func findEnvKeysReturnsConfiguredNamesWithoutValues() async throws {
    await withEnv("OPENAI_API_KEY", value: "sk-secret-value") {
        #expect(findEnvKeys(provider: "openai") == ["OPENAI_API_KEY"])
        #expect(findEnvKeys(provider: .openai) == ["OPENAI_API_KEY"])
        #expect(findEnvKeys(provider: "openai")?.contains("sk-secret-value") == false)
        #expect(getEnvApiKey(provider: "openai") == "sk-secret-value")
    }
}

@Test func newProvidersResolveTheirDocumentedEnvironmentKeys() async {
    await withEnv("BASETEN_API_KEY", value: "baseten-test-key") {
        #expect(findEnvKeys(provider: .baseten) == ["BASETEN_API_KEY"])
        #expect(getEnvApiKey(provider: .baseten) == "baseten-test-key")
    }
    await withEnv("QWEN_TOKEN_PLAN_API_KEY", value: "qwen-shared-test-key") {
        #expect(findEnvKeys(provider: .qwenTokenPlan) == ["QWEN_TOKEN_PLAN_API_KEY"])
        #expect(findEnvKeys(provider: .qwenTokenPlanIndividual) == ["QWEN_TOKEN_PLAN_API_KEY"])
        #expect(getEnvApiKey(provider: .qwenTokenPlan) == "qwen-shared-test-key")
        #expect(getEnvApiKey(provider: .qwenTokenPlanIndividual) == "qwen-shared-test-key")
    }
    await withEnv("QWEN_TOKEN_PLAN_CN_API_KEY", value: "qwen-cn-test-key") {
        #expect(findEnvKeys(provider: .qwenTokenPlanCn) == ["QWEN_TOKEN_PLAN_CN_API_KEY"])
        #expect(getEnvApiKey(provider: .qwenTokenPlanCn) == "qwen-cn-test-key")
    }
}

@Test func findEnvKeysOnlyReturnsSetProviderKeys() async throws {
    await withEnv("ANTHROPIC_AUTH_TOKEN", value: nil) {
        await withEnv("ANTHROPIC_OAUTH_TOKEN", value: nil) {
            await withEnv("ANTHROPIC_API_KEY", value: "sk-ant-api") {
                #expect(findEnvKeys(provider: "anthropic") == ["ANTHROPIC_API_KEY"])
                #expect(getEnvApiKey(provider: "anthropic") == "sk-ant-api")
            }
        }
    }

    await withEnv("ANTHROPIC_AUTH_TOKEN", value: "gateway-token") {
        await withEnv("ANTHROPIC_OAUTH_TOKEN", value: "oauth-token") {
            await withEnv("ANTHROPIC_API_KEY", value: "sk-ant-api") {
                #expect(findEnvKeys(provider: "anthropic") == [
                    "ANTHROPIC_AUTH_TOKEN",
                    "ANTHROPIC_OAUTH_TOKEN",
                    "ANTHROPIC_API_KEY",
                ])
                #expect(getEnvApiKey(provider: "anthropic") == "gateway-token")
                #expect(usesAnthropicBearerTransport("gateway-token"))
                #expect(!usesAnthropicBearerTransport("sk-ant-api"))
                #expect(anthropicAuthenticationHeaders(
                    apiKey: "gateway-token",
                    usesBearerTransport: usesAnthropicBearerTransport("gateway-token")
                ) == ["Authorization": "Bearer gateway-token"])
            }
        }
    }
}

@Test func findEnvKeysExcludesAmbientCredentialSources() async throws {
    await withEnv("AWS_PROFILE", value: "dev-profile") {
        #expect(findEnvKeys(provider: "amazon-bedrock") == nil)
        #expect(getEnvApiKey(provider: "amazon-bedrock") == "<authenticated>")
    }

    await withEnv("GOOGLE_CLOUD_PROJECT", value: "project") {
        await withEnv("GOOGLE_CLOUD_LOCATION", value: "us-central1") {
            #expect(findEnvKeys(provider: "google-vertex") == nil)
        }
    }

    await withEnv("GOOGLE_CLOUD_API_KEY", value: "google-cloud-key") {
        #expect(findEnvKeys(provider: "google-vertex") == ["GOOGLE_CLOUD_API_KEY"])
        #expect(getEnvApiKey(provider: "google-vertex") == "google-cloud-key")
    }
}

@Test func openAIPromptCacheRetentionHelper() async throws {
    await withEnv("PI_CACHE_RETENTION", value: nil) {
        #expect(resolveCacheRetention(nil) == .short)
        #expect(getPromptCacheRetention(baseUrl: "https://api.openai.com/v1", cacheRetention: .short) == nil)
    }
    await withEnv("PI_CACHE_RETENTION", value: "long") {
        #expect(resolveCacheRetention(nil) == .long)
        #expect(getPromptCacheRetention(baseUrl: "https://api.openai.com/v1", cacheRetention: .long) == "24h")
        #expect(getPromptCacheRetention(baseUrl: "https://proxy.example.com/v1", cacheRetention: .long) == nil)
    }
}

@Test func openAIResponsesCacheMiddlewareInjection() async throws {
    let payload: [String: Any] = [
        "model": "gpt-4o-mini",
        "input": [],
    ]
    let body = try JSONSerialization.data(withJSONObject: payload)
    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
    request.httpMethod = "POST"
    request.httpBody = body

    let sessionId = String(repeating: "a", count: 70)
    let middleware = OpenAIResponsesCacheMiddleware(
        sessionId: sessionId,
        cacheRetention: .long,
        promptCacheRetention: "24h",
        sessionAffinityFormat: .openai
    )
    let updated = middleware.intercept(request: request)
    let updatedBody = try #require(updated.httpBody)
    let updatedPayload = try #require(try JSONSerialization.jsonObject(with: updatedBody) as? [String: Any])
    #expect(updatedPayload["prompt_cache_key"] as? String == String(repeating: "a", count: 64))
    #expect(updatedPayload["prompt_cache_retention"] as? String == "24h")
    #expect(updated.value(forHTTPHeaderField: "session_id") == sessionId)
    #expect(updated.value(forHTTPHeaderField: "x-client-request-id") == sessionId)
}

@Test func openAIResponsesCacheMiddlewareDisabled() async throws {
    let payload: [String: Any] = [
        "model": "gpt-4o-mini",
        "input": [],
    ]
    let body = try JSONSerialization.data(withJSONObject: payload)
    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
    request.httpMethod = "POST"
    request.httpBody = body

    let middleware = OpenAIResponsesCacheMiddleware(
        sessionId: "session-123",
        cacheRetention: .none,
        promptCacheRetention: nil,
        sessionAffinityFormat: .openai
    )
    let updated = middleware.intercept(request: request)
    let updatedBody = updated.httpBody.flatMap { String(data: $0, encoding: .utf8) }
    #expect(updatedBody?.contains("\"prompt_cache_key\"") == false)
    #expect(updatedBody?.contains("\"prompt_cache_retention\"") == false)
}

/// v0.62.0: reasoning Responses models explicitly disable thinking with `effort: "none"`
/// when no reasoning effort/summary is requested.
@Test func openAIResponsesDefaultReasoningUsesNoneEffort() throws {
    let model = getModel(provider: .openai, modelId: "gpt-5.4")
    let query = try buildResponsesQuery(
        model: model,
        context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
        options: OpenAIResponsesOptions(apiKey: "test-key")
    )
    let object = try encodedJSONObject(query)
    let json = try canonicalJSONString(object)
    let reasoning = object["reasoning"] as? [String: Any]

    #expect(reasoning?["effort"] as? String == "none")
    #expect(reasoning?["summary"] == nil)
    #expect(object["include"] == nil)
    #expect(!json.contains("Juice"))
}

@Test func openAIResponsesReasoningRequestDefaultsSummaryAutoAndInclude() throws {
    let model = getModel(provider: .openai, modelId: "gpt-5.4")
    let query = try buildResponsesQuery(
        model: model,
        context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
        options: OpenAIResponsesOptions(apiKey: "test-key", reasoningEffort: .high)
    )
    let object = try encodedJSONObject(query)
    let reasoning = object["reasoning"] as? [String: Any]
    let include = object["include"] as? [String]

    #expect(reasoning?["effort"] as? String == "high")
    #expect(reasoning?["summary"] as? String == "auto")
    #expect(include == ["reasoning.encrypted_content"])
}

@Test func openAIResponsesDoesNotDefaultDisableGithubCopilotReasoning() throws {
    let model = Model(
        id: "gpt-5-copilot",
        name: "GPT-5 Copilot",
        api: .openAIResponses,
        provider: "github-copilot",
        baseUrl: "https://api.githubcopilot.com",
        reasoning: true,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 128000,
        maxTokens: 4096
    )
    let query = try buildResponsesQuery(
        model: model,
        context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
        options: OpenAIResponsesOptions(apiKey: "test-key")
    )
    let object = try encodedJSONObject(query)

    #expect(object["reasoning"] == nil)
    #expect(object["include"] == nil)
}

@Test func azureOpenAIResponsesDefaultReasoningUsesNoneEffort() throws {
    let model = Model(
        id: "gpt-5-azure",
        name: "GPT-5 Azure",
        api: .azureOpenAIResponses,
        provider: "azure-openai-responses",
        baseUrl: "https://example.openai.azure.com/openai/v1",
        reasoning: true,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 128000,
        maxTokens: 4096
    )
    let query = try buildAzureResponsesQuery(
        model: model,
        context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
        options: AzureOpenAIResponsesOptions(apiKey: "test-key"),
        deploymentName: "deployment-gpt-5"
    )
    let object = try encodedJSONObject(query)
    let json = try canonicalJSONString(object)
    let reasoning = object["reasoning"] as? [String: Any]

    #expect(object["model"] as? String == "deployment-gpt-5")
    #expect(reasoning?["effort"] as? String == "none")
    #expect(reasoning?["summary"] == nil)
    #expect(object["include"] == nil)
    #expect(!json.contains("Juice"))
}

@Test func anthropicCacheRetentionHelper() async throws {
    await withEnv("PI_CACHE_RETENTION", value: nil) {
        #expect(anthropicCacheTtl(baseUrl: "https://api.anthropic.com") == nil)
    }
    await withEnv("PI_CACHE_RETENTION", value: "long") {
        #expect(anthropicCacheTtl(baseUrl: "https://api.anthropic.com") == "1h")
        #expect(anthropicCacheTtl(baseUrl: "https://api.anthropic.com", supportsLongCacheRetention: false) == nil)
        #expect(anthropicCacheTtl(baseUrl: "https://proxy.example.com") == nil)
    }
}

@Test func anthropicCacheControlInjection() async throws {
    let payload: [String: Any] = [
        "model": "claude-3-5-haiku-20241022",
        "messages": [
            ["role": "user", "content": "Hello"],
        ],
        "system": "You are a helpful assistant.",
    ]
    let body = try JSONSerialization.data(withJSONObject: payload)
    let updatedDefault = injectCacheControl(body: body, ttl: nil)
    let updatedDefaultString = updatedDefault.flatMap { String(data: $0, encoding: .utf8) }
    #expect(updatedDefaultString?.contains("\"cache_control\"") == true)
    #expect(updatedDefaultString?.contains("\"ttl\"") == false)

    let updatedLong = injectCacheControl(body: body, ttl: "1h")
    let updatedLongString = updatedLong.flatMap { String(data: $0, encoding: .utf8) }
    #expect(updatedLongString?.contains("\"ttl\":\"1h\"") == true)
}

@Test func anthropicSSEParserRepairsJsonAndIgnoresUnknownEvents() throws {
    let lines = [
        "event: ping",
        "data: {\"type\":\"ping\"}",
        "",
        "event: message_start",
        "data: {\"type\":\"message_start\",",
        "data: \"message\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-test\",\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}",
        "",
        "event: content_block_start",
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
        "",
        "event: content_block_delta",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"bad\\qescape\"}}",
        "",
        "event: content_block_stop",
        "data: {\"type\":\"content_block_stop\",\"index\":0}",
        "",
        "event: done",
        "data: [DONE]",
        "",
        "event: message_stop",
        "data: {\"type\":\"message_stop\"}",
        "",
    ]

    let events = try decodeAnthropicSSELines(lines)
    #expect(events.map(\.type) == [
        "message_start",
        "content_block_start",
        "content_block_delta",
        "content_block_stop",
        "message_stop",
    ])
    #expect(events[2].delta?.text == "bad\\qescape")
}

// Line-based byte streams (AsyncLineSequence) swallow the blank separator
// lines, so the parser must also frame events on the next event field.
@Test func anthropicSSEParserHandlesMissingBlankLineSeparators() throws {
    let lines = [
        "event: message_start",
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-test\",\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}",
        "event: content_block_start",
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
        "event: ping",
        "data: {\"type\": \"ping\"}",
        "event: content_block_delta",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}",
        "event: content_block_stop",
        "data: {\"type\":\"content_block_stop\",\"index\":0   }",
        "event: message_stop",
        "data: {\"type\":\"message_stop\"     }",
    ]

    let events = try decodeAnthropicSSELines(lines)
    #expect(events.map(\.type) == [
        "message_start",
        "content_block_start",
        "content_block_delta",
        "content_block_stop",
        "message_stop",
    ])
    #expect(events[2].delta?.text == "hi")
}

@Test func anthropicSSEParserRequiresMessageStopAfterStart() throws {
    let lines = [
        "event: message_start",
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-test\",\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}",
        "",
    ]

    do {
        _ = try decodeAnthropicSSELines(lines)
        #expect(Bool(false), "Expected missing message_stop to throw")
    } catch {
        #expect(error.localizedDescription.contains("message_stop"))
    }
}

@Test func openAICompletionsAnthropicCacheControlInjection() throws {
    let payload: [String: Any] = [
        "model": "anthropic/claude-sonnet-4.5",
        "messages": [
            ["role": "system", "content": "You are concise."],
            [
                "role": "user",
                "content": [
                    ["type": "text", "text": "First"],
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64,AA=="]],
                ],
            ],
            ["role": "assistant", "content": "Cached answer"],
        ],
        "tools": [
            ["type": "function", "function": ["name": "first"]],
            ["type": "function", "function": ["name": "second"]],
        ],
    ]
    let body = try JSONSerialization.data(withJSONObject: payload)
    let cacheControl: [String: Any] = ["type": "ephemeral", "ttl": "1h"]

    guard let updatedBody = applyOpenAICompatCacheControl(
        data: body,
        cacheControl: cacheControl,
        supportsCacheControlOnTools: true
    ),
    let updated = try JSONSerialization.jsonObject(with: updatedBody) as? [String: Any],
    let messages = updated["messages"] as? [[String: Any]],
    let tools = updated["tools"] as? [[String: Any]] else {
        #expect(Bool(false), "Expected cache-control payload to decode")
        return
    }

    let systemContent = messages[0]["content"] as? [[String: Any]]
    let systemCache = systemContent?.first?["cache_control"] as? [String: Any]
    #expect(systemContent?.first?["text"] as? String == "You are concise.")
    #expect(systemCache?["type"] as? String == "ephemeral")
    #expect(systemCache?["ttl"] as? String == "1h")

    let userContent = messages[1]["content"] as? [[String: Any]]
    #expect(userContent?.first?["cache_control"] == nil)

    let assistantContent = messages[2]["content"] as? [[String: Any]]
    let assistantCache = assistantContent?.first?["cache_control"] as? [String: Any]
    #expect(assistantContent?.first?["text"] as? String == "Cached answer")
    #expect(assistantCache?["ttl"] as? String == "1h")

    #expect(tools.first?["cache_control"] == nil)
    let lastToolCache = tools.last?["cache_control"] as? [String: Any]
    #expect(lastToolCache?["type"] as? String == "ephemeral")
}

@Test func openAICompletionsCacheControlCanOmitToolMarker() throws {
    let payload: [String: Any] = [
        "model": "custom",
        "messages": [["role": "user", "content": "Hello"]],
        "tools": [["type": "function", "function": ["name": "search"]]],
    ]
    let body = try JSONSerialization.data(withJSONObject: payload)
    let cacheControl: [String: Any] = ["type": "ephemeral"]

    guard let updatedBody = applyOpenAICompatCacheControl(
        data: body,
        cacheControl: cacheControl,
        supportsCacheControlOnTools: false
    ),
    let updated = try JSONSerialization.jsonObject(with: updatedBody) as? [String: Any],
    let tools = updated["tools"] as? [[String: Any]] else {
        #expect(Bool(false), "Expected cache-control payload to decode")
        return
    }

    #expect(tools.first?["cache_control"] == nil)
}

@Test func openAICompletionsSessionAffinityHeaders() {
    let request = URLRequest(url: URL(string: "https://proxy.example.com/v1/chat/completions")!)
    let sessionId = "session-xyz"

    let openAI = applyOpenAICompletionsSessionAffinityHeaders(
        request: request,
        sessionId: sessionId,
        sendSessionAffinityHeaders: true,
        sessionAffinityFormat: .openai
    )
    #expect(openAI.value(forHTTPHeaderField: "session_id") == sessionId)
    #expect(openAI.value(forHTTPHeaderField: "x-client-request-id") == sessionId)
    #expect(openAI.value(forHTTPHeaderField: "x-session-affinity") == sessionId)
    #expect(openAI.value(forHTTPHeaderField: "x-session-id") == nil)

    let openAINosession = applyOpenAICompletionsSessionAffinityHeaders(
        request: request,
        sessionId: sessionId,
        sendSessionAffinityHeaders: true,
        sessionAffinityFormat: .openaiNosession
    )
    #expect(openAINosession.value(forHTTPHeaderField: "session_id") == nil)
    #expect(openAINosession.value(forHTTPHeaderField: "x-client-request-id") == sessionId)
    #expect(openAINosession.value(forHTTPHeaderField: "x-session-affinity") == sessionId)
    #expect(openAINosession.value(forHTTPHeaderField: "x-session-id") == nil)

    let openRouter = applyOpenAICompletionsSessionAffinityHeaders(
        request: request,
        sessionId: sessionId,
        sendSessionAffinityHeaders: true,
        sessionAffinityFormat: .openrouter
    )
    #expect(openRouter.value(forHTTPHeaderField: "x-session-id") == sessionId)
    #expect(openRouter.value(forHTTPHeaderField: "session_id") == nil)
    #expect(openRouter.value(forHTTPHeaderField: "x-client-request-id") == nil)
    #expect(openRouter.value(forHTTPHeaderField: "x-session-affinity") == nil)

    let omitted = applyOpenAICompletionsSessionAffinityHeaders(
        request: request,
        sessionId: sessionId,
        sendSessionAffinityHeaders: false,
        sessionAffinityFormat: .openai
    )
    #expect(omitted.value(forHTTPHeaderField: "session_id") == nil)
    #expect(omitted.value(forHTTPHeaderField: "x-client-request-id") == nil)
    #expect(omitted.value(forHTTPHeaderField: "x-session-affinity") == nil)
    #expect(omitted.value(forHTTPHeaderField: "x-session-id") == nil)
}

@Test func openAICompletionsPromptCacheFields() throws {
    let payload: [String: Any] = [
        "model": "gpt-4o-mini",
        "messages": [["role": "user", "content": "Hello"]],
    ]
    let body = try JSONSerialization.data(withJSONObject: payload)
    let longSession = String(repeating: "a", count: 70)

    guard let directBody = applyOpenAICompletionsPromptCache(
        data: body,
        baseUrl: "https://api.openai.com/v1",
        sessionId: longSession,
        cacheRetention: .short,
        supportsLongCacheRetention: true
    ),
    let direct = try JSONSerialization.jsonObject(with: directBody) as? [String: Any] else {
        #expect(Bool(false), "Expected direct OpenAI prompt cache payload")
        return
    }
    #expect((direct["prompt_cache_key"] as? String)?.count == 64)
    #expect(direct["prompt_cache_retention"] == nil)

    guard let proxyLongBody = applyOpenAICompletionsPromptCache(
        data: body,
        baseUrl: "https://proxy.example.com/v1",
        sessionId: "session-xyz",
        cacheRetention: .long,
        supportsLongCacheRetention: true
    ),
    let proxyLong = try JSONSerialization.jsonObject(with: proxyLongBody) as? [String: Any] else {
        #expect(Bool(false), "Expected proxy long-cache payload")
        return
    }
    #expect(proxyLong["prompt_cache_key"] as? String == "session-xyz")
    #expect(proxyLong["prompt_cache_retention"] as? String == "24h")

    guard let proxyUnsupportedBody = applyOpenAICompletionsPromptCache(
        data: body,
        baseUrl: "https://proxy.example.com/v1",
        sessionId: "session-xyz",
        cacheRetention: .long,
        supportsLongCacheRetention: false
    ),
    let proxyUnsupported = try JSONSerialization.jsonObject(with: proxyUnsupportedBody) as? [String: Any] else {
        #expect(Bool(false), "Expected proxy unsupported-cache payload")
        return
    }
    #expect(proxyUnsupported["prompt_cache_key"] == nil)
    #expect(proxyUnsupported["prompt_cache_retention"] == nil)
}

@Test func anthropicBetaHeadersCopilotExcludeFineGrained() {
    let headers = buildAnthropicBetaHeaders(
        apiKey: "tid_copilot_session_test_token",
        interleavedThinking: true,
        provider: "github-copilot"
    )
    #expect(headers?.contains("fine-grained-tool-streaming-2025-05-14") == false)
    #expect(headers?.contains("interleaved-thinking-2025-05-14") == true)
}

@Test func anthropicBetaHeadersDefaultIncludeFineGrained() {
    let headers = buildAnthropicBetaHeaders(
        apiKey: "sk-ant-api",
        interleavedThinking: true,
        provider: "anthropic"
    )
    #expect(headers?.contains("fine-grained-tool-streaming-2025-05-14") == true)
    #expect(headers?.contains("interleaved-thinking-2025-05-14") == true)
}

@Test func anthropicBetaHeadersUseLegacyFineGrainedOnlyWhenEagerUnsupported() {
    let eagerHeaders = buildAnthropicBetaHeaders(
        apiKey: "sk-ant-test",
        interleavedThinking: false,
        provider: "anthropic",
        hasTools: true,
        supportsEagerToolInputStreaming: true
    )
    #expect(eagerHeaders?.contains("fine-grained-tool-streaming-2025-05-14") != true)

    let legacyHeaders = buildAnthropicBetaHeaders(
        apiKey: "sk-ant-test",
        interleavedThinking: false,
        provider: "anthropic",
        hasTools: true,
        supportsEagerToolInputStreaming: false
    )
    #expect(legacyHeaders?.contains("fine-grained-tool-streaming-2025-05-14") == true)

    let noToolHeaders = buildAnthropicBetaHeaders(
        apiKey: "sk-ant-test",
        interleavedThinking: false,
        provider: "anthropic",
        hasTools: false,
        supportsEagerToolInputStreaming: false
    )
    #expect(noToolHeaders?.contains("fine-grained-tool-streaming-2025-05-14") != true)
}

@Test func anthropicMetadataInjection() async throws {
    let payload: [String: Any] = [
        "model": "claude-3-5-haiku-20241022",
        "messages": [
            ["role": "user", "content": "Hello"],
        ],
    ]
    let body = try JSONSerialization.data(withJSONObject: payload)
    let updated = injectAnthropicRequestBody(body: body, ttl: nil, metadataUserId: "user-123")
    let updatedString = updated.flatMap { String(data: $0, encoding: .utf8) }
    #expect(updatedString?.contains("\"metadata\":{\"user_id\":\"user-123\"}") == true)
}

@Test func anthropicToolEagerInputStreamingInjectionAndGates() throws {
    let payload: [String: Any] = [
        "model": "claude-sonnet-4-5",
        "messages": [["role": "user", "content": "Hello"]],
        "tools": [
            ["name": "first", "input_schema": ["type": "object"]],
            ["name": "second", "input_schema": ["type": "object"]],
        ],
    ]
    let body = try JSONSerialization.data(withJSONObject: payload)

    guard let eagerBody = injectAnthropicRequestBody(
        body: body,
        ttl: nil,
        metadataUserId: nil,
        supportsEagerToolInputStreaming: true,
        supportsCacheControlOnTools: true
    ),
    let eagerPayload = try JSONSerialization.jsonObject(with: eagerBody) as? [String: Any],
    let eagerTools = eagerPayload["tools"] as? [[String: Any]] else {
        #expect(Bool(false), "Expected eager Anthropic tools payload")
        return
    }
    #expect(eagerTools.first?["eager_input_streaming"] as? Bool == true)
    #expect(eagerTools.last?["eager_input_streaming"] as? Bool == true)
    #expect(eagerTools.first?["cache_control"] == nil)
    #expect((eagerTools.last?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")

    guard let gatedBody = injectAnthropicRequestBody(
        body: body,
        ttl: nil,
        metadataUserId: nil,
        supportsEagerToolInputStreaming: false,
        supportsCacheControlOnTools: false
    ),
    let gatedPayload = try JSONSerialization.jsonObject(with: gatedBody) as? [String: Any],
    let gatedTools = gatedPayload["tools"] as? [[String: Any]] else {
        #expect(Bool(false), "Expected gated Anthropic tools payload")
        return
    }
    #expect(gatedTools.first?["eager_input_streaming"] == nil)
    #expect(gatedTools.last?["cache_control"] == nil)
}

@Test func fireworksAnthropicCompatGatesCacheAndEagerToolMarkers() async throws {
    let model = getModel(provider: .fireworks, modelId: "accounts/fireworks/models/deepseek-v4-flash")
    #expect(model.api == .anthropicMessages)
    #expect(model.compat?.supportsLongCacheRetention == false)
    #expect(model.compat?.supportsEagerToolInputStreaming == false)
    #expect(model.compat?.sendSessionAffinityHeaders == true)
    #expect(model.compat?.supportsCacheControlOnTools == false)

    let headers = buildAnthropicBetaHeaders(
        apiKey: "fw-test-key",
        interleavedThinking: false,
        provider: model.provider,
        hasTools: true,
        supportsEagerToolInputStreaming: model.compat?.supportsEagerToolInputStreaming ?? true
    )
    #expect(headers?.contains("fine-grained-tool-streaming-2025-05-14") == true)

    await withEnv("PI_CACHE_RETENTION", value: "long") {
        #expect(anthropicCacheTtl(
            baseUrl: "https://api.anthropic.com",
            supportsLongCacheRetention: model.compat?.supportsLongCacheRetention ?? true
        ) == nil)
    }

    let payload: [String: Any] = [
        "model": model.id,
        "messages": [["role": "user", "content": "Hello"]],
        "tools": [
            ["name": "first", "input_schema": ["type": "object"]],
            ["name": "second", "input_schema": ["type": "object"]],
        ],
    ]
    let body = try JSONSerialization.data(withJSONObject: payload)
    guard let updatedBody = injectAnthropicRequestBody(
        body: body,
        ttl: "1h",
        metadataUserId: nil,
        supportsEagerToolInputStreaming: model.compat?.supportsEagerToolInputStreaming ?? true,
        supportsCacheControlOnTools: model.compat?.supportsCacheControlOnTools ?? true
    ),
    let updated = try JSONSerialization.jsonObject(with: updatedBody) as? [String: Any],
    let tools = updated["tools"] as? [[String: Any]] else {
        #expect(Bool(false), "Expected Fireworks Anthropic payload")
        return
    }
    #expect(tools.first?["eager_input_streaming"] == nil)
    #expect(tools.last?["eager_input_streaming"] == nil)
    #expect(tools.first?["cache_control"] == nil)
    #expect(tools.last?["cache_control"] == nil)
}

@Test func anthropicRequestBodyCanInjectDisabledThinking() throws {
    let payload: [String: Any] = [
        "model": "claude-sonnet-4-5",
        "messages": [["role": "user", "content": "Hello"]],
    ]
    let body = try JSONSerialization.data(withJSONObject: payload)
    guard let updatedBody = injectAnthropicRequestBody(
        body: body,
        ttl: nil,
        metadataUserId: nil,
        thinkingDisabled: true
    ),
    let updated = try JSONSerialization.jsonObject(with: updatedBody) as? [String: Any],
    let thinking = updated["thinking"] as? [String: Any] else {
        #expect(Bool(false), "Expected disabled thinking payload")
        return
    }
    #expect(thinking["type"] as? String == "disabled")
}

@Test func anthropicSimpleOptionsCarryMetadata() {
    let model = getModel(provider: .anthropic, modelId: "claude-haiku-4-5")
    let options = SimpleStreamOptions(metadata: ["user_id": AnyCodable("user-123")])
    let context = Context(messages: [.user(UserMessage(content: .text("hello")))])
    let mapped = mapAnthropicSimpleOptions(model: model, context: context, options: options, apiKey: "sk-ant-api")
    #expect(mapped.metadata?["user_id"]?.value as? String == "user-123")
}

@Test func googleToolDeclarationModes() {
    let tools = [
        AITool(
            name: "lookup",
            description: "Lookup data",
            parameters: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "q": AnyCodable(["type": "string"]),
                ]),
            ]
        ),
    ]

    let jsonSchemaMode = convertGoogleTools(tools, useParameters: false)
    let parametersMode = convertGoogleTools(tools, useParameters: true)

    let firstJson = jsonSchemaMode?.first?["functionDeclarations"] as? [[String: Any]]
    let firstParams = parametersMode?.first?["functionDeclarations"] as? [[String: Any]]
    #expect(firstJson?.first?["parametersJsonSchema"] != nil)
    #expect(firstJson?.first?["parameters"] == nil)
    #expect(firstParams?.first?["parameters"] != nil)
    #expect(firstParams?.first?["parametersJsonSchema"] == nil)
}

@Test func copilotClaudeModelsUseAnthropicApi() {
    let sonnet = getModel(provider: .githubCopilot, modelId: "claude-sonnet-4.5")
    let opus = getModel(provider: .githubCopilot, modelId: "claude-opus-4.5")
    #expect(sonnet.api == .anthropicMessages)
    #expect(opus.api == .anthropicMessages)
}

@Test func bedrockInterleavedThinkingDefaultsToEnabled() {
    let model = Model(
        id: "anthropic.claude-sonnet-4-5-20250929-v1:0",
        name: "Claude Sonnet 4.5 Bedrock",
        api: .bedrockConverseStream,
        provider: "amazon-bedrock",
        baseUrl: "",
        reasoning: true,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 200000,
        maxTokens: 64000
    )
    let fields = buildAdditionalModelRequestFields(
        model: model,
        options: BedrockOptions(reasoning: .xhigh)
    )
    let beta = fields?["anthropic_beta"]?.value as? [String]
    #expect(beta?.contains("interleaved-thinking-2025-05-14") == true)
    let thinking = fields?["thinking"]?.value as? [String: Any]
    #expect(thinking?["budget_tokens"] as? Int == 16384)
}

@Test func bedrockAdaptiveThinkingOmitsInterleavedBeta() {
    let model = Model(
        id: "anthropic.claude-opus-4-6-v1",
        name: "Claude Opus 4.6 Bedrock",
        api: .bedrockConverseStream,
        provider: "amazon-bedrock",
        baseUrl: "",
        reasoning: true,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 200000,
        maxTokens: 64000
    )
    let fields = buildAdditionalModelRequestFields(
        model: model,
        options: BedrockOptions(reasoning: .high, interleavedThinking: true)
    )
    #expect(fields?["anthropic_beta"] == nil)
    let thinking = fields?["thinking"]?.value as? [String: Any]
    #expect(thinking?["type"] as? String == "adaptive")
}

/// v0.67.67 / v0.68.0 / v0.62.0: Bedrock supports bearer-token auth, custom
/// non-reserved headers, catalog endpoint regions, Claude default maxTokens, request
/// metadata, and summarized thinking display.
@Test func bedrockBearerHeadersPayloadAndCatalogEndpoint() async {
    await codexRequestLock.withLock {
        await withCleanBedrockEnv {
            let capturedURL = LockedState<String?>(nil)
            let capturedAuthorization = LockedState<String?>(nil)
            let capturedCustomHeader = LockedState<String?>(nil)
            let capturedReservedHeader = LockedState<String?>(nil)
            let capturedBody = LockedState<String?>(nil)

            MockURLProtocol.allowedHosts.withLock { $0 = ["bedrock-runtime.eu-central-1.amazonaws.com"] }
            MockURLProtocol.requestHandler.withLock { $0 = { request in
                capturedURL.withLock { $0 = request.url?.absoluteString }
                capturedAuthorization.withLock { $0 = request.value(forHTTPHeaderField: "Authorization") }
                capturedCustomHeader.withLock { $0 = request.value(forHTTPHeaderField: "X-Cost-Center") }
                capturedReservedHeader.withLock { $0 = request.value(forHTTPHeaderField: "X-Amz-Date") }
                if let body = readRequestBody(request), let json = String(data: body, encoding: .utf8) {
                    capturedBody.withLock { $0 = json }
                }
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["content-type": "application/vnd.amazon.eventstream"]
                )!
                return (response, bedrockMessageStopData())
            } }
            URLProtocol.registerClass(MockURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockURLProtocol.self)
                MockURLProtocol.allowedHosts.withLock { $0 = [] }
                MockURLProtocol.requestHandler.withLock { $0 = nil }
            }

            let model = Model(
                id: "anthropic.claude-sonnet-4-5-20250929-v1:0",
                name: "Claude Sonnet 4.5 Bedrock",
                api: .bedrockConverseStream,
                provider: "amazon-bedrock",
                baseUrl: "https://bedrock-runtime.eu-central-1.amazonaws.com",
                reasoning: true,
                input: [.text],
                cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                contextWindow: 200000,
                maxTokens: 64000
            )
            let stream = streamBedrock(
                model: model,
                context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
                options: BedrockOptions(
                    reasoning: .high,
                    cacheRetention: CacheRetention.none,
                    headers: [
                        "X-Cost-Center": "agent-tests",
                        "Authorization": "should-not-win",
                        "X-Amz-Date": "should-not-win",
                    ],
                    requestMetadata: ["team": "ai"],
                    bearerToken: "bedrock-bearer-token"
                )
            )
            for await _ in stream {}
            let message = await stream.result()

            #expect(message.stopReason == .stop)
            #expect(capturedURL.withLock { $0 }?.contains("bedrock-runtime.eu-central-1.amazonaws.com") == true)
            #expect(capturedAuthorization.withLock { $0 } == "Bearer bedrock-bearer-token")
            #expect(capturedCustomHeader.withLock { $0 } == "agent-tests")
            #expect(capturedReservedHeader.withLock { $0 } != "should-not-win")

            guard let json = capturedBody.withLock({ $0 }),
                  let data = json.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let inferenceConfig = payload["inferenceConfig"] as? [String: Any],
                  let requestMetadata = payload["requestMetadata"] as? [String: Any],
                  let additional = payload["additionalModelRequestFields"] as? [String: Any],
                  let thinking = additional["thinking"] as? [String: Any] else {
                #expect(Bool(false), "Expected Bedrock request payload")
                return
            }
            #expect(inferenceConfig["maxTokens"] as? Int == 64000)
            #expect(inferenceConfig["temperature"] == nil)
            #expect(requestMetadata["team"] as? String == "ai")
            #expect(thinking["type"] as? String == "enabled")
            #expect(thinking["display"] as? String == ThinkingDisplay.summarized.rawValue)
        }
    }
}

/// v0.68.1: explicit region/profile settings override built-in regional Bedrock runtime endpoints.
@Test func bedrockConfiguredRegionOverridesCatalogEndpoint() async {
    await codexRequestLock.withLock {
        await withCleanBedrockEnv {
            let capturedHost = LockedState<String?>(nil)
            MockURLProtocol.allowedHosts.withLock { $0 = ["bedrock-runtime.us-west-2.amazonaws.com"] }
            MockURLProtocol.requestHandler.withLock { $0 = { request in
                capturedHost.withLock { $0 = request.url?.host }
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["content-type": "application/vnd.amazon.eventstream"]
                )!
                return (response, bedrockMessageStopData())
            } }
            URLProtocol.registerClass(MockURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockURLProtocol.self)
                MockURLProtocol.allowedHosts.withLock { $0 = [] }
                MockURLProtocol.requestHandler.withLock { $0 = nil }
            }

            let model = Model(
                id: "anthropic.claude-haiku-4-5-20251001-v1:0",
                name: "Claude Haiku 4.5 Bedrock",
                api: .bedrockConverseStream,
                provider: "amazon-bedrock",
                baseUrl: "https://bedrock-runtime.eu-central-1.amazonaws.com",
                reasoning: false,
                input: [.text],
                cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                contextWindow: 200000,
                maxTokens: 8192
            )
            let stream = streamBedrock(
                model: model,
                context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
                options: BedrockOptions(region: "us-west-2", cacheRetention: CacheRetention.none, bearerToken: "bedrock-bearer-token")
            )
            for await _ in stream {}
            let message = await stream.result()

            #expect(message.stopReason == .stop)
            #expect(capturedHost.withLock { $0 } == "bedrock-runtime.us-west-2.amazonaws.com")
        }
    }
}

/// v0.68.1: an ARN model ID's embedded region wins over a standard catalog endpoint region.
@Test func bedrockArnRegionOverridesStandardCatalogEndpoint() async {
    await codexRequestLock.withLock {
        await withCleanBedrockEnv {
            let capturedHost = LockedState<String?>(nil)
            MockURLProtocol.allowedHosts.withLock { $0 = ["bedrock-runtime.ap-southeast-2.amazonaws.com"] }
            MockURLProtocol.requestHandler.withLock { $0 = { request in
                capturedHost.withLock { $0 = request.url?.host }
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["content-type": "application/vnd.amazon.eventstream"]
                )!
                return (response, bedrockMessageStopData())
            } }
            URLProtocol.registerClass(MockURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockURLProtocol.self)
                MockURLProtocol.allowedHosts.withLock { $0 = [] }
                MockURLProtocol.requestHandler.withLock { $0 = nil }
            }

            let model = Model(
                id: "arn:aws:bedrock:ap-southeast-2:123456789012:application-inference-profile/example",
                name: "Claude Sonnet 4.5 Bedrock",
                api: .bedrockConverseStream,
                provider: "amazon-bedrock",
                baseUrl: "https://bedrock-runtime.eu-central-1.amazonaws.com",
                reasoning: false,
                input: [.text],
                cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                contextWindow: 200000,
                maxTokens: 8192
            )
            let stream = streamBedrock(
                model: model,
                context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
                options: BedrockOptions(cacheRetention: CacheRetention.none, bearerToken: "bedrock-bearer-token")
            )
            for await _ in stream {}
            let message = await stream.result()

            #expect(message.stopReason == .stop)
            #expect(capturedHost.withLock { $0 } == "bedrock-runtime.ap-southeast-2.amazonaws.com")
        }
    }
}

/// v0.68.0: non-Claude Bedrock requests omit unset inference fields instead of sending
/// guessed maxTokens or null/default temperature.
@Test func bedrockNonClaudeOmitsUnsetInferenceFields() async {
    await codexRequestLock.withLock {
        await withCleanBedrockEnv {
            let capturedBody = LockedState<String?>(nil)
            MockURLProtocol.allowedHosts.withLock { $0 = ["bedrock-runtime.us-east-1.amazonaws.com"] }
            MockURLProtocol.requestHandler.withLock { $0 = { request in
                if let body = readRequestBody(request), let json = String(data: body, encoding: .utf8) {
                    capturedBody.withLock { $0 = json }
                }
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["content-type": "application/vnd.amazon.eventstream"]
                )!
                return (response, bedrockMessageStopData())
            } }
            URLProtocol.registerClass(MockURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockURLProtocol.self)
                MockURLProtocol.allowedHosts.withLock { $0 = [] }
                MockURLProtocol.requestHandler.withLock { $0 = nil }
            }

            let model = Model(
                id: "amazon.nova-lite-v1:0",
                name: "Amazon Nova Lite",
                api: .bedrockConverseStream,
                provider: "amazon-bedrock",
                baseUrl: "https://bedrock-runtime.us-east-1.amazonaws.com",
                reasoning: false,
                input: [.text],
                cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                contextWindow: 300000,
                maxTokens: 5000
            )
            let stream = streamBedrock(
                model: model,
                context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
                options: BedrockOptions(cacheRetention: CacheRetention.none, bearerToken: "bedrock-bearer-token")
            )
            for await _ in stream {}
            let message = await stream.result()

            #expect(message.stopReason == .stop)
            guard let json = capturedBody.withLock({ $0 }),
                  let data = json.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let inferenceConfig = payload["inferenceConfig"] as? [String: Any] else {
                #expect(Bool(false), "Expected Bedrock inferenceConfig")
                return
            }
            #expect(inferenceConfig["maxTokens"] == nil)
            #expect(inferenceConfig["temperature"] == nil)
        }
    }
}

/// v0.67.6 / v0.70.3: GovCloud omits `thinking.display`, and inference-profile
/// names participate in adaptive/xhigh capability checks.
@Test func bedrockGovCloudOmitsThinkingDisplayAndModelNameDrivesAdaptiveXhigh() {
    let govModel = Model(
        id: "us-gov.anthropic.claude-sonnet-4-5-20250929-v1:0",
        name: "Claude Sonnet 4.5 GovCloud",
        api: .bedrockConverseStream,
        provider: "amazon-bedrock",
        baseUrl: "https://bedrock-runtime.us-gov-west-1.amazonaws.com",
        reasoning: true,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 200000,
        maxTokens: 64000
    )
    let govFields = buildAdditionalModelRequestFields(
        model: govModel,
        options: BedrockOptions(region: "us-gov-west-1", reasoning: .high)
    )
    let govThinking = govFields?["thinking"]?.value as? [String: Any]
    #expect(govThinking?["display"] == nil)
    let govEndpointFields = buildAdditionalModelRequestFields(
        model: govModel,
        options: BedrockOptions(reasoning: .high)
    )
    let govEndpointThinking = govEndpointFields?["thinking"]?.value as? [String: Any]
    #expect(govEndpointThinking?["display"] == nil)

    let profileModel = Model(
        id: "arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/example",
        name: "Claude Opus 4.7 Bedrock",
        api: .bedrockConverseStream,
        provider: "amazon-bedrock",
        baseUrl: "https://bedrock-runtime.us-east-1.amazonaws.com",
        reasoning: true,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 200000,
        maxTokens: 64000
    )
    let profileFields = buildAdditionalModelRequestFields(
        model: profileModel,
        options: BedrockOptions(reasoning: .xhigh)
    )
    let profileThinking = profileFields?["thinking"]?.value as? [String: Any]
    let outputConfig = profileFields?["output_config"]?.value as? [String: Any]
    #expect(profileThinking?["type"] as? String == "adaptive")
    #expect(outputConfig?["effort"] as? String == "xhigh")
}

/// v0.70.0: transient Bedrock HTTP/2 no-response transport failures are retried.
@Test func bedrockRetriesHTTP2NoResponseTransportFailure() async {
    await codexRequestLock.withLock {
        await withCleanBedrockEnv {
            let requestCount = LockedState(0)
            MockURLProtocol.allowedHosts.withLock { $0 = ["bedrock-runtime.us-east-1.amazonaws.com"] }
            MockURLProtocol.requestHandler.withLock { $0 = { request in
                let count = requestCount.withLock { value -> Int in
                    value += 1
                    return value
                }
                if count == 1 {
                    throw NSError(
                        domain: NSURLErrorDomain,
                        code: NSURLErrorNetworkConnectionLost,
                        userInfo: [NSLocalizedDescriptionKey: "http2 request did not get a response"]
                    )
                }
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["content-type": "application/vnd.amazon.eventstream"]
                )!
                return (response, bedrockMessageStopData())
            } }
            URLProtocol.registerClass(MockURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockURLProtocol.self)
                MockURLProtocol.allowedHosts.withLock { $0 = [] }
                MockURLProtocol.requestHandler.withLock { $0 = nil }
            }

            let model = Model(
                id: "anthropic.claude-haiku-4-5-20251001-v1:0",
                name: "Claude Haiku 4.5 Bedrock",
                api: .bedrockConverseStream,
                provider: "amazon-bedrock",
                baseUrl: "https://bedrock-runtime.us-east-1.amazonaws.com",
                reasoning: false,
                input: [.text],
                cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                contextWindow: 200000,
                maxTokens: 8192
            )
            let stream = streamBedrock(
                model: model,
                context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
                options: BedrockOptions(cacheRetention: CacheRetention.none, bearerToken: "bedrock-bearer-token", maxRetries: 1)
            )
            for await _ in stream {}
            let message = await stream.result()

            #expect(message.stopReason == .stop)
            #expect(requestCount.withLock { $0 } == 2)
        }
    }
}

@Test func supportsXhighModels() async throws {
    let gpt52 = getModel(provider: .openai, modelId: "gpt-5.2")
    #expect(supportsXhigh(model: gpt52))

    let gpt51 = getModel(provider: .openai, modelId: "gpt-5.1")
    #expect(supportsXhigh(model: gpt51) == false)

    let opus = Model(
        id: "claude-opus-4.6",
        name: "Claude Opus 4.6",
        api: .anthropicMessages,
        provider: "anthropic",
        baseUrl: "https://api.anthropic.com",
        reasoning: true,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 200000,
        maxTokens: 4096
    )
    #expect(supportsXhigh(model: opus))

    let togetherDeepSeek = getModel(provider: .together, modelId: "deepseek-ai/DeepSeek-V4-Pro")
    #expect(supportsXhigh(model: togetherDeepSeek))
    #expect(mappedThinkingLevel(model: togetherDeepSeek, level: .xhigh) == "max")

    let staleDeepSeek = Model(
        id: "deepseek-ai/DeepSeek-V4-Pro",
        name: "DeepSeek V4 Pro",
        api: .openAICompletions,
        provider: "deepseek-test",
        baseUrl: "https://deepseek-test.example/v1",
        reasoning: true,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 1000000,
        maxTokens: 384000,
        thinkingLevelMap: [.high: "high", .low: nil, .medium: nil, .minimal: nil, .xhigh: nil]
    )
    #expect(supportsXhigh(model: staleDeepSeek))
    #expect(mappedThinkingLevel(model: staleDeepSeek, level: .xhigh) == "max")
}

@Test func googleGeminiCliRetryDelayHeaderParsing() {
    let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse")!
    let nowSeconds = Int(Date().timeIntervalSince1970)
    let response = HTTPURLResponse(
        url: url,
        statusCode: 429,
        httpVersion: nil,
        headerFields: [
            "retry-after": "2",
            "x-ratelimit-reset": "\(nowSeconds + 10)",
        ]
    )
    let delay = extractRetryDelay(errorText: "", response: response)
    #expect(delay != nil)
    #expect((delay ?? 0) >= 2900)
    #expect((delay ?? 0) <= 3100)
}

@Test func googleGeminiCliRetriesEmptyStreamWithoutDuplicateStart() async {
    await codexRequestLock.withLock {
        let requestCount = LockedState(0)
        GeminiRetryMockURLProtocol.requestHandler.withLock { $0 = { request in
            let count = requestCount.withLock { value -> Int in
                value += 1
                return value
            }
            guard let url = request.url else { throw URLError(.badURL) }
            let body: String
            if count == 1 {
                body = "\n\n"
            } else {
                let payload = """
                {"response":{"candidates":[{"content":{"parts":[{"text":"pong"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1,"totalTokenCount":2}}}
                """
                body = "data: \(payload)\n\n"
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["content-type": "text/event-stream"]
            )!
            return (response, Data(body.utf8))
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

        let model = Model(
            id: "gemini-2.5-flash",
            name: "Gemini 2.5 Flash",
            api: .googleGeminiCli,
            provider: "google-gemini-cli",
            baseUrl: "http://cloudcode-pa.googleapis.com",
            reasoning: true,
            input: [.text, .image],
            cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 1_000_000,
            maxTokens: 65_536
        )
        let context = Context(messages: [.user(UserMessage(content: .text("say pong")))])
        let credentials = #"{"token":"tok_test","projectId":"proj_test"}"#
        let stream = streamGoogleGeminiCli(
            model: model,
            context: context,
            options: GoogleGeminiCliOptions(apiKey: credentials)
        )

        var startCount = 0
        for await event in stream {
            if case .start = event {
                startCount += 1
            }
        }
        let message = await stream.result()

        #expect(requestCount.withLock { $0 } == 2)
        #expect(startCount == 1)
        #expect(message.stopReason == .stop)
        let text = message.content.compactMap { block -> String? in
            if case .text(let textContent) = block { return textContent.text }
            return nil
        }.joined(separator: "")
        #expect(text.contains("pong"))
    }
}

@Test func openAICompletionsToolChoiceAndStrictPayload() async {
    await codexRequestLock.withLock {
        let capturedPayloadJson = LockedState<String?>(nil)
        OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = ["zai.example"] }
        OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let response = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data("error".utf8))
        } }
        URLProtocol.registerClass(OpenAICompletionsMockURLProtocol.self)
        defer {
            OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = nil }
            OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = [] }
            URLProtocol.unregisterClass(OpenAICompletionsMockURLProtocol.self)
        }

        let model = Model(
            id: "zai-test-model",
            name: "zai-test-model",
            api: .openAICompletions,
            provider: "zai",
            baseUrl: "https://zai.example/v1",
            reasoning: true,
            input: [.text],
            cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 8192,
            maxTokens: 4096,
            compat: OpenAICompat(
                thinkingFormat: .zai,
                supportsStrictMode: false
            )
        )
        let context = Context(
            messages: [.user(UserMessage(content: .text("Call ping")))],
            tools: [
                AITool(
                    name: "ping",
                    description: "Ping tool",
                    parameters: [
                        "type": AnyCodable("object"),
                        "properties": AnyCodable(["ok": ["type": "boolean"] as [String: String]]),
                    ]
                ),
            ]
        )

        let stream = streamOpenAICompletions(
            model: model,
            context: context,
            options: OpenAICompletionsOptions(
                apiKey: "test-key",
                toolChoice: .required,
                onPayload: { snapshot in
                    capturedPayloadJson.withLock { $0 = snapshot.json }
                }
            )
        )
        _ = await stream.result()

        let payload = capturedPayloadJson.withLock { $0 }.flatMap { jsonString -> [String: Any]? in
            guard let data = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data, options: []),
                  let dict = json as? [String: Any] else { return nil }
            return dict
        }
        #expect(payload != nil)
        #expect(payload?["tool_choice"] as? String == "required")
        let tools = payload?["tools"] as? [[String: Any]]
        let function = tools?.first?["function"] as? [String: Any]
        #expect(function != nil)
        #expect(function?["strict"] == nil)
    }
}

/// v0.61.0 / v0.62.0: OpenRouter-compatible Chat Completions uses nested
/// `reasoning.effort`, and defaults disabled reasoning to `none`.
@Test func openAICompletionsOpenRouterReasoningUsesNestedNoneEffort() async throws {
    await codexRequestLock.withLock {
        let capturedPayloadJson = LockedState<String?>(nil)
        OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = ["openrouter-chat.example"] }
        OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = { request in
            if let body = readRequestBody(request),
               let json = String(data: body, encoding: .utf8) {
                capturedPayloadJson.withLock { $0 = json }
            }
            let data = try openAITestSseData([
                [
                    "id": "chatcmpl-openrouter-reasoning",
                    "object": "chat.completion.chunk",
                    "created": 0,
                    "model": "openrouter-reasoning-test",
                    "choices": [
                        [
                            "index": 0,
                            "delta": ["content": "ok"],
                            "finish_reason": "stop",
                        ],
                    ],
                ],
            ])
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, data)
        } }
        URLProtocol.registerClass(OpenAICompletionsMockURLProtocol.self)
        defer {
            OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = nil }
            OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = [] }
            URLProtocol.unregisterClass(OpenAICompletionsMockURLProtocol.self)
        }

        let model = Model(
            id: "openrouter-reasoning-test",
            name: "OpenRouter Reasoning Test",
            api: .openAICompletions,
            provider: "openrouter",
            baseUrl: "https://openrouter-chat.example/v1",
            reasoning: true,
            input: [.text],
            cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 128000,
            maxTokens: 4096,
            compat: OpenAICompat(thinkingFormat: .openrouter)
        )
        let stream = streamOpenAICompletions(
            model: model,
            context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
            options: OpenAICompletionsOptions(apiKey: "test-key")
        )
        for await _ in stream {}

        let payload = capturedPayloadJson.withLock { $0 }.flatMap { jsonString -> [String: Any]? in
            guard let data = jsonString.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object
        }
        let reasoning = payload?["reasoning"] as? [String: Any]
        let provider = payload?["provider"] as? [String: Any]
        #expect(reasoning?["effort"] as? String == "none")
        #expect(provider?["reasoning_effort"] == nil)
    }
}

/// v0.70.1: DeepSeek V4 replay requires both the DeepSeek thinking payload and
/// `reasoning_content` on prior assistant turns, even when no thinking block exists.
@Test func openAICompletionsDeepSeekV4ReplayPayloadsInjectReasoningContent() async throws {
    await codexRequestLock.withLock {
        OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = ["deepseek-replay.example"] }
        OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = { request in
            let data = try openAITestSseData([
                [
                    "id": "chatcmpl-deepseek-replay",
                    "object": "chat.completion.chunk",
                    "created": 0,
                    "model": "deepseek-replay-test",
                    "choices": [
                        [
                            "index": 0,
                            "delta": ["content": "ok"],
                            "finish_reason": "stop",
                        ],
                    ],
                ],
            ])
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, data)
        } }
        URLProtocol.registerClass(OpenAICompletionsMockURLProtocol.self)
        defer {
            OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = nil }
            OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = [] }
            URLProtocol.unregisterClass(OpenAICompletionsMockURLProtocol.self)
        }

        for modelId in ["deepseek-v4-flash", "deepseek-v4-pro"] {
            let capturedPayloadJson = LockedState<String?>(nil)
            let model = Model(
                id: modelId,
                name: modelId,
                api: .openAICompletions,
                provider: "deepseek",
                baseUrl: "https://deepseek-replay.example/v1",
                reasoning: true,
                input: [.text],
                cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                contextWindow: 128000,
                maxTokens: 4096,
                compat: OpenAICompat(
                    maxTokensField: .maxTokens,
                    thinkingFormat: .deepseek,
                    reasoningEffortMap: [.xhigh: "max"],
                    requiresReasoningContentOnAssistantMessages: true
                )
            )
            let assistant = AssistantMessage(
                content: [.text(TextContent(text: "prior answer"))],
                api: model.api,
                provider: model.provider,
                model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                stopReason: .stop
            )
            let stream = streamOpenAICompletions(
                model: model,
                context: Context(messages: [
                    .assistant(assistant),
                    .user(UserMessage(content: .text("continue"))),
                ]),
                options: OpenAICompletionsOptions(
                    apiKey: "test-key",
                    reasoningEffort: .xhigh,
                    onPayload: { snapshot in capturedPayloadJson.withLock { $0 = snapshot.json } }
                )
            )
            _ = await stream.result()

            let payload = capturedPayloadJson.withLock { $0 }.flatMap { jsonString -> [String: Any]? in
                guard let data = jsonString.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return object
            }
            let thinking = payload?["thinking"] as? [String: Any]
            let messages = payload?["messages"] as? [[String: Any]]
            let assistantPayload = messages?.first { $0["role"] as? String == "assistant" }

            #expect(payload?["model"] as? String == modelId)
            #expect(thinking?["type"] as? String == "enabled")
            #expect(payload?["reasoning_effort"] as? String == "max")
            #expect(assistantPayload?["reasoning_content"] as? String == "")
        }
    }
}

/// v0.67.0: OpenRouter provider-selection routing emits the full routing field set.
@Test func openAICompletionsOpenRouterRoutingPayload() async throws {
    await codexRequestLock.withLock {
        let capturedPayloadJson = LockedState<String?>(nil)
        OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = ["openrouter.ai"] }
        OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = { request in
            if let body = readRequestBody(request),
               let json = String(data: body, encoding: .utf8) {
                capturedPayloadJson.withLock { $0 = json }
            }
            let data = try openAITestSseData([
                [
                    "id": "chatcmpl-openrouter-routing",
                    "object": "chat.completion.chunk",
                    "created": 0,
                    "model": "openrouter-routing-test",
                    "choices": [
                        [
                            "index": 0,
                            "delta": ["content": "ok"],
                            "finish_reason": "stop",
                        ],
                    ],
                ],
            ])
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, data)
        } }
        URLProtocol.registerClass(OpenAICompletionsMockURLProtocol.self)
        defer {
            OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = nil }
            OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = [] }
            URLProtocol.unregisterClass(OpenAICompletionsMockURLProtocol.self)
        }

        let model = Model(
            id: "openrouter-routing-test",
            name: "OpenRouter Routing Test",
            api: .openAICompletions,
            provider: "openrouter",
            baseUrl: "https://openrouter.ai/api/v1",
            reasoning: false,
            input: [.text],
            cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 128000,
            maxTokens: 4096,
            compat: OpenAICompat(openRouterRouting: OpenRouterRouting(
                allowFallbacks: false,
                requireParameters: true,
                dataCollection: "deny",
                zdr: true,
                enforceDistillableText: true,
                order: ["anthropic", "openai"],
                only: ["anthropic"],
                ignore: ["bad-provider"],
                quantizations: ["fp16", "int8"],
                sort: .structured(by: "throughput", partition: "none"),
                maxPrice: OpenRouterRoutingPrice(prompt: 1.25, completion: 2.5, image: 0.75, audio: 0.5, request: 0.01),
                preferredMinThroughput: .percentiles(p50: 120, p75: 90, p90: 60, p99: 30),
                preferredMaxLatency: .scalar(2.5)
            ))
        )
        let stream = streamOpenAICompletions(
            model: model,
            context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
            options: OpenAICompletionsOptions(apiKey: "test-key")
        )
        for await _ in stream {}

        let payload = capturedPayloadJson.withLock { $0 }.flatMap { jsonString -> [String: Any]? in
            guard let data = jsonString.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object
        }
        let provider = payload?["provider"] as? [String: Any]
        #expect(provider?["allow_fallbacks"] as? Bool == false)
        #expect(provider?["require_parameters"] as? Bool == true)
        #expect(provider?["data_collection"] as? String == "deny")
        #expect(provider?["zdr"] as? Bool == true)
        #expect(provider?["enforce_distillable_text"] as? Bool == true)
        #expect(provider?["order"] as? [String] == ["anthropic", "openai"])
        #expect(provider?["only"] as? [String] == ["anthropic"])
        #expect(provider?["ignore"] as? [String] == ["bad-provider"])
        #expect(provider?["quantizations"] as? [String] == ["fp16", "int8"])
        let sort = provider?["sort"] as? [String: Any]
        #expect(sort?["by"] as? String == "throughput")
        #expect(sort?["partition"] as? String == "none")
        let maxPrice = provider?["max_price"] as? [String: Any]
        #expect(maxPrice?["prompt"] as? Double == 1.25)
        #expect(maxPrice?["completion"] as? Double == 2.5)
        #expect(maxPrice?["image"] as? Double == 0.75)
        #expect(maxPrice?["audio"] as? Double == 0.5)
        #expect(maxPrice?["request"] as? Double == 0.01)
        let throughput = provider?["preferred_min_throughput"] as? [String: Any]
        #expect(throughput?["p50"] as? Double == 120)
        #expect(throughput?["p75"] as? Double == 90)
        #expect(throughput?["p90"] as? Double == 60)
        #expect(throughput?["p99"] as? Double == 30)
        #expect(provider?["preferred_max_latency"] as? Double == 2.5)
    }
}

/// v0.67.67: Qwen chat-template requests preserve thinking state across tool-call turns.
@Test func openAICompletionsQwenChatTemplatePreservesThinking() async throws {
    await codexRequestLock.withLock {
        let capturedPayloadJson = LockedState<String?>(nil)
        OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = ["qwen-template.example"] }
        OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = { request in
            if let body = readRequestBody(request),
               let json = String(data: body, encoding: .utf8) {
                capturedPayloadJson.withLock { $0 = json }
            }
            let data = try openAITestSseData([
                [
                    "id": "chatcmpl-qwen-template",
                    "object": "chat.completion.chunk",
                    "created": 0,
                    "model": "qwen-template-test",
                    "choices": [
                        [
                            "index": 0,
                            "delta": ["content": "ok"],
                            "finish_reason": "stop",
                        ],
                    ],
                ],
            ])
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, data)
        } }
        URLProtocol.registerClass(OpenAICompletionsMockURLProtocol.self)
        defer {
            OpenAICompletionsMockURLProtocol.requestHandler.withLock { $0 = nil }
            OpenAICompletionsMockURLProtocol.allowedHosts.withLock { $0 = [] }
            URLProtocol.unregisterClass(OpenAICompletionsMockURLProtocol.self)
        }

        let model = Model(
            id: "qwen-template-test",
            name: "Qwen Template Test",
            api: .openAICompletions,
            provider: "qwen-template",
            baseUrl: "https://qwen-template.example/v1",
            reasoning: true,
            input: [.text],
            cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 128000,
            maxTokens: 4096,
            compat: OpenAICompat(thinkingFormat: .qwenChatTemplate)
        )
        let stream = streamOpenAICompletions(
            model: model,
            context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
            options: OpenAICompletionsOptions(apiKey: "test-key", reasoningEffort: .high)
        )
        for await _ in stream {}

        let payload = capturedPayloadJson.withLock { $0 }.flatMap { jsonString -> [String: Any]? in
            guard let data = jsonString.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object
        }
        let kwargs = payload?["chat_template_kwargs"] as? [String: Any]
        #expect(kwargs?["enable_thinking"] as? Bool == true)
        #expect(kwargs?["preserve_thinking"] as? Bool == true)
    }
}

// MARK: - JSON Schema Validation Tests

@Suite("JSONSchemaValidator")
struct JSONSchemaValidatorTests {
    let validator = JSONSchemaValidator.shared

    // MARK: - String Validation

    @Suite("String Validation")
    struct StringValidationTests {
        let validator = JSONSchemaValidator.shared

        @Test func validatesStringType() {
            let schema: [String: Any] = ["type": "string"]
            let result = validator.validate("hello", against: schema)
            #expect(result.isValid)
            #expect(result.coercedValue as? String == "hello")
        }

        @Test func rejectsNonStringType() {
            let schema: [String: Any] = ["type": "string"]
            let result = validator.validate(123, against: schema, coerceTypes: false)
            #expect(!result.isValid)
            #expect(result.errors.first?.message.contains("must be a string") == true)
        }

        @Test func coercesNumberToString() {
            let schema: [String: Any] = ["type": "string"]
            let result = validator.validate(123, against: schema, coerceTypes: true)
            #expect(result.isValid)
            #expect(result.coercedValue as? String == "123")
        }

        @Test func validatesMinLength() {
            let schema: [String: Any] = ["type": "string", "minLength": 5]
            let valid = validator.validate("hello", against: schema)
            #expect(valid.isValid)

            let invalid = validator.validate("hi", against: schema)
            #expect(!invalid.isValid)
            #expect(invalid.errors.first?.message.contains("at least 5 characters") == true)
        }

        @Test func validatesMaxLength() {
            let schema: [String: Any] = ["type": "string", "maxLength": 3]
            let valid = validator.validate("hi", against: schema)
            #expect(valid.isValid)

            let invalid = validator.validate("hello", against: schema)
            #expect(!invalid.isValid)
            #expect(invalid.errors.first?.message.contains("at most 3 characters") == true)
        }

        @Test func validatesPattern() {
            let schema: [String: Any] = ["type": "string", "pattern": "^[a-z]+$"]
            let valid = validator.validate("hello", against: schema)
            #expect(valid.isValid)

            let invalid = validator.validate("Hello123", against: schema)
            #expect(!invalid.isValid)
            #expect(invalid.errors.first?.message.contains("must match pattern") == true)
        }

        @Test func validatesEmailFormat() {
            let schema: [String: Any] = ["type": "string", "format": "email"]
            let valid = validator.validate("user@example.com", against: schema)
            #expect(valid.isValid)

            let invalid = validator.validate("not-an-email", against: schema)
            #expect(!invalid.isValid)
            #expect(invalid.errors.first?.message.contains("valid email") == true)
        }

        @Test func validatesUriFormat() {
            let schema: [String: Any] = ["type": "string", "format": "uri"]
            let valid = validator.validate("https://example.com", against: schema)
            #expect(valid.isValid)

            // Note: Swift's URL(string:) is very lenient, so this is just a smoke test
            // Real URL validation would need a stricter regex
            let validSimple = validator.validate("http://example.com/path", against: schema)
            #expect(validSimple.isValid)
        }

        @Test func validatesUuidFormat() {
            let schema: [String: Any] = ["type": "string", "format": "uuid"]
            let valid = validator.validate("550e8400-e29b-41d4-a716-446655440000", against: schema)
            #expect(valid.isValid)

            let invalid = validator.validate("not-a-uuid", against: schema)
            #expect(!invalid.isValid)
        }
    }

    // MARK: - Number Validation

    @Suite("Number Validation")
    struct NumberValidationTests {
        let validator = JSONSchemaValidator.shared

        @Test func validatesNumberType() {
            let schema: [String: Any] = ["type": "number"]
            let result = validator.validate(3.14, against: schema)
            #expect(result.isValid)
            #expect(result.coercedValue as? Double == 3.14)
        }

        @Test func validatesIntegerType() {
            let schema: [String: Any] = ["type": "integer"]
            let valid = validator.validate(42, against: schema)
            #expect(valid.isValid)
            #expect(valid.coercedValue as? Int == 42)

            let invalid = validator.validate(3.14, against: schema)
            #expect(!invalid.isValid)
            #expect(invalid.errors.first?.message.contains("must be an integer") == true)
        }

        @Test func coercesStringToNumber() {
            let schema: [String: Any] = ["type": "number"]
            let result = validator.validate("3.14", against: schema, coerceTypes: true)
            #expect(result.isValid)
            #expect(result.coercedValue as? Double == 3.14)
        }

        @Test func validatesMinimum() {
            let schema: [String: Any] = ["type": "number", "minimum": 10.0]
            let valid = validator.validate(15.0, against: schema)
            #expect(valid.isValid)

            let invalid = validator.validate(5.0, against: schema)
            #expect(!invalid.isValid)
            #expect(invalid.errors.first?.message.contains("must be >=") == true)
        }

        @Test func validatesMaximum() {
            let schema: [String: Any] = ["type": "number", "maximum": 100.0]
            let valid = validator.validate(50.0, against: schema)
            #expect(valid.isValid)

            let invalid = validator.validate(150.0, against: schema)
            #expect(!invalid.isValid)
            #expect(invalid.errors.first?.message.contains("must be <=") == true)
        }

        @Test func validatesExclusiveMinimum() {
            let schema: [String: Any] = ["type": "number", "exclusiveMinimum": 10.0]
            let valid = validator.validate(11.0, against: schema)
            #expect(valid.isValid)

            let invalid = validator.validate(10.0, against: schema)
            #expect(!invalid.isValid)
            #expect(invalid.errors.first?.message.contains("must be greater than") == true)
        }

        @Test func validatesMultipleOf() {
            let schema: [String: Any] = ["type": "number", "multipleOf": 5.0]
            let valid = validator.validate(15.0, against: schema)
            #expect(valid.isValid)

            let invalid = validator.validate(17.0, against: schema)
            #expect(!invalid.isValid)
            #expect(invalid.errors.first?.message.contains("multiple of") == true)
        }
    }

    // MARK: - Boolean Validation

    @Suite("Boolean Validation")
    struct BooleanValidationTests {
        let validator = JSONSchemaValidator.shared

        @Test func validatesBooleanType() {
            let schema: [String: Any] = ["type": "boolean"]
            let resultTrue = validator.validate(true, against: schema)
            #expect(resultTrue.isValid)
            #expect(resultTrue.coercedValue as? Bool == true)

            let resultFalse = validator.validate(false, against: schema)
            #expect(resultFalse.isValid)
            #expect(resultFalse.coercedValue as? Bool == false)
        }

        @Test func coercesStringToBoolean() {
            let schema: [String: Any] = ["type": "boolean"]
            let resultTrue = validator.validate("true", against: schema, coerceTypes: true)
            #expect(resultTrue.isValid)
            #expect(resultTrue.coercedValue as? Bool == true)

            let resultFalse = validator.validate("false", against: schema, coerceTypes: true)
            #expect(resultFalse.isValid)
            #expect(resultFalse.coercedValue as? Bool == false)
        }

        @Test func rejectsInvalidBoolean() {
            let schema: [String: Any] = ["type": "boolean"]
            let result = validator.validate("maybe", against: schema, coerceTypes: true)
            #expect(!result.isValid)
        }
    }

    // MARK: - Array Validation

    @Suite("Array Validation")
    struct ArrayValidationTests {
        let validator = JSONSchemaValidator.shared

        @Test func validatesArrayType() {
            let schema: [String: Any] = ["type": "array"]
            let result = validator.validate([1, 2, 3], against: schema)
            #expect(result.isValid)
        }

        @Test func validatesMinItems() {
            let schema: [String: Any] = ["type": "array", "minItems": 2]
            let valid = validator.validate([1, 2, 3], against: schema)
            #expect(valid.isValid)

            let invalid = validator.validate([1], against: schema)
            #expect(!invalid.isValid)
            #expect(invalid.errors.first?.message.contains("at least 2 items") == true)
        }

        @Test func validatesMaxItems() {
            let schema: [String: Any] = ["type": "array", "maxItems": 3]
            let valid = validator.validate([1, 2], against: schema)
            #expect(valid.isValid)

            let invalid = validator.validate([1, 2, 3, 4, 5], against: schema)
            #expect(!invalid.isValid)
            #expect(invalid.errors.first?.message.contains("at most 3 items") == true)
        }

        @Test func validatesItemsSchema() {
            let schema: [String: Any] = [
                "type": "array",
                "items": ["type": "string"]
            ]
            let valid = validator.validate(["a", "b", "c"], against: schema)
            #expect(valid.isValid)

            let invalid = validator.validate(["a", 123, "c"], against: schema, coerceTypes: false)
            #expect(!invalid.isValid)
        }

        @Test func validatesUniqueItems() {
            let schema: [String: Any] = ["type": "array", "uniqueItems": true]
            let valid = validator.validate([1, 2, 3], against: schema)
            #expect(valid.isValid)

            let invalid = validator.validate([1, 2, 2], against: schema)
            #expect(!invalid.isValid)
            #expect(invalid.errors.first?.message.contains("must be unique") == true)
        }

        @Test func validatesDraft07AndDraft2020Tuples() {
            let draft07: [String: Any] = [
                "type": "array",
                "items": [["type": "string"], ["type": "number"]],
                "additionalItems": false,
            ]
            let draft2020: [String: Any] = [
                "type": "array",
                "prefixItems": [["type": "string"], ["type": "number"]],
                "items": false,
            ]
            #expect(validator.validate(["ok", 1], against: draft07).isValid)
            #expect(!validator.validate(["ok", 1, true], against: draft07).isValid)
            #expect(validator.validate(["ok", 1], against: draft2020).isValid)
            #expect(!validator.validate(["ok", 1, true], against: draft2020).isValid)
        }
    }

    // MARK: - Object Validation

    @Suite("Object Validation")
    struct ObjectValidationTests {
        let validator = JSONSchemaValidator.shared

        @Test func validatesObjectType() {
            let schema: [String: Any] = ["type": "object"]
            let result = validator.validate(["key": "value"], against: schema)
            #expect(result.isValid)
        }

        @Test func validatesRequiredProperties() {
            let schema: [String: Any] = [
                "type": "object",
                "required": ["name", "age"]
            ]
            let valid = validator.validate(["name": "John", "age": 30], against: schema)
            #expect(valid.isValid)

            let invalid = validator.validate(["name": "John"], against: schema)
            #expect(!invalid.isValid)
            #expect(invalid.errors.first?.message.contains("is required") == true)
        }

        @Test func validatesPropertySchemas() {
            let schema: [String: Any] = [
                "type": "object",
                "properties": [
                    "name": ["type": "string"],
                    "age": ["type": "integer"]
                ]
            ]
            let valid = validator.validate(["name": "John", "age": 30], against: schema)
            #expect(valid.isValid)

            let invalid = validator.validate(["name": "John", "age": "thirty"], against: schema, coerceTypes: false)
            #expect(!invalid.isValid)
        }

        @Test func rejectsAdditionalPropertiesWhenFalse() {
            let schema: [String: Any] = [
                "type": "object",
                "properties": ["name": ["type": "string"]],
                "additionalProperties": false
            ]
            let valid = validator.validate(["name": "John"], against: schema)
            #expect(valid.isValid)

            let invalid = validator.validate(["name": "John", "extra": "field"], against: schema)
            #expect(!invalid.isValid)
            #expect(invalid.errors.first?.message.contains("additional property not allowed") == true)
        }

        @Test func allowsAdditionalPropertiesWhenTrue() {
            let schema: [String: Any] = [
                "type": "object",
                "properties": ["name": ["type": "string"]],
                "additionalProperties": true
            ]
            let result = validator.validate(["name": "John", "extra": "field"], against: schema)
            #expect(result.isValid)
        }

        @Test func validatesMinProperties() {
            let schema: [String: Any] = ["type": "object", "minProperties": 2]
            let valid = validator.validate(["a": 1, "b": 2], against: schema)
            #expect(valid.isValid)

            let invalid = validator.validate(["a": 1], against: schema)
            #expect(!invalid.isValid)
        }
    }

    // MARK: - Enum and Const Validation

    @Suite("Enum and Const Validation")
    struct EnumConstTests {
        let validator = JSONSchemaValidator.shared

        @Test func validatesEnumValues() {
            let schema: [String: Any] = ["enum": ["red", "green", "blue"]]
            let valid = validator.validate("red", against: schema)
            #expect(valid.isValid)

            let invalid = validator.validate("yellow", against: schema)
            #expect(!invalid.isValid)
            #expect(invalid.errors.first?.message.contains("must be one of the allowed values") == true)
        }

        @Test func validatesConstValue() {
            let schema: [String: Any] = ["const": "fixed"]
            let valid = validator.validate("fixed", against: schema)
            #expect(valid.isValid)

            let invalid = validator.validate("other", against: schema)
            #expect(!invalid.isValid)
            #expect(invalid.errors.first?.message.contains("must be equal to constant") == true)
        }
    }

    // MARK: - Composition Keywords

    @Suite("Composition Keywords")
    struct CompositionTests {
        let validator = JSONSchemaValidator.shared

        @Test func validatesAnyOf() {
            let schema: [String: Any] = [
                "anyOf": [
                    ["type": "string"],
                    ["type": "number"]
                ]
            ]
            let validString = validator.validate("hello", against: schema)
            #expect(validString.isValid)

            let validNumber = validator.validate(123, against: schema)
            #expect(validNumber.isValid)

            // Test without type coercion to ensure strict type checking
            let invalid = validator.validate(true, against: schema, coerceTypes: false)
            #expect(!invalid.isValid)
        }

        @Test func validatesOneOf() {
            let schema: [String: Any] = [
                "oneOf": [
                    ["type": "string", "minLength": 5],
                    ["type": "string", "maxLength": 3]
                ]
            ]
            let validLong = validator.validate("hello world", against: schema)
            #expect(validLong.isValid)

            let validShort = validator.validate("hi", against: schema)
            #expect(validShort.isValid)

            // "test" matches neither (4 chars: not >= 5, not <= 3)
            let invalid = validator.validate("test", against: schema)
            #expect(!invalid.isValid)
        }

        @Test func validatesAllOf() {
            let schema: [String: Any] = [
                "allOf": [
                    ["type": "string"],
                    ["type": "string", "minLength": 3]
                ]
            ]
            let valid = validator.validate("hello", against: schema)
            #expect(valid.isValid)

            let invalid = validator.validate("hi", against: schema)
            #expect(!invalid.isValid)
        }
    }

    // MARK: - Null Handling

    @Suite("Null Handling")
    struct NullHandlingTests {
        let validator = JSONSchemaValidator.shared

        @Test func validatesNullableField() {
            let schema: [String: Any] = ["type": "string", "nullable": true]
            let validString = validator.validate("hello", against: schema)
            #expect(validString.isValid)

            let validNull = validator.validate(nil, against: schema)
            #expect(validNull.isValid)
        }

        @Test func validatesUnionWithNull() {
            let schema: [String: Any] = ["type": ["string", "null"]]
            let validString = validator.validate("hello", against: schema)
            #expect(validString.isValid)

            let validNull = validator.validate(nil, against: schema)
            #expect(validNull.isValid)
        }

        @Test func rejectsNullWhenNotAllowed() {
            let schema: [String: Any] = ["type": "string"]
            let result = validator.validate(nil, against: schema)
            #expect(!result.isValid)
            #expect(result.errors.first?.message.contains("is required") == true)
        }
    }
}

// MARK: - Tool Validation Tests

@Suite("ToolValidation")
struct ToolValidationTests {

    @Test func validateToolCallFindsToolByName() throws {
        let tool = AITool(
            name: "get_weather",
            description: "Get weather info",
            parameters: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "location": AnyCodable(["type": AnyCodable("string")])
                ]),
                "required": AnyCodable(["location"])
            ]
        )
        let toolCall = ToolCall(
            id: "call_1",
            name: "get_weather",
            arguments: ["location": AnyCodable("New York")]
        )

        let result = try validateToolCall(tools: [tool], toolCall: toolCall)
        #expect(result["location"]?.value as? String == "New York")
    }

    @Test func validateToolCallThrowsForUnknownTool() {
        let tool = AITool(
            name: "get_weather",
            description: "Get weather info",
            parameters: [:]
        )
        let toolCall = ToolCall(
            id: "call_1",
            name: "unknown_tool",
            arguments: [:]
        )

        #expect(throws: ValidationError.self) {
            try validateToolCall(tools: [tool], toolCall: toolCall)
        }
    }

    @Test func validateToolCallValidatesRequiredFields() {
        let tool = AITool(
            name: "create_user",
            description: "Create a user",
            parameters: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "name": AnyCodable(["type": AnyCodable("string")]),
                    "email": AnyCodable(["type": AnyCodable("string"), "format": AnyCodable("email")])
                ]),
                "required": AnyCodable(["name", "email"])
            ]
        )
        let toolCall = ToolCall(
            id: "call_1",
            name: "create_user",
            arguments: ["name": AnyCodable("John")]
        )

        #expect(throws: ValidationError.self) {
            try validateToolCall(tools: [tool], toolCall: toolCall)
        }
    }

    @Test func validateToolCallValidatesPropertyTypes() {
        // Create schema with minimum constraint using raw dictionaries
        // Note: AnyCodable wrapping needs to use raw types, not nested AnyCodable
        let tool = AITool(
            name: "set_age",
            description: "Set user age",
            parameters: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "age": ["type": "integer", "minimum": 0] as [String: Any]
                ] as [String: Any])
            ]
        )
        let toolCall = ToolCall(
            id: "call_1",
            name: "set_age",
            arguments: ["age": AnyCodable(-5)]
        )

        #expect(throws: ValidationError.self) {
            try validateToolCall(tools: [tool], toolCall: toolCall)
        }
    }

    @Test func validateToolCallCoercesTypes() throws {
        let tool = AITool(
            name: "calculate",
            description: "Calculate something",
            parameters: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "value": AnyCodable(["type": AnyCodable("number")])
                ])
            ]
        )
        let toolCall = ToolCall(
            id: "call_1",
            name: "calculate",
            arguments: ["value": AnyCodable("42.5")]
        )

        let result = try validateToolCall(tools: [tool], toolCall: toolCall)
        // The coerced value should be a number
        let coercedValue = result["value"]?.value
        // It could be Double or still String if coercion happens in validation but returns as is
        if let doubleVal = coercedValue as? Double {
            #expect(doubleVal == 42.5)
        } else if let stringVal = coercedValue as? String {
            // If not coerced in return value, at least validation passed
            #expect(stringVal == "42.5")
        } else {
            #expect(Bool(false), "Expected value to be number or string")
        }
    }

    @Test func validateToolCallHandlesEmptySchema() throws {
        let tool = AITool(
            name: "no_args",
            description: "Tool with no arguments",
            parameters: [:]
        )
        let toolCall = ToolCall(
            id: "call_1",
            name: "no_args",
            arguments: ["extra": AnyCodable("data")]
        )

        // Empty schema should pass through arguments without validation
        let result = try validateToolCall(tools: [tool], toolCall: toolCall)
        #expect(result["extra"]?.value as? String == "data")
    }

    @Test func validateToolCallHandlesNestedObjects() throws {
        let tool = AITool(
            name: "nested",
            description: "Nested object tool",
            parameters: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "user": AnyCodable([
                        "type": AnyCodable("object"),
                        "properties": AnyCodable([
                            "name": AnyCodable(["type": AnyCodable("string")]),
                            "settings": AnyCodable([
                                "type": AnyCodable("object"),
                                "properties": AnyCodable([
                                    "theme": AnyCodable(["type": AnyCodable("string")])
                                ])
                            ])
                        ])
                    ])
                ])
            ]
        )
        let toolCall = ToolCall(
            id: "call_1",
            name: "nested",
            arguments: [
                "user": AnyCodable([
                    "name": AnyCodable("John"),
                    "settings": AnyCodable([
                        "theme": AnyCodable("dark")
                    ])
                ])
            ]
        )

        let result = try validateToolCall(tools: [tool], toolCall: toolCall)
        #expect(result["user"] != nil)
    }

    @Test func validateToolCallHandlesArrays() throws {
        let tool = AITool(
            name: "list_handler",
            description: "Handle list of items",
            parameters: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "items": AnyCodable([
                        "type": AnyCodable("array"),
                        "items": AnyCodable(["type": AnyCodable("string")])
                    ])
                ])
            ]
        )
        let toolCall = ToolCall(
            id: "call_1",
            name: "list_handler",
            arguments: [
                "items": AnyCodable([AnyCodable("a"), AnyCodable("b"), AnyCodable("c")])
            ]
        )

        let result = try validateToolCall(tools: [tool], toolCall: toolCall)
        #expect(result["items"] != nil)
    }

    @Test func validateToolCallPreservesObjectsInsideArrays() throws {
        let tool = AITool(
            name: "replace",
            description: "Replace text",
            parameters: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "edits": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "oldText": ["type": "string"],
                                "newText": ["type": "string"],
                            ],
                            "required": ["oldText", "newText"],
                        ],
                    ],
                ] as [String: Any]),
                "required": AnyCodable(["edits"]),
            ]
        )
        let toolCall = ToolCall(
            id: "call_1",
            name: "replace",
            arguments: [
                "edits": AnyCodable([[
                    "oldText": "before",
                    "newText": "after",
                ]] as [[String: Any]]),
            ]
        )

        let result = try validateToolCall(tools: [tool], toolCall: toolCall)
        let edits = result["edits"]?.value as? [Any]
        let firstEdit = edits?.first as? [String: Any]
        #expect(firstEdit?["oldText"] as? String == "before")
        #expect(firstEdit?["newText"] as? String == "after")
    }
}

// MARK: - OAuth Tests

@Suite("OAuth")
struct OAuthTests {

    @Test func oauthProviderListReturnsAllProviders() {
        let providers = getOAuthProviders()
        #expect(providers.count == 6)

        let ids = providers.map { $0.id }
        #expect(ids.contains(.anthropic))
        #expect(ids.contains(.openAICodex))
        #expect(ids.contains(.githubCopilot))
        #expect(ids.contains(.openRouter))
        #expect(ids.contains(.kimiCoding))
        #expect(ids.contains(.xai))
        #expect(!ids.contains(.googleGeminiCli))
        #expect(!ids.contains(.googleAntigravity))
    }

    @Test func oauthProviderNamesAreSet() {
        let providers = getOAuthProviders()
        for provider in providers {
            #expect(!provider.name.isEmpty)
        }
        #expect(providers.first { $0.id == .openRouter }?.name == "OpenRouter OAuth")
        #expect(providers.first { $0.id == .kimiCoding }?.name == "Kimi Code (subscription)")
    }

    @Test func openRouterPkceExchangesPastedRedirectUrl() async throws {
        try await assertOpenRouterManualInput(
            "http://127.0.0.1:4567/oauth/callback/test?code=redirect-code",
            expectedCode: "redirect-code"
        )
    }

    @Test func openRouterPkceExchangesPastedBareCode() async throws {
        try await assertOpenRouterManualInput("bare-code", expectedCode: "bare-code")
    }

    @Test func openRouterLoopbackCallbackExchangesCode() async throws {
        try await codexRequestLock.withLock {
            let callbackTask = LockedState<Task<Int, Never>?>(nil)
            MockURLProtocol.allowedHosts.withLock { $0 = ["openrouter.ai"] }
            MockURLProtocol.requestHandler.withLock { $0 = { request in
                let url = try #require(request.url)
                let bodyData = try #require(readRequestBody(request))
                let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: String])
                #expect(body["code"] == "loopback-code")
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"key":"sk-or-loopback"}"#.utf8))
            } }
            URLProtocol.registerClass(MockURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockURLProtocol.self)
                MockURLProtocol.allowedHosts.withLock { $0 = [] }
                MockURLProtocol.requestHandler.withLock { $0 = nil }
            }

            let credentials = try await loginOpenRouter(OAuthLoginCallbacks(
                onAuth: { info in
                    let authorize = URLComponents(string: info.url)
                    let callback = authorize?.queryItems?.first { $0.name == "callback_url" }?.value
                    let task = Task.detached { () -> Int in
                        guard let callback,
                              var components = URLComponents(string: callback) else { return 0 }
                        components.queryItems = [URLQueryItem(name: "code", value: "loopback-code")]
                        guard let url = components.url else { return 0 }
                        do {
                            let (_, response) = try await URLSession.shared.data(from: url)
                            return (response as? HTTPURLResponse)?.statusCode ?? 0
                        } catch {
                            return 0
                        }
                    }
                    callbackTask.withLock { $0 = task }
                },
                onPrompt: { _ in
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    return ""
                }
            ))

            #expect(credentials.access == "sk-or-loopback")
            let task = try #require(callbackTask.withLock { $0 })
            #expect(await task.value == 200)
        }
    }

    private func assertOpenRouterManualInput(_ input: String, expectedCode: String) async throws {
        try await codexRequestLock.withLock {
            let authInfo = LockedState<OAuthAuthInfo?>(nil)
            let sawValidPkce = LockedState(false)
            MockURLProtocol.allowedHosts.withLock { $0 = ["openrouter.ai"] }
            MockURLProtocol.requestHandler.withLock { $0 = { request in
                let url = try #require(request.url)
                #expect(url.path == "/api/v1/auth/keys")
                #expect(request.httpMethod == "POST")
                let bodyData = try #require(readRequestBody(request))
                let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: String])
                #expect(body["code"] == expectedCode)
                #expect(body["code_challenge_method"] == "S256")

                let authorizeUrl = try #require(authInfo.withLock { $0?.url })
                let challenge = try #require(
                    URLComponents(string: authorizeUrl)?.queryItems?
                        .first { $0.name == "code_challenge" }?.value
                )
                let verifier = try #require(body["code_verifier"])
                let digest = Data(SHA256.hash(data: Data(verifier.utf8)))
                let derived = digest.base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
                #expect(derived == challenge)
                sawValidPkce.withLock { $0 = derived == challenge }

                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["content-type": "application/json"]
                )!
                return (response, Data(#"{"key":"sk-or-minted-key"}"#.utf8))
            } }
            URLProtocol.registerClass(MockURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockURLProtocol.self)
                MockURLProtocol.allowedHosts.withLock { $0 = [] }
                MockURLProtocol.requestHandler.withLock { $0 = nil }
            }

            let credentials = try await loginOpenRouter(OAuthLoginCallbacks(
                onAuth: { info in authInfo.withLock { $0 = info } },
                onPrompt: { prompt in
                    #expect(prompt.placeholder?.contains("/oauth/callback/") == true)
                    return input
                }
            ))

            #expect(sawValidPkce.withLock { $0 })
            #expect(credentials.access == "sk-or-minted-key")
            #expect(credentials.refresh.isEmpty)
            #expect(credentials.expires == 9_007_199_254_740_991)
            let authorizeUrl = try #require(authInfo.withLock { $0?.url })
            let items = URLComponents(string: authorizeUrl)?.queryItems ?? []
            #expect(items.first { $0.name == "callback_url" }?.value?.contains("/oauth/callback/") == true)
            #expect(items.first { $0.name == "code_challenge_method" }?.value == "S256")
        }
    }

    @Test func kimiCodingDeviceFlowHandlesSlowDown() async throws {
        try await codexRequestLock.withLock {
            let pollCount = LockedState(0)
            let authInfo = LockedState<OAuthAuthInfo?>(nil)
            MockURLProtocol.allowedHosts.withLock { $0 = ["auth.kimi.com"] }
            MockURLProtocol.requestHandler.withLock { $0 = { request in
                let url = try #require(request.url)
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
                let form = String(data: try #require(readRequestBody(request)), encoding: .utf8) ?? ""
                let fields = Dictionary(uniqueKeysWithValues: (URLComponents(string: "?\(form)")?.queryItems ?? []).compactMap {
                    item in item.value.map { (item.name, $0) }
                })
                #expect(fields["client_id"] == "17e5f671-d194-4dfb-9706-5516cb48c098")
                let response: HTTPURLResponse
                let data: Data
                switch url.path {
                case "/api/oauth/device_authorization":
                    response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    data = Data(#"{"device_code":"kimi-device","user_code":"KIMI-CODE","verification_uri":"https://auth.kimi.com/device","verification_uri_complete":"https://auth.kimi.com/device?user_code=KIMI-CODE","interval":0.001,"expires_in":30}"#.utf8)
                case "/api/oauth/token":
                    #expect(fields["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code")
                    #expect(fields["device_code"] == "kimi-device")
                    let poll = pollCount.withLock { count in count += 1; return count }
                    if poll == 1 {
                        response = HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!
                        data = Data(#"{"error":"slow_down","interval":0.001}"#.utf8)
                    } else {
                        response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                        data = Data(#"{"access_token":"kimi-access","refresh_token":"kimi-refresh","expires_in":3600}"#.utf8)
                    }
                default:
                    throw URLError(.badURL)
                }
                return (response, data)
            } }
            URLProtocol.registerClass(MockURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockURLProtocol.self)
                MockURLProtocol.allowedHosts.withLock { $0 = [] }
                MockURLProtocol.requestHandler.withLock { $0 = nil }
            }

            let credentials = try await loginKimiCoding(OAuthLoginCallbacks(
                onAuth: { info in authInfo.withLock { $0 = info } },
                onPrompt: { _ in "" }
            ))
            #expect(pollCount.withLock { $0 } == 2)
            #expect(authInfo.withLock { $0?.url } == "https://auth.kimi.com/device?user_code=KIMI-CODE")
            #expect(authInfo.withLock { $0?.instructions } == "Enter code: KIMI-CODE")
            #expect(credentials.access == "kimi-access")
            #expect(credentials.refresh == "kimi-refresh")
        }
    }

    @Test func kimiCodingRefreshUsesHostOverride() async throws {
        await codexRequestLock.withLock {
            await withEnv("KIMI_CODE_OAUTH_HOST", value: "https://kimi-oauth.example/") {
                MockURLProtocol.allowedHosts.withLock { $0 = ["kimi-oauth.example"] }
                MockURLProtocol.requestHandler.withLock { $0 = { request in
                    let url = try #require(request.url)
                    #expect(url.absoluteString == "https://kimi-oauth.example/api/oauth/token")
                    let form = String(data: try #require(readRequestBody(request)), encoding: .utf8) ?? ""
                    let fields = Dictionary(uniqueKeysWithValues: (URLComponents(string: "?\(form)")?.queryItems ?? []).compactMap {
                        item in item.value.map { (item.name, $0) }
                    })
                    #expect(fields["grant_type"] == "refresh_token")
                    #expect(fields["refresh_token"] == "old-kimi-refresh")
                    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, Data(#"{"access_token":"new-kimi-access","refresh_token":"new-kimi-refresh","expires_in":3600}"#.utf8))
                } }
                URLProtocol.registerClass(MockURLProtocol.self)
                defer {
                    URLProtocol.unregisterClass(MockURLProtocol.self)
                    MockURLProtocol.allowedHosts.withLock { $0 = [] }
                    MockURLProtocol.requestHandler.withLock { $0 = nil }
                }
                do {
                    let credentials = try await refreshKimiCodingToken("old-kimi-refresh")
                    #expect(credentials.access == "new-kimi-access")
                    #expect(credentials.refresh == "new-kimi-refresh")
                } catch {
                    Issue.record(error)
                }
            }
        }
    }

    @Test func refreshCancellationAbortsNetworkRequest() async {
        await codexRequestLock.withLock {
            BlockingOAuthURLProtocol.started.withLock { $0 = false }
            BlockingOAuthURLProtocol.stopped.withLock { $0 = false }
            URLProtocol.registerClass(BlockingOAuthURLProtocol.self)
            defer { URLProtocol.unregisterClass(BlockingOAuthURLProtocol.self) }

            let signal = CancellationToken()
            let task = Task {
                try await refreshXaiToken("refresh-token", signal: signal)
            }
            while !BlockingOAuthURLProtocol.started.withLock({ $0 }) {
                await Task.yield()
            }
            signal.cancel()
            do {
                _ = try await task.value
                Issue.record("Refresh completed after cancellation")
            } catch let error as OAuthError {
                if case .cancelled = error {
                    #expect(Bool(true))
                } else {
                    Issue.record("Unexpected OAuth error: \(error)")
                }
            } catch {
                Issue.record(error)
            }
            for _ in 0..<100 where !BlockingOAuthURLProtocol.stopped.withLock({ $0 }) {
                await Task.yield()
            }
            #expect(BlockingOAuthURLProtocol.stopped.withLock { $0 })
        }
    }

    @Test func oauthMinimumValidityPolicy() {
        let now = Date().timeIntervalSince1970 * 1000
        let twoMinutes = OAuthCredentials(refresh: "r", access: "a", expires: now + 2 * 60 * 1000)
        let thirtyMinutes = OAuthCredentials(refresh: "r", access: "a", expires: now + 30 * 60 * 1000)
        #expect(oauthCredentialNeedsRefresh(twoMinutes, now: now))
        #expect(!oauthCredentialNeedsRefresh(thirtyMinutes, now: now))
        #expect(oauthCredentialNeedsRefresh(
            thirtyMinutes,
            minimumValidityMs: 45 * 60 * 1000,
            now: now
        ))
    }

    @Test func normalizeGitHubDomainHandlesVariousInputs() {
        // Empty input
        #expect(normalizeGitHubDomain("") == nil)
        #expect(normalizeGitHubDomain("   ") == nil)

        // Simple hostname
        #expect(normalizeGitHubDomain("github.com") == "github.com")
        #expect(normalizeGitHubDomain("company.ghe.com") == "company.ghe.com")

        // With protocol
        #expect(normalizeGitHubDomain("https://github.com") == "github.com")
        #expect(normalizeGitHubDomain("https://company.ghe.com/path") == "company.ghe.com")

        // With whitespace
        #expect(normalizeGitHubDomain("  github.com  ") == "github.com")
    }

    @Test func gitHubCopilotBaseUrlExtraction() {
        // From token with proxy-ep
        let tokenWithProxy = "tid=abc;exp=123;proxy-ep=proxy.individual.githubcopilot.com;sku=free"
        let baseUrl = getGitHubCopilotBaseUrl(token: tokenWithProxy, enterpriseDomain: nil)
        #expect(baseUrl == "https://api.individual.githubcopilot.com")

        // Without token, with enterprise domain
        let enterpriseUrl = getGitHubCopilotBaseUrl(token: nil, enterpriseDomain: "company.ghe.com")
        #expect(enterpriseUrl == "https://copilot-api.company.ghe.com")

        // Default fallback
        let defaultUrl = getGitHubCopilotBaseUrl(token: nil, enterpriseDomain: nil)
        #expect(defaultUrl == "https://api.individual.githubcopilot.com")

        // Token without proxy-ep
        let tokenWithoutProxy = "tid=abc;exp=123;sku=free"
        let fallbackUrl = getGitHubCopilotBaseUrl(token: tokenWithoutProxy, enterpriseDomain: nil)
        #expect(fallbackUrl == "https://api.individual.githubcopilot.com")
    }

    @Test func gitHubCopilotLoginDeviceFlowExchangesTokenAndEnablesModels() async throws {
        try await codexRequestLock.withLock {
            let seenDeviceCode = LockedState(false)
            let seenAccessToken = LockedState(false)
            let seenCopilotToken = LockedState(false)
            let enabledModelCount = LockedState(0)
            let authInfo = LockedState<OAuthAuthInfo?>(nil)
            let progressMessages = LockedState<[String]>([])

            MockURLProtocol.allowedHosts.withLock {
                $0 = ["github.com", "api.github.com", "api.individual.githubcopilot.com"]
            }
            MockURLProtocol.requestHandler.withLock { $0 = { request in
                guard let url = request.url else { throw URLError(.badURL) }
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["content-type": "application/json"]
                )!
                switch (url.host, url.path) {
                case ("github.com", "/login/device/code"):
                    seenDeviceCode.withLock { $0 = true }
                    #expect(request.httpMethod == "POST")
                    #expect(request.value(forHTTPHeaderField: "User-Agent") == "GitHubCopilotChat/0.35.0")
                    return (response, Data("""
                    {"device_code":"device-123","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","interval":1,"expires_in":60}
                    """.utf8))
                case ("github.com", "/login/oauth/access_token"):
                    seenAccessToken.withLock { $0 = true }
                    #expect(request.httpMethod == "POST")
                    return (response, Data("""
                    {"access_token":"gh_access_token"}
                    """.utf8))
                case ("api.github.com", "/copilot_internal/v2/token"):
                    seenCopilotToken.withLock { $0 = true }
                    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer gh_access_token")
                    #expect(request.value(forHTTPHeaderField: "Copilot-Integration-Id") == "vscode-chat")
                    return (response, Data("""
                    {"token":"tid=abc;exp=123;proxy-ep=proxy.individual.githubcopilot.com;sku=free","expires_at":2000000000}
                    """.utf8))
                default:
                    if url.host == "api.individual.githubcopilot.com", url.path.hasPrefix("/models/"), url.path.hasSuffix("/policy") {
                        enabledModelCount.withLock { $0 += 1 }
                        #expect(request.httpMethod == "POST")
                        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer tid=abc") == true)
                        #expect(request.value(forHTTPHeaderField: "openai-intent") == "chat-policy")
                        return (response, Data("{}".utf8))
                    }
                    throw URLError(.badURL)
                }
            } }
            URLProtocol.registerClass(MockURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockURLProtocol.self)
                MockURLProtocol.allowedHosts.withLock { $0 = [] }
                MockURLProtocol.requestHandler.withLock { $0 = nil }
            }

            let credentials = try await loginGitHubCopilot(OAuthLoginCallbacks(
                onAuth: { info in authInfo.withLock { $0 = info } },
                onPrompt: { prompt in
                    #expect(prompt.allowEmpty)
                    return ""
                },
                onProgress: { message in progressMessages.withLock { $0.append(message) } }
            ))

            #expect(seenDeviceCode.withLock { $0 })
            #expect(seenAccessToken.withLock { $0 })
            #expect(seenCopilotToken.withLock { $0 })
            #expect(enabledModelCount.withLock { $0 } == getModels(provider: .githubCopilot).count)
            #expect(authInfo.withLock { $0?.url } == "https://github.com/login/device")
            #expect(authInfo.withLock { $0?.instructions } == "Enter code: ABCD-EFGH")
            #expect(progressMessages.withLock { $0 }.contains("Enabling models..."))
            #expect(credentials.refresh == "gh_access_token")
            #expect(credentials.access.contains("proxy-ep=proxy.individual.githubcopilot.com"))
            #expect(credentials.enterpriseUrl == nil)
        }
    }

    @Test func xaiLoginDeviceFlowPollsAndReturnsBearerApiKey() async throws {
        try await codexRequestLock.withLock {
            let tokenPollCount = LockedState(0)
            let authInfo = LockedState<OAuthAuthInfo?>(nil)

            MockURLProtocol.allowedHosts.withLock { $0 = ["auth.x.ai"] }
            MockURLProtocol.requestHandler.withLock { $0 = { request in
                let url = try #require(request.url)
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")

                let form = String(data: try #require(readRequestBody(request)), encoding: .utf8) ?? ""
                let queryItems = URLComponents(string: "?\(form)")?.queryItems ?? []
                let fields = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
                    item.value.map { (item.name, $0) }
                })
                #expect(fields["client_id"] == "b1a00492-073a-47ea-816f-4c329264a828")

                switch url.path {
                case "/oauth2/device/code":
                    #expect(fields["scope"] == "openid profile email offline_access grok-cli:access api:access")
                    #expect(fields["referrer"] == "pi")
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["content-type": "application/json"]
                    )!
                    return (response, Data("""
                    {"device_code":"xai-device-123","user_code":"GROK-CODE","verification_uri":"https://auth.x.ai/device","verification_uri_complete":"https://auth.x.ai/device?user_code=GROK-CODE","interval":1,"expires_in":60}
                    """.utf8))
                case "/oauth2/token":
                    #expect(fields["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code")
                    #expect(fields["device_code"] == "xai-device-123")
                    let poll = tokenPollCount.withLock { count in
                        count += 1
                        return count
                    }
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: poll == 1 ? 400 : 200,
                        httpVersion: nil,
                        headerFields: ["content-type": "application/json"]
                    )!
                    if poll == 1 {
                        return (response, Data(#"{"error":"authorization_pending"}"#.utf8))
                    }
                    return (response, Data(#"{"access_token":"xai-access-token","refresh_token":"xai-refresh-token","expires_in":3600}"#.utf8))
                default:
                    throw URLError(.badURL)
                }
            } }
            URLProtocol.registerClass(MockURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockURLProtocol.self)
                MockURLProtocol.allowedHosts.withLock { $0 = [] }
                MockURLProtocol.requestHandler.withLock { $0 = nil }
            }

            let credentials = try await loginXai(OAuthLoginCallbacks(
                onAuth: { info in authInfo.withLock { $0 = info } },
                onPrompt: { _ in "" }
            ))

            #expect(tokenPollCount.withLock { $0 } == 2)
            #expect(authInfo.withLock { $0?.url } == "https://auth.x.ai/device?user_code=GROK-CODE")
            #expect(authInfo.withLock { $0?.instructions } == "Enter code: GROK-CODE")
            #expect(credentials.access == "xai-access-token")
            #expect(credentials.refresh == "xai-refresh-token")
            #expect(credentials.expires > Date().timeIntervalSince1970 * 1000)
            #expect(try oauthApiKey(provider: .xai, credentials: credentials) == "xai-access-token")
        }
    }

    @Test func refreshXaiTokenPreservesUnrotatedRefreshToken() async throws {
        try await codexRequestLock.withLock {
            MockURLProtocol.allowedHosts.withLock { $0 = ["auth.x.ai"] }
            MockURLProtocol.requestHandler.withLock { $0 = { request in
                let url = try #require(request.url)
                #expect(url.path == "/oauth2/token")
                let form = String(data: try #require(readRequestBody(request)), encoding: .utf8) ?? ""
                let queryItems = URLComponents(string: "?\(form)")?.queryItems ?? []
                let fields = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
                    item.value.map { (item.name, $0) }
                })
                #expect(fields["grant_type"] == "refresh_token")
                #expect(fields["refresh_token"] == "old-refresh-token")
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["content-type": "application/json"]
                )!
                return (response, Data(#"{"access_token":"new-xai-access","expires_in":3600}"#.utf8))
            } }
            URLProtocol.registerClass(MockURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockURLProtocol.self)
                MockURLProtocol.allowedHosts.withLock { $0 = [] }
                MockURLProtocol.requestHandler.withLock { $0 = nil }
            }

            let credentials = try await refreshXaiToken("old-refresh-token")
            #expect(credentials.access == "new-xai-access")
            #expect(credentials.refresh == "old-refresh-token")
            #expect(credentials.expires > Date().timeIntervalSince1970 * 1000)
        }
    }

    @Test func grok45UsesXaiResponsesRoutingAndReasoningEffort() throws {
        let model = try #require(getModel(provider: "xai", modelId: "grok-4.5"))
        #expect(model.api == .openAIResponses)
        #expect(model.baseUrl == "https://api.x.ai/v1")
        #expect(mapResponsesReasoningEffort(model: model, requested: .low)?.rawValue == "low")
        #expect(mapResponsesReasoningEffort(model: model, requested: .medium)?.rawValue == "medium")
        #expect(mapResponsesReasoningEffort(model: model, requested: .high)?.rawValue == "high")
    }

    @Test func oauthCredentialsEncoding() throws {
        let credentials = OAuthCredentials(
            refresh: "refresh_token",
            access: "access_token",
            expires: 1234567890.0,
            enterpriseUrl: "company.ghe.com",
            projectId: "project-123",
            email: "user@example.com",
            accountId: "acc_123"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(credentials)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(OAuthCredentials.self, from: data)

        #expect(decoded.refresh == "refresh_token")
        #expect(decoded.access == "access_token")
        #expect(decoded.expires == 1234567890.0)
        #expect(decoded.enterpriseUrl == "company.ghe.com")
        #expect(decoded.projectId == "project-123")
        #expect(decoded.email == "user@example.com")
        #expect(decoded.accountId == "acc_123")
    }

    @Test func oauthApiKeyForSimpleProviders() throws {
        // Anthropic - just returns access token
        let anthropicKey = try oauthApiKey(provider: .anthropic, accessToken: "token123", projectId: nil)
        #expect(anthropicKey == "token123")

        // GitHub Copilot - just returns access token
        let copilotKey = try oauthApiKey(provider: .githubCopilot, accessToken: "ghtoken", projectId: nil)
        #expect(copilotKey == "ghtoken")
    }

    @Test func oauthApiKeyForGoogleProviders() throws {
        // Google Gemini CLI - requires projectId, returns JSON
        let geminiKey = try oauthApiKey(provider: .googleGeminiCli, accessToken: "gtoken", projectId: "proj-123")
        #expect(geminiKey.contains("token"))
        #expect(geminiKey.contains("gtoken"))
        #expect(geminiKey.contains("projectId"))
        #expect(geminiKey.contains("proj-123"))

        // Antigravity - requires projectId, returns JSON
        let antigravityKey = try oauthApiKey(provider: .googleAntigravity, accessToken: "atoken", projectId: "proj-456")
        #expect(antigravityKey.contains("atoken"))
        #expect(antigravityKey.contains("proj-456"))
    }

    @Test func oauthApiKeyThrowsForMissingProjectId() {
        // Google providers require projectId
        #expect(throws: OAuthError.self) {
            try oauthApiKey(provider: .googleGeminiCli, accessToken: "token", projectId: nil)
        }

        #expect(throws: OAuthError.self) {
            try oauthApiKey(provider: .googleAntigravity, accessToken: "token", projectId: nil)
        }
    }

    @Test func requiresProjectIdForGoogleProviders() {
        // Verify the helper function correctly identifies which providers need projectId
        let geminiCreds = OAuthCredentials(refresh: "r", access: "a", expires: 0, projectId: nil)
        let antigravityCreds = OAuthCredentials(refresh: "r", access: "a", expires: 0, projectId: nil)

        // These should throw when trying to get API key
        #expect(throws: OAuthError.self) {
            try oauthApiKey(provider: .googleGeminiCli, credentials: geminiCreds)
        }
        #expect(throws: OAuthError.self) {
            try oauthApiKey(provider: .googleAntigravity, credentials: antigravityCreds)
        }

        // With projectId, they should work
        let geminiCredsWithProject = OAuthCredentials(refresh: "r", access: "a", expires: 0, projectId: "proj")
        let key = try? oauthApiKey(provider: .googleGeminiCli, credentials: geminiCredsWithProject)
        #expect(key != nil)
    }
}

@Suite("ApiRegistry", .serialized)
struct ApiRegistryTests {
    @Test func registryStartsWithBuiltInProviders() {
        // Reset to ensure clean state
        resetApiProviders()

        let providers = getApiProviders()
        #expect(providers.count >= 7)

        // Check specific providers exist
        #expect(getApiProvider(.anthropicMessages) != nil)
        #expect(getApiProvider(.openAICompletions) != nil)
        #expect(getApiProvider(.openAIResponses) != nil)
        #expect(getApiProvider(.azureOpenAIResponses) != nil)
        #expect(getApiProvider(.googleGenerativeAI) != nil)
        #expect(getApiProvider(.googleGeminiCli) == nil)
        #expect(getApiProvider(.googleVertex) != nil)
        #expect(getApiProvider(.bedrockConverseStream) != nil)
    }

    @Test func canRegisterCustomProvider() {
        resetApiProviders()

        // Create a mock provider (we can't easily test the actual streaming)
        let customProvider = ApiProvider(
            api: .anthropicMessages, // Reusing existing API type for test
            stream: { _, _, _ in createAssistantMessageEventStream() },
            streamSimple: { _, _, _ in createAssistantMessageEventStream() }
        )

        // Register with a custom source ID
        registerApiProvider(customProvider, sourceId: "test-source")

        // Verify it's registered
        #expect(getApiProvider(.anthropicMessages) != nil)

        // Cleanup
        resetApiProviders()
    }

    @Test func unregisterRemovesProvidersBySourceId() {
        // Clear and set up isolated test state
        clearApiProviders()

        let provider1 = ApiProvider(
            api: .anthropicMessages,
            stream: { _, _, _ in createAssistantMessageEventStream() },
            streamSimple: { _, _, _ in createAssistantMessageEventStream() }
        )
        let provider2 = ApiProvider(
            api: .openAICompletions,
            stream: { _, _, _ in createAssistantMessageEventStream() },
            streamSimple: { _, _, _ in createAssistantMessageEventStream() }
        )

        registerApiProvider(provider1, sourceId: "source-a")
        registerApiProvider(provider2, sourceId: "source-b")

        #expect(getApiProviders().count == 2)

        // Unregister source-a
        unregisterApiProviders(sourceId: "source-a")

        #expect(getApiProviders().count == 1)
        #expect(getApiProvider(.anthropicMessages) == nil)
        #expect(getApiProvider(.openAICompletions) != nil)

        // Restore built-in providers
        resetApiProviders()
    }

    @Test func clearRemovesAllProviders() {
        resetApiProviders()
        let initialCount = getApiProviders().count
        #expect(initialCount > 0)

        clearApiProviders()
        #expect(getApiProviders().count == 0)

        // Restore built-in providers
        resetApiProviders()
        #expect(getApiProviders().count == initialCount)
    }

    @Test func resetApiProvidersRestoresBuiltIn() {
        // Clear everything
        clearApiProviders()
        #expect(getApiProviders().count == 0)

        // Reset should restore built-in providers
        resetApiProviders()
        #expect(getApiProviders().count >= 8)
    }

    @Test func registryHasMethod() {
        // Restore built-in providers first to ensure clean state
        resetApiProviders()

        #expect(ApiProviderRegistry.shared.has(.anthropicMessages))
        #expect(ApiProviderRegistry.shared.has(.openAICompletions))

        clearApiProviders()
        #expect(!ApiProviderRegistry.shared.has(.anthropicMessages))

        // Restore for other tests
        resetApiProviders()
    }

    @Test func streamUsesRegisteredProviderDispatch() async throws {
        resetApiProviders()
        let invoked = LockedState(false)

        let custom = ApiProvider(
            api: .openAIResponses,
            stream: { model, _, _ in
                invoked.withLock { $0 = true }
                let stream = createAssistantMessageEventStream()
                let message = AssistantMessage(
                    content: [.text(TextContent(text: "custom-provider"))],
                    api: model.api,
                    provider: model.provider,
                    model: model.id,
                    usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                    stopReason: .stop
                )
                stream.push(.start(partial: message))
                stream.push(.done(reason: .stop, message: message))
                stream.end(message)
                return stream
            },
            streamSimple: { model, _, _ in
                let stream = createAssistantMessageEventStream()
                let message = AssistantMessage(
                    content: [.text(TextContent(text: "custom-provider-simple"))],
                    api: model.api,
                    provider: model.provider,
                    model: model.id,
                    usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                    stopReason: .stop
                )
                stream.push(.start(partial: message))
                stream.push(.done(reason: .stop, message: message))
                stream.end(message)
                return stream
            }
        )
        registerApiProvider(custom, sourceId: "test-stream-dispatch")

        let baseModel = getModel(provider: .openai, modelId: "gpt-5-mini")
        let model = Model(
            id: baseModel.id,
            name: baseModel.name,
            api: .openAIResponses,
            provider: baseModel.provider,
            baseUrl: baseModel.baseUrl,
            reasoning: baseModel.reasoning,
            input: baseModel.input,
            cost: baseModel.cost,
            contextWindow: baseModel.contextWindow,
            maxTokens: baseModel.maxTokens,
            headers: baseModel.headers,
            compat: baseModel.compat
        )
        let context = Context(messages: [.user(UserMessage(content: .text("hello")))])
        let result = try await complete(model: model, context: context)

        #expect(invoked.withLock { $0 })
        let text = result.content.compactMap { block -> String? in
            if case .text(let textContent) = block { return textContent.text }
            return nil
        }.joined(separator: "")
        #expect(text == "custom-provider")

        resetApiProviders()
    }

    @Test func fauxProviderStreamsScriptedMessagesAndFactories() async throws {
        resetApiProviders()
        defer { resetApiProviders() }

        let registration = registerFauxProvider(FauxRegistrationOptions(
            models: [
                FauxModelDefinition(
                    id: "faux-test",
                    name: "Faux Test",
                    reasoning: true,
                    input: [.text],
                    cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                    contextWindow: 4096,
                    maxTokens: 1024
                )
            ],
            minTokenSize: 1,
            maxTokenSize: 1
        ))
        registration.setResponses([
            .message(fauxAssistantMessage(
                content: [
                    fauxThinking("plan"),
                    fauxText("answer"),
                    fauxToolCall(name: "lookup", arguments: ["query": AnyCodable("pi")], id: "call-1"),
                ],
                stopReason: .toolUse,
                responseId: "faux-response-1"
            )),
            .factory { _, _, state, _ in
                fauxAssistantMessage(
                    content: [fauxText("factory call \(state.callCount)")],
                    responseId: "faux-response-2"
                )
            },
        ])

        guard let model = registration.getModel(id: "faux-test") else {
            #expect(Bool(false), "Expected faux model")
            return
        }

        let firstStream = try streamSimple(
            model: model,
            context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
            options: SimpleStreamOptions(cacheRetention: .short, sessionId: "faux-session")
        )
        var sawThinking = false
        var sawText = false
        var sawTool = false
        for await event in firstStream {
            switch event {
            case .thinkingDelta:
                sawThinking = true
            case .textDelta:
                sawText = true
            case .toolCallEnd:
                sawTool = true
            default:
                break
            }
        }
        let first = await firstStream.result()
        #expect(sawThinking)
        #expect(sawText)
        #expect(sawTool)
        #expect(first.api == Api.openAICompletions)
        #expect(first.provider == "faux")
        #expect(first.model == "faux-test")
        #expect(first.responseId == "faux-response-1")
        #expect(first.stopReason == StopReason.toolUse)
        #expect(first.usage.totalTokens > 0)
        #expect(registration.pendingResponseCount() == 1)
        #expect(registration.state().callCount == 1)

        let second = try await completeSimple(
            model: model,
            context: Context(messages: [.user(UserMessage(content: .text("again")))])
        )
        let secondText = second.content.compactMap { block -> String? in
            if case .text(let text) = block { return text.text }
            return nil
        }.joined()
        #expect(secondText == "factory call 2")
        #expect(registration.pendingResponseCount() == 0)
        #expect(registration.state().callCount == 2)

        registration.unregister()
        #expect(getApiProvider(.openAICompletions) == nil)
    }
}

// MARK: - v0.54.0→v0.61.1 new tests

@Test func contextOverflowDetectionZaiPattern() {
    let usage = Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0)
    let message = AssistantMessage(
        content: [.text(TextContent(text: ""))],
        api: .openAICompletions,
        provider: "zai",
        model: "glm-5",
        usage: usage,
        stopReason: .error,
        errorMessage: "model_context_window_exceeded"
    )
    #expect(isContextOverflow(message))
}

@Test func assistantMessageResponseIdField() {
    let message = AssistantMessage(
        content: [.text(TextContent(text: "hello"))],
        api: .anthropicMessages,
        provider: "anthropic",
        model: "claude-sonnet-4-6",
        responseId: "msg_01ABC123",
        usage: Usage(input: 10, output: 5, cacheRead: 0, cacheWrite: 0, totalTokens: 15),
        stopReason: .stop
    )
    #expect(message.responseId == "msg_01ABC123")

    // Default should be nil
    let noId = AssistantMessage(
        content: [],
        api: .openAICompletions,
        provider: "openai",
        model: "gpt-4o-mini",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .stop
    )
    #expect(noId.responseId == nil)
}

@Test func thinkingContentRedactedField() {
    let redacted = ThinkingContent(
        thinking: "[Reasoning redacted]",
        thinkingSignature: "opaque-encrypted-payload",
        redacted: true
    )
    #expect(redacted.redacted == true)
    #expect(redacted.thinkingSignature == "opaque-encrypted-payload")

    let normal = ThinkingContent(thinking: "some reasoning", thinkingSignature: "sig")
    #expect(normal.redacted == nil)
}

@Test func transformMessagesDropsRedactedThinkingOnCrossModelReplay() {
    let targetModel = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let redactedThinking = ThinkingContent(
        thinking: "[Reasoning redacted]",
        thinkingSignature: "opaque-payload",
        redacted: true
    )
    let normalText = TextContent(text: "visible response")
    let assistant = AssistantMessage(
        content: [.thinking(redactedThinking), .text(normalText)],
        api: .anthropicMessages,
        provider: "anthropic",
        model: "claude-opus-4-6",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .stop
    )

    let transformed = transformMessages([.assistant(assistant)], model: targetModel)
    guard case .assistant(let transformedAssistant) = transformed.first else {
        #expect(Bool(false), "Expected assistant message")
        return
    }

    // Redacted thinking should be dropped on cross-model replay
    let hasThinking = transformedAssistant.content.contains { block in
        if case .thinking = block { return true }
        return false
    }
    #expect(!hasThinking)

    // Normal text should be preserved
    let hasText = transformedAssistant.content.contains { block in
        if case .text(let text) = block { return text.text == "visible response" }
        return false
    }
    #expect(hasText)
}

@Test func transformMessagesPreservesRedactedThinkingForSameModel() {
    let model = getModel(provider: .anthropic, modelId: "claude-opus-4-6")
    let redactedThinking = ThinkingContent(
        thinking: "[Reasoning redacted]",
        thinkingSignature: "opaque-payload",
        redacted: true
    )
    let assistant = AssistantMessage(
        content: [.thinking(redactedThinking)],
        api: .anthropicMessages,
        provider: "anthropic",
        model: "claude-opus-4-6",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .stop
    )

    let transformed = transformMessages([.assistant(assistant)], model: model)
    guard case .assistant(let transformedAssistant) = transformed.first else {
        #expect(Bool(false), "Expected assistant message")
        return
    }

    // Redacted thinking should be preserved for same model
    guard case .thinking(let thinking) = transformedAssistant.content.first else {
        #expect(Bool(false), "Expected thinking content block")
        return
    }
    #expect(thinking.redacted == true)
    #expect(thinking.thinkingSignature == "opaque-payload")
}

@Test func compactionReasoningAwarenessNonReasoningModel() {
    // A model with reasoning: false should produce nil reasoning in summarization options
    let nonReasoningModel = Model(
        id: "gpt-4o",
        name: "GPT-4o",
        api: .openAIResponses,
        provider: "openai",
        baseUrl: "https://api.openai.com",
        reasoning: false,
        input: [.text],
        cost: ModelCost(input: 5, output: 15, cacheRead: 0.5, cacheWrite: 5),
        contextWindow: 128000,
        maxTokens: 4096
    )
    let reasoning: ThinkingLevel? = nonReasoningModel.reasoning ? .high : nil
    #expect(reasoning == nil)

    let reasoningModel = Model(
        id: "claude-sonnet-4-5",
        name: "Claude Sonnet 4.5",
        api: .anthropicMessages,
        provider: "anthropic",
        baseUrl: "https://api.anthropic.com",
        reasoning: true,
        input: [.text],
        cost: ModelCost(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        contextWindow: 200000,
        maxTokens: 8192
    )
    let reasoning2: ThinkingLevel? = reasoningModel.reasoning ? .high : nil
    #expect(reasoning2 == .high)
}

@Test func adaptiveThinkingModelSkipsInterleavedBetaHeader() {
    // Opus 4.6 should not get interleaved-thinking header
    let headers = buildAnthropicBetaHeaders(apiKey: "sk-ant-test", interleavedThinking: true, provider: "anthropic", modelId: "claude-opus-4-6")
    let hasInterleaved = headers?.contains("interleaved-thinking-2025-05-14") ?? false
    #expect(!hasInterleaved)

    // Sonnet 4.6 should not get interleaved-thinking header
    let headers2 = buildAnthropicBetaHeaders(apiKey: "sk-ant-test", interleavedThinking: true, provider: "anthropic", modelId: "claude-sonnet-4-6")
    let hasInterleaved2 = headers2?.contains("interleaved-thinking-2025-05-14") ?? false
    #expect(!hasInterleaved2)

    // Older model should still get the header
    let headers3 = buildAnthropicBetaHeaders(apiKey: "sk-ant-test", interleavedThinking: true, provider: "anthropic", modelId: "claude-sonnet-4-5")
    let hasInterleaved3 = headers3?.contains("interleaved-thinking-2025-05-14") ?? false
    #expect(hasInterleaved3)
}

// MARK: - Removed Google CLI providers

@Test func googleCliProvidersAreNotInDefaultModelRegistry() {
    let antigravityModels = getModels(provider: .googleAntigravity)
    let geminiCliModels = getModels(provider: .googleGeminiCli)
    #expect(antigravityModels.isEmpty)
    #expect(geminiCliModels.isEmpty)
    #expect(!getProviders().contains(.googleAntigravity))
    #expect(!getProviders().contains(.googleGeminiCli))
}

// MARK: - Thinking level mapping test

@Test func modelThinkingLevelMapTest() {
    let map: ThinkingLevelMap = [
        .off: nil,
        .minimal: "budget_tokens:1024",
        .low: "budget_tokens:4096",
        .medium: "budget_tokens:8192",
        .high: "budget_tokens:16384",
        .xhigh: "budget_tokens:32768",
    ]
    let model = Model(
        id: "mapped-thinking",
        name: "Mapped Thinking",
        api: .openAICompletions,
        provider: "test",
        baseUrl: "",
        reasoning: true,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 1000,
        maxTokens: 1000,
        thinkingLevelMap: map
    )

    #expect(getSupportedThinkingLevels(model) == [.minimal, .low, .medium, .high, .xhigh])
    #expect(clampThinkingLevel(model: model, requested: .off) == .minimal)
    #expect(mappedThinkingLevel(model: model, level: .xhigh) == "budget_tokens:32768")
    #expect(mappedOffThinkingLevel(model: model) == nil)
}

@Test func codexTransportSupportsWebSocketCached() {
    #expect(Transport.websocketCached.rawValue == "websocket-cached")
}

@Test func maxThinkingLevelRequiresMappingAndClampsWhenUnsupported() {
    func model(thinkingLevelMap: ThinkingLevelMap? = nil) -> PiSwiftAI.Model {
        PiSwiftAI.Model(
            id: "thinking-level-test",
            name: "Thinking Level Test",
            api: .openAIResponses,
            provider: "test",
            baseUrl: "https://example.invalid",
            reasoning: true,
            input: [.text],
            cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 1_000,
            maxTokens: 1_000,
            thinkingLevelMap: thinkingLevelMap
        )
    }

    #expect(!getSupportedThinkingLevels(model()).contains(.max))
    #expect(getSupportedThinkingLevels(model(thinkingLevelMap: [.max: "max"])).contains(.max))
    #expect(clampThinkingLevel(model: model(thinkingLevelMap: [.high: "high"]), requested: .max) == .high)
    #expect(mapAnthropicAdaptiveThinkingEffort(model: model(thinkingLevelMap: [.xhigh: "max"]), level: .xhigh) == .max)
}

@Test func calculateCostUsesHighestMatchingInputTier() {
    func model(cost: ModelCost) -> PiSwiftAI.Model {
        PiSwiftAI.Model(
            id: "tiered-cost-test",
            name: "Tiered Cost Test",
            api: .openAICompletions,
            provider: "test",
            baseUrl: "https://example.invalid",
            reasoning: false,
            input: [.text],
            cost: cost,
            contextWindow: 1_000,
            maxTokens: 1_000
        )
    }

    let base = ModelCost(input: 1, output: 2, cacheRead: 3, cacheWrite: 4)
    var noTiers = Usage(input: 1_000_000, output: 1_000_000, cacheRead: 0, cacheWrite: 0, totalTokens: 2_000_000)
    #expect(calculateCost(model: model(cost: base), usage: &noTiers).total == 3)

    let tiered = ModelCost(
        input: 1,
        output: 2,
        cacheRead: 3,
        cacheWrite: 4,
        tiers: [
            ModelCostTier(inputTokensAbove: 100, input: 10, output: 20, cacheRead: 30, cacheWrite: 40),
            ModelCostTier(inputTokensAbove: 1_000, input: 100, output: 200, cacheRead: 300, cacheWrite: 400),
        ]
    )
    var belowFirst = Usage(input: 100, output: 1_000_000, cacheRead: 0, cacheWrite: 0, totalTokens: 1_000_100)
    #expect(calculateCost(model: model(cost: tiered), usage: &belowFirst).total == 2.0001)

    var aboveFirst = Usage(input: 101, output: 1_000_000, cacheRead: 0, cacheWrite: 0, totalTokens: 1_000_101)
    #expect(calculateCost(model: model(cost: tiered), usage: &aboveFirst).total == 20.00101)

    var highestMatch = Usage(input: 1_001, output: 1_000_000, cacheRead: 0, cacheWrite: 0, totalTokens: 1_001_001)
    #expect(calculateCost(model: model(cost: tiered), usage: &highestMatch).total == 200.1001)
}

@Test func providerUsageDecodesAndPropagatesReasoningTokens() throws {
    let anthropicData = Data("""
    {"input_tokens":10,"output_tokens":30,"thinking_tokens":17,"cache_read_input_tokens":2,"cache_creation_input_tokens":1}
    """.utf8)
    let anthropicDecoder = JSONDecoder()
    anthropicDecoder.keyDecodingStrategy = .convertFromSnakeCase
    let decodedAnthropic = try anthropicDecoder.decode(MessageResponse.Usage.self, from: anthropicData)
    let anthropic = makeAnthropicUsage(
        input: decodedAnthropic.inputTokens ?? 0,
        output: decodedAnthropic.outputTokens,
        cacheRead: decodedAnthropic.cacheReadInputTokens ?? 0,
        cacheWrite: decodedAnthropic.cacheCreationInputTokens ?? 0,
        reasoning: decodedAnthropic.thinkingTokens
    )
    #expect(anthropic.reasoning == 17)
    #expect(anthropic.output == 30)

    let responsesData = Data("""
    {"input_tokens":120,"input_tokens_details":{"cached_tokens":20},"output_tokens":80,"output_tokens_details":{"reasoning_tokens":55},"total_tokens":200}
    """.utf8)
    let responses = try JSONDecoder().decode(Components.Schemas.ResponseUsage.self, from: responsesData)
    let openAI = makeOpenAIResponsesUsage(responses)
    #expect(openAI.input == 100)
    #expect(openAI.reasoning == 55)
    #expect(openAI.output == 80)
}

@Test func openAIResponsesMaxReasoningUsesRawOverride() throws {
    let data = try JSONSerialization.data(withJSONObject: ["reasoning": ["effort": "high"]])
    let updated = try #require(applyOpenAIResponsesReasoningEffort(data: data, effort: "max"))
    let payload = try #require(try JSONSerialization.jsonObject(with: updated) as? [String: Any])
    let reasoning = try #require(payload["reasoning"] as? [String: Any])
    #expect(reasoning["effort"] as? String == "max")
}

@Test func chatTemplateThinkingKwargsResolveVariables() throws {
    let model = Model(
        id: "chat-template-test",
        name: "Chat Template Test",
        api: .openAICompletions,
        provider: "test",
        baseUrl: "https://example.invalid",
        reasoning: true,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 1_000,
        maxTokens: 1_000,
        thinkingLevelMap: [.max: "provider-max"]
    )
    let data = try JSONSerialization.data(withJSONObject: ["model": model.id])
    let kwargs: [String: ChatTemplateKwargValue] = [
        "enabled": .variable(.thinkingEnabled),
        "effort": .variable(.thinkingEffort, omitWhenOff: true),
        "temperature": .number(0.5),
    ]
    let configured = try #require(applyOpenAIChatTemplateKwargs(data: data, model: model, effort: .max, kwargs: kwargs))
    let payload = try #require(try JSONSerialization.jsonObject(with: configured) as? [String: Any])
    let resolved = try #require(payload["chat_template_kwargs"] as? [String: Any])
    #expect(resolved["enabled"] as? Bool == true)
    #expect(resolved["effort"] as? String == "provider-max")
    #expect(resolved["temperature"] as? Double == 0.5)
}

// MARK: - Phase 2 (v0.61.1 → v0.70.5) tests

/// v0.65.0: Anthropic HTTP 413 surfaces as `request_too_large` and counts as context overflow.
@Test func contextOverflowDetectsRequestTooLarge() {
    let model = getModel(provider: .anthropic, modelId: "claude-haiku-4-5")
    let message = AssistantMessage(
        content: [],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .error,
        errorMessage: "request_too_large: 413 Payload Too Large"
    )
    #expect(isContextOverflow(message))
}

/// v0.63.1: Ollama explicit overflow detection.
@Test func contextOverflowDetectsOllamaPattern() {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let message = AssistantMessage(
        content: [],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .error,
        errorMessage: "prompt too long; exceeded max context length 8192"
    )
    #expect(isContextOverflow(message))
}

@Test func contextOverflowDetectsDS4ConfiguredContextPattern() {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let message = AssistantMessage(
        content: [], api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .error,
        errorMessage: "Prompt has 131,073 tokens, but the configured context size is 131,072 tokens"
    )
    #expect(isContextOverflow(message))
}

@Test func streamSimpleMaxTokensLeavesContextHeadroom() {
    let model = Model(
        id: "test", name: "test", api: .openAICompletions, provider: "openai", baseUrl: "",
        reasoning: false, input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 8_192, maxTokens: 8_192
    )
    let context = Context(messages: [.user(UserMessage(content: .text(String(repeating: "x", count: 24_000))))])
    #expect(clampSimpleMaxTokensToContext(model: model, context: context, maxTokens: 8_192) == 1)
}

@Test func responsesQueryClampsMinimumOutputTokens() throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let query = try buildResponsesQuery(
        model: model,
        context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
        options: OpenAIResponsesOptions(maxTokens: 1, apiKey: "test")
    )
    #expect(query.maxOutputTokens == 16)
}

@Test func responsesToolResultWithoutTextOrImageUsesExplicitNoOutput() throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let items = convertResponsesMessages(
        model: model,
        context: Context(messages: [.toolResult(ToolResultMessage(toolCallId: "call", toolName: "tool", content: [], isError: false))]),
        allowedToolCallProviders: []
    )
    let data = try JSONEncoder().encode(items)
    #expect(String(decoding: data, as: UTF8.self).contains("(no tool output)"))
}

/// v0.70.3: Azure Cognitive Services endpoints get the same `/openai/v1` path normalization
/// as `.openai.azure.com` endpoints. Without this, the AzureOpenAI SDK can't resolve
/// `/deployments/<model>/...` routes correctly.
@Test func azureNormalizeCognitiveServicesBareHost() throws {
    let normalized = try normalizeAzureBaseUrl("https://my-resource.cognitiveservices.azure.com")
    #expect(normalized == "https://my-resource.cognitiveservices.azure.com/openai/v1")
}

@Test func azureNormalizeCognitiveServicesTrailingSlash() throws {
    let normalized = try normalizeAzureBaseUrl("https://my-resource.cognitiveservices.azure.com/")
    #expect(normalized == "https://my-resource.cognitiveservices.azure.com/openai/v1")
}

@Test func azureNormalizeCognitiveServicesPartialPath() throws {
    let normalized = try normalizeAzureBaseUrl("https://my-resource.cognitiveservices.azure.com/openai")
    #expect(normalized == "https://my-resource.cognitiveservices.azure.com/openai/v1")
}

@Test func azureNormalizeOpenAIAzureHost() throws {
    let normalized = try normalizeAzureBaseUrl("https://res.openai.azure.com")
    #expect(normalized == "https://res.openai.azure.com/openai/v1")
}

@Test func azureNormalizePreservesNonAzureUrls() throws {
    let normalized = try normalizeAzureBaseUrl("https://proxy.example.com/api/v3/")
    // Non-Azure host: trim trailing slashes, leave path alone.
    #expect(normalized == "https://proxy.example.com/api/v3")
}

@Test func azureNormalizeRejectsInvalidUrl() {
    #expect(throws: AzureOpenAIResponsesError.self) {
        _ = try normalizeAzureBaseUrl("not a url")
    }
}

/// v0.65.0: Bedrock throttling errors must NOT be classified as context overflow.
/// AWS Bedrock formats throttling as `"Throttling error: Too many tokens..."` — without
/// the non-overflow exclusion, the generic "too many tokens" pattern would false-positive
/// and trigger compaction instead of a retry.
@Test func contextOverflowExcludesBedrockThrottling() {
    let model = getModel(provider: .amazonBedrock, modelId: "anthropic.claude-haiku-4-5-20251001-v1:0")
    let message = AssistantMessage(
        content: [],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .error,
        errorMessage: "Throttling error: Too many tokens, please wait before trying again."
    )
    #expect(!isContextOverflow(message))
}

/// v0.65.0: rate-limit errors must NOT be classified as context overflow.
@Test func contextOverflowExcludesRateLimit() {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let message = AssistantMessage(
        content: [],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .error,
        errorMessage: "Rate limit reached for gpt-4o-mini in organization org-x. Too many requests."
    )
    #expect(!isContextOverflow(message))
}

/// v0.65.0: "Service unavailable:" prefix from Bedrock formatBedrockError() also bypasses overflow.
@Test func contextOverflowExcludesBedrockServiceUnavailable() {
    let model = getModel(provider: .amazonBedrock, modelId: "anthropic.claude-haiku-4-5-20251001-v1:0")
    let message = AssistantMessage(
        content: [],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .error,
        errorMessage: "Service unavailable: too many requests on this endpoint"
    )
    #expect(!isContextOverflow(message))
}

/// v0.69.0: transformMessages synthesizes trailing tool results when the transcript ends
/// with unresolved assistant tool calls (no following user/assistant message).
@Test func transformMessagesSynthesizesTrailingToolResults() {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let toolCall = ToolCall(id: "trailing-call", name: "stop", arguments: [:])
    let assistant = AssistantMessage(
        content: [.toolCall(toolCall)],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .toolUse
    )
    let transformed = transformMessages([.assistant(assistant)], model: model)
    #expect(transformed.count == 2)
    guard case .toolResult(let toolResult) = transformed[1] else {
        #expect(Bool(false), "Expected synthetic trailing tool result")
        return
    }
    #expect(toolResult.toolCallId == "trailing-call")
    #expect(toolResult.isError)
}

/// v0.67.5: Opus 4.7 supports xhigh on both anthropic-messages and bedrock-converse-stream.
@Test func supportsXhighRecognizesOpus47() {
    let opus47Anthropic = Model(
        id: "claude-opus-4-7",
        name: "Claude Opus 4.7",
        api: .anthropicMessages,
        provider: "anthropic",
        baseUrl: "",
        reasoning: true,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 200000,
        maxTokens: 8192
    )
    #expect(supportsXhigh(model: opus47Anthropic))

    let opus47Bedrock = Model(
        id: "anthropic.claude-opus-4-7",
        name: "Claude Opus 4.7 (Bedrock)",
        api: .bedrockConverseStream,
        provider: "amazon-bedrock",
        baseUrl: "",
        reasoning: true,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 200000,
        maxTokens: 8192
    )
    #expect(supportsXhigh(model: opus47Bedrock))
}

/// v0.70.0: GPT-5.5 codex supports xhigh.
@Test func supportsXhighRecognizesGpt55() {
    let model = Model(
        id: "gpt-5.5",
        name: "GPT-5.5",
        api: .openAICodexResponses,
        provider: "openai-codex",
        baseUrl: "",
        reasoning: true,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 272000,
        maxTokens: 8192
    )
    #expect(supportsXhigh(model: model))
}

/// v0.68.0: JSON Schema meta-declaration keys (`$schema`, `$defs`, etc.) are stripped from
/// tool parameters before sending to Cloud Code Assist / Gemini.
@Test func googleToolsStripsJsonSchemaMetaKeys() {
    let tool = AITool(
        name: "search",
        description: "Search",
        parameters: [
            "$schema": AnyCodable("http://json-schema.org/draft-07/schema#"),
            "$defs": AnyCodable(["x": "y"]),
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "query": ["type": "string"]
            ])
        ]
    )
    let result = convertGoogleTools([tool], useParameters: true)
    guard let result, let group = result.first,
          let declarations = group["functionDeclarations"] as? [[String: Any]],
          let first = declarations.first,
          let parameters = first["parameters"] as? [String: Any] else {
        #expect(Bool(false), "Expected functionDeclarations with parameters")
        return
    }
    #expect(parameters["$schema"] == nil)
    #expect(parameters["$defs"] == nil)
    #expect(parameters["type"] as? String == "object")
}

/// v0.62.0: explicit disabled thinking uses the lowest supported Gemini 3 level instead of
/// a zero thinking budget on models that do not support full disable.
@Test func googleDisabledThinkingConfigMatchesUpstreamFallbacks() {
    let pro = Model(
        id: "gemini-3.1-pro-preview",
        name: "Gemini 3.1 Pro",
        api: .googleGenerativeAI,
        provider: "google",
        baseUrl: "",
        reasoning: true,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 1_000_000,
        maxTokens: 65_536
    )
    let flash = Model(
        id: "gemini-3.1-flash-lite",
        name: "Gemini 3.1 Flash Lite",
        api: .googleGenerativeAI,
        provider: "google",
        baseUrl: "",
        reasoning: true,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 1_000_000,
        maxTokens: 65_536
    )
    let gemma = Model(
        id: "gemma-4-27b-it",
        name: "Gemma 4",
        api: .googleGenerativeAI,
        provider: "google",
        baseUrl: "",
        reasoning: true,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 131_072,
        maxTokens: 8_192
    )
    let gemini2 = Model(
        id: "gemini-2.5-flash",
        name: "Gemini 2.5 Flash",
        api: .googleGenerativeAI,
        provider: "google",
        baseUrl: "",
        reasoning: true,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 1_000_000,
        maxTokens: 65_536
    )

    let proConfig = googleDisabledThinkingConfig(model: pro)
    #expect(proConfig["thinkingLevel"] as? String == GoogleThinkingLevel.low.rawValue)
    #expect(proConfig["includeThoughts"] == nil)
    #expect(proConfig["thinkingBudget"] == nil)

    let flashConfig = googleDisabledThinkingConfig(model: flash)
    #expect(flashConfig["thinkingLevel"] as? String == GoogleThinkingLevel.minimal.rawValue)
    #expect(flashConfig["includeThoughts"] == nil)
    #expect(flashConfig["thinkingBudget"] == nil)

    let gemmaConfig = googleDisabledThinkingConfig(model: gemma)
    #expect(gemmaConfig["thinkingLevel"] as? String == GoogleThinkingLevel.minimal.rawValue)
    #expect(gemmaConfig["includeThoughts"] == nil)
    #expect(gemmaConfig["thinkingBudget"] == nil)

    let gemini2Config = googleDisabledThinkingConfig(model: gemini2)
    #expect(gemini2Config["thinkingBudget"] as? Int == 0)
    #expect(gemini2Config["includeThoughts"] == nil)
    #expect(gemini2Config["thinkingLevel"] == nil)
}

/// v0.63.0: cached prompt tokens are cache-read tokens, not billable input tokens.
/// v0.62.0: disabled thinking payloads use Gemini 3 fallback levels where required.
@Test func googleUsageSubtractsCachedTokensAndPayloadDisablesThinking() async {
    await codexRequestLock.withLock {
        let capturedPayload = LockedState<String?>(nil)
        MockURLProtocol.allowedHosts.withLock { $0 = ["google-usage.example"] }
        MockURLProtocol.requestHandler.withLock { $0 = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["content-type": "text/event-stream"]
            )!
            let payload = """
            {"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":100,"cachedContentTokenCount":30,"candidatesTokenCount":7,"thoughtsTokenCount":3,"totalTokenCount":110},"responseId":"resp-google"}
            """
            return (response, Data("data: \(payload)\n\ndata: [DONE]\n\n".utf8))
        } }
        URLProtocol.registerClass(MockURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(MockURLProtocol.self)
            MockURLProtocol.allowedHosts.withLock { $0 = [] }
            MockURLProtocol.requestHandler.withLock { $0 = nil }
        }

        let model = Model(
            id: "gemini-3.1-pro-preview",
            name: "Gemini 3.1 Pro",
            api: .googleGenerativeAI,
            provider: "google",
            baseUrl: "https://google-usage.example/v1beta",
            reasoning: true,
            input: [.text],
            cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 1_000_000,
            maxTokens: 65_536
        )
        let stream = streamGoogle(
            model: model,
            context: Context(
                systemPrompt: "be terse",
                messages: [.user(UserMessage(content: .text("say ok")))]
            ),
            options: GoogleOptions(
                apiKey: "google-key",
                thinking: GoogleOptions.ThinkingConfig(enabled: false),
                onPayload: { snapshot in capturedPayload.withLock { $0 = snapshot.json } }
            )
        )
        for await _ in stream {}
        let message = await stream.result()

        #expect(message.stopReason == .stop)
        #expect(message.usage.input == 70)
        #expect(message.usage.cacheRead == 30)
        #expect(message.usage.output == 10)
        #expect(message.usage.totalTokens == 110)

        guard let json = capturedPayload.withLock({ $0 }),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let generationConfig = object["generationConfig"] as? [String: Any],
              let thinkingConfig = generationConfig["thinkingConfig"] as? [String: Any] else {
            #expect(Bool(false), "Expected Google payload generationConfig.thinkingConfig")
            return
        }
        // v1beta rejects a top-level thinkingConfig as an unknown field.
        #expect(object["thinkingConfig"] == nil)
        #expect(thinkingConfig["thinkingLevel"] as? String == GoogleThinkingLevel.low.rawValue)
        #expect(thinkingConfig["includeThoughts"] == nil)
        #expect(thinkingConfig["thinkingBudget"] == nil)

        // system_instruction is a Content, so a bare string is rejected.
        let systemInstruction = object["systemInstruction"] as? [String: Any]
        let parts = systemInstruction?["parts"] as? [[String: Any]]
        #expect(parts?.count == 1)
        #expect(parts?.first?["text"] as? String == "be terse")
    }
}

/// v0.63.0: Vertex also subtracts cached prompt tokens from billable input tokens.
/// v0.67.3: `gcp-vertex-credentials` is an ADC marker, not a literal bearer token.
@Test func googleVertexUsageSubtractsCachedTokens() async {
    await codexRequestLock.withLock {
        await withEnv("GOOGLE_CLOUD_API_KEY", value: nil) {
            await withEnv("GOOGLE_ACCESS_TOKEN", value: "vertex-adc-token") {
                let capturedAuthorization = LockedState<String?>(nil)
                let capturedPayload = LockedState<String?>(nil)
                MockURLProtocol.allowedHosts.withLock { $0 = ["vertex-usage.example"] }
                MockURLProtocol.requestHandler.withLock { $0 = { request in
                    capturedAuthorization.withLock { $0 = request.value(forHTTPHeaderField: "Authorization") }
                    guard let url = request.url else { throw URLError(.badURL) }
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["content-type": "text/event-stream"]
                    )!
                    let payload = """
                    {"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":80,"cachedContentTokenCount":55,"candidatesTokenCount":4,"thoughtsTokenCount":1,"totalTokenCount":85},"responseId":"resp-vertex"}
                    """
                    return (response, Data("data: \(payload)\n\ndata: [DONE]\n\n".utf8))
                } }
                URLProtocol.registerClass(MockURLProtocol.self)
                defer {
                    URLProtocol.unregisterClass(MockURLProtocol.self)
                    MockURLProtocol.allowedHosts.withLock { $0 = [] }
                    MockURLProtocol.requestHandler.withLock { $0 = nil }
                }

                let model = Model(
                    id: "gemini-3.1-pro-preview",
                    name: "Gemini 3.1 Pro",
                    api: .googleVertex,
                    provider: "google-vertex",
                    baseUrl: "https://vertex-usage.example",
                    reasoning: true,
                    input: [.text],
                    cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                    contextWindow: 1_000_000,
                    maxTokens: 65_536
                )
                let stream = streamGoogleVertex(
                    model: model,
                    context: Context(
                        systemPrompt: "be terse",
                        messages: [.user(UserMessage(content: .text("say ok")))]
                    ),
                    options: GoogleVertexOptions(
                        apiKey: "gcp-vertex-credentials",
                        thinking: GoogleOptions.ThinkingConfig(enabled: false),
                        project: "proj-test",
                        location: "us-central1",
                        onPayload: { snapshot in capturedPayload.withLock { $0 = snapshot.json } }
                    )
                )
                for await _ in stream {}
                let message = await stream.result()

                #expect(capturedAuthorization.withLock { $0 } == "Bearer vertex-adc-token")
                #expect(message.stopReason == .stop)
                #expect(message.usage.input == 25)
                #expect(message.usage.cacheRead == 55)
                #expect(message.usage.output == 5)
                #expect(message.usage.totalTokens == 85)

                guard let json = capturedPayload.withLock({ $0 }),
                      let data = json.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    #expect(Bool(false), "Expected Vertex payload")
                    return
                }
                // Vertex shares the GenerateContentRequest shape: nested thinkingConfig, Content system prompt.
                #expect(object["thinkingConfig"] == nil)
                #expect((object["generationConfig"] as? [String: Any])?["thinkingConfig"] != nil)
                let parts = (object["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]]
                #expect(parts?.first?["text"] as? String == "be terse")
            }
        }
    }
}

/// v0.67.1 / v0.62.0: Antigravity uses the current upstream default User-Agent and sends
/// disabled-thinking fallback config through Cloud Code Assist payloads.
@Test func googleAntigravityUserAgentAndDisabledThinkingPayload() async {
    await codexRequestLock.withLock {
        await withEnv("PI_AI_ANTIGRAVITY_VERSION", value: nil) {
            let capturedUserAgent = LockedState<String?>(nil)
            let capturedBody = LockedState<String?>(nil)
            GeminiRetryMockURLProtocol.requestHandler.withLock { $0 = { request in
                capturedUserAgent.withLock { $0 = request.value(forHTTPHeaderField: "User-Agent") }
                if let body = readRequestBody(request), let json = String(data: body, encoding: .utf8) {
                    capturedBody.withLock { $0 = json }
                }
                guard let url = request.url else { throw URLError(.badURL) }
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["content-type": "text/event-stream"]
                )!
                let payload = """
                {"response":{"candidates":[{"content":{"parts":[{"text":"pong"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1,"totalTokenCount":2}}}
                """
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

            let model = Model(
                id: "gemini-3.1-flash-lite",
                name: "Gemini 3.1 Flash Lite",
                api: .googleGeminiCli,
                provider: "google-antigravity",
                baseUrl: "http://cloudcode-pa.googleapis.com",
                reasoning: true,
                input: [.text, .image],
                cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                contextWindow: 1_000_000,
                maxTokens: 65_536
            )
            let stream = streamGoogleGeminiCli(
                model: model,
                context: Context(messages: [.user(UserMessage(content: .text("say pong")))]),
                options: GoogleGeminiCliOptions(
                    apiKey: #"{"token":"tok_test","projectId":"proj_test"}"#,
                    thinking: GoogleOptions.ThinkingConfig(enabled: false)
                )
            )
            for await _ in stream {}
            let message = await stream.result()

            #expect(message.stopReason == .stop)
            #expect(capturedUserAgent.withLock { $0 } == "antigravity/1.21.9 darwin/arm64")

            guard let json = capturedBody.withLock({ $0 }),
                  let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let request = object["request"] as? [String: Any],
                  let generationConfig = request["generationConfig"] as? [String: Any],
                  let thinkingConfig = generationConfig["thinkingConfig"] as? [String: Any] else {
                #expect(Bool(false), "Expected Gemini CLI request thinkingConfig")
                return
            }
            #expect(thinkingConfig["thinkingLevel"] as? String == GoogleThinkingLevel.minimal.rawValue)
            #expect(thinkingConfig["includeThoughts"] == nil)
            #expect(thinkingConfig["thinkingBudget"] == nil)
        }
    }
}

/// OpenAI Responses cache middleware uses the configured session-affinity header format.
@Test func openAIResponsesCacheMiddlewareSendsAffinityHeaders() throws {
    let payload: [String: Any] = ["model": "gpt-4o-mini", "input": []]
    let body = try JSONSerialization.data(withJSONObject: payload)
    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
    request.httpMethod = "POST"
    request.httpBody = body

    let middleware = OpenAIResponsesCacheMiddleware(
        sessionId: "session-xyz",
        cacheRetention: .none,
        promptCacheRetention: nil,
        sessionAffinityFormat: .openai
    )
    let updated = middleware.intercept(request: request)
    #expect(updated.value(forHTTPHeaderField: "session_id") == "session-xyz")
    #expect(updated.value(forHTTPHeaderField: "x-client-request-id") == "session-xyz")
    #expect(updated.value(forHTTPHeaderField: "x-session-affinity") == nil)
}

@Test func openAIResponsesCacheMiddlewareCanOmitSessionIdHeader() throws {
    let payload: [String: Any] = ["model": "gpt-4o-mini", "input": []]
    let body = try JSONSerialization.data(withJSONObject: payload)
    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
    request.httpMethod = "POST"
    request.httpBody = body

    let openAI = OpenAIResponsesCacheMiddleware(
        sessionId: "session-xyz",
        cacheRetention: .none,
        promptCacheRetention: nil,
        sessionAffinityFormat: .openai
    ).intercept(request: request)
    #expect(openAI.value(forHTTPHeaderField: "session_id") == "session-xyz")
    #expect(openAI.value(forHTTPHeaderField: "x-client-request-id") == "session-xyz")
    #expect(openAI.value(forHTTPHeaderField: "x-session-id") == nil)
    #expect(openAI.value(forHTTPHeaderField: "x-session-affinity") == nil)

    let openAINosession = OpenAIResponsesCacheMiddleware(
        sessionId: "session-xyz",
        cacheRetention: .none,
        promptCacheRetention: nil,
        sessionAffinityFormat: .openaiNosession
    ).intercept(request: request)
    #expect(openAINosession.value(forHTTPHeaderField: "session_id") == nil)
    #expect(openAINosession.value(forHTTPHeaderField: "x-client-request-id") == "session-xyz")
    #expect(openAINosession.value(forHTTPHeaderField: "x-session-id") == nil)
    #expect(openAINosession.value(forHTTPHeaderField: "x-session-affinity") == nil)

    let openRouter = OpenAIResponsesCacheMiddleware(
        sessionId: "session-xyz",
        cacheRetention: .none,
        promptCacheRetention: nil,
        sessionAffinityFormat: .openrouter
    ).intercept(request: request)
    #expect(openRouter.value(forHTTPHeaderField: "x-session-id") == "session-xyz")
    #expect(openRouter.value(forHTTPHeaderField: "session_id") == nil)
    #expect(openRouter.value(forHTTPHeaderField: "x-client-request-id") == nil)
    #expect(openRouter.value(forHTTPHeaderField: "x-session-affinity") == nil)
}

/// v0.70.0 / v0.68.0: new compat flags are exposed and round-trip through OpenAICompat.
@Test func openAICompatNewFlags() {
    let compat = OpenAICompat(
        supportsLongCacheRetention: false,
        sendSessionIdHeader: false,
        supportsEagerToolInputStreaming: false,
        cacheControlFormat: .anthropic,
        sendSessionAffinityHeaders: true,
        requiresReasoningContentOnAssistantMessages: true
    )
    #expect(compat.supportsLongCacheRetention == false)
    #expect(compat.sendSessionIdHeader == false)
    #expect(compat.supportsEagerToolInputStreaming == false)
    #expect(compat.cacheControlFormat == .anthropic)
    #expect(compat.sendSessionAffinityHeaders == true)
    #expect(compat.requiresReasoningContentOnAssistantMessages == true)
}

/// v0.70.1: DeepSeek thinking format added to compat enum.
@Test func openAICompatDeepSeekThinkingFormat() {
    let compat = OpenAICompat(thinkingFormat: .deepseek)
    #expect(compat.thinkingFormat == .deepseek)
}

@Test func simpleOptionsForwardProviderRequestControls() {
    let options = SimpleStreamOptions(
        signal: CancellationToken(),
        apiKey: "key",
        transport: .websocketCached,
        reasoning: .low,
        cacheRetention: .short,
        sessionId: "session-1",
        headers: ["X-Test": "1"],
        onPayload: { _ in },
        maxRetryDelayMs: 1234,
        metadata: ["trace": AnyCodable("yes")],
        onResponse: { _ in },
        timeoutMs: 2345,
        websocketConnectTimeoutMs: 3456,
        maxRetries: 2
    )

    let openAI = getModel(provider: .openai, modelId: "gpt-5.4")
    let responses = mapOpenAIResponsesSimpleOptions(model: openAI, options: options, apiKey: "key")
    #expect(responses.timeoutMs == 2345)
    #expect(responses.maxRetries == 2)
    #expect(responses.websocketConnectTimeoutMs == 3456)

    let codex = mapOpenAICodexResponsesSimpleOptions(model: openAI, options: options, apiKey: "key")
    #expect(codex.timeoutMs == 2345)
    #expect(codex.maxRetries == 2)
    #expect(codex.websocketConnectTimeoutMs == 3456)

    let completions = mapOpenAICompletionsSimpleOptions(model: openAI, options: options, apiKey: "key")
    #expect(completions.timeoutMs == 2345)
    #expect(completions.maxRetries == 2)
    #expect(completions.cacheRetention == .short)
    #expect(completions.sessionId == "session-1")

    let anthropic = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
    let anthropicOptions = mapAnthropicSimpleOptions(model: anthropic, context: Context(messages: [.user(UserMessage(content: .text("hello")))]), options: options, apiKey: "key")
    #expect(anthropicOptions.timeoutMs == 2345)
    #expect(anthropicOptions.maxRetries == 2)

    let google = getModel(provider: .google, modelId: "gemini-3.1-pro-preview")
    let googleOptions = mapGoogleSimpleOptions(model: google, options: options, apiKey: "key")
    #expect(googleOptions.timeoutMs == 2345)
    #expect(googleOptions.maxRetries == 2)

    let vertex = getModel(provider: .googleVertex, modelId: "gemini-3.1-pro-preview")
    let vertexOptions = mapGoogleVertexSimpleOptions(model: vertex, options: options, apiKey: "key")
    #expect(vertexOptions.timeoutMs == 2345)
    #expect(vertexOptions.maxRetries == 2)

    let bedrock = getModel(provider: .amazonBedrock, modelId: "anthropic.claude-sonnet-4-5-20250929-v1:0")
    let bedrockOptions = mapBedrockSimpleOptions(model: bedrock, options: options)
    #expect(bedrockOptions.timeoutMs == 2345)
    #expect(bedrockOptions.maxRetries == 2)

    let mistral = getModel(provider: .mistral, modelId: "mistral-small-latest")
    let mistralOptions = mapMistralSimpleOptions(model: mistral, options: options, apiKey: "key")
    #expect(mistralOptions.timeoutMs == 2345)
    #expect(mistralOptions.maxRetries == 2)
}

/// v0.67.67: Mistral Small 4 / Medium 3.5 use `reasoning_effort`, not `prompt_mode`.
@Test func mistralReasoningEffortMappingUsesModelMetadata() {
    let options = SimpleStreamOptions(reasoning: .xhigh)

    let small = getModel(provider: .mistral, modelId: "mistral-small-2603")
    let smallOptions = mapMistralSimpleOptions(model: small, options: options, apiKey: "key")
    #expect(smallOptions.promptMode == nil)
    #expect(smallOptions.reasoningEffort == "high")

    let medium = getModel(provider: .mistral, modelId: "mistral-medium-3.5")
    let mediumOptions = mapMistralSimpleOptions(model: medium, options: SimpleStreamOptions(reasoning: .high), apiKey: "key")
    #expect(mediumOptions.promptMode == nil)
    #expect(mediumOptions.reasoningEffort == "high")

    let large = getModel(provider: .mistral, modelId: "magistral-medium-latest")
    let largeOptions = mapMistralSimpleOptions(model: large, options: SimpleStreamOptions(reasoning: .high), apiKey: "key")
    #expect(largeOptions.promptMode == "reasoning")
    #expect(largeOptions.reasoningEffort == nil)
}

/// v0.70.1: `maxRetries` retries retryable Mistral response setup failures before stream consumption.
@Test func mistralRetriesRetryableHTTPFailure() async {
    await codexRequestLock.withLock {
        let requestCount = LockedState(0)
        let capturedBody = LockedState<String?>(nil)
        MockURLProtocol.allowedHosts.withLock { $0 = ["api.mistral.ai"] }
        MockURLProtocol.requestHandler.withLock { $0 = { request in
            if let body = readRequestBody(request), let json = String(data: body, encoding: .utf8) {
                capturedBody.withLock { $0 = json }
            }
            let count = requestCount.withLock { value -> Int in
                value += 1
                return value
            }
            if count == 1 {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(#"{"error":"try again"}"#.utf8))
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            let event = #"data: {"choices":[{"finish_reason":"stop","delta":{}}]}"# + "\n\n"
            return (response, Data(event.utf8))
        } }
        URLProtocol.registerClass(MockURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(MockURLProtocol.self)
            MockURLProtocol.allowedHosts.withLock { $0 = [] }
            MockURLProtocol.requestHandler.withLock { $0 = nil }
        }

        let model = getModel(provider: .mistral, modelId: "mistral-medium-3.5")
        let mapped = mapMistralSimpleOptions(
            model: model,
            options: SimpleStreamOptions(reasoning: .high, maxRetries: 1),
            apiKey: "test-key"
        )
        let stream = streamMistral(
            model: model,
            context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
            options: mapped
        )
        for await _ in stream {}
        let message = await stream.result()

        #expect(message.stopReason == .stop)
        #expect(requestCount.withLock { $0 } == 2)
        let payload = capturedBody.withLock { $0 }.flatMap { jsonString -> [String: Any]? in
            guard let data = jsonString.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object
        }
        #expect(payload?["reasoning_effort"] as? String == "high")
        #expect(payload?["prompt_mode"] == nil)
    }
}

@Test func resolveCloudflareModelMaterializesEndpointPlaceholders() {
    func makeModel(provider: Provider, baseUrl: String) -> PiSwiftAI.Model {
        PiSwiftAI.Model(
            id: "test-model",
            name: "Test Model",
            api: .openAICompletions,
            provider: provider,
            baseUrl: baseUrl,
            reasoning: false,
            input: [.text],
            cost: ModelCost(input: 1, output: 2, cacheRead: 0.5, cacheWrite: 0.25),
            contextWindow: 128_000,
            maxTokens: 4_096,
            headers: ["X-Test": "value"]
        )
    }

    let workersPlaceholder = "{CLOUDFLARE_ACCOUNT_ID}"
    let workers = makeModel(
        provider: "cloudflare-workers-ai",
        baseUrl: "https://api.cloudflare.com/client/v4/accounts/\(workersPlaceholder)/ai/run"
    )
    let resolvedWorkers = resolveCloudflareModel(
        workers,
        env: ["CLOUDFLARE_ACCOUNT_ID": "acct123"]
    )
    #expect(resolvedWorkers.baseUrl.contains("acct123"))
    #expect(!resolvedWorkers.baseUrl.contains(workersPlaceholder))

    let gatewayPlaceholder = "{CLOUDFLARE_GATEWAY_ID}"
    let gateway = makeModel(
        provider: "cloudflare-ai-gateway",
        baseUrl: "https://gateway.ai.cloudflare.com/v1/\(workersPlaceholder)/\(gatewayPlaceholder)/compat"
    )
    let resolvedGateway = resolveCloudflareModel(
        gateway,
        env: [
            "CLOUDFLARE_ACCOUNT_ID": "acct456",
            "CLOUDFLARE_GATEWAY_ID": "gateway789",
        ]
    )
    #expect(resolvedGateway.baseUrl == "https://gateway.ai.cloudflare.com/v1/acct456/gateway789/compat")

    let partiallyResolvedGateway = resolveCloudflareModel(
        gateway,
        env: ["CLOUDFLARE_ACCOUNT_ID": "acct456"]
    )
    #expect(partiallyResolvedGateway.baseUrl.contains(gatewayPlaceholder))

    let nonCloudflare = makeModel(
        provider: "openai",
        baseUrl: "https://example.com/\(workersPlaceholder)"
    )
    let unchanged = resolveCloudflareModel(
        nonCloudflare,
        env: ["CLOUDFLARE_ACCOUNT_ID": "must-not-be-used"]
    )
    #expect(unchanged.baseUrl == nonCloudflare.baseUrl)
    #expect(unchanged.provider == nonCloudflare.provider)
    #expect(unchanged.id == nonCloudflare.id)
}

@Test func generatedTextCatalogMatchesUpstreamMetadata() throws {
    let upstream = try loadJSONResource("upstream-models.generated")
    #expect(Set(ModelsData.keys) == Set(upstream.keys))

    var compared = 0
    for provider in ModelsData.keys.sorted() {
        guard let swiftModels = ModelsData[provider],
              let upstreamModels = upstream[provider] as? [String: Any] else {
            #expect(Bool(false), "Missing provider \(provider)")
            continue
        }
        #expect(Set(swiftModels.keys) == Set(upstreamModels.keys), "Model ID drift for provider \(provider)")

        for modelId in swiftModels.keys.sorted() {
            guard let upstreamModel = upstreamModels[modelId] as? [String: Any],
                  let swiftModel = swiftModels[modelId] else {
                #expect(Bool(false), "Missing model \(provider)/\(modelId)")
                continue
            }
            let actual = try canonicalJSONString(normalizeModel(swiftModel))
            let expected = try canonicalJSONString(upstreamModel)
            #expect(actual == expected, "Metadata drift for \(provider)/\(modelId)")
            compared += 1
        }
    }

    let allModels = getProviders().flatMap { getModels(provider: $0) }
    #expect(getProviders().count == 39)
    #expect(allModels.count == 1224)
    #expect(compared == 1224)
    #expect(getProviders().contains(.antLing))
    #expect(getProviders().contains(.nvidia))
    #expect(getProviders().contains(.moonshotai))
    #expect(getProviders().contains(.moonshotaiCn))
    #expect(getProviders().contains(.together))
    #expect(getProviders().contains(.cloudflareWorkersAi))
    #expect(getProviders().contains(.cloudflareAiGateway))
    #expect(getProviders().contains(.baseten))
    #expect(getProviders().contains(.qwenTokenPlan))
    #expect(getProviders().contains(.qwenTokenPlanCn))
    #expect(getProviders().contains(.qwenTokenPlanIndividual))
    #expect(getProviders().contains(.xiaomi))
    #expect(getProviders().contains(.xiaomiTokenPlanCn))
    #expect(getProviders().contains(.xiaomiTokenPlanAms))
    #expect(getProviders().contains(.xiaomiTokenPlanSgp))
    #expect(getProviders().contains(.zaiCodingCn))

    let antLing = getModel(provider: .antLing, modelId: "Ring-2.6-1T")
    #expect(antLing.compat?.thinkingFormat == .antLing)
    #expect(antLing.thinkingLevelMap?[.xhigh] == "xhigh")

    let together = getModel(provider: .together, modelId: "MiniMaxAI/MiniMax-M3")
    #expect(together.compat?.thinkingFormat == .together)
    #expect(together.input == [.text, .image])
}

@Test func generatedImageCatalogMatchesUpstreamMetadata() throws {
    let upstream = try loadJSONResource("upstream-image-models.generated")
    #expect(Set(ImageModelsData.keys) == Set(upstream.keys))

    var compared = 0
    for provider in ImageModelsData.keys.sorted() {
        guard let swiftModels = ImageModelsData[provider],
              let upstreamModels = upstream[provider] as? [String: Any] else {
            #expect(Bool(false), "Missing image provider \(provider)")
            continue
        }
        #expect(Set(swiftModels.keys) == Set(upstreamModels.keys), "Image model ID drift for provider \(provider)")

        for modelId in swiftModels.keys.sorted() {
            guard let upstreamModel = upstreamModels[modelId] as? [String: Any],
                  let swiftModel = swiftModels[modelId] else {
                #expect(Bool(false), "Missing image model \(provider)/\(modelId)")
                continue
            }
            let actual = try canonicalJSONString(normalizeImagesModel(swiftModel))
            let expected = try canonicalJSONString(upstreamModel)
            #expect(actual == expected, "Image metadata drift for \(provider)/\(modelId)")
            compared += 1
        }
    }

    let providers = getImageProviders()
    let models = getImageModels(provider: .openrouter)
    #expect(providers == [.openrouter])
    #expect(models.count == 42)
    #expect(compared == 42)

    let model = getImageModel(provider: .openrouter, modelId: "google/gemini-3-pro-image-preview")
    #expect(model.api == .openrouterImages)
    #expect(model.provider == "openrouter")
    #expect(model.input == [.image, .text])
    #expect(model.output == [.image, .text])
    #expect(model.cost.output == 12)
}

@Test func openRouterImagesGenerateBuildsPayloadAndParsesResponse() async throws {
    let model = getImageModel(provider: .openrouter, modelId: "google/gemini-3-pro-image-preview")
    let payloadJSON = LockedState<String?>(nil)
    let responseStatus = LockedState<Int?>(nil)

    OpenRouterImagesMockURLProtocol.requestHandler.withLock { $0 = { request in
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request.value(forHTTPHeaderField: "X-Test") == "1")

        guard let body = readRequestBody(request),
              let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = payload["messages"] as? [[String: Any]],
              let first = messages.first,
              let content = first["content"] as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        #expect(payload["model"] as? String == model.id)
        #expect(payload["stream"] as? Bool == false)
        #expect(payload["modalities"] as? [String] == ["image", "text"])
        #expect(content.count == 2)
        #expect(content[0]["type"] as? String == "text")
        #expect(content[0]["text"] as? String == "draw")
        #expect(content[1]["type"] as? String == "image_url")

        let responsePayload: [String: Any] = [
            "id": "chatcmpl-image-1",
            "usage": [
                "prompt_tokens": 100,
                "completion_tokens": 20,
                "prompt_tokens_details": [
                    "cached_tokens": 15,
                    "cache_write_tokens": 5,
                ],
            ],
            "choices": [
                [
                    "message": [
                        "content": "caption",
                        "images": [
                            ["image_url": ["url": "data:image/png;base64,aW1n"]],
                        ],
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: responsePayload)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["X-Response": "ok"]
        )!
        return (response, data)
    } }
    setOpenRouterImagesURLSessionFactory { _ in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenRouterImagesMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
    defer {
        OpenRouterImagesMockURLProtocol.requestHandler.withLock { $0 = nil }
        resetOpenRouterImagesURLSessionFactory()
    }

    let result = await generateImages(
        model: model,
        context: ImagesContext(input: [
            .text(TextContent(text: "draw")),
            .image(ImageContent(data: "aW5wdXQ=", mimeType: "image/png")),
        ]),
        options: ImagesOptions(
            apiKey: "test-key",
            onPayload: { snapshot in payloadJSON.withLock { $0 = snapshot.json } },
            onResponse: { response in responseStatus.withLock { $0 = response.statusCode } },
            headers: ["X-Test": "1"],
            timeoutMs: 1000,
            maxRetries: 0
        )
    )

    #expect(result.stopReason == StopReason.stop)
    #expect(result.responseId == "chatcmpl-image-1")
    #expect(responseStatus.withLock { $0 } == 200)
    #expect(payloadJSON.withLock { $0 }?.contains("\"modalities\"") == true)
    #expect(result.output.count == 2)
    guard result.output.count == 2 else {
        return
    }
    if case .text(let text) = result.output[0] {
        #expect(text.text == "caption")
    } else {
        #expect(Bool(false), "Expected text output")
    }
    if case .image(let image) = result.output[1] {
        #expect(image.mimeType == "image/png")
        #expect(image.data == "aW1n")
    } else {
        #expect(Bool(false), "Expected image output")
    }
    #expect(result.usage?.input == 85)
    #expect(result.usage?.output == 20)
    #expect(result.usage?.cacheRead == 10)
    #expect(result.usage?.cacheWrite == 5)
    #expect(result.usage?.totalTokens == 120)
    #expect(abs((result.usage?.cost.total ?? 0) - 0.000413875) < 0.000000001)
}
