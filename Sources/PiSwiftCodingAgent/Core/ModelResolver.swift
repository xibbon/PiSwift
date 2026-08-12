import Foundation
import PiSwiftAI
import PiSwiftAgent

public struct ScopedModel: Sendable {
    public var model: Model
    public var thinkingLevel: ThinkingLevel?
    public var isThinkingExplicit: Bool

    public init(model: Model, thinkingLevel: ThinkingLevel? = nil, isThinkingExplicit: Bool = true) {
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.isThinkingExplicit = isThinkingExplicit
    }
}

public struct ParsedModelResult: Sendable {
    public var model: Model?
    public var thinkingLevel: ThinkingLevel
    public var isThinkingExplicit: Bool
    public var warning: String?
}

public struct ResolveCliModelResult: Sendable {
    public var model: Model?
    public var thinkingLevel: ThinkingLevel?
    public var warning: String?
    public var error: String?
}

private func isAlias(_ id: String) -> Bool {
    if id.hasSuffix("-latest") { return true }
    let pattern = try? NSRegularExpression(pattern: "-\\d{8}$", options: [])
    let range = NSRange(location: 0, length: id.utf16.count)
    if let pattern, pattern.firstMatch(in: id, options: [], range: range) != nil {
        return false
    }
    return true
}

private func tryMatchModel(_ modelPattern: String, availableModels: [Model]) -> Model? {
    if let slashIndex = modelPattern.firstIndex(of: "/") {
        let provider = String(modelPattern[..<slashIndex])
        let modelId = String(modelPattern[modelPattern.index(after: slashIndex)...])
        if let providerMatch = availableModels.first(where: { $0.provider.lowercased() == provider.lowercased() && $0.id.lowercased() == modelId.lowercased() }) {
            return providerMatch
        }
    }

    let exactMatches = availableModels.filter { $0.id.lowercased() == modelPattern.lowercased() }
    if !exactMatches.isEmpty {
        let providers = Set(exactMatches.map { $0.provider })
        if providers.count > 1 {
            return nil  // Ambiguous: same modelId in multiple providers
        }
        return exactMatches.first
    }

    let matches: [Model]
    if modelPattern.isEmpty {
        matches = availableModels
    } else {
        matches = availableModels.filter {
            $0.id.lowercased().contains(modelPattern.lowercased()) ||
            $0.name.lowercased().contains(modelPattern.lowercased())
        }
    }

    if matches.isEmpty {
        return nil
    }

    let aliases = matches.filter { isAlias($0.id) }.sorted { $0.id > $1.id }
    if let alias = aliases.first {
        return alias
    }

    let dated = matches.filter { !isAlias($0.id) }.sorted { $0.id > $1.id }
    return dated.first
}

public func parseModelPattern(
    _ pattern: String,
    _ availableModels: [Model],
    allowInvalidThinkingLevelFallback: Bool = true
) -> ParsedModelResult {
    if let exact = tryMatchModel(pattern, availableModels: availableModels) {
        return ParsedModelResult(model: exact, thinkingLevel: .off, isThinkingExplicit: false, warning: nil)
    }

    guard let lastColon = pattern.lastIndex(of: ":") else {
        return ParsedModelResult(model: nil, thinkingLevel: .off, isThinkingExplicit: false, warning: nil)
    }

    let prefix = String(pattern[..<lastColon])
    let suffix = String(pattern[pattern.index(after: lastColon)...])

    if isValidThinkingLevel(suffix) {
        let result = parseModelPattern(prefix, availableModels, allowInvalidThinkingLevelFallback: allowInvalidThinkingLevelFallback)
        if let model = result.model {
            let level = ThinkingLevel(rawValue: suffix) ?? .off
            if result.warning == nil {
                return ParsedModelResult(model: model, thinkingLevel: level, isThinkingExplicit: true, warning: nil)
            }
            return ParsedModelResult(model: model, thinkingLevel: .off, isThinkingExplicit: false, warning: result.warning)
        }
        return result
    } else {
        if !allowInvalidThinkingLevelFallback {
            return ParsedModelResult(model: nil, thinkingLevel: .off, isThinkingExplicit: false, warning: nil)
        }

        let result = parseModelPattern(prefix, availableModels, allowInvalidThinkingLevelFallback: allowInvalidThinkingLevelFallback)
        if let model = result.model {
            return ParsedModelResult(
                model: model,
                thinkingLevel: .off,
                isThinkingExplicit: false,
                warning: "Invalid thinking level \"\(suffix)\" in pattern \"\(pattern)\". Using \"off\" instead."
            )
        }
        return result
    }
}

public func resolveCliModel(
    cliProvider: String? = nil,
    cliModel: String? = nil,
    modelRegistry: ModelRegistry
) -> ResolveCliModelResult {
    resolveCliModel(
        cliProvider: cliProvider,
        cliModel: cliModel,
        availableModels: modelRegistry.getAll(),
        hasConfiguredAuth: modelRegistry.hasConfiguredAuth
    )
}

public func resolveCliModel(
    cliProvider: String? = nil,
    cliModel: String? = nil,
    availableModels: [Model]
) -> ResolveCliModelResult {
    resolveCliModel(
        cliProvider: cliProvider,
        cliModel: cliModel,
        availableModels: availableModels,
        hasConfiguredAuth: { _ in false }
    )
}

private func resolveCliModel(
    cliProvider: String?,
    cliModel: String?,
    availableModels: [Model],
    hasConfiguredAuth: (Model) -> Bool
) -> ResolveCliModelResult {
    guard let cliModel, !cliModel.isEmpty else {
        return ResolveCliModelResult(model: nil, thinkingLevel: nil, warning: nil, error: nil)
    }

    if availableModels.isEmpty {
        return ResolveCliModelResult(
            model: nil,
            thinkingLevel: nil,
            warning: nil,
            error: "No models available. Check your installation or add models to models.json."
        )
    }

    var providerLookup: [String: String] = [:]
    for model in availableModels {
        providerLookup[model.provider.lowercased()] = model.provider
    }

    var provider: String?
    if let cliProvider, !cliProvider.isEmpty {
        guard let canonicalProvider = providerLookup[cliProvider.lowercased()] else {
            return ResolveCliModelResult(
                model: nil,
                thinkingLevel: nil,
                warning: nil,
                error: "Unknown provider \"\(cliProvider)\". Use --list-models to see available providers/models."
            )
        }
        provider = canonicalProvider
    }

    // Check the complete ID before treating a leading path component as a
    // provider. Some gateway model IDs contain a slash that is part of the ID.
    // Bare exact IDs can also exist under more than one provider.
    if provider == nil {
        let lower = cliModel.lowercased()
        let exactMatches = availableModels.filter { $0.id.lowercased() == lower }
        if exactMatches.count == 1 {
            return ResolveCliModelResult(model: exactMatches[0], thinkingLevel: nil, warning: nil, error: nil)
        }
        if exactMatches.count > 1 {
            let authenticatedMatches = exactMatches.filter(hasConfiguredAuth)
            if authenticatedMatches.count == 1 {
                return ResolveCliModelResult(model: authenticatedMatches[0], thinkingLevel: nil, warning: nil, error: nil)
            }
            let matches = exactMatches
                .map { "\($0.provider)/\($0.id)" }
                .sorted()
                .joined(separator: ", ")
            let authHint = authenticatedMatches.isEmpty
                ? "No matching provider is authenticated."
                : "More than one matching provider is authenticated."
            return ResolveCliModelResult(
                model: nil,
                thinkingLevel: nil,
                warning: nil,
                error: "Model \"\(cliModel)\" is ambiguous across providers: \(matches). \(authHint) Use --provider or provider/model."
            )
        }
    }

    var pattern = cliModel
    if provider == nil, let slashIndex = cliModel.firstIndex(of: "/") {
        let maybeProvider = String(cliModel[..<slashIndex])
        if let canonicalProvider = providerLookup[maybeProvider.lowercased()] {
            provider = canonicalProvider
            pattern = String(cliModel[cliModel.index(after: slashIndex)...])
        }
    } else if let provider {
        let prefix = "\(provider)/"
        if cliModel.lowercased().hasPrefix(prefix.lowercased()) {
            pattern = String(cliModel.dropFirst(prefix.count))
        }
    }

    let candidates: [Model]
    if let provider {
        candidates = availableModels.filter { $0.provider == provider }
    } else {
        candidates = availableModels
    }

    let parsed = parseModelPattern(
        pattern,
        candidates,
        allowInvalidThinkingLevelFallback: false
    )

    guard let model = parsed.model else {
        let display = provider.map { "\($0)/\(pattern)" } ?? cliModel
        return ResolveCliModelResult(
            model: nil,
            thinkingLevel: nil,
            warning: parsed.warning,
            error: "Model \"\(display)\" not found. Use --list-models to see available models."
        )
    }

    let thinking = parsed.isThinkingExplicit ? parsed.thinkingLevel : nil
    return ResolveCliModelResult(model: model, thinkingLevel: thinking, warning: parsed.warning, error: nil)
}

public func resolveModelScope(_ patterns: [String], _ modelRegistry: ModelRegistry) async -> [ScopedModel] {
    let available = await modelRegistry.getAvailable()
    var scoped: [ScopedModel] = []

    for pattern in patterns {
        if pattern.contains("*") || pattern.contains("?") || pattern.contains("[") {
            var globPattern = pattern
            var thinkingLevel: ThinkingLevel = .off
            var isThinkingExplicit = false
            if let colon = pattern.lastIndex(of: ":") {
                let suffix = String(pattern[pattern.index(after: colon)...])
                if isValidThinkingLevel(suffix) {
                    thinkingLevel = ThinkingLevel(rawValue: suffix) ?? .off
                    globPattern = String(pattern[..<colon])
                    isThinkingExplicit = true
                }
            }

            for model in available {
                let fullId = "\(model.provider)/\(model.id)"
                if matchesGlob(fullId, globPattern) || matchesGlob(model.id, globPattern) {
                    if !scoped.contains(where: { modelsAreEqual($0.model, model) }) {
                        scoped.append(ScopedModel(model: model, thinkingLevel: thinkingLevel, isThinkingExplicit: isThinkingExplicit))
                    }
                }
            }
            continue
        }

        let parsed = parseModelPattern(pattern, available)
        if let model = parsed.model {
            if !scoped.contains(where: { modelsAreEqual($0.model, model) }) {
                scoped.append(ScopedModel(model: model, thinkingLevel: parsed.thinkingLevel, isThinkingExplicit: parsed.isThinkingExplicit))
            }
        }
    }

    return scoped
}
