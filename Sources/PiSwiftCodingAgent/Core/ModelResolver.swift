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

/// Compatibility view of the model-reference result. Ambiguity has no model in this view.
@available(*, deprecated, message: "Use resolveModelReference to handle ambiguity and optional thinking levels.")
public func parseModelPattern(
    _ pattern: String,
    _ availableModels: [Model],
    allowInvalidThinkingLevelFallback: Bool = true
) -> ParsedModelResult {
    let result = resolveModelReference(
        ModelReferenceRequest(text: pattern, thinkingSuffix: allowInvalidThinkingLevelFallback ? .lenient : .strict),
        availableModels,
        usable: { _ in true }
    )
    return ParsedModelResult(model: result.model, thinkingLevel: result.thinkingLevel ?? .off,
                             isThinkingExplicit: result.thinkingLevel != nil, warning: result.warning)
}

@available(*, deprecated, message: "Pass cliThinking and inlineApiKey to use custom model fallback.")
public func resolveCliModel(
    cliProvider: String? = nil,
    cliModel: String? = nil,
    modelRegistry: ModelRegistry
) -> ResolveCliModelResult {
    let models = modelRegistry.getAll()
    return resolveCliModelReference(
        cliProvider: cliProvider, cliModel: cliModel, cliThinking: nil, inlineApiKey: false,
        availableModels: models,
        usable: { provider in models.contains { $0.provider == provider && modelRegistry.hasConfiguredAuth($0) } },
        allowCustomFallback: false
    )
}

@available(*, deprecated, message: "Pass cliThinking and inlineApiKey to use custom model fallback.")
public func resolveCliModel(
    cliProvider: String? = nil,
    cliModel: String? = nil,
    availableModels: [Model]
) -> ResolveCliModelResult {
    resolveCliModelReference(cliProvider: cliProvider, cliModel: cliModel, cliThinking: nil, inlineApiKey: false,
                             availableModels: availableModels, usable: { _ in false }, allowCustomFallback: false)
}

public func resolveCliModel(
    cliProvider: String? = nil,
    cliModel: String? = nil,
    cliThinking: ThinkingLevel?,
    inlineApiKey: Bool,
    modelRegistry: ModelRegistry
) -> ResolveCliModelResult {
    let models = modelRegistry.getAll()
    return resolveCliModel(
        cliProvider: cliProvider, cliModel: cliModel, cliThinking: cliThinking, inlineApiKey: inlineApiKey,
        availableModels: models,
        usable: { provider in models.contains { $0.provider == provider && modelRegistry.hasConfiguredAuth($0) } }
    )
}

public func resolveCliModel(
    cliProvider: String? = nil,
    cliModel: String? = nil,
    cliThinking: ThinkingLevel?,
    inlineApiKey: Bool,
    availableModels: [Model],
    usable: (String) -> Bool = { _ in false }
) -> ResolveCliModelResult {
    resolveCliModelReference(cliProvider: cliProvider, cliModel: cliModel, cliThinking: cliThinking,
                             inlineApiKey: inlineApiKey, availableModels: availableModels,
                             usable: usable, allowCustomFallback: true)
}

private func resolveCliModelReference(
    cliProvider: String?, cliModel: String?, cliThinking: ThinkingLevel?, inlineApiKey: Bool,
    availableModels: [Model], usable: (String) -> Bool, allowCustomFallback: Bool
) -> ResolveCliModelResult {
    guard let cliModel, !cliModel.isEmpty else {
        return ResolveCliModelResult(model: nil, thinkingLevel: nil, warning: nil, error: nil)
    }
    guard !availableModels.isEmpty else {
        return ResolveCliModelResult(model: nil, thinkingLevel: nil, warning: nil,
            error: "No models available. Check your installation or add models to models.json.")
    }
    let provider = cliProvider.flatMap { requested in
        availableModels.first { $0.provider.lowercased() == requested.lowercased() }?.provider
    }
    if let cliProvider, !cliProvider.isEmpty, provider == nil {
        return ResolveCliModelResult(model: nil, thinkingLevel: nil, warning: nil,
            error: "Unknown provider \"\(cliProvider)\". Use --list-models to see available providers/models.")
    }
    let result = resolveModelReference(
        ModelReferenceRequest(text: cliModel, provider: provider, thinkingSuffix: .strict, fuzzy: true),
        availableModels,
        usable: { !inlineApiKey && usable($0) }
    )
    switch result {
    case .resolved(let model, let thinking, let warning):
        return ResolveCliModelResult(model: model, thinkingLevel: thinking, warning: warning, error: nil)
    case .ambiguous(let candidates, let usableCount, _, _):
        let matches = candidates.map { "\($0.provider)/\($0.id)" }.sorted().joined(separator: ", ")
        let authHint = inlineApiKey ? "--api-key does not choose a provider."
            : usableCount == 0 ? "No matching provider is authenticated." : "More than one matching provider is authenticated."
        return ResolveCliModelResult(model: nil, thinkingLevel: nil, warning: nil,
            error: "Model \"\(cliModel)\" is ambiguous across providers: \(matches). \(authHint) Use --provider or provider/model.")
    case .notFound(let target):
        guard allowCustomFallback, let target else {
            let display = target.map { "\($0.provider)/\($0.modelText)" } ?? cliModel
            return ResolveCliModelResult(model: nil, thinkingLevel: nil, warning: nil,
                error: "Model \"\(display)\" not found. Use --list-models to see available models.")
        }
        let modelId = cliThinking != nil ? target.modelText : target.modelId
        let thinking = cliThinking == nil ? target.thinkingLevel : nil
        let requestedThinking = cliThinking ?? thinking
        let model = buildFallbackModel(target, modelId: modelId, reasoning: requestedThinking.map { $0 != .off } ?? false)
        return ResolveCliModelResult(model: model, thinkingLevel: thinking,
            warning: "Model \"\(modelId)\" not found for provider \"\(target.provider)\". Using custom model id.", error: nil)
    }
}

private func buildFallbackModel(_ target: ModelReferenceTarget, modelId: String, reasoning: Bool) -> Model {
    // The target is built only when this provider has at least one catalog model.
    let defaultId = defaultModelPerProvider.first { $0.0.rawValue == target.provider }?.1
    let base = target.providerModels.first { $0.id == defaultId } ?? target.providerModels[0]
    return Model(
        id: modelId, name: modelId, api: base.api, provider: base.provider, baseUrl: base.baseUrl,
        reasoning: reasoning || base.reasoning, input: base.input, cost: base.cost,
        contextWindow: base.contextWindow, maxTokens: base.maxTokens, samplingParams: base.samplingParams,
        headers: base.headers, compat: base.compat, thinkingLevelMap: base.thinkingLevelMap,
        inputLimits: base.inputLimits, promptCache: base.promptCache,
        samplingParamsByThinkingLevel: base.samplingParamsByThinkingLevel
    )
}

public struct ModelScopeDiagnostic: Sendable, Equatable {
    public enum DiagnosticType: String, Sendable { case warning }
    public enum Code: String, Sendable {
        case noMatch = "no-match"
        case invalidThinkingLevel = "invalid-thinking-level"
        case ambiguous
    }
    public let type: DiagnosticType = .warning
    public let code: Code
    public let message: String
    public let pattern: String
}

public struct ResolveModelScopeResult: Sendable {
    public let scopedModels: [ScopedModel]
    public let diagnostics: [ModelScopeDiagnostic]
}

public func resolveModelScopeFromModels(_ patterns: [String], _ models: [Model]) -> ResolveModelScopeResult {
    var scoped: [ScopedModel] = []
    var diagnostics: [ModelScopeDiagnostic] = []
    func add(_ matches: [Model], thinking: ThinkingLevel?) {
        for model in matches where !scoped.contains(where: { modelsAreEqual($0.model, model) }) {
            scoped.append(ScopedModel(model: model, thinkingLevel: thinking, isThinkingExplicit: thinking != nil))
        }
    }
    func noMatch(_ pattern: String) {
        diagnostics.append(ModelScopeDiagnostic(code: .noMatch, message: "No models match pattern \"\(pattern)\"", pattern: pattern))
    }
    func ambiguous(_ pattern: String, _ candidates: [Model]) {
        let providers = Set(candidates.map(\.provider)).sorted().joined(separator: ", ")
        diagnostics.append(ModelScopeDiagnostic(code: .ambiguous,
            message: "Pattern \"\(pattern)\" matches several providers: \(providers). Use provider/id to choose one.", pattern: pattern))
    }
    for pattern in patterns {
        if pattern.contains("*") || pattern.contains("?") || pattern.contains("[") {
            let thinking = splitModelThinkingSuffix(pattern)
            let glob = thinking?.base ?? pattern
            let exact = resolveModelReference(ModelReferenceRequest(text: glob, thinkingSuffix: .none, fuzzy: false), models, usable: { _ in true })
            let matches: [Model]
            switch exact {
            case .resolved(let model, _, _): matches = [model]
            case .ambiguous(let candidates, _, _, _):
                matches = candidates
                ambiguous(pattern, candidates)
            case .notFound:
                matches = models.filter { matchesModelScopeGlob("\($0.provider)/\($0.id)", glob) || matchesModelScopeGlob($0.id, glob) }
            }
            if matches.isEmpty { noMatch(pattern) }
            add(matches, thinking: thinking?.thinkingLevel)
            continue
        }
        let result = resolveModelReference(ModelReferenceRequest(text: pattern, thinkingSuffix: .lenient), models, usable: { _ in true })
        if result.status == .notFound {
            noMatch(pattern)
            continue
        }
        if let warning = result.warning {
            diagnostics.append(ModelScopeDiagnostic(code: .invalidThinkingLevel, message: warning, pattern: pattern))
        }
        if result.status == .ambiguous { ambiguous(pattern, result.candidates) }
        add(result.model.map { [$0] } ?? result.candidates, thinking: result.thinkingLevel)
    }
    return ResolveModelScopeResult(scopedModels: scoped, diagnostics: diagnostics)
}

public func resolveModelScopeWithDiagnostics(_ patterns: [String], _ modelRegistry: ModelRegistry) async -> ResolveModelScopeResult {
    resolveModelScopeFromModels(patterns, await modelRegistry.getAvailable())
}

@available(*, deprecated, message: "Use resolveModelScopeWithDiagnostics and display its diagnostics in the host.")
public func resolveModelScope(_ patterns: [String], _ modelRegistry: ModelRegistry) async -> [ScopedModel] {
    await resolveModelScopeWithDiagnostics(patterns, modelRegistry).scopedModels
}

public struct InitialModelResult: Sendable {
    public var model: Model?
    public var thinkingLevel: ThinkingLevel
    public var fallbackMessage: String?
}

/// Resolves startup defaults without process exits or terminal output.
public func findInitialModel(
    scopedModels: [ScopedModel] = [],
    isContinuing: Bool = false,
    defaultProvider: String? = nil,
    defaultModelId: String? = nil,
    defaultThinkingLevel: ThinkingLevel? = nil,
    modelThinkingLevels: [String: ThinkingLevel] = [:],
    modelRegistry: ModelRegistry
) async -> InitialModelResult {
    if !isContinuing, let scoped = scopedModels.first {
        return InitialModelResult(
            model: scoped.model,
            thinkingLevel: (scoped.isThinkingExplicit ? scoped.thinkingLevel : nil)
                ?? modelThinkingLevels["\(scoped.model.provider)/\(scoped.model.id)"]
                ?? defaultThinkingLevel ?? DEFAULT_THINKING_LEVEL
        )
    }
    if let provider = defaultProvider, let modelId = defaultModelId,
       let model = modelRegistry.find(provider, modelId), modelRegistry.hasConfiguredAuth(model) {
        return InitialModelResult(model: model,
            thinkingLevel: modelThinkingLevels["\(provider)/\(modelId)"] ?? defaultThinkingLevel ?? DEFAULT_THINKING_LEVEL)
    }
    let available = await modelRegistry.getAvailable()
    let preferred = await selectDefaultModel(available: available, registry: modelRegistry)
    return InitialModelResult(model: preferred ?? available.first, thinkingLevel: DEFAULT_THINKING_LEVEL)
}
