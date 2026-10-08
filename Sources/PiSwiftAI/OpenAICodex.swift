import Foundation

enum OpenAICodexError: Error, LocalizedError {
    case missingAccountId

    var errorDescription: String? {
        switch self {
        case .missingAccountId:
            return "OpenAI Codex token is missing chatgpt_account_id."
        }
    }
}

func resolveOpenAICodexBaseUrl(_ baseUrl: String) -> String {
    let trimmed = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return baseUrl }
    if trimmed.contains("/codex") { return trimmed }
    if trimmed.hasSuffix("/") { return trimmed + "codex" }
    return trimmed + "/codex"
}

func buildOpenAICodexHeaders(
    baseHeaders: ProviderHeaders?,
    additionalHeaders: ProviderHeaders? = nil,
    accessToken: String
) throws -> [String: String] {
    guard let accountId = openAICodexAccountId(from: accessToken) else {
        throw OpenAICodexError.missingAccountId
    }

    // Upstream v1.1.0: defaults, model fields, caller fields, then protected auth fields.
    let defaults: ProviderHeaders = ["originator": "pi", "User-Agent": getPiUserAgent()]
    let requested = mergeProviderHeaders(mergeProviderHeaders(defaults, baseHeaders), additionalHeaders)
    let protected: ProviderHeaders = [
        "Authorization": "Bearer \(accessToken)",
        "chatgpt-account-id": accountId,
    ]
    let headers = providerHeadersToRecord(mergeProviderHeaders(requested, protected)) ?? [:]
    return headers
}

private func openAICodexAccountId(from accessToken: String) -> String? {
    guard let payload = decodeJwt(accessToken) else { return nil }
    guard let auth = payload["https://api.openai.com/auth"] as? [String: Any] else { return nil }
    let accountId = auth["chatgpt_account_id"] as? String
    return (accountId?.isEmpty == false) ? accountId : nil
}

private func decodeJwt(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count == 3 else { return nil }
    guard let data = base64UrlDecode(String(parts[1])) else { return nil }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return json
}

private func base64UrlDecode(_ input: String) -> Data? {
    var base64 = input.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder != 0 {
        base64 += String(repeating: "=", count: 4 - remainder)
    }
    return Data(base64Encoded: base64)
}
