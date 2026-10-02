import PiSwiftAI
import PiSwiftAgent

/// The API marker for catalog entries that must be routed before streaming.
public let VIRTUAL_MODEL_API: Api = .piVirtual
public let VIRTUAL_MODEL_STATE_ENTRY = "pi.virtual-model-state"

public enum ModelRouteReason: String, Sendable {
    case user
    case continuation
    case retry
    case direct
}

public struct ModelRouteResponse: Sendable {
    public var model: Model
    public var thinkingLevel: ModelThinkingLevel?

    public init(model: Model, thinkingLevel: ModelThinkingLevel? = nil) {
        self.model = model
        self.thinkingLevel = thinkingLevel
    }
}

public struct ModelRouteFailure: Sendable {
    public var model: Model
    public var thinkingLevel: ModelThinkingLevel?
    public var message: AssistantMessage

    public init(model: Model, thinkingLevel: ModelThinkingLevel? = nil, message: AssistantMessage) {
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.message = message
    }
}

public struct ModelRouteRequest: Sendable {
    public var model: Model
    public var thinkingLevel: ModelThinkingLevel
    public var reason: ModelRouteReason
    public var previous: ModelRouteResponse?
    public var failed: ModelRouteFailure?
    public var state: AnyCodable?
    public var messages: [Message]
    public var signal: CancellationToken?

    public init(model: Model, thinkingLevel: ModelThinkingLevel, reason: ModelRouteReason,
                previous: ModelRouteResponse? = nil, failed: ModelRouteFailure? = nil,
                state: AnyCodable? = nil, messages: [Message], signal: CancellationToken? = nil) {
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.reason = reason
        self.previous = previous
        self.failed = failed
        self.state = state
        self.messages = messages
        self.signal = signal
    }
}

public struct ModelRoute: Sendable {
    public var model: Model
    public var thinkingLevel: ModelThinkingLevel
    public var state: AnyCodable?

    public init(model: Model, thinkingLevel: ModelThinkingLevel, state: AnyCodable? = nil) {
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.state = state
    }
}

public struct VirtualModelDefinition: Sendable {
    public var provider: String
    public var id: String
    public var name: String
    public var thinkingLevels: [ModelThinkingLevel]
    public var contextWindow: Int
    public var maxTokens: Int
    public var input: [ModelInput]
    public var route: @Sendable (ModelRouteRequest) async throws -> ModelRoute

    public init(provider: String, id: String, name: String,
                thinkingLevels: [ModelThinkingLevel] = [.off], contextWindow: Int = 0,
                maxTokens: Int = 0, input: [ModelInput] = [.text, .image],
                route: @escaping @Sendable (ModelRouteRequest) async throws -> ModelRoute) {
        self.provider = provider
        self.id = id
        self.name = name
        self.thinkingLevels = thinkingLevels
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.input = input
        self.route = route
    }

    public var model: Model {
        var levelMap: ThinkingLevelMap = [:]
        for level in ModelThinkingLevel.allCases {
            if thinkingLevels.contains(level) {
                levelMap[level] = level.rawValue
            } else {
                levelMap.updateValue(nil, forKey: level)
            }
        }
        return Model(id: id, name: name, api: VIRTUAL_MODEL_API, provider: provider,
                     baseUrl: "", reasoning: thinkingLevels.contains { $0 != .off },
                     input: input, cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                     contextWindow: contextWindow, maxTokens: maxTokens, thinkingLevelMap: levelMap)
    }
}

public func isVirtualModel(_ model: Model) -> Bool { model.api == VIRTUAL_MODEL_API }

public func findLatestResponse(_ messages: [AgentMessage]) -> AssistantMessage? {
    for message in messages.reversed() {
        if case .assistant(let response) = message,
           response.stopReason != .error && response.stopReason != .aborted {
            return response
        }
    }
    return nil
}

/// Return the branch model selection with at most one catalog lookup.
public func getBranchSelection(_ branch: [SessionEntry], getModel: (String, String) -> Model?)
    -> (provider: String, modelId: String)? {
    for index in branch.indices.reversed() {
        switch branch[index] {
        case .modelChange(let change):
            return (change.provider, change.modelId)
        case .message(let entry):
            guard case .assistant(let response) = entry.message,
                  response.api != VIRTUAL_MODEL_API else { continue }
            if let change = findLastModelChange(branch, before: index),
               let model = getModel(change.provider, change.modelId), isVirtualModel(model) {
                return change
            }
            return (response.provider, response.model)
        default: break
        }
    }
    return nil
}

private func findLastModelChange(_ branch: [SessionEntry], before: Int)
    -> (provider: String, modelId: String)? {
    for index in branch.indices.prefix(before).reversed() {
        if case .modelChange(let change) = branch[index] {
            return (change.provider, change.modelId)
        }
    }
    return nil
}

public func getVirtualModelState(_ branch: [SessionEntry], provider: String, modelId: String) -> AnyCodable? {
    for entry in branch.reversed() {
        guard case .custom(let custom) = entry,
              custom.customType == VIRTUAL_MODEL_STATE_ENTRY,
              let object = custom.data?.value as? [String: Any],
              object["provider"] as? String == provider,
              object["modelId"] as? String == modelId else { continue }
        return object["state"].map(AnyCodable.init)
    }
    return nil
}
