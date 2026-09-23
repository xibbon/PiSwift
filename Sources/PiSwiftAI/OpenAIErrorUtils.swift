import Foundation
import OpenAI

func shouldLogOpenAIDebug() -> Bool {
    let env = ProcessInfo.processInfo.environment
    let flag = (env["PI_DEBUG_OPENAI"] ?? env["PI_DEBUG"])?.lowercased()
    return flag == "1" || flag == "true" || flag == "yes"
}

func logOpenAIDebug(_ message: String) {
    guard shouldLogOpenAIDebug() else { return }
    let line = "PI_DEBUG: \(message)\n"
    if let data = line.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

private func requestId(from response: HTTPURLResponse) -> String? {
    response.value(forHTTPHeaderField: "x-request-id") ??
        response.value(forHTTPHeaderField: "openai-request-id")
}

func describeOpenAIError(_ error: Error, provider: String? = nil) -> String {
    let providerName = provider.map { $0 == "openai" ? "OpenAI" : $0 } ?? "OpenAI"
    if let apiError = error as? APIErrorResponse {
        return apiError.errorDescription ?? "\(providerName) API error."
    }

    if let openAIError = error as? OpenAIError {
        switch openAIError {
        case .emptyData:
            return "\(providerName) API returned an empty response."
        case .statusError(let response, let statusCode):
            let requestId = requestId(from: response)
            if let requestId {
                logOpenAIDebug("openai statusError status=\(statusCode) requestId=\(requestId) url=\(response.url?.absoluteString ?? "")")
            } else {
                logOpenAIDebug("openai statusError status=\(statusCode) url=\(response.url?.absoluteString ?? "")")
            }
            var message = "\(providerName) API error (HTTP \(statusCode)). Check your API key, model, and request parameters."
            if let requestId {
                message += "\nRequest ID: \(requestId)"
            }
            return message
        }
    }

    let message = retryAwareErrorDescription(error)
    guard provider != nil else { return message }
    return "\(providerName) API error: \(message)"
}
