import Foundation
import PiSwiftAI
import PiSwiftCodingAgent

// Port of the parts of pi-codex-image-gen `src/image-oauth.ts` that a ChatGPT
// session still needs. The session already holds `openai-codex` OAuth, so this
// extension has no login provider, token exchange, or credential fallback.

/// The ChatGPT subscription provider. The extension is active only for it.
public let codexImageChatGPTProvider = "openai-codex"

let codexDefaultBaseUrl = "https://chatgpt.com/backend-api"
private let authClaim = "https://api.openai.com/auth"
private let maxTokenBytes = 64 * 1024

/// True when the model routes through the ChatGPT subscription backend.
public func isChatGPTModel(_ model: Model?) -> Bool {
    model?.provider == codexImageChatGPTProvider
}

struct CodexImageError: Error, LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Credentials and routing for one image request.
struct CodexImageAuth: Sendable {
    var token: String
    var accountId: String
    var responsesURL: URL
    /// Model and provider headers. The protected headers replace these.
    var extraHeaders: [String: String]
    /// The session model, used as the Responses routing model.
    var routingModel: String
}

/// Read the ChatGPT account id claim. This is a routing hint only: OpenAI, not
/// this client, authenticates the JWT.
func extractChatGPTAccountId(_ token: String) throws -> String {
    let failure = CodexImageError("The ChatGPT login has no valid account ID. Run /login \(codexImageChatGPTProvider) again.")
    guard token.utf8.count <= maxTokenBytes,
          token.unicodeScalars.allSatisfy({ isTokenScalar($0) }) else { throw failure }
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }),
          let payload = base64URLDecode(String(parts[1])),
          let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
          let claim = json[authClaim] as? [String: Any],
          let accountId = claim["chatgpt_account_id"] as? String,
          isIdentifier(accountId, maxLength: 128) else { throw failure }
    return accountId
}

private func isTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar {
    case "a"..."z", "A"..."Z", "0"..."9", "_", ".", "-": return true
    default: return false
    }
}

/// `[A-Za-z0-9_-]{1,maxLength}`.
func isIdentifier(_ value: String, maxLength: Int) -> Bool {
    guard !value.isEmpty, value.utf8.count <= maxLength else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "_", "-": return true
        default: return false
        }
    }
}

func base64URLDecode(_ value: String) -> Data? {
    var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder == 1 { return nil }
    if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
    return Data(base64Encoded: base64)
}

/// The same `/codex` suffix rule as the `openai-codex` chat provider, plus `/responses`.
func codexResponsesURL(baseUrl: String?) -> URL? {
    var base = (baseUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if base.isEmpty { base = codexDefaultBaseUrl }
    while base.hasSuffix("/") { base.removeLast() }
    if !base.contains("/codex") { base += "/codex" }
    guard let url = URL(string: base + "/responses"), url.scheme == "https" || url.scheme == "http" else { return nil }
    return url
}

/// Resolve the session's ChatGPT credentials. AuthStorage refreshes an
/// expiring OAuth token before it returns it.
func resolveCodexImageAuth(model: Model?, registry: ModelRegistry, signal: CancellationToken?) async throws -> CodexImageAuth {
    guard let model, isChatGPTModel(model) else {
        throw CodexImageError("Image generation needs a ChatGPT (\(codexImageChatGPTProvider)) session. No generation request was made.")
    }
    let resolved = await registry.resolveModelRequest(model, signal: signal)
    let auth = resolved.auth
    guard auth.ok, let token = auth.apiKey, !token.isEmpty else {
        throw CodexImageError("Missing ChatGPT credentials. Run /login \(codexImageChatGPTProvider). No generation request was made.")
    }
    let accountId = try extractChatGPTAccountId(token)
    guard let url = codexResponsesURL(baseUrl: auth.baseUrl ?? resolved.model.baseUrl) else {
        throw CodexImageError("The ChatGPT base URL is not valid. No generation request was made.")
    }
    let routingModel = model.id
    guard !routingModel.isEmpty, routingModel.count <= 200, !routingModel.hasPrefix("gpt-image-") else {
        throw CodexImageError("The session model cannot route Codex image generation. No generation request was made.")
    }
    return CodexImageAuth(token: token, accountId: accountId, responsesURL: url,
                          extraHeaders: providerHeadersToRecord(auth.headers) ?? [:], routingModel: routingModel)
}
