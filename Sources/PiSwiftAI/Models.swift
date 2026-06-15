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

private let extendedThinkingLevels: [ModelThinkingLevel] = [.off, .minimal, .low, .medium, .high, .xhigh]

private enum ThinkingLevelMapLookup {
    case missing
    case unsupported
    case mapped(String)
}

private func lookupThinkingLevelMap(_ map: ThinkingLevelMap?, level: ModelThinkingLevel) -> ThinkingLevelMapLookup {
    guard let map else { return .missing }
    switch map[level] {
    case nil:
        return .missing
    case .some(nil):
        return .unsupported
    case .some(.some(let value)):
        return .mapped(value)
    }
}

private func inferredThinkingLevelMap(model: Model) -> ThinkingLevelMap? {
    if model.id.contains("gpt-5.2") || model.id.contains("gpt-5.3") {
        return [.xhigh: "xhigh"]
    }
    if model.id.contains("gpt-5.5") {
        return [.minimal: "low", .xhigh: "xhigh"]
    }
    if model.id.contains("deepseek") && (model.id.contains("v4-pro") || model.id.contains("v4.pro")) {
        return [.xhigh: "max"]
    }
    if model.api == .anthropicMessages || model.api == .bedrockConverseStream {
        if model.id.contains("opus-4-6") || model.id.contains("opus-4.6")
            || model.id.contains("opus-4-7") || model.id.contains("opus-4.7") {
            return [.xhigh: "xhigh"]
        }
    }
    return nil
}

private func effectiveThinkingLevelMap(model: Model) -> ThinkingLevelMap? {
    model.thinkingLevelMap ?? inferredThinkingLevelMap(model: model)
}

public func getSupportedThinkingLevels(_ model: Model) -> [ModelThinkingLevel] {
    if !model.reasoning {
        return [.off]
    }

    let map = effectiveThinkingLevelMap(model: model)
    return extendedThinkingLevels.filter { level in
        switch lookupThinkingLevelMap(map, level: level) {
        case .unsupported:
            return false
        case .missing:
            return level != .xhigh
        case .mapped:
            return true
        }
    }
}

public func clampThinkingLevel(model: Model, requested level: ModelThinkingLevel) -> ModelThinkingLevel {
    let availableLevels = getSupportedThinkingLevels(model)
    if availableLevels.contains(level) {
        return level
    }

    guard let requestedIndex = extendedThinkingLevels.firstIndex(of: level) else {
        return availableLevels.first ?? .off
    }

    for candidate in extendedThinkingLevels[requestedIndex...] {
        if availableLevels.contains(candidate) {
            return candidate
        }
    }

    if requestedIndex > 0 {
        for candidate in extendedThinkingLevels[..<requestedIndex].reversed() {
            if availableLevels.contains(candidate) {
                return candidate
            }
        }
    }

    return availableLevels.first ?? .off
}

public func clampThinkingLevel(model: Model, requested level: ThinkingLevel?) -> ThinkingLevel? {
    guard let level else { return nil }
    return clampThinkingLevel(model: model, requested: ModelThinkingLevel(level)).thinkingLevel
}

public func mappedThinkingLevel(model: Model, level: ThinkingLevel) -> String? {
    let map = effectiveThinkingLevelMap(model: model)
    switch lookupThinkingLevelMap(map, level: ModelThinkingLevel(level)) {
    case .mapped(let value):
        return value
    case .missing, .unsupported:
        return nil
    }
}

public func mappedOffThinkingLevel(model: Model) -> String? {
    let map = effectiveThinkingLevelMap(model: model)
    switch lookupThinkingLevelMap(map, level: .off) {
    case .mapped(let value):
        return value
    case .missing:
        return "none"
    case .unsupported:
        return nil
    }
}

public func supportsXhigh(model: Model) -> Bool {
    getSupportedThinkingLevels(model).contains(.xhigh)
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
