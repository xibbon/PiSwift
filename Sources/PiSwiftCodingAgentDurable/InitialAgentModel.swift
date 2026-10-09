import PiSwiftAgent
import PiSwiftAI
import PiSwiftCodingAgent
import PiSwiftDurable

/// The model and thinking level for a new root conversation.
public struct InitialAgentModel: Sendable, Equatable {
    public let model: ModelRef?
    public let thinkingLevel: ModelThinkingLevel?
    public let fallbackMessage: String?

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
