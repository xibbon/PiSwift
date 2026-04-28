import Foundation

public func getModel(provider: KnownProvider, modelId: String) -> Model {
    guard let model = ModelsData[provider.rawValue]?[modelId] else {
        fatalError("Unknown model \(modelId) for provider \(provider.rawValue)")
    }
    return model
}

public func getModel(provider: String, modelId: String) -> Model? {
    ModelsData[provider]?[modelId]
}

public func getProviders() -> [KnownProvider] {
    ModelsData.keys.compactMap { KnownProvider(rawValue: $0) }
}

public func getModels(provider: KnownProvider) -> [Model] {
    guard let values = ModelsData[provider.rawValue]?.values else {
        return []
    }
    return Array(values)
}

@discardableResult
public func calculateCost(model: Model, usage: inout Usage) -> UsageCost {
    usage.cost.input = (model.cost.input / 1_000_000) * Double(usage.input)
    usage.cost.output = (model.cost.output / 1_000_000) * Double(usage.output)
    usage.cost.cacheRead = (model.cost.cacheRead / 1_000_000) * Double(usage.cacheRead)
    usage.cost.cacheWrite = (model.cost.cacheWrite / 1_000_000) * Double(usage.cacheWrite)
    usage.cost.total = usage.cost.input + usage.cost.output + usage.cost.cacheRead + usage.cost.cacheWrite
    return usage.cost
}

public func supportsXhigh(model: Model) -> Bool {
    if model.id.contains("gpt-5.2") || model.id.contains("gpt-5.3") {
        return true
    }
    // v0.70.0: GPT-5.5 Codex supports xhigh and must not be downgraded to high.
    if model.id.contains("gpt-5.5") {
        return true
    }
    // v0.70.3: DeepSeek V4 Pro supports xhigh; map to provider's `max` effort via reasoningEffortMap.
    if model.id.contains("deepseek") && (model.id.contains("v4-pro") || model.id.contains("v4.pro")) {
        return true
    }
    if model.api == .anthropicMessages || model.api == .bedrockConverseStream {
        // v0.67.5: Opus 4.7 joins Opus 4.6 as adaptive-thinking models with xhigh support.
        return model.id.contains("opus-4-6") || model.id.contains("opus-4.6")
            || model.id.contains("opus-4-7") || model.id.contains("opus-4.7")
    }
    return false
}

public func modelsAreEqual(_ a: Model?, _ b: Model?) -> Bool {
    guard let a, let b else { return false }
    return a.id == b.id && a.provider == b.provider
}

public struct OpenAIOptions: Sendable {
    public var apiKey: String?
    public var maxTokens: Int?
    public var temperature: Double?
    public var signal: CancellationToken?

    public init(apiKey: String? = nil, maxTokens: Int? = nil, temperature: Double? = nil, signal: CancellationToken? = nil) {
        self.apiKey = apiKey
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.signal = signal
    }
}
