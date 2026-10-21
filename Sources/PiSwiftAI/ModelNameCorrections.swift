import Foundation

/// A display-name correction for one catalog model.
///
/// Upstream (models.dev, through pi-mono) names some version aliases
/// "Claude Opus 4.5 (latest)". The alias points to the newest snapshot of that
/// one version, not to the newest model, so the label is misleading next to
/// newer versions. Each correction applies only when the incoming name is the
/// same as `upstreamName`. When upstream changes the name, the correction has
/// no effect and `modelNameCorrectionsMatchUpstream` in PiSwiftAITests fails,
/// so the row can be removed or updated.
public struct ModelNameCorrection: Sendable, Equatable {
    public let provider: String
    public let id: String
    public let upstreamName: String
    public let name: String
}

/// Corrections are explicit rows, not a pattern rule, so that rolling aliases
/// (for example `~anthropic/claude-opus-latest`) and new unreviewed entries
/// keep their upstream names.
public let modelNameCorrections: [ModelNameCorrection] = [
    // Version aliases: "(latest)" suggests the newest model across versions.
    ModelNameCorrection(provider: "anthropic", id: "claude-haiku-4-5", upstreamName: "Claude Haiku 4.5 (latest)", name: "Claude Haiku 4.5"),
    ModelNameCorrection(provider: "anthropic", id: "claude-opus-4-5", upstreamName: "Claude Opus 4.5 (latest)", name: "Claude Opus 4.5"),
    ModelNameCorrection(provider: "anthropic", id: "claude-sonnet-4-5", upstreamName: "Claude Sonnet 4.5 (latest)", name: "Claude Sonnet 4.5"),
    ModelNameCorrection(provider: "cloudflare-ai-gateway", id: "claude-haiku-4-5", upstreamName: "Claude Haiku 4.5 (latest)", name: "Claude Haiku 4.5"),
    ModelNameCorrection(provider: "cloudflare-ai-gateway", id: "claude-opus-4-5", upstreamName: "Claude Opus 4.5 (latest)", name: "Claude Opus 4.5"),
    ModelNameCorrection(provider: "cloudflare-ai-gateway", id: "claude-sonnet-4-5", upstreamName: "Claude Sonnet 4.5 (latest)", name: "Claude Sonnet 4.5"),
    ModelNameCorrection(provider: "github-copilot", id: "claude-haiku-4.5", upstreamName: "Claude Haiku 4.5 (latest)", name: "Claude Haiku 4.5"),
    // Dated snapshots: a date keeps names unique within the provider.
    ModelNameCorrection(provider: "anthropic", id: "claude-haiku-4-5-20251001", upstreamName: "Claude Haiku 4.5", name: "Claude Haiku 4.5 (2025-10-01)"),
    ModelNameCorrection(provider: "anthropic", id: "claude-opus-4-5-20251101", upstreamName: "Claude Opus 4.5", name: "Claude Opus 4.5 (2025-11-01)"),
    ModelNameCorrection(provider: "anthropic", id: "claude-sonnet-4-5-20250929", upstreamName: "Claude Sonnet 4.5", name: "Claude Sonnet 4.5 (2025-09-29)"),
]

private let modelNameCorrectionsByKey: [String: ModelNameCorrection] = Dictionary(
    uniqueKeysWithValues: modelNameCorrections.map { ("\($0.provider)/\($0.id)", $0) }
)

/// Returns the corrected display name, or `name` when no correction matches.
public func correctedModelName(provider: String, id: String, name: String) -> String {
    guard let correction = modelNameCorrectionsByKey["\(provider)/\(id)"],
          correction.upstreamName == name else {
        return name
    }
    return correction.name
}

/// Returns `model` with its display name corrected. All other fields stay the same.
public func applyingModelNameCorrection(_ model: Model) -> Model {
    let name = correctedModelName(provider: model.provider, id: model.id, name: model.name)
    guard name != model.name else {
        return model
    }
    return Model(
        id: model.id, name: name, api: model.api, provider: model.provider, baseUrl: model.baseUrl,
        reasoning: model.reasoning, input: model.input, cost: model.cost, contextWindow: model.contextWindow,
        maxTokens: model.maxTokens, samplingParams: model.samplingParams, headers: model.headers,
        compat: model.compat, thinkingLevelMap: model.thinkingLevelMap,
        inputLimits: model.inputLimits, promptCache: model.promptCache,
        samplingParamsByThinkingLevel: model.samplingParamsByThinkingLevel
    )
}

/// The built-in chat catalog with display-name corrections applied. Read this,
/// not the generated `ModelsData`, which stays raw upstream output.
let CorrectedModelsData: [String: [String: Model]] = ModelsData.mapValues { models in
    models.mapValues(applyingModelNameCorrection)
}
