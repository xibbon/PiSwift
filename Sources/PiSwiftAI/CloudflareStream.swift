import Foundation

/// Substitute Cloudflare account/gateway endpoint placeholders in a model's baseUrl from `env`.
/// Unset keys keep their placeholder (matches upstream fallback). Returns the same model when
/// nothing changes.
public protocol CloudflareResolvableModel: CatalogModel {
    func with(baseUrl: String) -> Self
}

extension Model: CloudflareResolvableModel {}

extension ClassifierModel: CloudflareResolvableModel {
    public func with(baseUrl: String) -> ClassifierModel {
        var copy = self
        copy.baseUrl = baseUrl
        return copy
    }
}

public func resolveCloudflareModel<T: CloudflareResolvableModel>(_ model: T, env: [String: String]) -> T {
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
    return model.with(baseUrl: resolved)
}

/// Process-env-backed convenience used by provider stream entry points.
public func resolveCloudflareModel<T: CloudflareResolvableModel>(_ model: T) -> T {
    resolveCloudflareModel(model, env: ProcessInfo.processInfo.environment)
}
