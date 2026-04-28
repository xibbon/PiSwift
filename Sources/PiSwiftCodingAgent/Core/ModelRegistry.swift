import Foundation
import PiSwiftAI

/// v0.63.0: result of model-aware auth lookup. Carries the API key plus any per-model headers
/// (re-resolved on each call, so `!cmd` values pick up fresh tokens).
public struct ModelAuth: Sendable {
    public let ok: Bool
    public let apiKey: String?
    public let headers: [String: String]?
    public let error: String?

    public init(ok: Bool, apiKey: String?, headers: [String: String]?, error: String?) {
        self.ok = ok
        self.apiKey = apiKey
        self.headers = headers
        self.error = error
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
       openRouterRouting == nil,
       vercelGatewayRouting == nil,
       supportsLongCacheRetention == nil,
       sendSessionIdHeader == nil,
       supportsEagerToolInputStreaming == nil,
       cacheControlFormat == nil,
       sendSessionAffinityHeaders == nil,
       requiresReasoningContentOnAssistantMessages == nil {
        return nil
    }

    return OpenAICompat(
        supportsStore: supportsStore,
        supportsDeveloperRole: supportsDeveloperRole,
        supportsReasoningEffort: supportsReasoningEffort,
        supportsUsageInStreaming: supportsUsageInStreaming,
        maxTokensField: maxTokensField,
        requiresToolResultName: requiresToolResultName,
        requiresAssistantAfterToolResult: requiresAssistantAfterToolResult,
        requiresThinkingAsText: requiresThinkingAsText,
        requiresMistralToolIds: requiresMistralToolIds,
        thinkingFormat: thinkingFormat,
        openRouterRouting: openRouterRouting,
        vercelGatewayRouting: vercelGatewayRouting,
        supportsStrictMode: supportsStrictMode,
        supportsLongCacheRetention: supportsLongCacheRetention,
        sendSessionIdHeader: sendSessionIdHeader,
        supportsEagerToolInputStreaming: supportsEagerToolInputStreaming,
        cacheControlFormat: cacheControlFormat,
        sendSessionAffinityHeaders: sendSessionAffinityHeaders,
        requiresReasoningContentOnAssistantMessages: requiresReasoningContentOnAssistantMessages
    )
}

private struct ProviderOverride: Sendable {
    var baseUrl: String?
    var headers: [String: String]?
    var apiKey: String?
}

private struct ModelOverride: Sendable {
    var name: String?
    var baseUrl: String?
    var reasoning: Bool?
    var input: [String]?
    var cost: ModelCostOverride?
    var contextWindow: Int?
    var maxTokens: Int?
    var headers: [String: String]?
    var compat: OpenAICompat?
}

private struct ModelCostOverride: Sendable {
    var input: Double?
    var output: Double?
    var cacheRead: Double?
    var cacheWrite: Double?
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

    return OpenAICompat(
        supportsStore: override.supportsStore ?? base.supportsStore,
        supportsDeveloperRole: override.supportsDeveloperRole ?? base.supportsDeveloperRole,
        supportsReasoningEffort: override.supportsReasoningEffort ?? base.supportsReasoningEffort,
        supportsUsageInStreaming: override.supportsUsageInStreaming ?? base.supportsUsageInStreaming,
        maxTokensField: override.maxTokensField ?? base.maxTokensField,
        requiresToolResultName: override.requiresToolResultName ?? base.requiresToolResultName,
        requiresAssistantAfterToolResult: override.requiresAssistantAfterToolResult ?? base.requiresAssistantAfterToolResult,
        requiresThinkingAsText: override.requiresThinkingAsText ?? base.requiresThinkingAsText,
        requiresMistralToolIds: override.requiresMistralToolIds ?? base.requiresMistralToolIds,
        thinkingFormat: override.thinkingFormat ?? base.thinkingFormat,
        openRouterRouting: mergedOpenRouter,
        vercelGatewayRouting: mergedVercel,
        supportsStrictMode: override.supportsStrictMode ?? base.supportsStrictMode,
        // v0.68.0 / v0.70.0 / v0.70.1: new compat fields preserved from base when not overridden.
        supportsLongCacheRetention: override.supportsLongCacheRetention ?? base.supportsLongCacheRetention,
        sendSessionIdHeader: override.sendSessionIdHeader ?? base.sendSessionIdHeader,
        supportsEagerToolInputStreaming: override.supportsEagerToolInputStreaming ?? base.supportsEagerToolInputStreaming,
        cacheControlFormat: override.cacheControlFormat ?? base.cacheControlFormat,
        sendSessionAffinityHeaders: override.sendSessionAffinityHeaders ?? base.sendSessionAffinityHeaders,
        requiresReasoningContentOnAssistantMessages: override.requiresReasoningContentOnAssistantMessages ?? base.requiresReasoningContentOnAssistantMessages
    )
}

private func applyModelOverride(model: Model, override: ModelOverride) -> Model {
    var updated = model
    if let name = override.name { updated = Model(id: updated.id, name: name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: updated.input, cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens, headers: updated.headers, compat: updated.compat) }
    if let baseUrl = override.baseUrl {
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: baseUrl, reasoning: updated.reasoning, input: updated.input, cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens, headers: updated.headers, compat: updated.compat)
    }
    if let reasoning = override.reasoning {
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: reasoning, input: updated.input, cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens, headers: updated.headers, compat: updated.compat)
    }
    if let input = override.input {
        let mapped = input.compactMap { ModelInput(rawValue: $0) }
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: mapped, cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens, headers: updated.headers, compat: updated.compat)
    }
    if let contextWindow = override.contextWindow {
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: updated.input, cost: updated.cost, contextWindow: contextWindow, maxTokens: updated.maxTokens, headers: updated.headers, compat: updated.compat)
    }
    if let maxTokens = override.maxTokens {
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: updated.input, cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: maxTokens, headers: updated.headers, compat: updated.compat)
    }

    if let cost = override.cost {
        let mergedCost = ModelCost(
            input: cost.input ?? updated.cost.input,
            output: cost.output ?? updated.cost.output,
            cacheRead: cost.cacheRead ?? updated.cost.cacheRead,
            cacheWrite: cost.cacheWrite ?? updated.cost.cacheWrite
        )
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: updated.input, cost: mergedCost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens, headers: updated.headers, compat: updated.compat)
    }

    if let headers = resolveHeaders(override.headers) {
        var mergedHeaders = updated.headers ?? [:]
        for (key, value) in headers { mergedHeaders[key] = value }
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: updated.input, cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens, headers: mergedHeaders, compat: updated.compat)
    }

    let mergedCompat = mergeCompat(updated.compat, override.compat)
    if mergedCompat != nil {
        updated = Model(id: updated.id, name: updated.name, api: updated.api, provider: updated.provider, baseUrl: updated.baseUrl, reasoning: updated.reasoning, input: updated.input, cost: updated.cost, contextWindow: updated.contextWindow, maxTokens: updated.maxTokens, headers: updated.headers, compat: mergedCompat)
    }

    return updated
}

public final class ModelRegistry: Sendable {
    public let authStorage: AuthStorage
    private let modelsDir: String?
    private let state = LockedState(State())
    private let customProviderApiKeys = LockedState<[String: String]>([:])

    private struct State: Sendable {
        var models: [Model] = []
        var errorMessage: String?
    }

    public init(_ authStorage: AuthStorage, _ modelsDir: String? = nil) {
        self.authStorage = authStorage
        self.modelsDir = modelsDir
        self.authStorage.setFallbackResolver { [weak self] provider in
            guard let self else { return nil }
            let keyConfig = self.customProviderApiKeys.withLock { $0[provider] }
            if let keyConfig {
                return resolveConfigValue(keyConfig)
            }
            return nil
        }
        loadModels()
    }

    public func getError() -> String? {
        state.withLock { $0.errorMessage }
    }

    public func refresh() {
        state.withLock { $0.errorMessage = nil }
        customProviderApiKeys.withLock { $0 = [:] }
        loadModels()
    }

    public func find(_ provider: String, _ modelId: String) -> Model? {
        state.withLock { state in
            state.models.first { $0.provider.lowercased() == provider.lowercased() && $0.id.lowercased() == modelId.lowercased() }
        }
    }

    public func getAvailable() async -> [Model] {
        let models = state.withLock { $0.models }
        return models.filter { authStorage.hasAuth($0.provider) }
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
        let resolvedHeaders = resolveHeaders(model.headers)
        if apiKey == nil && (resolvedHeaders?.isEmpty ?? true) {
            return ModelAuth(
                ok: false,
                apiKey: nil,
                headers: nil,
                error: "No API key or headers configured for provider \"\(model.provider)\""
            )
        }
        return ModelAuth(ok: true, apiKey: apiKey, headers: resolvedHeaders, error: nil)
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
        let combined = mergeCustomModels(builtInModels: builtInModels, customModels: customResult.models)
        state.withLock { $0.models = combined }
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
                let mergedHeaders: [String: String]? = {
                    guard let resolvedHeaders else { return model.headers }
                    var headers = model.headers ?? [:]
                    for (key, value) in resolvedHeaders { headers[key] = value }
                    return headers
                }()

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
                    headers: mergedHeaders,
                    compat: model.compat
                )

                if let override = perModelOverrides[model.id] {
                    updated = applyModelOverride(model: updated, override: override)
                }

                models.append(updated)
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
                    headers: custom.headers,
                    compat: mergedCompat
                )
                merged[index] = withCompat
            } else {
                merged.append(custom)
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
            let root = try JSONSerialization.jsonObject(with: data)
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
                cacheWrite: cost["cacheWrite"] as? Double ?? 0
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
                headers: entry["headers"] as? [String: String],
                compat: parseCompat(entry["compat"])
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
            let headers = providerConfig["headers"] as? [String: String]
            let authHeader = providerConfig["authHeader"] as? Bool ?? false
            let overridesDict = providerConfig["modelOverrides"] as? [String: Any]

            if baseUrl != nil || headers != nil || apiKey != nil {
                overrides[providerName] = ProviderOverride(baseUrl: baseUrl, headers: headers, apiKey: apiKey)
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
                            cacheWrite: cost["cacheWrite"] as? Double
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
                        headers: dict["headers"] as? [String: String],
                        compat: parseCompat(dict["compat"])
                    )
                }
                modelOverrides[providerName] = parsed
            }

            if models.isEmpty {
                continue
            }

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

                let apiRaw = (modelDef["api"] as? String) ?? apiOverride
                guard let apiRaw, let api = Api(rawValue: apiRaw) else { continue }

                var resolvedHeaders = resolveHeaders(headers)
                if let modelHeaders = resolveHeaders(modelDef["headers"] as? [String: String]) {
                    resolvedHeaders = (resolvedHeaders ?? [:]).merging(modelHeaders) { _, new in new }
                }

                if authHeader, let apiKey, let resolvedKey = resolveConfigValue(apiKey) {
                    var headers = resolvedHeaders ?? [:]
                    headers["Authorization"] = "Bearer \(resolvedKey)"
                    resolvedHeaders = headers
                }

                let costModel = ModelCost(
                    input: cost["input"] as? Double ?? 0,
                    output: cost["output"] as? Double ?? 0,
                    cacheRead: cost["cacheRead"] as? Double ?? 0,
                    cacheWrite: cost["cacheWrite"] as? Double ?? 0
                )

                let modelBaseUrl = modelDef["baseUrl"] as? String ?? baseUrl
                guard let modelBaseUrl else { continue }
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
                    headers: resolvedHeaders,
                    compat: parseCompat(modelDef["compat"])
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
