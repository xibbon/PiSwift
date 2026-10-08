import Foundation
import PiSwiftAI

private let remoteCatalogSourceId = "pi.dev"

public enum VirtualModelRegistrationError: Error, LocalizedError, Sendable {
    case emptyIdentifier
    case physicalConflict(String, String)
    case notRegistered(String, String)
    case invalidTarget(String, String, String, String)
    case unauthenticatedTarget(String, String, String, String)

    public var errorDescription: String? {
        switch self {
        case .emptyIdentifier: "Virtual model provider and id must not be empty."
        case .physicalConflict(let provider, let id): "Virtual model \(provider)/\(id) conflicts with a physical model."
        case .notRegistered(let provider, let id): "Virtual model \(provider)/\(id) is not registered."
        case .invalidTarget(let provider, let id, let targetProvider, let targetId):
            "Virtual model \(provider)/\(id) routed to \(targetProvider)/\(targetId), which is not a physical model."
        case .unauthenticatedTarget(let provider, let id, let targetProvider, let targetId):
            "Virtual model \(provider)/\(id) routed to \(targetProvider)/\(targetId), which has no credentials."
        }
    }
}

private func storedCredentialString(_ credential: AuthCredential?) -> String? {
    switch credential {
    case .apiKey(let value):
        return value.key
    case .oauth(let value):
        return value.access
    case nil:
        return nil
    }
}

public enum CredentialSynchronizationOperation: String, Sendable {
    case login
    case logout
    case setRuntimeApiKey
    case removeRuntimeApiKey
}

/// Credentials committed, but the registry could not synchronize its local model state.
public struct CredentialSynchronizationError: Error, LocalizedError, Sendable {
    public let providerId: String
    public let operation: CredentialSynchronizationOperation
    public let credential: AuthCredential?
    public let cause: any Error

    public init(
        providerId: String,
        operation: CredentialSynchronizationOperation,
        credential: AuthCredential?,
        cause: any Error
    ) {
        self.providerId = providerId
        self.operation = operation
        self.credential = credential
        self.cause = cause
    }

    public var errorDescription: String? {
        "Credential \(operation.rawValue) committed for \(providerId), but local synchronization failed"
    }
}

/// A provider and its authentication methods for a login interface.
public struct LoginProviderInfo: Sendable {
    public let id: String
    public let name: String
    public let apiKey: ApiKeyAuthMethod?
    public let oauth: OAuthProviderInfo?

    public init(id: String, name: String, apiKey: ApiKeyAuthMethod? = nil, oauth: OAuthProviderInfo? = nil) {
        self.id = id
        self.name = name
        self.apiKey = apiKey
        self.oauth = oauth
    }
}

public enum ProviderLoginError: Error, LocalizedError, Sendable {
    case unknownProvider(String)
    case apiKeyLoginUnsupported(String)

    public var errorDescription: String? {
        switch self {
        case .unknownProvider(let id): "Unknown provider: \(id)"
        case .apiKeyLoginUnsupported(let name): "\(name) does not support api_key login"
        }
    }
}

/// Provider authentication status. This check does not execute configured commands.
public struct ProviderAuthStatus: Sendable, Equatable {
    public let configured: Bool
    public let source: String?
    public let label: String?
    public init(configured: Bool, source: String? = nil, label: String? = nil) {
        self.configured = configured
        self.source = source
        self.label = label
    }
}

func mergeConfigEnvironment(_ base: [String: String]?, _ override: [String: String]?) -> [String: String]? {
    let merged = (base ?? [:]).merging(override ?? [:]) { _, value in value }
    return merged.isEmpty ? nil : merged
}

/// Authentication and scoped environment resolved for one model request.
public struct ModelAuth: Sendable {
    public let ok: Bool
    public let apiKey: String?
    public let headers: ProviderHeaders?
    public let baseUrl: String?
    public let error: String?
    public let env: [String: String]?
    /// A provider resolver returned auth, including ambient cloud auth without a key.
    public let hasResolvedAuth: Bool

    public init(ok: Bool, apiKey: String?, headers: ProviderHeaders?, baseUrl: String? = nil, error: String?, env: [String: String]? = nil, hasResolvedAuth: Bool = false) {
        self.ok = ok
        self.apiKey = apiKey
        self.headers = headers
        self.baseUrl = baseUrl
        self.error = error
        self.env = env
        self.hasResolvedAuth = hasResolvedAuth
    }
}

public struct ResolvedModelRequest: Sendable {
    public let model: Model
    public let auth: ModelAuth

    public init(model: Model, auth: ModelAuth) {
        self.model = model
        self.auth = auth
    }
}

public struct ResolvedImageModelRequest: Sendable {
    public let model: ImageModel
    public let auth: ModelAuth
}

public struct ResolvedClassifierModelRequest: Sendable {
    public let model: ClassifierModel
    public let auth: ModelAuth
}

private enum ModelRegistryStreamError: LocalizedError {
    case cancelled
    case authentication(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "Authentication cancelled"
        case .authentication(let message): message
        }
    }
}

private struct ParsedRouting {
    var allowFallbacks: Bool?
    var requireParameters: Bool?
    var dataCollection: String?
    var zdr: Bool?
    var enforceDistillableText: Bool?
    var only: [String]?
    var order: [String]?
    var ignore: [String]?
    var quantizations: [String]?
    var sort: OpenRouterRoutingSort?
    var maxPrice: OpenRouterRoutingPrice?
    var preferredMinThroughput: OpenRouterRoutingPercentile?
    var preferredMaxLatency: OpenRouterRoutingPercentile?
}

private func parseRouting(_ value: Any?) -> ParsedRouting? {
    guard let dict = value as? [String: Any] else { return nil }
    var r = ParsedRouting()
    r.allowFallbacks = dict["allow_fallbacks"] as? Bool
    r.requireParameters = dict["require_parameters"] as? Bool
    r.dataCollection = dict["data_collection"] as? String
    r.zdr = dict["zdr"] as? Bool
    r.enforceDistillableText = dict["enforce_distillable_text"] as? Bool
    r.only = dict["only"] as? [String]
    r.order = dict["order"] as? [String]
    r.ignore = dict["ignore"] as? [String]
    r.quantizations = dict["quantizations"] as? [String]
    if let s = dict["sort"] as? String {
        r.sort = .named(s)
    } else if let s = dict["sort"] as? [String: Any] {
        r.sort = .structured(by: s["by"] as? String, partition: s["partition"] as? String)
    }
    if let mp = dict["max_price"] as? [String: Any] {
        func num(_ key: String) -> Double? {
            if let v = mp[key] as? Double { return v }
            if let v = mp[key] as? Int { return Double(v) }
            if let v = mp[key] as? String, let d = Double(v) { return d }
            return nil
        }
        r.maxPrice = OpenRouterRoutingPrice(
            prompt: num("prompt"),
            completion: num("completion"),
            image: num("image"),
            audio: num("audio"),
            request: num("request")
        )
    }
    r.preferredMinThroughput = parseRoutingPercentile(dict["preferred_min_throughput"])
    r.preferredMaxLatency = parseRoutingPercentile(dict["preferred_max_latency"])

    let allEmpty = r.allowFallbacks == nil && r.requireParameters == nil && r.dataCollection == nil &&
        r.zdr == nil && r.enforceDistillableText == nil && r.only == nil && r.order == nil &&
        r.ignore == nil && r.quantizations == nil && r.sort == nil && r.maxPrice == nil &&
        r.preferredMinThroughput == nil && r.preferredMaxLatency == nil
    return allEmpty ? nil : r
}

private func parseRoutingPercentile(_ value: Any?) -> OpenRouterRoutingPercentile? {
    if let n = value as? Double { return .scalar(n) }
    if let n = value as? Int { return .scalar(Double(n)) }
    if let dict = value as? [String: Any] {
        func num(_ key: String) -> Double? {
            if let v = dict[key] as? Double { return v }
            if let v = dict[key] as? Int { return Double(v) }
            return nil
        }
        return .percentiles(p50: num("p50"), p75: num("p75"), p90: num("p90"), p99: num("p99"))
    }
    return nil
}

private let extendedCompatKeys: Set<String> = [
    "supportsFinishReason",
    "vllmPriority",
    "supportsAdditionalTools",
    "supportsMaxOutputTokens",
    "supportsMidConvoEffort",
    "supportsMidConvoSystemMessages",
    "supportsMidConvoToolAdditions",
    "supportsMidConvoToolChanges",
    "thinkingTokenBudgetField",
    "supportsOpenAIGrammarTools",
    "supportsToolSearch",
    "supportsTemperature",
    "supportsCacheControlOnTools",
    "forceAdaptiveThinking",
    "allowEmptySignature",
    "supportsStrictTools",
    "sessionAffinityFormat",
    "chatTemplateKwargs",
    "chatTemplateArgs",
    "allowedFallbackModels",
]

private func parseCompat(_ value: Any?) -> OpenAICompat? {
    guard let dict = value as? [String: Any] else { return nil }

    let supportsStore = dict["supportsStore"] as? Bool
    let supportsDeveloperRole = dict["supportsDeveloperRole"] as? Bool
    let supportsReasoningEffort = dict["supportsReasoningEffort"] as? Bool
    let supportsUsageInStreaming = dict["supportsUsageInStreaming"] as? Bool
    let maxTokensField = (dict["maxTokensField"] as? String).flatMap(OpenAICompatMaxTokensField.init(rawValue:))
    let requiresToolResultName = dict["requiresToolResultName"] as? Bool
    let requiresAssistantAfterToolResult = dict["requiresAssistantAfterToolResult"] as? Bool
    let requiresThinkingAsText = dict["requiresThinkingAsText"] as? Bool
    let requiresMistralToolIds = dict["requiresMistralToolIds"] as? Bool
    let thinkingFormat = (dict["thinkingFormat"] as? String).flatMap(OpenAICompatThinkingFormat.init(rawValue:))
    let supportsStrictMode = dict["supportsStrictMode"] as? Bool
    let supportsThinkingTokenBudget = dict["supportsThinkingTokenBudget"] as? Bool

    let openRouterRoutingValue = parseRouting(dict["openRouterRouting"])
    let vercelGatewayRoutingValue = parseRouting(dict["vercelGatewayRouting"])

    let openRouterRouting = openRouterRoutingValue.map { r in
        OpenRouterRouting(
            allowFallbacks: r.allowFallbacks,
            requireParameters: r.requireParameters,
            dataCollection: r.dataCollection,
            zdr: r.zdr,
            enforceDistillableText: r.enforceDistillableText,
            order: r.order,
            only: r.only,
            ignore: r.ignore,
            quantizations: r.quantizations,
            sort: r.sort,
            maxPrice: r.maxPrice,
            preferredMinThroughput: r.preferredMinThroughput,
            preferredMaxLatency: r.preferredMaxLatency
        )
    }
    let vercelGatewayRouting = vercelGatewayRoutingValue.map { r in
        VercelGatewayRouting(only: r.only, order: r.order, allowFallbacks: r.allowFallbacks)
    }

    // v0.68.0 / v0.70.0 / v0.70.1: new compat fields read from models.json so proxies and
    // custom-provider entries can opt in/out without recompiling.
    let supportsLongCacheRetention = dict["supportsLongCacheRetention"] as? Bool
    let sendSessionIdHeader = dict["sendSessionIdHeader"] as? Bool
    let supportsEagerToolInputStreaming = dict["supportsEagerToolInputStreaming"] as? Bool
    let cacheControlFormat = (dict["cacheControlFormat"] as? String).flatMap(OpenAICompatCacheControlFormat.init(rawValue:))
    let sendSessionAffinityHeaders = dict["sendSessionAffinityHeaders"] as? Bool
    let requiresReasoningContentOnAssistantMessages = dict["requiresReasoningContentOnAssistantMessages"] as? Bool

    if supportsStore == nil,
       supportsDeveloperRole == nil,
       supportsReasoningEffort == nil,
       supportsUsageInStreaming == nil,
       maxTokensField == nil,
       requiresToolResultName == nil,
       requiresAssistantAfterToolResult == nil,
       requiresThinkingAsText == nil,
       requiresMistralToolIds == nil,
       thinkingFormat == nil,
       supportsStrictMode == nil,
       supportsThinkingTokenBudget == nil,
       openRouterRouting == nil,
       vercelGatewayRouting == nil,
       supportsLongCacheRetention == nil,
       sendSessionIdHeader == nil,
       supportsEagerToolInputStreaming == nil,
       cacheControlFormat == nil,
       sendSessionAffinityHeaders == nil,
       requiresReasoningContentOnAssistantMessages == nil {
        if !extendedCompatKeys.contains(where: { dict[$0] != nil }) { return nil }
    }

    let accepted = dict.filter { extendedCompatKeys.contains($0.key) }
    var parsed = OpenAICompat()
    if let data = try? JSONSerialization.data(withJSONObject: accepted),
       let decoded = try? JSONDecoder().decode(OpenAICompat.self, from: data) {
        parsed = decoded
    }
    parsed.supportsStore = supportsStore
    parsed.supportsDeveloperRole = supportsDeveloperRole
    parsed.supportsReasoningEffort = supportsReasoningEffort
    parsed.supportsUsageInStreaming = supportsUsageInStreaming
    parsed.maxTokensField = maxTokensField
    parsed.requiresToolResultName = requiresToolResultName
    parsed.requiresAssistantAfterToolResult = requiresAssistantAfterToolResult
    parsed.requiresThinkingAsText = requiresThinkingAsText
    parsed.requiresMistralToolIds = requiresMistralToolIds
    parsed.thinkingFormat = thinkingFormat
    parsed.openRouterRouting = openRouterRouting
    parsed.vercelGatewayRouting = vercelGatewayRouting
    parsed.supportsThinkingTokenBudget = supportsThinkingTokenBudget
    parsed.supportsStrictMode = supportsStrictMode
    parsed.supportsLongCacheRetention = supportsLongCacheRetention
    parsed.sendSessionIdHeader = sendSessionIdHeader
    parsed.supportsEagerToolInputStreaming = supportsEagerToolInputStreaming
    parsed.cacheControlFormat = cacheControlFormat
    parsed.sendSessionAffinityHeaders = sendSessionAffinityHeaders
    parsed.requiresReasoningContentOnAssistantMessages = requiresReasoningContentOnAssistantMessages
    return parsed
}

private struct ProviderOverride: Sendable {
    var name: String?
    var baseUrl: String?
    var headers: ProviderHeaders?
    var apiKey: String?
    var compat: OpenAICompat?
    var authHeader: Bool = false
    var modelHeaders: [String: ProviderHeaders] = [:]
}

private struct ModelOverride: Sendable {
    var name: String?
    var baseUrl: String?
    var reasoning: Bool?
    var input: [String]?
    var cost: ModelCostOverride?
    var contextWindow: Int?
    var maxTokens: Int?
    var samplingParams: SamplingParams?
    var samplingParamsByThinkingLevel: SamplingParamsByThinkingLevel?
    var headers: ProviderHeaders?
    var compat: OpenAICompat?
    var thinkingLevelMap: ThinkingLevelMap?
    var inputLimits: ModelInputLimits?
    var promptCache: ModelPromptCache?
}

private struct ModelCostOverride: Sendable {
    var input: Double?
    var output: Double?
    var cacheRead: Double?
    var cacheWrite: Double?
    var tiers: [ModelCostTier]?
}

private func parseProviderHeaders(_ value: Any?) -> ProviderHeaders? {
    guard let values = value as? [String: Any] else { return nil }
    var headers: ProviderHeaders = [:]
    for (name, value) in values {
        if let value = value as? String {
            headers.updateValue(value, forKey: name)
        } else if value is NSNull {
            headers.updateValue(nil, forKey: name)
        }
    }
    return headers
}

private func parseSamplingParams(_ value: Any?) -> SamplingParams? {
    guard let values = value as? [String: Any] else { return nil }
    return values.mapValues(AnyCodable.init)
}

private func parseSamplingParamsByThinkingLevel(_ value: Any?) -> SamplingParamsByThinkingLevel? {
    guard let values = value as? [String: Any] else { return nil }
    var result: SamplingParamsByThinkingLevel = [:]
    for (name, value) in values {
        guard let level = ModelThinkingLevel(rawValue: name),
              let params = parseSamplingParams(value) else { continue }
        result[level] = params
    }
    return result
}

private func parseModelMetadata<T: Decodable>(_ value: Any?, as type: T.Type) -> T? {
    guard let value, JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}

private func parseThinkingLevelMap(_ value: Any?) -> ThinkingLevelMap? {
    guard let values = value as? [String: Any] else { return nil }
    var result: ThinkingLevelMap = [:]
    for (name, value) in values {
        guard let level = ModelThinkingLevel(rawValue: name) else { continue }
        if let value = value as? String {
            result.updateValue(value, forKey: level)
        } else if value is NSNull {
            result.updateValue(nil, forKey: level)
        }
    }
    return result
}

private func parseModelCostTiers(_ value: Any?) -> [ModelCostTier]? {
    guard let values = value as? [[String: Any]] else { return nil }
    return values.compactMap { tier in
        guard let inputTokensAbove = tier["inputTokensAbove"] as? Int else { return nil }
        return ModelCostTier(
            inputTokensAbove: inputTokensAbove,
            input: tier["input"] as? Double ?? 0,
            output: tier["output"] as? Double ?? 0,
            cacheRead: tier["cacheRead"] as? Double ?? 0,
            cacheWrite: tier["cacheWrite"] as? Double ?? 0
        )
    }
}

private struct CustomModelsResult: Sendable {
    var models: [Model]
    var overrides: [String: ProviderOverride]
    var modelOverrides: [String: [String: ModelOverride]]
    var errorMessage: String?
}

private func emptyCustomModelsResult(errorMessage: String? = nil) -> CustomModelsResult {
    CustomModelsResult(models: [], overrides: [:], modelOverrides: [:], errorMessage: errorMessage)
}

private func mergeCompat(_ base: OpenAICompat?, _ override: OpenAICompat?) -> OpenAICompat? {
    guard let override else { return base }
    guard let base else { return override }

    let mergedOpenRouter: OpenRouterRouting? = {
        if base.openRouterRouting == nil && override.openRouterRouting == nil { return nil }
        let b = base.openRouterRouting
        let o = override.openRouterRouting
        return OpenRouterRouting(
            allowFallbacks: o?.allowFallbacks ?? b?.allowFallbacks,
            requireParameters: o?.requireParameters ?? b?.requireParameters,
            dataCollection: o?.dataCollection ?? b?.dataCollection,
            zdr: o?.zdr ?? b?.zdr,
            enforceDistillableText: o?.enforceDistillableText ?? b?.enforceDistillableText,
            order: o?.order ?? b?.order,
            only: o?.only ?? b?.only,
            ignore: o?.ignore ?? b?.ignore,
            quantizations: o?.quantizations ?? b?.quantizations,
            sort: o?.sort ?? b?.sort,
            maxPrice: o?.maxPrice ?? b?.maxPrice,
            preferredMinThroughput: o?.preferredMinThroughput ?? b?.preferredMinThroughput,
            preferredMaxLatency: o?.preferredMaxLatency ?? b?.preferredMaxLatency
        )
    }()

    let mergedVercel: VercelGatewayRouting? = {
        if base.vercelGatewayRouting == nil && override.vercelGatewayRouting == nil { return nil }
        let b = base.vercelGatewayRouting
        let o = override.vercelGatewayRouting
        return VercelGatewayRouting(
            only: o?.only ?? b?.only,
            order: o?.order ?? b?.order,
            allowFallbacks: o?.allowFallbacks ?? b?.allowFallbacks
        )
    }()

    var merged = base
    merged.supportsStore = override.supportsStore ?? base.supportsStore
    merged.supportsDeveloperRole = override.supportsDeveloperRole ?? base.supportsDeveloperRole
    merged.supportsReasoningEffort = override.supportsReasoningEffort ?? base.supportsReasoningEffort
    merged.supportsUsageInStreaming = override.supportsUsageInStreaming ?? base.supportsUsageInStreaming
    merged.supportsFinishReason = override.supportsFinishReason ?? base.supportsFinishReason
    merged.supportsTemperature = override.supportsTemperature ?? base.supportsTemperature
    merged.maxTokensField = override.maxTokensField ?? base.maxTokensField
    merged.requiresToolResultName = override.requiresToolResultName ?? base.requiresToolResultName
    merged.requiresAssistantAfterToolResult = override.requiresAssistantAfterToolResult ?? base.requiresAssistantAfterToolResult
    merged.requiresThinkingAsText = override.requiresThinkingAsText ?? base.requiresThinkingAsText
    merged.requiresMistralToolIds = override.requiresMistralToolIds ?? base.requiresMistralToolIds
    merged.thinkingFormat = override.thinkingFormat ?? base.thinkingFormat
    merged.chatTemplateKwargs = override.chatTemplateKwargs ?? base.chatTemplateKwargs
    merged.chatTemplateArgs = override.chatTemplateArgs ?? base.chatTemplateArgs
    merged.openRouterRouting = mergedOpenRouter
    merged.vercelGatewayRouting = mergedVercel
    merged.supportsThinkingTokenBudget = override.supportsThinkingTokenBudget ?? base.supportsThinkingTokenBudget
    merged.supportsOpenAIGrammarTools = override.supportsOpenAIGrammarTools ?? base.supportsOpenAIGrammarTools
    merged.supportsStrictMode = override.supportsStrictMode ?? base.supportsStrictMode
    merged.reasoningEffortMap = override.reasoningEffortMap ?? base.reasoningEffortMap
    merged.supportsLongCacheRetention = override.supportsLongCacheRetention ?? base.supportsLongCacheRetention
    merged.sendSessionIdHeader = override.sendSessionIdHeader ?? base.sendSessionIdHeader
    merged.supportsEagerToolInputStreaming = override.supportsEagerToolInputStreaming ?? base.supportsEagerToolInputStreaming
    merged.cacheControlFormat = override.cacheControlFormat ?? base.cacheControlFormat
    merged.sendSessionAffinityHeaders = override.sendSessionAffinityHeaders ?? base.sendSessionAffinityHeaders
    merged.requiresReasoningContentOnAssistantMessages = override.requiresReasoningContentOnAssistantMessages ?? base.requiresReasoningContentOnAssistantMessages
    merged.supportsCacheControlOnTools = override.supportsCacheControlOnTools ?? base.supportsCacheControlOnTools
    merged.supportsStrictTools = override.supportsStrictTools ?? base.supportsStrictTools
    merged.forceAdaptiveThinking = override.forceAdaptiveThinking ?? base.forceAdaptiveThinking
    merged.zaiToolStream = override.zaiToolStream ?? base.zaiToolStream
    merged.allowEmptySignature = override.allowEmptySignature ?? base.allowEmptySignature
    merged.sessionAffinityFormat = override.sessionAffinityFormat ?? base.sessionAffinityFormat
    merged.supportsToolSearch = override.supportsToolSearch ?? base.supportsToolSearch
    merged.supportsExplicitPromptCacheMode = override.supportsExplicitPromptCacheMode ?? base.supportsExplicitPromptCacheMode
    merged.thinkingTokenBudgetField = override.thinkingTokenBudgetField ?? base.thinkingTokenBudgetField
    merged.vllmPriority = override.vllmPriority ?? base.vllmPriority
    merged.supportsAdditionalTools = override.supportsAdditionalTools ?? base.supportsAdditionalTools
    merged.supportsMaxOutputTokens = override.supportsMaxOutputTokens ?? base.supportsMaxOutputTokens
    merged.supportsMidConvoEffort = override.supportsMidConvoEffort ?? base.supportsMidConvoEffort
    merged.supportsMidConvoSystemMessages = override.supportsMidConvoSystemMessages ?? base.supportsMidConvoSystemMessages
    merged.supportsMidConvoToolAdditions = override.supportsMidConvoToolAdditions ?? base.supportsMidConvoToolAdditions
    merged.supportsMidConvoToolChanges = override.supportsMidConvoToolChanges ?? base.supportsMidConvoToolChanges
    merged.allowedFallbackModels = override.allowedFallbackModels ?? base.allowedFallbackModels
    return merged
}

private func applyModelOverride(model: Model, override: ModelOverride) -> Model {
    var updated = model
    if let name = override.name { updated = Model(id: updated.id, name: name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: updated.input, cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens, samplingParams: updated.samplingParams, headers: updated.headers, compat: updated.compat, thinkingLevelMap: updated.thinkingLevelMap, inputLimits: updated.inputLimits, promptCache: updated.promptCache, samplingParamsByThinkingLevel: updated.samplingParamsByThinkingLevel) }
    if let baseUrl = override.baseUrl {
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: baseUrl, reasoning: updated.reasoning, input: updated.input, cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens, samplingParams: updated.samplingParams, headers: updated.headers, compat: updated.compat, thinkingLevelMap: updated.thinkingLevelMap, inputLimits: updated.inputLimits, promptCache: updated.promptCache, samplingParamsByThinkingLevel: updated.samplingParamsByThinkingLevel)
    }
    if let reasoning = override.reasoning {
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: reasoning, input: updated.input, cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens, samplingParams: updated.samplingParams, headers: updated.headers, compat: updated.compat, thinkingLevelMap: updated.thinkingLevelMap, inputLimits: updated.inputLimits, promptCache: updated.promptCache, samplingParamsByThinkingLevel: updated.samplingParamsByThinkingLevel)
    }
    if let input = override.input {
        let mapped = input.compactMap { ModelInput(rawValue: $0) }
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: mapped, cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens, samplingParams: updated.samplingParams, headers: updated.headers, compat: updated.compat, thinkingLevelMap: updated.thinkingLevelMap, inputLimits: updated.inputLimits, promptCache: updated.promptCache, samplingParamsByThinkingLevel: updated.samplingParamsByThinkingLevel)
    }
    if let contextWindow = override.contextWindow {
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: updated.input, cost: updated.cost, contextWindow: contextWindow, maxTokens: updated.maxTokens, samplingParams: updated.samplingParams, headers: updated.headers, compat: updated.compat, thinkingLevelMap: updated.thinkingLevelMap, inputLimits: updated.inputLimits, promptCache: updated.promptCache, samplingParamsByThinkingLevel: updated.samplingParamsByThinkingLevel)
    }
    if let maxTokens = override.maxTokens {
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: updated.input, cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: maxTokens, samplingParams: updated.samplingParams, headers: updated.headers, compat: updated.compat, thinkingLevelMap: updated.thinkingLevelMap, inputLimits: updated.inputLimits, promptCache: updated.promptCache, samplingParamsByThinkingLevel: updated.samplingParamsByThinkingLevel)
    }
    if let samplingParams = override.samplingParams {
        let mergedSamplingParams = (updated.samplingParams ?? [:]).merging(samplingParams) { _, value in value }
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: updated.input, cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens, samplingParams: mergedSamplingParams, headers: updated.headers, compat: updated.compat, thinkingLevelMap: updated.thinkingLevelMap, inputLimits: updated.inputLimits, promptCache: updated.promptCache, samplingParamsByThinkingLevel: updated.samplingParamsByThinkingLevel)
    }
    if let samplingParamsByThinkingLevel = override.samplingParamsByThinkingLevel {
        var merged = updated.samplingParamsByThinkingLevel ?? [:]
        for (level, params) in samplingParamsByThinkingLevel {
            merged[level] = (merged[level] ?? [:]).merging(params) { _, value in value }
        }
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: updated.input, cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens, samplingParams: updated.samplingParams, headers: updated.headers, compat: updated.compat, thinkingLevelMap: updated.thinkingLevelMap, inputLimits: updated.inputLimits, promptCache: updated.promptCache, samplingParamsByThinkingLevel: merged)
    }
    if let thinkingLevelMap = override.thinkingLevelMap {
        let mergedThinkingLevelMap = (updated.thinkingLevelMap ?? [:]).merging(thinkingLevelMap) { _, value in value }
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: updated.input, cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens, samplingParams: updated.samplingParams, headers: updated.headers, compat: updated.compat, thinkingLevelMap: mergedThinkingLevelMap, inputLimits: updated.inputLimits, promptCache: updated.promptCache, samplingParamsByThinkingLevel: updated.samplingParamsByThinkingLevel)
    }

    if let cost = override.cost {
        let mergedCost = ModelCost(
            input: cost.input ?? updated.cost.input,
            output: cost.output ?? updated.cost.output,
            cacheRead: cost.cacheRead ?? updated.cost.cacheRead,
            cacheWrite: cost.cacheWrite ?? updated.cost.cacheWrite,
            tiers: cost.tiers ?? updated.cost.tiers
        )
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: updated.input, cost: mergedCost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens, samplingParams: updated.samplingParams, headers: updated.headers, compat: updated.compat, thinkingLevelMap: updated.thinkingLevelMap, inputLimits: updated.inputLimits, promptCache: updated.promptCache, samplingParamsByThinkingLevel: updated.samplingParamsByThinkingLevel)
    }

    if let headers = override.headers {
        let mergedHeaders = mergeProviderHeaders(updated.headers, headers)
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: updated.input, cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens, samplingParams: updated.samplingParams, headers: mergedHeaders, compat: updated.compat, thinkingLevelMap: updated.thinkingLevelMap, inputLimits: updated.inputLimits, promptCache: updated.promptCache, samplingParamsByThinkingLevel: updated.samplingParamsByThinkingLevel)
    }

    let mergedCompat = mergeCompat(updated.compat, override.compat)
    if mergedCompat != nil {
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: updated.input, cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens, samplingParams: updated.samplingParams, headers: updated.headers, compat: mergedCompat, thinkingLevelMap: updated.thinkingLevelMap, inputLimits: updated.inputLimits, promptCache: updated.promptCache, samplingParamsByThinkingLevel: updated.samplingParamsByThinkingLevel)
    }

    if override.inputLimits != nil || override.promptCache != nil {
        updated = Model(
            id: updated.id, name: updated.name, api: updated.api, provider: updated.provider,
            baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: updated.input,
            cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens,
            samplingParams: updated.samplingParams, headers: updated.headers, compat: updated.compat,
            thinkingLevelMap: updated.thinkingLevelMap,
            inputLimits: override.inputLimits ?? updated.inputLimits,
            promptCache: override.promptCache ?? updated.promptCache,
            samplingParamsByThinkingLevel: updated.samplingParamsByThinkingLevel
        )
    }

    return updated
}

func findModelDefaults(_ models: [Model], modelId: String, api: Api? = nil) -> Model? {
    models.first { $0.id == modelId }
        ?? api.flatMap { api in models.first { $0.api == api } }
        ?? models.first { $0.api == .openAICompletions }
        ?? models.first
}

private func normalizeProviderModel(_ model: Model) -> Model {
    guard model.provider == OAuthProvider.githubCopilot.rawValue else { return model }

    let api = model.api
    let copilotCompat = mergeCompat(
        model.compat,
        OpenAICompat(
            supportsStore: false,
            supportsDeveloperRole: false,
            supportsReasoningEffort: false,
            supportsUsageInStreaming: false,
            supportsStrictMode: false,
            sendSessionIdHeader: false
        )
    )

    return Model(
        id: model.id,
        name: model.name,
        api: api,
        provider: model.provider,
        baseUrl: model.baseUrl,
        reasoning: model.reasoning,
        input: model.input,
        cost: model.cost,
        contextWindow: model.contextWindow,
        maxTokens: model.maxTokens,
        samplingParams: model.samplingParams,
        headers: model.headers,
        compat: copilotCompat,
        thinkingLevelMap: model.thinkingLevelMap,
        inputLimits: model.inputLimits,
        promptCache: model.promptCache,
        samplingParamsByThinkingLevel: model.samplingParamsByThinkingLevel
    )
}

public final class ModelRegistry: Sendable {
    public let authStorage: AuthStorage
    private let modelsDir: String?
    private let networkEnabled: Bool
    private let state = LockedState(State())
    private let customProviderApiKeys = LockedState<[String: String]>([:])
    private let refreshCoordinator = LockedState<ModelCatalogRefreshCoordinator?>(nil)

    private struct State: Sendable {
        var models: [Model] = []
        var physicalModels: [Model] = []
        var allModels: [AnyModel] = []
        var baseModels: [Model] = []
        var userModels: [Model] = []
        var configuredProviderOverrides: [String: ProviderOverride] = [:]
        var configuredModelOverrides: [String: [String: ModelOverride]] = [:]
        var dynamicModelsBySource: [String: [String: [Model]]] = [:]
        var dynamicNonChatModelsBySource: [String: [String: [AnyModel]]] = [:]
        var remoteModelsByProvider: [String: [AnyModel]] = [:]
        var dynamicProviderConfigsBySource: [String: [String: HookProviderConfig]] = [:]
        var dynamicProviderApiKeysBySource: [String: [String: String]] = [:]
        var dynamicProviderStreamsBySource: [String: [String: ApiStreamSimpleFunction]] = [:]
        var dynamicProviderImagesBySource: [String: [String: [ImageApi: ImageApiFunction]]] = [:]
        var dynamicProviderClassifiersBySource: [String: [String: [ClassifierApi: ClassifierFunction]]] = [:]
        var virtualModelsBySource: [String: [String: [String: VirtualModelDefinition]]] = [:]
        var dynamicSourceOrder: [String] = [remoteCatalogSourceId]
        var errorMessage: String?
        var githubCopilotSupportedModelIds: Set<String>?
    }

    public convenience init(_ authStorage: AuthStorage, _ modelsDir: String? = nil) {
        let storeDir = modelsDir ?? getAgentDir()
        let storePath = (storeDir as NSString).appendingPathComponent("models-store.json")
        self.init(
            authStorage,
            modelsDir,
            modelsStore: FileModelsStore(storePath),
            networkEnabled: true
        )
    }

    public init(
        _ authStorage: AuthStorage,
        _ modelsDir: String? = nil,
        modelsStore: any ModelsStore,
        catalogBaseURL: String = "https://pi.dev",
        remoteHTTPClient: any ProviderHTTPClient = DefaultProviderHTTPClient(),
        networkEnabled: Bool = true,
        now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1_000 }
    ) {
        self.authStorage = authStorage
        self.modelsDir = modelsDir
        self.networkEnabled = networkEnabled
        self.authStorage.setFallbackResolver({ [weak self] provider in
            guard let self, let value = self.requestConfiguration(provider: provider).key else { return nil }
            return try? resolveConfigValueOrThrow(value, description: "API key for provider \"\(provider)\"")
        }, configured: { [weak self] provider in
            guard let self, let value = self.requestConfiguration(provider: provider).key else { return false }
            return isConfigValueConfigured(value)
        })
        loadModels()

        let sources = getProviders().map { provider -> ModelsRefreshSource in
            let providerId = provider.rawValue
            let remote = RemoteCatalogProvider(
                providerId: providerId,
                catalogBaseURL: catalogBaseURL,
                httpClient: remoteHTTPClient,
                now: now,
                updateOverlay: { [weak self] models in
                    self?.setRemoteCatalogModels(models, providerId: providerId)
                }
            )
            return ModelsRefreshSource(
                id: providerId,
                readStoredCredential: { [authStorage] in
                    storedCredentialString(authStorage.get(providerId))
                },
                resolveCredential: { [authStorage] signal in
                    await authStorage.getApiKey(providerId, signal: signal)
                },
                refresh: remote.refresh
            )
        }
        refreshCoordinator.withLock {
            $0 = ModelCatalogRefreshCoordinator(store: modelsStore, sources: sources)
        }
    }

    public func getError() -> String? {
        state.withLock { $0.errorMessage }
    }

    public func refresh(_ options: ModelsRefreshOptions = .init()) async -> ModelsRefreshResult {
        state.withLock {
            $0.errorMessage = nil
            $0.githubCopilotSupportedModelIds = nil
        }
        customProviderApiKeys.withLock { $0 = [:] }
        loadModels()
        guard let coordinator = refreshCoordinator.withLock({ $0 }) else {
            return ModelsRefreshResult(aborted: options.signal?.isCancelled == true)
        }
        var effectiveOptions = options
        effectiveOptions.allowNetwork = effectiveOptions.allowNetwork && networkEnabled
        return await coordinator.refresh(effectiveOptions)
    }

    /// Compose built-in, models.json, and extension login methods in provider id order.
    public func getLoginProviders() -> [LoginProviderInfo] {
        let builtins = Dictionary(uniqueKeysWithValues: getBuiltinProviderAuth().map { ($0.id, $0) })
        return state.withLock { state in
            var extensions: [String: HookProviderConfig] = [:]
            for source in state.dynamicSourceOrder {
                for (id, config) in state.dynamicProviderConfigsBySource[source] ?? [:] {
                    extensions[id] = config
                }
            }
            let ids = Set(builtins.keys).union(state.configuredProviderOverrides.keys).union(extensions.keys)
            return ids.sorted().map { id in
                let builtin = builtins[id]
                let config = state.configuredProviderOverrides[id]
                let extensionConfig = extensions[id]
                let oauth = builtin?.oauth
                var apiKey = builtin?.apiKey
                // Upstream fabricates a method for a custom provider, or for an
                // OAuth-only provider with a configured API key.
                if apiKey == nil && (oauth == nil || extensionConfig?.apiKey != nil || config?.apiKey != nil) {
                    apiKey = ApiKeyAuthMethod(name: "API key", envVars: [], login: envApiKeyLogin(name: "API key"))
                }
                return LoginProviderInfo(id: id,
                    name: extensionConfig?.name ?? config?.name ?? builtin?.name ?? id,
                    apiKey: apiKey, oauth: oauth)
            }
        }
    }

    public func getLoginProvider(_ id: String) -> LoginProviderInfo? {
        getLoginProviders().first { $0.id == id }
    }

    public func getProviderDisplayName(_ id: String) -> String {
        getLoginProvider(id)?.name ?? id
    }

    public func isUsingOAuth(_ provider: String) -> Bool {
        if case .oauth = authStorage.get(provider) { return true }
        return false
    }

    /// Store the login result, then refresh local state without network requests.
    @discardableResult
    public func loginApiKey(_ provider: String, interaction: ProviderAuthInteraction) async throws -> AuthCredential {
        guard let info = getLoginProvider(provider) else { throw ProviderLoginError.unknownProvider(provider) }
        guard let login = info.apiKey?.login else { throw ProviderLoginError.apiKeyLoginUnsupported(info.name) }
        let result = try await login(interaction)
        let credential = AuthCredential.apiKey(ApiKeyCredential(key: result.key, env: result.env))
        authStorage.set(provider, credential: credential)
        _ = await refresh(ModelsRefreshOptions(allowNetwork: false))
        return credential
    }

    /// Remove a stored API-key or OAuth credential, then refresh local state.
    public func logout(_ provider: String) async {
        authStorage.remove(provider)
        _ = await refresh(ModelsRefreshOptions(allowNetwork: false))
    }

    public func registerProvider(_ config: HookProviderConfig, sourceId: String) {
        let configuredOverrides = state.withLock { $0.configuredModelOverrides[config.provider] ?? [:] }
        let allModels: [AnyModel] = config.models.map { definition in
            switch definition {
            case .chat(let model):
            let registered = Model(
                id: model.id,
                name: model.name ?? model.id,
                api: model.api ?? config.api,
                provider: config.provider,
                baseUrl: model.baseUrl ?? config.baseUrl,
                reasoning: model.reasoning,
                input: model.input,
                cost: model.cost,
                contextWindow: model.contextWindow,
                maxTokens: model.maxTokens,
                samplingParams: model.samplingParams,
                headers: mergeHeaders(config.headers, model.headers),
                compat: mergeCompat(config.compat, model.compat),
                thinkingLevelMap: model.thinkingLevelMap,
                inputLimits: model.inputLimits,
                promptCache: model.promptCache,
                samplingParamsByThinkingLevel: model.samplingParamsByThinkingLevel
            )
            let overridden = configuredOverrides[model.id].map { applyModelOverride(model: registered, override: $0) } ?? registered
            return .chat(normalizeProviderModel(overridden))
            case .image(let model):
                return .image(ImageModel(
                    id: model.id, name: model.name ?? model.id, api: model.api,
                    provider: config.provider, baseUrl: model.baseUrl ?? config.baseUrl,
                    input: model.input, output: model.output, cost: model.cost,
                    headers: mergeHeaders(config.headers, model.headers), inputLimits: model.inputLimits
                ))
            case .classifier(let model):
                return .classifier(ClassifierModel(
                    id: model.id, name: model.name ?? model.id, api: model.api,
                    provider: config.provider, baseUrl: model.baseUrl ?? config.baseUrl,
                    input: model.input, cost: model.cost, contextWindow: model.contextWindow,
                    headers: mergeHeaders(config.headers, model.headers), inputLimits: model.inputLimits
                ))
            }
        }

        state.withLock { state in
            if !state.dynamicSourceOrder.contains(sourceId) {
                state.dynamicSourceOrder.append(sourceId)
            }
            state.dynamicProviderConfigsBySource[sourceId, default: [:]][config.provider] = config
            var sourceModels = state.dynamicModelsBySource[sourceId] ?? [:]
            sourceModels[config.provider] = allModels.compactMap { if case .chat(let model) = $0 { return model }; return nil }
            state.dynamicModelsBySource[sourceId] = sourceModels
            var sourceNonChatModels = state.dynamicNonChatModelsBySource[sourceId] ?? [:]
            sourceNonChatModels[config.provider] = allModels.filter { $0.type != .chat }
            state.dynamicNonChatModelsBySource[sourceId] = sourceNonChatModels

            var sourceKeys = state.dynamicProviderApiKeysBySource[sourceId] ?? [:]
            if let apiKey = config.apiKey {
                sourceKeys[config.provider] = apiKey
            } else {
                sourceKeys.removeValue(forKey: config.provider)
            }
            state.dynamicProviderApiKeysBySource[sourceId] = sourceKeys.isEmpty ? nil : sourceKeys
            var sourceStreams = state.dynamicProviderStreamsBySource[sourceId] ?? [:]
            sourceStreams[config.provider] = config.streamSimple
            state.dynamicProviderStreamsBySource[sourceId] = sourceStreams.isEmpty ? nil : sourceStreams
            var sourceImages = state.dynamicProviderImagesBySource[sourceId] ?? [:]
            sourceImages[config.provider] = config.images.isEmpty ? nil : config.images
            state.dynamicProviderImagesBySource[sourceId] = sourceImages.isEmpty ? nil : sourceImages
            var sourceClassifiers = state.dynamicProviderClassifiersBySource[sourceId] ?? [:]
            sourceClassifiers[config.provider] = config.classifiers.isEmpty ? nil : config.classifiers
            state.dynamicProviderClassifiersBySource[sourceId] = sourceClassifiers.isEmpty ? nil : sourceClassifiers
            rebuildModelsLocked(&state)
        }
    }

    public func unregisterProvider(_ provider: String, sourceId: String) {
        state.withLock { state in
            state.dynamicProviderConfigsBySource[sourceId]?[provider] = nil
            state.dynamicModelsBySource[sourceId]?[provider] = nil
            state.dynamicNonChatModelsBySource[sourceId]?[provider] = nil
            if state.dynamicModelsBySource[sourceId]?.isEmpty == true {
                state.dynamicModelsBySource[sourceId] = nil
            }
            state.dynamicProviderApiKeysBySource[sourceId]?[provider] = nil
            state.dynamicProviderStreamsBySource[sourceId]?[provider] = nil
            state.dynamicProviderImagesBySource[sourceId]?[provider] = nil
            state.dynamicProviderClassifiersBySource[sourceId]?[provider] = nil
            if state.dynamicProviderApiKeysBySource[sourceId]?.isEmpty == true {
                state.dynamicProviderApiKeysBySource[sourceId] = nil
            }
            if state.dynamicProviderStreamsBySource[sourceId]?.isEmpty == true {
                state.dynamicProviderStreamsBySource[sourceId] = nil
            }
            if state.dynamicNonChatModelsBySource[sourceId]?.isEmpty == true { state.dynamicNonChatModelsBySource[sourceId] = nil }
            if state.dynamicProviderImagesBySource[sourceId]?.isEmpty == true { state.dynamicProviderImagesBySource[sourceId] = nil }
            if state.dynamicProviderClassifiersBySource[sourceId]?.isEmpty == true { state.dynamicProviderClassifiersBySource[sourceId] = nil }
            if state.dynamicModelsBySource[sourceId] == nil && state.dynamicProviderApiKeysBySource[sourceId] == nil &&
                state.dynamicProviderStreamsBySource[sourceId] == nil && state.virtualModelsBySource[sourceId] == nil {
                state.dynamicSourceOrder.removeAll { $0 == sourceId }
            }
            rebuildModelsLocked(&state)
        }
    }

    public func unregisterProviders(sourceId: String) {
        state.withLock { state in
            state.dynamicProviderConfigsBySource[sourceId] = nil
            state.dynamicModelsBySource[sourceId] = nil
            state.dynamicNonChatModelsBySource[sourceId] = nil
            state.dynamicProviderApiKeysBySource[sourceId] = nil
            state.dynamicProviderStreamsBySource[sourceId] = nil
            state.dynamicProviderImagesBySource[sourceId] = nil
            state.dynamicProviderClassifiersBySource[sourceId] = nil
            state.virtualModelsBySource[sourceId] = nil
            state.dynamicSourceOrder.removeAll { $0 == sourceId }
            rebuildModelsLocked(&state)
        }
    }

    public func find(_ provider: String, _ modelId: String) -> Model? {
        state.withLock { state in
            state.models.first { $0.provider.lowercased() == provider.lowercased() && $0.id.lowercased() == modelId.lowercased() }
        }
    }

    /// A catalog chat model that is not virtual, including models hidden by a virtual entry.
    public func getPhysicalModel(_ provider: String, _ modelId: String) -> Model? {
        state.withLock { state in
            if state.models.contains(where: { $0.provider == provider && $0.id == modelId && isVirtualModel($0) }) {
                return nil
            }
            return state.physicalModels.first { $0.provider == provider && $0.id == modelId }
        }
    }

    public func registerVirtualModel(_ definition: VirtualModelDefinition, sourceId: String) throws {
        guard !definition.provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !definition.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VirtualModelRegistrationError.emptyIdentifier
        }
        try state.withLock { state in
            if state.physicalModels.contains(where: { $0.provider == definition.provider && $0.id == definition.id }) {
                throw VirtualModelRegistrationError.physicalConflict(definition.provider, definition.id)
            }
            if !state.dynamicSourceOrder.contains(sourceId) { state.dynamicSourceOrder.append(sourceId) }
            state.virtualModelsBySource[sourceId, default: [:]][definition.provider, default: [:]][definition.id] = definition
            rebuildModelsLocked(&state)
        }
    }

    public func unregisterVirtualModel(provider: String, id: String, sourceId: String) {
        state.withLock { state in
            state.virtualModelsBySource[sourceId]?[provider]?[id] = nil
            if state.virtualModelsBySource[sourceId]?[provider]?.isEmpty == true {
                state.virtualModelsBySource[sourceId]?[provider] = nil
            }
            if state.virtualModelsBySource[sourceId]?.isEmpty == true { state.virtualModelsBySource[sourceId] = nil }
            if state.virtualModelsBySource[sourceId] == nil && state.dynamicModelsBySource[sourceId] == nil {
                state.dynamicSourceOrder.removeAll { $0 == sourceId }
            }
            rebuildModelsLocked(&state)
        }
    }

    public func resolveVirtualModel(_ model: Model, messages: [Message], reason: ModelRouteReason,
                                    thinkingLevel: ModelThinkingLevel, signal: CancellationToken? = nil,
                                    failed: AssistantMessage? = nil, state routeState: AnyCodable? = nil) async throws -> ModelRoute {
        let definition = state.withLock { state -> VirtualModelDefinition? in
            for source in state.dynamicSourceOrder.reversed() {
                if let value = state.virtualModelsBySource[source]?[model.provider]?[model.id] { return value }
            }
            return nil
        }
        guard let definition else { throw VirtualModelRegistrationError.notRegistered(model.provider, model.id) }
        let latest = messages.reversed().compactMap { message -> AssistantMessage? in
            guard case .assistant(let response) = message,
                  response.stopReason != .error && response.stopReason != .aborted else { return nil }
            return response
        }.first
        let previous = latest.flatMap { response -> ModelRouteResponse? in
            guard let physical = getPhysicalModel(response.provider, response.model) else { return nil }
            return ModelRouteResponse(model: physical, thinkingLevel: response.thinkingLevel)
        }
        let failedRoute = failed.flatMap { response -> ModelRouteFailure? in
            guard let physical = getPhysicalModel(response.provider, response.model) else { return nil }
            return ModelRouteFailure(model: physical, thinkingLevel: response.thinkingLevel, message: response)
        }
        let request = ModelRouteRequest(model: model, thinkingLevel: thinkingLevel, reason: reason,
                                        previous: previous, failed: failedRoute, state: routeState,
                                        messages: messages, signal: signal)
        let route = try await definition.route(request)
        guard let physical = getPhysicalModel(route.model.provider, route.model.id) else {
            throw VirtualModelRegistrationError.invalidTarget(model.provider, model.id, route.model.provider, route.model.id)
        }
        guard hasConfiguredAuth(physical) else {
            throw VirtualModelRegistrationError.unauthenticatedTarget(model.provider, model.id, physical.provider, physical.id)
        }
        return ModelRoute(model: physical, thinkingLevel: clampThinkingLevel(model: physical, requested: route.thinkingLevel), state: route.state)
    }

    public func getAvailable() async -> [Model] {
        let models = state.withLock { $0.models }
        var available: [Model] = []
        for model in models {
            if await isAvailable(model) {
                available.append(model)
            }
        }
        return available
    }

    public func isAvailable(_ model: Model) async -> Bool {
        guard hasConfiguredAuth(model) else { return false }
        if isVirtualModel(model) { return true }
        guard model.provider == OAuthProvider.githubCopilot.rawValue else { return true }
        guard let supportedIds = await githubCopilotSupportedModelIds() else { return true }
        return supportedIds.contains(model.id)
    }

    /// Whether a model has usable provider authentication or request headers configured.
    /// Header-only local and extension providers are valid even when they do not use an API key.
    private func hasProviderConfiguredAuth(_ provider: String) -> Bool {
        if authStorage.has(provider) || authStorage.getRuntimeApiKey(provider) != nil { return authStorage.hasAuth(provider) }
        if let key = requestConfiguration(provider: provider).key { return isConfigValueConfigured(key) }
        return authStorage.hasAuth(provider)
    }

    public func hasConfiguredAuth(_ model: Model) -> Bool {
        if isVirtualModel(model) {
            let physical = state.withLock { state in
                state.physicalModels.filter { $0.provider == model.provider }
            }
            return physical.isEmpty || hasProviderConfiguredAuth(model.provider) ||
                physical.contains { !($0.headers?.isEmpty ?? true) }
        }
        if requestConfiguration(provider: model.provider).key != nil { return hasProviderConfiguredAuth(model.provider) }
        return hasProviderConfiguredAuth(model.provider) || !(model.headers?.isEmpty ?? true)
    }

    public func getProviderAuthStatus(_ provider: String, env: [String: String]? = nil) -> ProviderAuthStatus {
        if authStorage.getRuntimeApiKey(provider) != nil { return ProviderAuthStatus(configured: true, source: "runtime") }
        if authStorage.has(provider) { return ProviderAuthStatus(configured: true, source: "stored") }
        let configuration = requestConfiguration(provider: provider)
        if let value = configuration.key {
            if isCommandConfigValue(value) { return ProviderAuthStatus(configured: true, source: "models_json_command") }
            let names = getConfigValueEnvVarNames(value)
            if !names.isEmpty {
                return isConfigValueConfigured(value)
                    ? ProviderAuthStatus(configured: true, source: "environment", label: names.joined(separator: ", "))
                    : ProviderAuthStatus(configured: false)
            }
            return ProviderAuthStatus(configured: true, source: configuration.extensionKey ? "fallback" : "models_json_key")
        }
        let label = findEnvKeys(provider: provider, env: env)?.joined(separator: ", ") ?? ambientAuthSource(provider: provider, env: env)
        return getEnvApiKey(provider: provider, env: env) != nil || label != nil
            ? ProviderAuthStatus(configured: true, source: "environment", label: label)
            : ProviderAuthStatus(configured: false)
    }

    public func getAll() -> [Model] {
        state.withLock { $0.models }
    }

    public func getAllModels(provider: String? = nil) -> [AnyModel] {
        state.withLock { state in
            state.allModels.filter { provider == nil || $0.provider == provider }
        }
    }

    public func getModelsOfType(_ type: ModelType, provider: String? = nil) -> [AnyModel] {
        getAllModels(provider: provider).filter { $0.type == type }
    }

    public func getModelOfType(_ type: ModelType, provider: String, modelId: String) -> AnyModel? {
        getModelsOfType(type, provider: provider).first { $0.id == modelId }
    }

    public func getAvailableOfType(_ type: ModelType, provider: String? = nil) async -> [AnyModel] {
        var result: [AnyModel] = []
        for model in getModelsOfType(type, provider: provider) where await isAvailable(model) {
            result.append(model)
        }
        return result
    }

    public func getAllAvailable(provider: String? = nil) async -> [AnyModel] {
        var result: [AnyModel] = []
        for model in getAllModels(provider: provider) where await isAvailable(model) {
            result.append(model)
        }
        return result
    }

    private func isAvailable(_ model: AnyModel) async -> Bool {
        if case .chat(let chat) = model { return await isAvailable(chat) }
        if requestConfiguration(provider: model.provider).key != nil { return hasProviderConfiguredAuth(model.provider) }
        return hasProviderConfiguredAuth(model.provider) || !(model.catalog.headers?.isEmpty ?? true)
    }

    public func generateImages(_ model: ImageModel, context: ImagesContext, options: ImagesOptions? = nil) async -> AssistantImages {
        let resolved = await resolveModelRequest(model, signal: options?.signal, env: options?.env)
        let auth = resolved.auth
        guard auth.ok || options?.apiKey != nil || options?.headers?.isEmpty == false else {
            return AssistantImages(api: model.api, provider: model.provider, model: model.id,
                                   stopReason: options?.signal?.isCancelled == true ? .aborted : .error,
                                   errorMessage: auth.error)
        }
        var request = options ?? ImagesOptions()
        request.env = mergeConfigEnvironment(auth.env, request.env)
        request.apiKey = request.apiKey ?? auth.apiKey
        request.headers = mergeProviderHeaders(auth.headers, request.headers)
        if let implementation = extensionImages(for: resolved.model) {
            return await implementation(resolved.model, context, request)
        }
        return await PiSwiftAI.generateImages(model: resolved.model, context: context, options: request)
    }

    public func classify(_ model: ClassifierModel, context: ClassifierContext, options: ClassifierOptions? = nil) async -> ClassifierResult {
        let resolved = await resolveModelRequest(model, signal: options?.signal, env: options?.env)
        let auth = resolved.auth
        guard auth.ok || options?.apiKey != nil || options?.headers?.isEmpty == false else {
            return ClassifierResult(api: model.api, provider: model.provider, model: model.id,
                                    stopReason: options?.signal?.isCancelled == true ? .aborted : .error,
                                    errorMessage: auth.error)
        }
        var request = options ?? ClassifierOptions()
        request.env = mergeConfigEnvironment(auth.env, request.env)
        request.apiKey = request.apiKey ?? auth.apiKey
        request.headers = mergeProviderHeaders(auth.headers, request.headers)
        if let implementation = extensionClassifier(for: resolved.model) {
            return await implementation(resolved.model, context, request)
        }
        return await PiSwiftAI.classify(model: resolved.model, context: context, options: request)
    }

    private func extensionImages(for model: ImageModel) -> ImageApiFunction? {
        state.withLock { state in
            for source in state.dynamicSourceOrder.reversed() {
                if let implementation = state.dynamicProviderImagesBySource[source]?[model.provider]?[model.api] {
                    return implementation
                }
            }
            return nil
        }
    }

    private func extensionClassifier(for model: ClassifierModel) -> ClassifierFunction? {
        state.withLock { state in
            for source in state.dynamicSourceOrder.reversed() {
                if let implementation = state.dynamicProviderClassifiersBySource[source]?[model.provider]?[model.api] {
                    return implementation
                }
            }
            return nil
        }
    }

    public func resolveModelRequest(_ model: ImageModel, signal: CancellationToken? = nil, env: [String: String]? = nil) async -> ResolvedImageModelRequest {
        let auth = await getApiKeyAndHeaders(provider: model.provider, headers: model.headers, modelId: model.id, type: .image, signal: signal, env: env)
        return ResolvedImageModelRequest(model: model, auth: auth)
    }

    public func resolveModelRequest(_ model: ClassifierModel, signal: CancellationToken? = nil, env: [String: String]? = nil) async -> ResolvedClassifierModelRequest {
        let auth = await getApiKeyAndHeaders(provider: model.provider, headers: model.headers, modelId: model.id, type: .classifier, signal: signal, env: env)
        return ResolvedClassifierModelRequest(model: model, auth: auth)
    }

    private struct RequestConfiguration {
        var key: String?
        var headers: ProviderHeaders?
        var modelHeaders: ProviderHeaders?
        var authHeader: Bool
        var extensionKey: Bool
    }

    private func requestConfiguration(provider: String, modelId: String? = nil, type: ModelType = .chat) -> RequestConfiguration {
        state.withLock { state in
            let config = state.configuredProviderOverrides[provider]
            let extensionConfig = state.dynamicSourceOrder.reversed().compactMap {
                state.dynamicProviderConfigsBySource[$0]?[provider]
            }.first
            var modelHeaders: ProviderHeaders?
            if let modelId {
                if type == .chat {
                    modelHeaders = mergeProviderHeaders(state.configuredModelOverrides[provider]?[modelId]?.headers, config?.modelHeaders[modelId])
                }
                let definitionHeaders = extensionConfig?.models.compactMap { definition -> ProviderHeaders? in
                    switch definition {
                    case .chat(let value): return type == .chat && value.id == modelId ? value.headers : nil
                    case .image(let value): return type == .image && value.id == modelId ? value.headers : nil
                    case .classifier(let value): return type == .classifier && value.id == modelId ? value.headers : nil
                    }
                }.first
                modelHeaders = mergeProviderHeaders(modelHeaders, definitionHeaders)
            }
            return RequestConfiguration(
                key: extensionConfig?.apiKey ?? config?.apiKey,
                headers: mergeProviderHeaders(config?.headers, extensionConfig?.headers),
                modelHeaders: modelHeaders,
                authHeader: extensionConfig?.authHeader ?? config?.authHeader ?? false,
                extensionKey: extensionConfig?.apiKey != nil
            )
        }
    }

    private func getApiKeyAndHeaders(provider: String, headers: ProviderHeaders?, modelId: String, type: ModelType,
                                    signal: CancellationToken?, env: [String: String]? = nil) async -> ModelAuth {
        let configuration = requestConfiguration(provider: provider, modelId: modelId, type: type)
        // Reload before deciding credential precedence. Scoped values belong to the
        // credential; request overrides apply to provider configuration and model headers.
        let storedKey = await authStorage.getApiKey(provider, signal: signal, includeFallback: false, env: env)
        let runtimeKey = authStorage.getRuntimeApiKey(provider)
        let credential = runtimeKey == nil ? authStorage.get(provider) : nil
        let credentialEnv = runtimeKey == nil ? authStorage.getProviderEnv(provider) : nil
        // auth/resolve overlays request env on API-key credentials. Stored OAuth
        // toAuth receives the credential unchanged; only model headers use overrides.
        let isOAuth: Bool
        if case .oauth = credential { isOAuth = true } else { isOAuth = false }
        let scopedEnv = isOAuth ? credentialEnv : mergeConfigEnvironment(credentialEnv, env)
        if signal?.isCancelled == true {
            return ModelAuth(ok: false, apiKey: nil, headers: nil, error: "Authentication cancelled")
        }
        do {
            let hasCredential = credential != nil || runtimeKey != nil
            let apiKey: String?
            if !hasCredential, let rawKey = configuration.key {
                apiKey = try resolveConfigValueOrThrow(rawKey, description: "API key for provider \"\(provider)\"", env: scopedEnv)
            } else if provider == "anthropic", case .apiKey(let value) = credential, value.key?.isEmpty == true {
                // The upstream resolver treats an empty stored key as absent.
                apiKey = getEnvApiKey(provider: provider, env: scopedEnv)
            } else { apiKey = storedKey }
            var requestApiKey = apiKey
            var inheritedHeaders: ProviderHeaders?
            // AuthResult.env is the provider resolver's result. OAuth uses the
            // credential bag for provider headers only; configured and ambient
            // standard keys do not return an environment bag.
            var resultEnv = hasCredential && !isOAuth ? scopedEnv : nil
            var hasResolution = apiKey != nil
            let hasStoredApiKey: Bool
            if case .apiKey(let value) = credential { hasStoredApiKey = value.key?.isEmpty == false }
            else { hasStoredApiKey = false }
            if provider == "anthropic", runtimeKey == nil, !isOAuth, !hasStoredApiKey,
               hasCredential || configuration.key == nil,
               let token = getProviderEnvValue("ANTHROPIC_AUTH_TOKEN", env: scopedEnv), !token.isEmpty {
                // Auth tokens use Bearer transport. OAuth tokens and API keys
                // continue through the API-key path.
                inheritedHeaders = ["Authorization": "Bearer \(token)"]
                requestApiKey = nil
            }
            if provider == "anthropic", apiKey == nil,
               let federation = anthropicFederationEnv(env: providerEnvironment(scopedEnv)) {
                resultEnv = federation
                hasResolution = true
            }
            if provider == "amazon-bedrock" || provider == "google-vertex" {
                let hasStoredKey: Bool
                if case .apiKey(let value) = credential { hasStoredKey = value.key != nil }
                else { hasStoredKey = false }
                let hasExplicitKey = runtimeKey != nil || hasStoredKey || (!hasCredential && configuration.key != nil)
                // The AI compatibility API uses this marker for ambient cloud
                // auth. The canonical request auth has no API key in that case.
                if apiKey == "<authenticated>" && !hasExplicitKey { requestApiKey = nil }
                if provider == "google-vertex", requestApiKey != nil { resultEnv = nil }
            }
            if provider == "cloudflare-workers-ai" || provider == "cloudflare-ai-gateway" {
                let account = (hasCredential ? scopedEnv?["CLOUDFLARE_ACCOUNT_ID"] : nil) ?? getProviderEnvValue("CLOUDFLARE_ACCOUNT_ID", env: env)
                let gateway = (hasCredential ? scopedEnv?["CLOUDFLARE_GATEWAY_ID"] : nil) ?? getProviderEnvValue("CLOUDFLARE_GATEWAY_ID", env: env)
                if let apiKey, !apiKey.isEmpty, let account, !account.isEmpty,
                   provider != "cloudflare-ai-gateway" || gateway?.isEmpty == false {
                    resultEnv = ["CLOUDFLARE_ACCOUNT_ID": account]
                    if provider == "cloudflare-ai-gateway", let gateway {
                        resultEnv?["CLOUDFLARE_GATEWAY_ID"] = gateway
                        inheritedHeaders = ["cf-aig-authorization": "Bearer \(apiKey)", "Authorization": nil, "x-api-key": nil]
                        requestApiKey = nil
                    }
                } else {
                    hasResolution = false
                    requestApiKey = nil
                    resultEnv = nil
                }
            }
            let headerEnv = mergeConfigEnvironment(scopedEnv, resultEnv)
            // Upstream uses provider descriptions with auth, and model descriptions
            // for the compatibility fallback when provider auth is unconfigured.
            let providerHeaders = hasResolution
                ? try resolveHeadersOrThrow(configuration.headers, description: "provider \"\(provider)\"", env: headerEnv)
                : nil
            let configuredHeaders: ProviderHeaders?
            if hasResolution {
                configuredHeaders = try resolveHeadersOrThrow(configuration.modelHeaders, description: "model \"\(provider)/\(modelId)\"", env: mergeConfigEnvironment(resultEnv, env))
            } else {
                configuredHeaders = try resolveHeadersOrThrow(
                    mergeProviderHeaders(configuration.headers, configuration.modelHeaders),
                    description: "model \"\(provider)/\(modelId)\"")
            }
            var resolved = mergeProviderHeaders(mergeProviderHeaders(headers, inheritedHeaders), providerHeaders)
            if configuration.authHeader {
                guard let apiKey = requestApiKey, !apiKey.isEmpty else {
                    return ModelAuth(ok: false, apiKey: nil, headers: nil, error: "No API key found for \"\(provider)\"")
                }
                resolved = mergeProviderHeaders(resolved, ["Authorization": "Bearer \(apiKey)"])
            }
            // Model headers have the final priority, as model-runtime.getAuth does.
            resolved = mergeProviderHeaders(resolved, configuredHeaders)
            if provider == OAuthProvider.kimiCoding.rawValue, case .oauth(let credential) = authStorage.get(provider) {
                resolved = mergeProviderHeaders(resolved, ["Authorization": "Bearer \(credential.access)"])
            }
            return ModelAuth(ok: true, apiKey: requestApiKey, headers: resolved, error: nil, env: hasResolution ? resultEnv : nil, hasResolvedAuth: hasResolution)
        } catch {
            return ModelAuth(ok: false, apiKey: nil, headers: nil, error: error.localizedDescription)
        }
    }

    public func getApiKeyForProvider(_ provider: String) async -> String? {
        let stored = await authStorage.getApiKey(provider, includeFallback: false)
        if authStorage.has(provider) || authStorage.getRuntimeApiKey(provider) != nil { return stored }
        if let key = requestConfiguration(provider: provider).key {
            return try? resolveConfigValueOrThrow(key, description: "API key for provider \"\(provider)\"")
        }
        return stored
    }

    /// Configured keys and headers resolve for each request, uncached, as in
    /// upstream provider-composer. Stored command keys retain the auth-storage cache.
    public func getApiKeyAndHeaders(_ model: Model, signal: CancellationToken? = nil, env: [String: String]? = nil) async -> ModelAuth {
        let auth = await getApiKeyAndHeaders(provider: model.provider, headers: model.headers, modelId: model.id,
                                            type: .chat, signal: signal, env: env)
        guard auth.ok else { return auth }
        return ModelAuth(ok: true, apiKey: auth.apiKey, headers: auth.headers,
                         baseUrl: dynamicBaseUrl(for: model, apiKey: auth.apiKey), error: nil, env: auth.env, hasResolvedAuth: auth.hasResolvedAuth)
    }

    public func resolveModelRequest(_ model: Model, signal: CancellationToken? = nil, env: [String: String]? = nil) async -> ResolvedModelRequest {
        let auth = await getApiKeyAndHeaders(model, signal: signal, env: env)
        return ResolvedModelRequest(model: applyBaseUrlOverride(model, auth.baseUrl), auth: auth)
    }

    /// Stream with the provider registered for this model. Credentials are resolved when the
    /// returned stream starts, including credentials supplied by an extension provider.
    public func stream(model: Model, context: Context, options: StreamOptions? = nil) -> AssistantMessageEventStream {
        let startedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let output = AssistantMessageEventStream()
        if isVirtualModel(model) {
            output.setOnStart { [weak output] in
                guard let output else { return }
                Task { await self.forwardStream(model: model, context: context, fullOptions: options, simpleOptions: nil, output: output, startedAt: startedAt) }
            }
        } else {
            Task { await forwardStream(model: model, context: context, fullOptions: options, simpleOptions: nil, output: output, startedAt: startedAt) }
        }
        return output
    }

    /// Stream with provider-neutral options and request-time authentication.
    public func streamSimple(model: Model, context: Context, options: SimpleStreamOptions? = nil) -> AssistantMessageEventStream {
        let startedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let output = AssistantMessageEventStream()
        if isVirtualModel(model) {
            output.setOnStart { [weak output] in
                guard let output else { return }
                Task { await self.forwardStream(model: model, context: context, fullOptions: nil, simpleOptions: options ?? SimpleStreamOptions(), output: output, startedAt: startedAt) }
            }
        } else {
            Task { await forwardStream(model: model, context: context, fullOptions: nil, simpleOptions: options ?? SimpleStreamOptions(), output: output, startedAt: startedAt) }
        }
        return output
    }

    private func extensionStream(for model: Model) -> ApiStreamSimpleFunction? {
        state.withLock { state in
            for source in state.dynamicSourceOrder.reversed() {
                if let callback = state.dynamicProviderStreamsBySource[source]?[model.provider],
                   state.dynamicModelsBySource[source]?[model.provider]?.contains(where: { $0.api == model.api }) == true {
                    return callback
                }
            }
            return nil
        }
    }

    private func forwardStream(
        model: Model,
        context: Context,
        fullOptions: StreamOptions?,
        simpleOptions: SimpleStreamOptions?,
        output: AssistantMessageEventStream,
        startedAt: Int64
    ) async {
        do {
            if isVirtualModel(model) {
                guard var options = simpleOptions else {
                    throw ModelRegistryStreamError.authentication("Virtual model \(model.provider)/\(model.id) must be routed before streaming")
                }
                let route = try await resolveVirtualModel(
                    model, messages: normalizeContext(context).messages, reason: .direct,
                    thinkingLevel: options.reasoning.flatMap { ModelThinkingLevel(rawValue: $0.rawValue) } ?? .off,
                    signal: options.signal
                )
                if let budget = options.maxTokens, route.model.maxTokens > 0 {
                    options.maxTokens = min(budget, route.model.maxTokens)
                }
                let physicalReasoning: PiSwiftAI.ThinkingLevel?
                if route.thinkingLevel == .off {
                    physicalReasoning = nil
                } else {
                    physicalReasoning = PiSwiftAI.ThinkingLevel(rawValue: route.thinkingLevel.rawValue)
                }
                options.reasoning = physicalReasoning
                if route.model.provider != model.provider {
                    options.apiKey = nil
                    options.headers = nil
                }
                await forwardStream(model: route.model, context: context, fullOptions: nil,
                                    simpleOptions: options, output: output, startedAt: startedAt)
                return
            }
            let signal = fullOptions?.signal ?? simpleOptions?.signal
            let resolved = await resolveModelRequest(model, signal: signal, env: simpleOptions?.env ?? fullOptions?.env)
            let suppliedKey = fullOptions?.apiKey ?? simpleOptions?.apiKey
            let suppliedHeaders = fullOptions?.headers ?? simpleOptions?.headers
            guard signal?.isCancelled != true else { throw ModelRegistryStreamError.cancelled }
            guard resolved.auth.ok || suppliedKey != nil || suppliedHeaders?.isEmpty == false else {
                throw ModelRegistryStreamError.authentication(resolved.auth.error ?? "Provider is not configured: \(model.provider)")
            }

            let input: AssistantMessageEventStream
            if let customStream = extensionStream(for: model) {
                var options = simpleOptions ?? SimpleStreamOptions(
                    env: fullOptions?.env,
                    temperature: fullOptions?.temperature,
                    samplingParams: fullOptions?.samplingParams,
                    maxTokens: fullOptions?.maxTokens,
                    signal: fullOptions?.signal,
                    apiKey: fullOptions?.apiKey,
                    httpClient: fullOptions?.httpClient,
                    transport: fullOptions?.transport,
                    cacheRetention: fullOptions?.cacheRetention,
                    sessionId: fullOptions?.sessionId,
                    headers: fullOptions?.headers,
                    onPayload: fullOptions?.onPayload,
                    maxRetryDelayMs: fullOptions?.maxRetryDelayMs,
                    metadata: fullOptions?.metadata,
                    onResponse: fullOptions?.onResponse,
                    onProviderStreamEvent: fullOptions?.onProviderStreamEvent,
                    timeoutMs: fullOptions?.timeoutMs,
                    websocketConnectTimeoutMs: fullOptions?.websocketConnectTimeoutMs,
                    maxRetries: fullOptions?.maxRetries
                )
                options.env = mergeConfigEnvironment(resolved.auth.env, options.env)
                options.apiKey = options.apiKey ?? resolved.auth.apiKey
                options.headers = mergeProviderHeaders(resolved.auth.headers, options.headers)
                input = customStream(resolved.model, normalizeContext(context), options)
            } else if var options = simpleOptions {
                options.env = mergeConfigEnvironment(resolved.auth.env, options.env)
                options.apiKey = options.apiKey ?? resolved.auth.apiKey
                options.headers = mergeProviderHeaders(resolved.auth.headers, options.headers)
                input = try PiSwiftAI.streamSimple(model: resolved.model, context: context, options: options)
            } else {
                var options = fullOptions ?? StreamOptions()
                options.env = mergeConfigEnvironment(resolved.auth.env, options.env)
                options.apiKey = options.apiKey ?? resolved.auth.apiKey
                options.headers = mergeProviderHeaders(resolved.auth.headers, options.headers)
                input = try PiSwiftAI.stream(model: resolved.model, context: context, options: options)
            }
            for await event in input { output.push(event) }
            output.end(await input.result())
        } catch {
            let failed = AssistantMessage(
                content: [], api: model.api, provider: model.provider, model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                stopReason: .error, errorMessage: error.localizedDescription, timestamp: startedAt
            )
            output.push(.error(reason: .error, error: failed))
            output.end()
        }
    }

    private func dynamicBaseUrl(for model: Model, apiKey: String?) -> String? {
        guard model.provider == OAuthProvider.githubCopilot.rawValue else { return nil }
        let enterpriseDomain: String? = {
            if case .oauth(let oauth) = authStorage.get(model.provider) {
                return oauth.enterpriseUrl
            }
            return nil
        }()
        return getGitHubCopilotBaseUrl(token: apiKey, enterpriseDomain: enterpriseDomain)
    }

    private func applyBaseUrlOverride(_ model: Model, _ baseUrl: String?) -> Model {
        guard let baseUrl, !baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, baseUrl != model.baseUrl else {
            return model
        }
        return Model(
            id: model.id,
            name: model.name,
            api: model.api,
            provider: model.provider,
            baseUrl: baseUrl,
            reasoning: model.reasoning,
            input: model.input,
            cost: model.cost,
            contextWindow: model.contextWindow,
            maxTokens: model.maxTokens,
            samplingParams: model.samplingParams,
            headers: model.headers,
            compat: model.compat,
            thinkingLevelMap: model.thinkingLevelMap,
            inputLimits: model.inputLimits,
            promptCache: model.promptCache,
            samplingParamsByThinkingLevel: model.samplingParamsByThinkingLevel
        )
    }

    private func githubCopilotSupportedModelIds() async -> Set<String>? {
        if let cached = state.withLock({ $0.githubCopilotSupportedModelIds }) {
            return cached
        }
        if case .oauth(let oauth) = authStorage.get(OAuthProvider.githubCopilot.rawValue),
           let availableModelIds = oauth.availableModelIds {
            let ids = Set(availableModelIds)
            state.withLock { $0.githubCopilotSupportedModelIds = ids }
            return ids
        }
        guard let apiKey = await authStorage.getApiKey(OAuthProvider.githubCopilot.rawValue) else {
            return nil
        }
        let enterpriseDomain: String? = {
            if case .oauth(let oauth) = authStorage.get(OAuthProvider.githubCopilot.rawValue) {
                return oauth.enterpriseUrl
            }
            return nil
        }()
        let baseUrl = getGitHubCopilotBaseUrl(token: apiKey, enterpriseDomain: enterpriseDomain)
        guard let url = URL(string: baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/models") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("GitHubCopilotChat/0.35.0", forHTTPHeaderField: "User-Agent")
        request.setValue("vscode/1.107.0", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.35.0", forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue("vscode-chat", forHTTPHeaderField: "Copilot-Integration-Id")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let root = try JSONSerialization.jsonObject(with: stripUTF8BOM(data)) as? [String: Any],
                  let entries = root["data"] as? [[String: Any]] else {
                return nil
            }
            let ids = Set(entries.compactMap { $0["id"] as? String })
            state.withLock { $0.githubCopilotSupportedModelIds = ids }
            return ids
        } catch {
            return nil
        }
    }

    private func loadModels() {
        let customResult = modelsDir.map(loadCustomModels) ?? emptyCustomModelsResult()
        if let errorMessage = customResult.errorMessage {
            state.withLock { $0.errorMessage = errorMessage }
        }
        let builtInModels = loadBuiltInModels(
            overrides: customResult.overrides,
            modelOverrides: customResult.modelOverrides
        )
        state.withLock { state in
            state.baseModels = builtInModels
            state.userModels = customResult.models
            state.configuredProviderOverrides = customResult.overrides
            state.configuredModelOverrides = customResult.modelOverrides
            rebuildModelsLocked(&state)
        }
    }

    private func rebuildModelsLocked(_ state: inout State) {
        var combined = state.baseModels
        if let providers = state.dynamicModelsBySource[remoteCatalogSourceId] {
            for provider in providers.keys.sorted() {
                let configured = (providers[provider] ?? []).map {
                    applyConfiguredRemoteModel($0, state: state)
                }
                combined = mergeCustomModels(builtInModels: combined, customModels: configured)
            }
        }

        // Explicit models.json entries are applied after pi.dev, so user configuration wins.
        let configuredUserModels = state.userModels.map { model in
            state.configuredModelOverrides[model.provider]?[model.id].map {
                applyModelOverride(model: model, override: $0)
            } ?? model
        }
        combined = mergeCustomModels(builtInModels: combined, customModels: configuredUserModels)

        for sourceId in state.dynamicSourceOrder where sourceId != remoteCatalogSourceId {
            guard let providers = state.dynamicModelsBySource[sourceId] else { continue }
            for provider in providers.keys.sorted() {
                // An extension's model list replaces the whole provider catalog.
                combined.removeAll { $0.provider == provider }
                combined += providers[provider] ?? []
            }
        }
        state.physicalModels = combined
        var listed = combined
        for sourceId in state.dynamicSourceOrder {
            guard let providers = state.virtualModelsBySource[sourceId] else { continue }
            for provider in providers.keys.sorted() {
                for id in (providers[provider] ?? [:]).keys.sorted() {
                    guard let definition = providers[provider]?[id] else { continue }
                    listed.removeAll { $0.provider == provider && $0.id == id }
                    listed.append(definition.model)
                }
            }
        }
        state.models = listed
        var all = PiSwiftAI.getAllModels().map { applyConfiguredNonChatModel($0, state: state) }
        // Chat overlays use the same order as the chat-only snapshot.
        all.removeAll { $0.type == .chat }
        all += listed.map(AnyModel.chat)
        for provider in state.remoteModelsByProvider.keys.sorted() {
            for raw in state.remoteModelsByProvider[provider] ?? [] where raw.type != .chat {
                let model = applyConfiguredNonChatModel(raw, state: state)
                if let index = all.firstIndex(where: { $0.type == model.type && $0.provider == model.provider && $0.id == model.id }) {
                    all[index] = model
                } else {
                    all.append(model)
                }
            }
        }
        for sourceId in state.dynamicSourceOrder where sourceId != remoteCatalogSourceId {
            guard let providers = state.dynamicNonChatModelsBySource[sourceId] else { continue }
            for provider in providers.keys.sorted() {
                all.removeAll { $0.provider == provider && $0.type != .chat }
                all += providers[provider] ?? []
            }
        }
        state.allModels = all
    }

    private func applyConfiguredNonChatModel(_ model: AnyModel, state: State) -> AnyModel {
        guard let providerOverride = state.configuredProviderOverrides[model.provider] else { return model }
        let headers = mergeProviderHeaders(model.catalog.headers, providerOverride.headers)
        switch model {
        case .chat: return model
        case .image(let value):
            return .image(ImageModel(id: value.id, name: value.name, api: value.api,
                provider: value.provider, baseUrl: providerOverride.baseUrl ?? value.baseUrl,
                input: value.input, output: value.output, cost: value.cost,
                headers: headers, inputLimits: value.inputLimits))
        case .classifier(let value):
            return .classifier(ClassifierModel(id: value.id, name: value.name, api: value.api,
                provider: value.provider, baseUrl: providerOverride.baseUrl ?? value.baseUrl,
                input: value.input, cost: value.cost, contextWindow: value.contextWindow,
                headers: headers, inputLimits: value.inputLimits))
        }
    }

    private func setRemoteCatalogModels(_ models: [AnyModel], providerId: String) {
        state.withLock { state in
            state.remoteModelsByProvider[providerId] = models
            state.dynamicSourceOrder.removeAll { $0 == remoteCatalogSourceId }
            state.dynamicSourceOrder.insert(remoteCatalogSourceId, at: 0)
            var sourceModels = state.dynamicModelsBySource[remoteCatalogSourceId] ?? [:]
            sourceModels[providerId] = models.compactMap { if case .chat(let chat) = $0 { return chat } else { return nil } }
            state.dynamicModelsBySource[remoteCatalogSourceId] = sourceModels
            rebuildModelsLocked(&state)
        }
    }

    private func applyConfiguredRemoteModel(_ model: Model, state: State) -> Model {
        let providerOverride = state.configuredProviderOverrides[model.provider]
        let resolvedHeaders = providerOverride?.headers
        let headers = mergeProviderHeaders(model.headers, resolvedHeaders)
        var configured = Model(
            id: model.id,
            name: model.name,
            api: model.api,
            provider: model.provider,
            baseUrl: providerOverride?.baseUrl ?? model.baseUrl,
            reasoning: model.reasoning,
            input: model.input,
            cost: model.cost,
            contextWindow: model.contextWindow,
            maxTokens: model.maxTokens,
            samplingParams: model.samplingParams,
            headers: headers,
            compat: mergeCompat(model.compat, providerOverride?.compat),
            thinkingLevelMap: model.thinkingLevelMap,
            inputLimits: model.inputLimits,
            promptCache: model.promptCache,
            samplingParamsByThinkingLevel: model.samplingParamsByThinkingLevel
        )
        if let override = state.configuredModelOverrides[model.provider]?[model.id] {
            configured = applyModelOverride(model: configured, override: override)
        }
        return normalizeProviderModel(configured)
    }

    private func mergeHeaders(_ providerHeaders: ProviderHeaders?, _ modelHeaders: ProviderHeaders?) -> ProviderHeaders? {
        mergeProviderHeaders(providerHeaders, modelHeaders)
    }

    private func loadBuiltInModels(
        overrides: [String: ProviderOverride],
        modelOverrides: [String: [String: ModelOverride]]
    ) -> [Model] {
        var models: [Model] = []
        for provider in getProviders() {
            let providerId = provider.rawValue
            let builtIns = getModels(provider: provider)
            let override = overrides[providerId]
            let resolvedHeaders = override?.headers
            let perModelOverrides = modelOverrides[providerId] ?? [:]

            for model in builtIns {
                let mergedHeaders = mergeProviderHeaders(model.headers, resolvedHeaders)
                let mergedCompat = mergeCompat(model.compat, override?.compat)

                var updated = Model(
                    id: model.id,
                    name: model.name,
                    api: model.api,
                    provider: model.provider,
                    baseUrl: override?.baseUrl ?? model.baseUrl,
                    reasoning: model.reasoning,
                    input: model.input,
                    cost: model.cost,
                    contextWindow: model.contextWindow,
                    maxTokens: model.maxTokens,
                    samplingParams: model.samplingParams,
                    headers: mergedHeaders,
                    compat: mergedCompat,
                    thinkingLevelMap: model.thinkingLevelMap,
                    inputLimits: model.inputLimits,
                    promptCache: model.promptCache,
                    samplingParamsByThinkingLevel: model.samplingParamsByThinkingLevel
                )

                if let override = perModelOverrides[model.id] {
                    updated = applyModelOverride(model: updated, override: override)
                }

                models.append(normalizeProviderModel(updated))
            }

            if let apiKey = override?.apiKey {
                customProviderApiKeys.withLock { $0[providerId] = apiKey }
            }
        }
        return models
    }

    private func mergeCustomModels(builtInModels: [Model], customModels: [Model]) -> [Model] {
        var merged = builtInModels
        for custom in customModels {
            if let index = merged.firstIndex(where: { $0.provider == custom.provider && $0.id == custom.id }) {
                // Merge compat from built-in defaults so user models.json entries
                // don't lose provider compat fields they didn't explicitly set.
                let mergedCompat = mergeCompat(merged[index].compat, custom.compat)
                let withCompat = Model(
                    id: custom.id,
                    name: custom.name,
                    api: custom.api,
                    provider: custom.provider,
                    baseUrl: custom.baseUrl,
                    reasoning: custom.reasoning,
                    input: custom.input,
                    cost: custom.cost,
                    contextWindow: custom.contextWindow,
                    maxTokens: custom.maxTokens,
                    samplingParams: custom.samplingParams,
                    headers: custom.headers,
                    compat: mergedCompat,
                    thinkingLevelMap: custom.thinkingLevelMap,
                    inputLimits: custom.inputLimits,
                    promptCache: custom.promptCache,
                    samplingParamsByThinkingLevel: custom.samplingParamsByThinkingLevel
                )
                merged[index] = normalizeProviderModel(withCompat)
            } else {
                merged.append(normalizeProviderModel(custom))
            }
        }
        return merged
    }

    private func loadCustomModels(from dir: String) -> CustomModelsResult {
        let path = (dir as NSString).appendingPathComponent("models.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return emptyCustomModelsResult()
        }

        do {
            let root = try JSONSerialization.jsonObject(with: stripUTF8BOM(data))
            if let entries = root as? [[String: Any]] {
            return parseLegacyModels(entries)
        }
        guard let dict = root as? [String: Any],
              let providers = dict["providers"] as? [String: Any] else {
            return emptyCustomModelsResult(errorMessage: "models.json parse error")
            }
            return parseProviderModels(providers)
        } catch {
            return emptyCustomModelsResult(errorMessage: "models.json parse error")
        }
    }

    private func parseLegacyModels(_ entries: [[String: Any]]) -> CustomModelsResult {
        var custom: [Model] = []
        for entry in entries {
            guard let provider = entry["provider"] as? String,
                  let id = entry["id"] as? String,
                  let name = entry["name"] as? String,
                  let apiRaw = entry["api"] as? String,
                  let api = Api(rawValue: apiRaw),
                  let baseUrl = entry["baseUrl"] as? String,
                  let reasoning = entry["reasoning"] as? Bool,
                  let input = entry["input"] as? [String],
                  let contextWindow = entry["contextWindow"] as? Int,
                  let maxTokens = entry["maxTokens"] as? Int,
                  let cost = entry["cost"] as? [String: Any]
            else { continue }

            let costModel = ModelCost(
                input: cost["input"] as? Double ?? 0,
                output: cost["output"] as? Double ?? 0,
                cacheRead: cost["cacheRead"] as? Double ?? 0,
                cacheWrite: cost["cacheWrite"] as? Double ?? 0,
                tiers: parseModelCostTiers(cost["tiers"])
            )

            let model = Model(
                id: id,
                name: name,
                api: api,
                provider: provider,
                baseUrl: baseUrl,
                reasoning: reasoning,
                input: input.compactMap { ModelInput(rawValue: $0) },
                cost: costModel,
                contextWindow: contextWindow,
                maxTokens: maxTokens,
                samplingParams: parseSamplingParams(entry["samplingParams"]),
                headers: parseProviderHeaders(entry["headers"]),
                compat: parseCompat(entry["compat"]),
                thinkingLevelMap: parseThinkingLevelMap(entry["thinkingLevelMap"]),
                inputLimits: parseModelMetadata(entry["inputLimits"], as: ModelInputLimits.self),
                promptCache: parseModelMetadata(entry["promptCache"], as: ModelPromptCache.self),
                samplingParamsByThinkingLevel: parseSamplingParamsByThinkingLevel(entry["samplingParamsByThinkingLevel"])
            )
            custom.append(model)
        }
        return CustomModelsResult(models: custom, overrides: [:], modelOverrides: [:], errorMessage: nil)
    }

    private func parseProviderModels(_ providers: [String: Any]) -> CustomModelsResult {
        var custom: [Model] = []
        var overrides: [String: ProviderOverride] = [:]
        var modelOverrides: [String: [String: ModelOverride]] = [:]

        for (providerName, value) in providers {
            guard let providerConfig = value as? [String: Any] else { continue }
            let models = providerConfig["models"] as? [[String: Any]] ?? []
            if let name = providerConfig["name"], (name as? String)?.isEmpty != false {
                return CustomModelsResult(models: [], overrides: [:], modelOverrides: [:],
                    errorMessage: "Provider \(providerName): name must be a nonempty string")
            }
            let name = providerConfig["name"] as? String
            let baseUrl = providerConfig["baseUrl"] as? String
            let apiKey = providerConfig["apiKey"] as? String
            let apiOverride = providerConfig["api"] as? String
            let headers = parseProviderHeaders(providerConfig["headers"])
            let authHeader = providerConfig["authHeader"] as? Bool ?? false
            let overridesDict = providerConfig["modelOverrides"] as? [String: Any]
            let providerCompat = parseCompat(providerConfig["compat"])

            // Keep even a provider with only a name or modelOverrides in the login list.
            overrides[providerName] = ProviderOverride(name: name, baseUrl: baseUrl, headers: headers, apiKey: apiKey, compat: providerCompat, authHeader: authHeader, modelHeaders: Dictionary(models.compactMap { definition in
                    guard let id = definition["id"] as? String, let values = parseProviderHeaders(definition["headers"]) else { return nil }
                    return (id, values)
                }, uniquingKeysWith: { _, last in last }))

            if let apiKey {
                customProviderApiKeys.withLock { $0[providerName] = apiKey }
            }

            if let overridesDict {
                var parsed: [String: ModelOverride] = [:]
                for (rawModelId, value) in overridesDict {
                    guard let dict = value as? [String: Any] else { continue }
                    let modelId = rawModelId
                    let costOverride: ModelCostOverride? = {
                        guard let cost = dict["cost"] as? [String: Any] else { return nil }
                        return ModelCostOverride(
                            input: cost["input"] as? Double,
                            output: cost["output"] as? Double,
                            cacheRead: cost["cacheRead"] as? Double,
                            cacheWrite: cost["cacheWrite"] as? Double,
                            tiers: parseModelCostTiers(cost["tiers"])
                        )
                    }()

                    parsed[modelId] = ModelOverride(
                        name: dict["name"] as? String,
                        baseUrl: dict["baseUrl"] as? String,
                        reasoning: dict["reasoning"] as? Bool,
                        input: dict["input"] as? [String],
                        cost: costOverride,
                        contextWindow: dict["contextWindow"] as? Int,
                        maxTokens: dict["maxTokens"] as? Int,
                        samplingParams: parseSamplingParams(dict["samplingParams"]),
                        samplingParamsByThinkingLevel: parseSamplingParamsByThinkingLevel(dict["samplingParamsByThinkingLevel"]),
                        headers: parseProviderHeaders(dict["headers"]),
                        compat: parseCompat(dict["compat"]),
                        thinkingLevelMap: parseThinkingLevelMap(dict["thinkingLevelMap"]),
                        inputLimits: parseModelMetadata(dict["inputLimits"], as: ModelInputLimits.self),
                        promptCache: parseModelMetadata(dict["promptCache"], as: ModelPromptCache.self)
                    )
                }
                modelOverrides[providerName] = parsed
            }

            if models.isEmpty {
                continue
            }

            let providerModels = KnownProvider(rawValue: providerName).map { getModels(provider: $0) } ?? []

            for modelDef in models {
                guard let rawId = modelDef["id"] as? String else { continue }
                let modelProvider = providerName
                let id = rawId
                let name = modelDef["name"] as? String ?? id
                let reasoning = modelDef["reasoning"] as? Bool ?? false
                let input = modelDef["input"] as? [String] ?? ["text"]
                let contextWindow = modelDef["contextWindow"] as? Int ?? 128000
                let maxTokens = modelDef["maxTokens"] as? Int ?? 16384
                let cost = modelDef["cost"] as? [String: Any] ?? [:]

                let requestedAPI = ((modelDef["api"] as? String) ?? apiOverride).flatMap(Api.init(rawValue:))
                let builtInDefaults = findModelDefaults(providerModels + custom.filter { $0.provider == providerName }, modelId: id, api: requestedAPI)
                let api = requestedAPI ?? builtInDefaults?.api
                guard let api else { continue }

                let resolvedHeaders = mergeProviderHeaders(headers, parseProviderHeaders(modelDef["headers"]))

                let costModel = ModelCost(
                    input: cost["input"] as? Double ?? 0,
                    output: cost["output"] as? Double ?? 0,
                    cacheRead: cost["cacheRead"] as? Double ?? 0,
                    cacheWrite: cost["cacheWrite"] as? Double ?? 0,
                    tiers: parseModelCostTiers(cost["tiers"])
                )

                let modelBaseUrl = modelDef["baseUrl"] as? String ?? baseUrl ?? builtInDefaults?.baseUrl
                guard let modelBaseUrl else { continue }
                let compat = mergeCompat(providerCompat, parseCompat(modelDef["compat"]))
                let model = Model(
                    id: id,
                    name: name,
                    api: api,
                    provider: modelProvider,
                    baseUrl: modelBaseUrl,
                    reasoning: reasoning,
                    input: input.compactMap { ModelInput(rawValue: $0) },
                    cost: costModel,
                    contextWindow: contextWindow,
                    maxTokens: maxTokens,
                    samplingParams: parseSamplingParams(modelDef["samplingParams"]),
                    headers: resolvedHeaders,
                    compat: compat,
                    thinkingLevelMap: parseThinkingLevelMap(modelDef["thinkingLevelMap"]),
                    inputLimits: parseModelMetadata(modelDef["inputLimits"], as: ModelInputLimits.self),
                    promptCache: parseModelMetadata(modelDef["promptCache"], as: ModelPromptCache.self),
                    samplingParamsByThinkingLevel: parseSamplingParamsByThinkingLevel(modelDef["samplingParamsByThinkingLevel"])
                )
                custom.append(model)
            }
        }

        return CustomModelsResult(
            models: custom,
            overrides: overrides,
            modelOverrides: modelOverrides,
            errorMessage: nil
        )
    }
}
