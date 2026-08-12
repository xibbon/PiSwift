import Foundation
import OpenAI

func makeOpenAIClient(
    model: Model,
    apiKey: String?,
    headers: ProviderHeaders? = nil,
    timeoutMs: Int? = nil,
    middlewares: [OpenAIMiddleware] = []
) throws -> OpenAI {
    let token = apiKey ?? ""
    if token.isEmpty {
        throw StreamError.missingApiKey(model.provider)
    }

    let url = URL(string: model.baseUrl)
    let host = url?.host ?? "api.openai.com"
    let scheme = url?.scheme ?? "https"
    let port = url?.port ?? 443
    let rawPath = url?.path ?? ""
    let basePath: String
    if model.provider == "github-copilot" {
        basePath = rawPath.isEmpty || rawPath == "/" ? "" : rawPath
    } else {
        basePath = rawPath.isEmpty || rawPath == "/" ? "/v1" : rawPath
    }
    let mergedHeaders = mergeProviderHeaders(model.headers, headers)

    let timeoutInterval = Double(timeoutMs ?? 60_000) / 1000.0
    let configuration = OpenAI.Configuration(
        token: token,
        organizationIdentifier: nil,
        host: host,
        port: port,
        scheme: scheme,
        basePath: basePath,
        timeoutInterval: timeoutInterval,
        customHeaders: providerHeadersToRecord(mergedHeaders) ?? [:]
    )
    let session = proxySession(for: url)
    let effectiveMiddlewares = middlewares + [ProviderHeadersMiddleware(headers: mergedHeaders ?? [:])]
    return OpenAI(configuration: configuration, session: session, middlewares: effectiveMiddlewares)
}

private struct ProviderHeadersMiddleware: OpenAIMiddleware {
    let headers: ProviderHeaders

    func intercept(request: URLRequest) -> URLRequest {
        var updated = request
        applyProviderHeaders(headers, to: &updated)
        return updated
    }
}
