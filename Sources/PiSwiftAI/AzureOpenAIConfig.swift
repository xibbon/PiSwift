import Foundation

// Shared endpoint options for the two Azure APIs.
internal protocol AzureEndpointOptions: Sendable {
    var env: [String: String]? { get }
    var azureApiVersion: String? { get }
    var azureResourceName: String? { get }
    var azureBaseUrl: String? { get }
    var azureDeploymentName: String? { get }
}

extension StreamOptions: AzureEndpointOptions {}
extension SimpleStreamOptions: AzureEndpointOptions {}
extension OpenAICompletionsOptions: AzureEndpointOptions {}
extension AzureOpenAIResponsesOptions: AzureEndpointOptions {}

private func nonempty(_ value: String?) -> String? {
    value.flatMap { $0.isEmpty ? nil : $0 }
}

internal func parseDeploymentNameMap(_ value: String?) -> [String: String] {
    var map: [String: String] = [:]
    for entry in (value ?? "").split(separator: ",") {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        // JavaScript split("=", 2) keeps only the first two parts.
        let parts = trimmed.split(separator: "=", omittingEmptySubsequences: false).prefix(2)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
        map[parts[0].trimmingCharacters(in: .whitespacesAndNewlines)] =
            parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return map
}

internal func resolveDeploymentName(model: Model, options: (any AzureEndpointOptions)?) -> String {
    if let deployment = nonempty(options?.azureDeploymentName) { return deployment }
    let map = parseDeploymentNameMap(getProviderEnvValue("AZURE_OPENAI_DEPLOYMENT_NAME_MAP", env: options?.env))
    return nonempty(map[model.id]) ?? model.id
}

internal func normalizeAzureBaseUrl(_ baseUrl: String) throws -> String {
    var trimmed = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    guard var url = URLComponents(string: trimmed), let scheme = url.scheme, !scheme.isEmpty else {
        throw AzureOpenAIResponsesError.invalidBaseUrl(baseUrl)
    }
    if ["http", "https"].contains(scheme.lowercased()), url.host?.isEmpty != false {
        throw AzureOpenAIResponsesError.invalidBaseUrl(baseUrl)
    }
    if ["http", "https"].contains(scheme.lowercased()) {
        // WHATWG URL parsing resolves literal and percent-encoded dot segments.
        url.percentEncodedPath = url.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map { segment in
            switch segment.lowercased() {
            case "%2e": return "."
            case ".%2e", "%2e.", "%2e%2e": return ".."
            default: return String(segment)
            }
        }.joined(separator: "/")
        if let standardized = url.url?.standardized,
           let components = URLComponents(url: standardized, resolvingAgainstBaseURL: false) {
            url = components
        }
    }
    let host = (url.host ?? "").lowercased()
    let isAzureHost = host.hasSuffix(".openai.azure.com") ||
        host.hasSuffix(".cognitiveservices.azure.com") || host.hasSuffix(".ai.azure.com")
    var path = url.percentEncodedPath
    while path.hasSuffix("/") { path.removeLast() }
    if isAzureHost && (path.isEmpty || path == "/" || path == "/openai" || path == "/openai/v1/responses") {
        url.path = "/openai/v1"
        url.query = nil
    }
    if url.host != nil {
        url.host = host
        if url.percentEncodedPath.isEmpty { url.path = "/" }
    }
    if (scheme.lowercased() == "https" && url.port == 443) || (scheme.lowercased() == "http" && url.port == 80) {
        url.port = nil
    }
    url.scheme = scheme.lowercased()
    guard var result = url.string else { throw AzureOpenAIResponsesError.invalidBaseUrl(baseUrl) }
    while result.hasSuffix("/") { result.removeLast() }
    return result
}

internal func resolveAzureBaseUrl(model: Model, options: (any AzureEndpointOptions)?) throws -> String {
    let baseUrl = nonempty(options?.azureBaseUrl?.trimmingCharacters(in: .whitespacesAndNewlines)) ??
        nonempty(getProviderEnvValue("AZURE_OPENAI_BASE_URL", env: options?.env)?.trimmingCharacters(in: .whitespacesAndNewlines))
    let resource = nonempty(options?.azureResourceName) ??
        nonempty(getProviderEnvValue("AZURE_OPENAI_RESOURCE_NAME", env: options?.env))
    guard let resolved = baseUrl ?? resource.map({ "https://\($0).openai.azure.com/openai/v1" }) ?? nonempty(model.baseUrl) else {
        throw AzureOpenAIResponsesConfigError.missingBaseUrl
    }
    return try normalizeAzureBaseUrl(resolved)
}

internal func resolveAzureConfig(model: Model, options: (any AzureEndpointOptions)?) throws -> (baseUrl: String, apiVersion: String) {
    (try resolveAzureBaseUrl(model: model, options: options),
     nonempty(options?.azureApiVersion) ?? nonempty(getProviderEnvValue("AZURE_OPENAI_API_VERSION", env: options?.env)) ?? "v1")
}

internal enum AzureOpenAIResponsesConfigError: LocalizedError {
    case missingBaseUrl

    var errorDescription: String? {
        switch self {
        case .missingBaseUrl:
            return "Azure OpenAI base URL is required. Set AZURE_OPENAI_BASE_URL or AZURE_OPENAI_RESOURCE_NAME, or pass azureBaseUrl, azureResourceName, or model.baseUrl."
        }
    }
}
