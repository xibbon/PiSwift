import Foundation
import CoreFoundation

/// OpenRouter rates in dollars per token.
public struct OpenRouterPricing: Sendable, Codable {
    public var prompt: String?
    public var completion: String?
    public var inputCacheRead: String?
    public var inputCacheWrite: String?
    public var overrides: [OpenRouterPricingOverride]?

    public init(prompt: String? = nil, completion: String? = nil,
                inputCacheRead: String? = nil, inputCacheWrite: String? = nil,
                overrides: [OpenRouterPricingOverride]? = nil) {
        self.prompt = prompt
        self.completion = completion
        self.inputCacheRead = inputCacheRead
        self.inputCacheWrite = inputCacheWrite
        self.overrides = overrides
    }

    private enum CodingKeys: String, CodingKey {
        case prompt, completion, overrides
        case inputCacheRead = "input_cache_read", inputCacheWrite = "input_cache_write"
    }
}

public struct OpenRouterPricingOverride: Sendable, Codable {
    public var minPromptTokens: Int?
    public var utcStart: Double?
    public var utcEnd: Double?
    public var utcDays: [String]?
    public var prompt: String?
    public var completion: String?
    public var inputCacheRead: String?
    public var inputCacheWrite: String?

    public init(minPromptTokens: Int? = nil, utcStart: Double? = nil, utcEnd: Double? = nil,
                utcDays: [String]? = nil, prompt: String? = nil, completion: String? = nil,
                inputCacheRead: String? = nil, inputCacheWrite: String? = nil) {
        self.minPromptTokens = minPromptTokens
        self.utcStart = utcStart
        self.utcEnd = utcEnd
        self.utcDays = utcDays
        self.prompt = prompt
        self.completion = completion
        self.inputCacheRead = inputCacheRead
        self.inputCacheWrite = inputCacheWrite
    }

    private enum CodingKeys: String, CodingKey {
        case minPromptTokens = "min_prompt_tokens", utcStart = "utc_start", utcEnd = "utc_end", utcDays = "utc_days"
        case prompt, completion
        case inputCacheRead = "input_cache_read", inputCacheWrite = "input_cache_write"
    }
}

/// Convert rates to dollars per million tokens. Invalid and negative rates use the base rate.
public func openRouterCost(_ pricing: OpenRouterPricing?) -> ModelCost {
    var base = ModelCost(
        input: openRouterPerMillion(pricing?.prompt, fallback: 0),
        output: openRouterPerMillion(pricing?.completion, fallback: 0),
        cacheRead: openRouterPerMillion(pricing?.inputCacheRead, fallback: 0),
        cacheWrite: openRouterPerMillion(pricing?.inputCacheWrite, fallback: 0)
    )
    let tiers = (pricing?.overrides ?? []).compactMap { override -> ModelCostTier? in
        guard let threshold = override.minPromptTokens,
              override.utcStart == nil, override.utcEnd == nil, override.utcDays == nil else { return nil }
        return ModelCostTier(
            inputTokensAbove: threshold,
            input: openRouterPerMillion(override.prompt, fallback: base.input),
            output: openRouterPerMillion(override.completion, fallback: base.output),
            cacheRead: openRouterPerMillion(override.inputCacheRead, fallback: base.cacheRead),
            cacheWrite: openRouterPerMillion(override.inputCacheWrite, fallback: base.cacheWrite)
        )
    }
    if !tiers.isEmpty { base.tiers = tiers }
    return base
}

private func openRouterPerMillion(_ value: String?, fallback: Double) -> Double {
    // Match Number.parseFloat: accept the numeric prefix, including Infinity.
    let whitespace = CharacterSet(charactersIn: "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
    let text = (value ?? "").trimmingCharacters(in: whitespace)
    guard let range = text.range(of: #"^[+-]?(?:Infinity|(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)"#,
                                 options: .regularExpression),
          let perToken = Double(text[range]), perToken >= 0 else { return fallback }
    let rate = perToken * 1_000_000
    if rate == 0 { return 0 }
    // At 2^33 and above, rounding to six places cannot change the Double.
    guard rate.isFinite, rate < 8_589_934_592 else { return rate }
    // Exact decimal half ties with six places are odd multiples of 1/128.
    // JavaScript toFixed rounds them up; printf uses the even neighbor.
    let halves = rate * 128
    if halves < 9_007_199_254_740_992, halves.rounded(.towardZero) == halves,
       halves.truncatingRemainder(dividingBy: 2) == 1 {
        return Double(String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), rate.nextUp)) ?? rate
    }
    return Double(String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), rate)) ?? rate
}

public enum OpenRouterCatalogError: Error, Sendable, Equatable, LocalizedError {
    case requestFailed(Int)
    case invalidResponse
    case invalidURL(String)
    case timedOut(milliseconds: Int)

    public var errorDescription: String? {
        switch self {
        case .requestFailed(let status): "OpenRouter model list request failed: \(status)"
        case .invalidResponse: "Invalid OpenRouter model list response"
        case .invalidURL(let url): "Invalid OpenRouter model list URL: \(url)"
        case .timedOut(let milliseconds): "OpenRouter model list request timed out after \(milliseconds)ms"
        }
    }
}

/// Filter chat models by the key's catalog and apply its limits and prices.
/// `credential` is the resolved API key or OAuth access token.
public func personalizeOpenRouterCatalog(
    _ catalog: [AnyModel], credential: String?, baseUrl: String? = nil,
    client: any ProviderHTTPClient = DefaultProviderHTTPClient(), signal: CancellationToken? = nil,
    timeout: Duration = .seconds(15)
) async throws -> [AnyModel] {
    guard let credential, !credential.isEmpty else { return catalog }
    let base = (baseUrl ?? "https://openrouter.ai/api/v1").replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
    let address = base + "/models/user"
    guard let url = URL(string: address) else { throw OpenRouterCatalogError.invalidURL(address) }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    let timeoutSeconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
    request.timeoutInterval = timeoutSeconds
    request.setValue("application/json", forHTTPHeaderField: "accept")
    request.setValue("Bearer \(credential)", forHTTPHeaderField: "authorization")
    let finalRequest = request
    let effectiveSignal = CancellationToken()
    let deadline = CancellationToken()
    let removeHandler = signal?.onCancel { effectiveSignal.cancel() }
    let timer = Task {
        do {
            try await Task.sleep(for: timeout)
            deadline.cancel()
            effectiveSignal.cancel()
        } catch { /* The request finished before the deadline. */ }
    }
    defer { removeHandler?(); timer.cancel() }
    let body: Data?
    do {
        body = try await retryProviderRequest(maxRetries: 0, signal: effectiveSignal) {
            try Task.checkCancellation()
            let response = try await client.send(finalRequest)
            try Task.checkCancellation()
            if [401, 403, 404].contains(response.statusCode) { return nil }
            guard (200..<300).contains(response.statusCode) else {
                throw OpenRouterCatalogError.requestFailed(response.statusCode)
            }
            var data = Data()
            for try await chunk in response.body {
                try Task.checkCancellation()
                data.append(chunk)
            }
            try Task.checkCancellation()
            return data
        }
    } catch {
        if deadline.isCancelled { throw OpenRouterCatalogError.timedOut(milliseconds: Int(timeoutSeconds * 1_000)) }
        throw error
    }
    guard let body else { return catalog }
    let json = try JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
    guard let object = json as? [String: Any], let entries = object["data"] as? [Any] else {
        throw OpenRouterCatalogError.invalidResponse
    }
    var allowed: [String: [String: Any]] = [:]
    for case let entry as [String: Any] in entries {
        if let id = entry["id"] as? String { allowed[id] = entry }
    }
    return catalog.compactMap { item in
        guard case .chat(let model) = item else { return item }
        guard let entry = allowed[model.id] else { return nil }
        let top = entry["top_provider"] as? [String: Any]
        let context = openRouterLimit(top?["context_length"]) ?? openRouterLimit(entry["context_length"]) ?? model.contextWindow
        let maximum = openRouterLimit(top?["max_completion_tokens"]) ?? model.maxTokens
        let cost = entry["pricing"].flatMap { openRouterTruthy($0) ? openRouterPricing($0) : nil }.map(openRouterCost) ?? model.cost
        return .chat(Model(
            id: model.id, name: model.name, api: model.api, provider: model.provider, baseUrl: model.baseUrl,
            reasoning: model.reasoning, input: model.input, cost: cost, contextWindow: context,
            maxTokens: maximum, samplingParams: model.samplingParams, headers: model.headers,
            compat: model.compat, thinkingLevelMap: model.thinkingLevelMap, inputLimits: model.inputLimits,
            promptCache: model.promptCache, samplingParamsByThinkingLevel: model.samplingParamsByThinkingLevel
        ))
    }
}

private func openRouterLimit(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          let integer = Int(exactly: number.doubleValue), integer != 0 else { return nil }
    return integer
}

private func openRouterPricing(_ value: Any) -> OpenRouterPricing {
    let object = value as? [String: Any] ?? [:]
    let overrides = (object["overrides"] as? [[String: Any]])?.compactMap { item -> OpenRouterPricingOverride? in
        // A present time condition, including null, is not a prompt-length tier.
        guard !item.keys.contains("utc_start"), !item.keys.contains("utc_end"), !item.keys.contains("utc_days") else { return nil }
        return OpenRouterPricingOverride(
            minPromptTokens: (item["min_prompt_tokens"] as? NSNumber).flatMap { Int(exactly: $0.doubleValue) },
            prompt: item["prompt"] as? String, completion: item["completion"] as? String,
            inputCacheRead: item["input_cache_read"] as? String, inputCacheWrite: item["input_cache_write"] as? String
        )
    }
    return OpenRouterPricing(prompt: object["prompt"] as? String, completion: object["completion"] as? String,
        inputCacheRead: object["input_cache_read"] as? String, inputCacheWrite: object["input_cache_write"] as? String,
        overrides: overrides)
}

private func openRouterTruthy(_ value: Any) -> Bool {
    if value is NSNull { return false }
    if let string = value as? String { return !string.isEmpty }
    if let number = value as? NSNumber { return number.doubleValue != 0 }
    return true
}
