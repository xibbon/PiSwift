import Foundation
import PiSwiftAI

private let remoteCatalogSourceId = "pi.dev"

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

/// v0.63.0: result of model-aware auth lookup. Carries the API key plus any per-model headers
/// (re-resolved on each call, so `!cmd` values pick up fresh tokens).
public struct ModelAuth: Sendable {
    public let ok: Bool
    public let apiKey: String?
    public let headers: ProviderHeaders?
    public let baseUrl: String?
    public let error: String?

    public init(ok: Bool, apiKey: String?, headers: ProviderHeaders?, baseUrl: String? = nil, error: String?) {
        self.ok = ok
        self.apiKey = apiKey
        self.headers = headers
        self.baseUrl = baseUrl
        self.error = error
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
    "thinkingTokenBudgetField",
    "supportsOpenAIGrammarTools",
    "supportsToolSearch",
    "supportsTemperature",
    "supportsCacheControlOnTools",
    "forceAdaptiveThinking",
    "allowEmptySignature",
    "supportsStrictTools",
    "supportsToolReferences",
    "deferredToolsMode",
    "sessionAffinityFormat",
    "chatTemplateKwargs",
    "chatTemplateArgs",
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
    var baseUrl: String?
    var headers: ProviderHeaders?
    var apiKey: String?
    var compat: OpenAICompat?
}

private struct ModelOverride: Sendable {
    var name: String?
    var baseUrl: String?
    var reasoning: Bool?
    var input: [String]?
    var cost: ModelCostOverride?
    var contextWindow: Int?
    var maxTokens: Int?
    var samplingParams: [String: AnyCodable]?
    var headers: ProviderHeaders?
    var compat: OpenAICompat?
    var thinkingLevelMap: ThinkingLevelMap?
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

private func parseSamplingParams(_ value: Any?) -> [String: AnyCodable]? {
    guard let values = value as? [String: Any] else { return nil }
    return values.mapValues(AnyCodable.init)
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
    merged.deferredToolsMode = override.deferredToolsMode ?? base.deferredToolsMode
    merged.sessionAffinityFormat = override.sessionAffinityFormat ?? base.sessionAffinityFormat
    merged.supportsToolSearch = override.supportsToolSearch ?? base.supportsToolSearch
    merged.supportsExplicitPromptCacheMode = override.supportsExplicitPromptCacheMode ?? base.supportsExplicitPromptCacheMode
    merged.supportsToolReferences = override.supportsToolReferences ?? base.supportsToolReferences
    merged.thinkingTokenBudgetField = override.thinkingTokenBudgetField ?? base.thinkingTokenBudgetField
    merged.vllmPriority = override.vllmPriority ?? base.vllmPriority
    merged.supportsAdditionalTools = override.supportsAdditionalTools ?? base.supportsAdditionalTools
    merged.supportsMaxOutputTokens = override.supportsMaxOutputTokens ?? base.supportsMaxOutputTokens
    merged.supportsMidConvoEffort = override.supportsMidConvoEffort ?? base.supportsMidConvoEffort
    merged.allowedFallbackModels = override.allowedFallbackModels ?? base.allowedFallbackModels
    return merged
}

private func applyModelOverride(model: Model, override: ModelOverride) -> Model {
    var updated = model
    if let name = override.name { updated = Model(id: updated.id, name: name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: updated.input, cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens, samplingParams: updated.samplingParams, headers: updated.headers, compat: updated.compat, thinkingLevelMap: updated.thinkingLevelMap) }
    if let baseUrl = override.baseUrl {
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: baseUrl, reasoning: updated.reasoning, input: updated.input, cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens, samplingParams: updated.samplingParams, headers: updated.headers, compat: updated.compat, thinkingLevelMap: updated.thinkingLevelMap)
    }
    if let reasoning = override.reasoning {
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: reasoning, input: updated.input, cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens, samplingParams: updated.samplingParams, headers: updated.headers, compat: updated.compat, thinkingLevelMap: updated.thinkingLevelMap)
    }
    if let input = override.input {
        let mapped = input.compactMap { ModelInput(rawValue: $0) }
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: mapped, cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens, samplingParams: updated.samplingParams, headers: updated.headers, compat: updated.compat, thinkingLevelMap: updated.thinkingLevelMap)
    }
    if let contextWindow = override.contextWindow {
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: updated.input, cost: updated.cost, contextWindow: contextWindow, maxTokens: updated.maxTokens, samplingParams: updated.samplingParams, headers: updated.headers, compat: updated.compat, thinkingLevelMap: updated.thinkingLevelMap)
    }
    if let maxTokens = override.maxTokens {
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: updated.input, cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: maxTokens, samplingParams: updated.samplingParams, headers: updated.headers, compat: updated.compat, thinkingLevelMap: updated.thinkingLevelMap)
    }
    if let samplingParams = override.samplingParams {
        let mergedSamplingParams = (updated.samplingParams ?? [:]).merging(samplingParams) { _, value in value }
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: updated.input, cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens, samplingParams: mergedSamplingParams, headers: updated.headers, compat: updated.compat, thinkingLevelMap: updated.thinkingLevelMap)
    }
    if let thinkingLevelMap = override.thinkingLevelMap {
        let mergedThinkingLevelMap = (updated.thinkingLevelMap ?? [:]).merging(thinkingLevelMap) { _, value in value }
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: updated.input, cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens, samplingParams: updated.samplingParams, headers: updated.headers, compat: updated.compat, thinkingLevelMap: mergedThinkingLevelMap)
    }

    if let cost = override.cost {
        let mergedCost = ModelCost(
            input: cost.input ?? updated.cost.input,
            output: cost.output ?? updated.cost.output,
            cacheRead: cost.cacheRead ?? updated.cost.cacheRead,
            cacheWrite: cost.cacheWrite ?? updated.cost.cacheWrite,
            tiers: cost.tiers ?? updated.cost.tiers
        )
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: updated.input, cost: mergedCost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens, samplingParams: updated.samplingParams, headers: updated.headers, compat: updated.compat, thinkingLevelMap: updated.thinkingLevelMap)
    }

    if let headers = resolveHeaders(override.headers) {
        let mergedHeaders = mergeProviderHeaders(updated.headers, headers)
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: updated.input, cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens, samplingParams: updated.samplingParams, headers: mergedHeaders, compat: updated.compat, thinkingLevelMap: updated.thinkingLevelMap)
    }

    let mergedCompat = mergeCompat(updated.compat, override.compat)
    if mergedCompat != nil {
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: updated.input, cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens, samplingParams: updated.samplingParams, headers: updated.headers, compat: mergedCompat, thinkingLevelMap: updated.thinkingLevelMap)
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
        thinkingLevelMap: model.thinkingLevelMap
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
        var baseModels: [Model] = []
        var userModels: [Model] = []
        var configuredProviderOverrides: [String: ProviderOverride] = [:]
        var configuredModelOverrides: [String: [String: ModelOverride]] = [:]
        var dynamicModelsBySource: [String: [String: [Model]]] = [:]
        var dynamicProviderApiKeysBySource: [String: [String: String]] = [:]
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
        self.authStorage.setFallbackResolver { [weak self] provider in
            guard let self else { return nil }
            let dynamicKeyConfig = self.state.withLock { state -> String? in
                for sourceId in state.dynamicSourceOrder.reversed() {
                    if let keyConfig = state.dynamicProviderApiKeysBySource[sourceId]?[provider] {
                        return keyConfig
                    }
                }
                return nil
            }
            if let dynamicKeyConfig {
                return resolveConfigValue(dynamicKeyConfig)
            }
            let keyConfig = self.customProviderApiKeys.withLock { $0[provider] }
            if let keyConfig {
                return resolveConfigValue(keyConfig)
            }
            return nil
        }
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

    public func registerProvider(_ config: HookProviderConfig, sourceId: String) {
        let configuredOverrides = state.withLock { $0.configuredModelOverrides[config.provider] ?? [:] }
        let models = config.models.map { model in
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
                thinkingLevelMap: model.thinkingLevelMap
            )
            let overridden = configuredOverrides[model.id].map { applyModelOverride(model: registered, override: $0) } ?? registered
            return normalizeProviderModel(overridden)
        }

        state.withLock { state in
            if !state.dynamicSourceOrder.contains(sourceId) {
                state.dynamicSourceOrder.append(sourceId)
            }
            var sourceModels = state.dynamicModelsBySource[sourceId] ?? [:]
            sourceModels[config.provider] = models
            state.dynamicModelsBySource[sourceId] = sourceModels

            var sourceKeys = state.dynamicProviderApiKeysBySource[sourceId] ?? [:]
            if let apiKey = config.apiKey {
                sourceKeys[config.provider] = apiKey
            } else {
                sourceKeys.removeValue(forKey: config.provider)
            }
            state.dynamicProviderApiKeysBySource[sourceId] = sourceKeys.isEmpty ? nil : sourceKeys
            rebuildModelsLocked(&state)
        }
    }

    public func unregisterProvider(_ provider: String, sourceId: String) {
        state.withLock { state in
            state.dynamicModelsBySource[sourceId]?[provider] = nil
            if state.dynamicModelsBySource[sourceId]?.isEmpty == true {
                state.dynamicModelsBySource[sourceId] = nil
            }
            state.dynamicProviderApiKeysBySource[sourceId]?[provider] = nil
            if state.dynamicProviderApiKeysBySource[sourceId]?.isEmpty == true {
                state.dynamicProviderApiKeysBySource[sourceId] = nil
            }
            if state.dynamicModelsBySource[sourceId] == nil && state.dynamicProviderApiKeysBySource[sourceId] == nil {
                state.dynamicSourceOrder.removeAll { $0 == sourceId }
            }
            rebuildModelsLocked(&state)
        }
    }

    public func unregisterProviders(sourceId: String) {
        state.withLock { state in
            state.dynamicModelsBySource[sourceId] = nil
            state.dynamicProviderApiKeysBySource[sourceId] = nil
            state.dynamicSourceOrder.removeAll { $0 == sourceId }
            rebuildModelsLocked(&state)
        }
    }

    public func find(_ provider: String, _ modelId: String) -> Model? {
        state.withLock { state in
            state.models.first { $0.provider.lowercased() == provider.lowercased() && $0.id.lowercased() == modelId.lowercased() }
        }
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
        guard model.provider == OAuthProvider.githubCopilot.rawValue else { return true }
        guard let supportedIds = await githubCopilotSupportedModelIds() else { return true }
        return supportedIds.contains(model.id)
    }

    /// Whether a model has usable provider authentication or request headers configured.
    /// Header-only local and extension providers are valid even when they do not use an API key.
    public func hasConfiguredAuth(_ model: Model) -> Bool {
        authStorage.hasAuth(model.provider) || !(model.headers?.isEmpty ?? true)
    }

    public func getAll() -> [Model] {
        state.withLock { $0.models }
    }

    /// v0.63.0: provider-only API-key lookup. Use this only when you explicitly want
    /// provider-level lookup without model headers or `authHeader` handling.
    /// For model-aware auth (which includes per-model `headers` and `compat.authHeader`
    /// resolution), call `getApiKeyAndHeaders(_ model:)` instead.
    public func getApiKeyForProvider(_ provider: String) async -> String? {
        await authStorage.getApiKey(provider)
    }

    /// v0.63.0: model-aware auth lookup. Resolves the API key from the auth store AND
    /// the model's headers (which may include per-request shell-command resolution).
    ///
    /// Header resolution runs through `resolveHeaders` on each call so values like
    /// `"Authorization": "!my-token-cmd"` re-execute their underlying command instead
    /// of returning a long-lived stale token. Pi leaves caching/TTL/recovery to the
    /// user-provided wrapper command.
    public func getApiKeyAndHeaders(_ model: Model) async -> ModelAuth {
        let apiKey = await authStorage.getApiKey(model.provider)
        // Re-resolve model.headers each time so `!cmd` values pick up fresh tokens.
        var resolvedHeaders = resolveHeaders(model.headers)
        if model.provider == OAuthProvider.kimiCoding.rawValue,
           case .oauth(let credential) = authStorage.get(model.provider) {
            var headers = resolvedHeaders ?? [:]
            headers.updateValue("Bearer \(credential.access)", forKey: "Authorization")
            resolvedHeaders = headers
        }
        if apiKey == nil && (resolvedHeaders?.isEmpty ?? true) {
            return ModelAuth(
                ok: false,
                apiKey: nil,
                headers: nil,
                baseUrl: nil,
                error: "No API key or headers configured for provider \"\(model.provider)\""
            )
        }
        let baseUrl = dynamicBaseUrl(for: model, apiKey: apiKey)
        return ModelAuth(ok: true, apiKey: apiKey, headers: resolvedHeaders, baseUrl: baseUrl, error: nil)
    }

    public func resolveModelRequest(_ model: Model) async -> ResolvedModelRequest {
        let auth = await getApiKeyAndHeaders(model)
        return ResolvedModelRequest(model: applyBaseUrlOverride(model, auth.baseUrl), auth: auth)
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
            thinkingLevelMap: model.thinkingLevelMap
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
        combined = mergeCustomModels(builtInModels: combined, customModels: state.userModels)

        for sourceId in state.dynamicSourceOrder where sourceId != remoteCatalogSourceId {
            guard let providers = state.dynamicModelsBySource[sourceId] else { continue }
            for provider in providers.keys.sorted() {
                combined = mergeCustomModels(builtInModels: combined, customModels: providers[provider] ?? [])
            }
        }
        state.models = combined
    }

    private func setRemoteCatalogModels(_ models: [Model], providerId: String) {
        state.withLock { state in
            state.dynamicSourceOrder.removeAll { $0 == remoteCatalogSourceId }
            state.dynamicSourceOrder.insert(remoteCatalogSourceId, at: 0)
            var sourceModels = state.dynamicModelsBySource[remoteCatalogSourceId] ?? [:]
            sourceModels[providerId] = models
            state.dynamicModelsBySource[remoteCatalogSourceId] = sourceModels
            rebuildModelsLocked(&state)
        }
    }

    private func applyConfiguredRemoteModel(_ model: Model, state: State) -> Model {
        let providerOverride = state.configuredProviderOverrides[model.provider]
        let resolvedHeaders = resolveHeaders(providerOverride?.headers)
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
            thinkingLevelMap: model.thinkingLevelMap
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
            let resolvedHeaders = resolveHeaders(override?.headers)
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
                    thinkingLevelMap: model.thinkingLevelMap
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
                    thinkingLevelMap: custom.thinkingLevelMap
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
                thinkingLevelMap: parseThinkingLevelMap(entry["thinkingLevelMap"])
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
            let baseUrl = providerConfig["baseUrl"] as? String
            let apiKey = providerConfig["apiKey"] as? String
            let apiOverride = providerConfig["api"] as? String
            let headers = parseProviderHeaders(providerConfig["headers"])
            let authHeader = providerConfig["authHeader"] as? Bool ?? false
            let overridesDict = providerConfig["modelOverrides"] as? [String: Any]
            let providerCompat = parseCompat(providerConfig["compat"])

            if baseUrl != nil || headers != nil || apiKey != nil || providerCompat != nil {
                overrides[providerName] = ProviderOverride(baseUrl: baseUrl, headers: headers, apiKey: apiKey, compat: providerCompat)
            }

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
                        headers: parseProviderHeaders(dict["headers"]),
                        compat: parseCompat(dict["compat"]),
                        thinkingLevelMap: parseThinkingLevelMap(dict["thinkingLevelMap"])
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

                var resolvedHeaders = resolveHeaders(headers)
                let modelHeaders = resolveHeaders(parseProviderHeaders(modelDef["headers"]))
                resolvedHeaders = mergeProviderHeaders(resolvedHeaders, modelHeaders)

                if authHeader, let apiKey, let resolvedKey = resolveConfigValue(apiKey) {
                    var headers = resolvedHeaders ?? [:]
                    headers.updateValue("Bearer \(resolvedKey)", forKey: "Authorization")
                    resolvedHeaders = headers
                }

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
                    thinkingLevelMap: parseThinkingLevelMap(modelDef["thinkingLevelMap"])
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
