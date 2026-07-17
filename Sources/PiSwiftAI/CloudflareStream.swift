import Foundation

/// Substitute Cloudflare account/gateway endpoint placeholders in a model's baseUrl from `env`.
/// Unset keys keep their placeholder (matches upstream fallback). Returns the same model when
/// nothing changes.
public func resolveCloudflareModel(_ model: Model, env: [String: String]) -> Model {
    guard model.provider == "cloudflare-workers-ai" || model.provider == "cloudflare-ai-gateway" else {
        return model
    }
    let resolved = model.baseUrl
        .replacingOccurrences(
            of: "{CLOUDFLARE_ACCOUNT_ID}",
            with: env["CLOUDFLARE_ACCOUNT_ID"] ?? "{CLOUDFLARE_ACCOUNT_ID}"
        )
        .replacingOccurrences(
            of: "{CLOUDFLARE_GATEWAY_ID}",
            with: env["CLOUDFLARE_GATEWAY_ID"] ?? "{CLOUDFLARE_GATEWAY_ID}"
        )
    guard resolved != model.baseUrl else { return model }
    return Model(
        id: model.id,
        name: model.name,
        api: model.api,
        provider: model.provider,
        baseUrl: resolved,
        reasoning: model.reasoning,
        input: model.input,
        cost: model.cost,
        contextWindow: model.contextWindow,
        maxTokens: model.maxTokens,
        headers: model.headers,
        compat: model.compat,
        thinkingLevelMap: model.thinkingLevelMap
    )
}

/// Process-env-backed convenience used by provider stream entry points.
public func resolveCloudflareModel(_ model: Model) -> Model {
    resolveCloudflareModel(model, env: ProcessInfo.processInfo.environment)
}
