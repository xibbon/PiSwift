import PiSwiftAgent
import PiSwiftAI
import PiSwiftCodingAgent
import PiSwiftDurable

/// The model and thinking level for a new root conversation.
public struct InitialAgentModel: Sendable, Equatable {
    /// The selected model, or nil when no authenticated model is available.
    public let model: ModelRef?
    /// The thinking level for the selected model, or nil when no model is available.
    public let thinkingLevel: ModelThinkingLevel?
    /// Optional information from the coding-agent model resolver.
    public let fallbackMessage: String?

    /// Creates the initial model selection and its optional notice.
    public init(model: ModelRef? = nil, thinkingLevel: ModelThinkingLevel? = nil, fallbackMessage: String? = nil) {
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.fallbackMessage = fallbackMessage
    }
}

/// Resolves the saved defaults through the coding-agent model resolver.
public func findInitialAgentModel(settingsManager: SettingsManager, registry: ModelRegistry) async -> InitialAgentModel {
    let initial = await findInitialModel(
        scopedModels: [], isContinuing: false,
        defaultProvider: settingsManager.getDefaultProvider(),
        defaultModelId: settingsManager.getDefaultModel(),
        defaultThinkingLevel: settingsManager.getDefaultThinkingLevel().flatMap(PiSwiftAgent.ThinkingLevel.init(rawValue:)),
        modelRegistry: registry
    )
    return InitialAgentModel(
        model: initial.model.map { ModelRef(provider: $0.provider, modelId: $0.id) },
        thinkingLevel: initial.model == nil ? nil : ModelThinkingLevel(rawValue: initial.thinkingLevel.rawValue),
        fallbackMessage: initial.fallbackMessage
    )
}
