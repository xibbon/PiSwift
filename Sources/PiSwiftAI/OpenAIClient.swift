import Foundation
import OpenAI

func makeOpenAIClient(
    model: Model,
    apiKey: String?,
    headers: [String: String]? = nil,
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
    var mergedHeaders = model.headers ?? [:]
    if let headers {
        for (key, value) in headers {
            mergedHeaders[key] = value
        }
    }

    let configuration = OpenAI.Configuration(
        token: token,
        organizationIdentifier: nil,
        host: host,
        port: port,
        scheme: scheme,
        basePath: basePath,
        timeoutInterval: 60,
        customHeaders: mergedHeaders
    )
    let session = proxySession(for: url)
    return OpenAI(configuration: configuration, session: session, middlewares: middlewares)
}
