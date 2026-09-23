import Foundation
import CoreFoundation

private let metaClientId = "1031625952748946"
private let metaDeviceAuthorizationURL = URL(string: "https://auth.meta.com/oidc/device/authorization/")!
private let metaDeviceTokenURL = URL(string: "https://auth.meta.com/oidc/device/token/")!
private let metaKeyMintURL = URL(string: "https://api.meta.ai/muse-code/key")!
private let metaKeyLifetimeMs = 24 * 60 * 60 * 1000.0
private let metaRequestTimeoutMs = 30_000

/// An injected request executor keeps the device flow and key mint testable without network access.
struct MetaOAuthHTTPClient: Sendable {
    let send: @Sendable (URLRequest, CancellationToken?) async throws -> OAuthNetworkResponse

    static let live = MetaOAuthHTTPClient { request, signal in
        try await oauthData(for: request, signal: signal, timeoutMs: metaRequestTimeoutMs)
    }
}

private struct MetaDeviceAuthorization: Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let intervalSeconds: Double?
    let expiresInSeconds: Double?
}

private func metaForm(_ fields: [(String, String)]) -> Data {
    func encode(_ value: String) -> String {
        value.utf8.map { byte in
            switch byte {
            case 65...90, 97...122, 48...57, 42, 45, 46, 95:
                return String(UnicodeScalar(byte))
            case 32:
                return "+"
            default:
                return String(format: "%%%02X", byte)
            }
        }.joined()
    }
    return Data(fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&").utf8)
}

private func metaFormRequest(url: URL, fields: [(String, String)]) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = Double(metaRequestTimeoutMs) / 1000
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = metaForm(fields)
    return request
}

private func metaJSON(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func metaErrorDetail(_ json: [String: Any]?) -> String {
    for key in ["error_description", "detail", "message", "error"] {
        if let value = json?[key] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return ": \(trimmed)" }
        }
    }
    return ""
}

private func metaTrustedURL(_ value: Any?) -> String? {
    guard let value = value as? String,
          !value.isEmpty,
          let components = URLComponents(string: value),
          let scheme = components.scheme?.lowercased(),
          (scheme == "https" || scheme == "http"),
          let host = components.host, !host.isEmpty,
          let url = components.url else { return nil }
    return url.absoluteString
}

private func metaPositiveNumber(_ value: Any?) -> Double? {
    guard let value = value as? NSNumber,
          CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
    let number = value.doubleValue
    return number.isFinite && number > 0 ? number : nil
}

private func startMetaDeviceAuthorization(
    signal: CancellationToken?,
    httpClient: MetaOAuthHTTPClient
) async throws -> MetaDeviceAuthorization {
    try throwIfOAuthCancelled(signal)
    let request = metaFormRequest(url: metaDeviceAuthorizationURL, fields: [("client_id", metaClientId)])
    let response = try await httpClient.send(request, signal)
    let json = metaJSON(response.data)
    guard (200..<300).contains(response.status) else {
        throw OAuthError.tokenExchangeFailed(
            "Meta device authorization failed with status \(response.status)\(metaErrorDetail(json))"
        )
    }
    guard let deviceCode = json?["device_code"] as? String, !deviceCode.isEmpty,
          let userCode = json?["user_code"] as? String, !userCode.isEmpty,
          let verificationURI = metaTrustedURL(json?["verification_uri_complete"])
            ?? metaTrustedURL(json?["verification_uri"]) else {
        throw OAuthError.tokenExchangeFailed("Invalid Meta device authorization response")
    }
    return MetaDeviceAuthorization(
        deviceCode: deviceCode,
        userCode: userCode,
        verificationURI: verificationURI,
        intervalSeconds: metaPositiveNumber(json?["interval"]),
        expiresInSeconds: metaPositiveNumber(json?["expires_in"])
    )
}

private func pollMetaIdentityToken(
    device: MetaDeviceAuthorization,
    signal: CancellationToken?,
    httpClient: MetaOAuthHTTPClient
) async throws -> String {
    try await pollOAuthDeviceCodeFlow(
        intervalSeconds: device.intervalSeconds ?? 5,
        expiresInSeconds: device.expiresInSeconds,
        signal: signal,
        minimumIntervalMs: 1_000
    ) {
        let request = metaFormRequest(url: metaDeviceTokenURL, fields: [
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ("device_code", device.deviceCode),
            ("client_id", metaClientId),
        ])
        let response = try await httpClient.send(request, signal)
        let json = metaJSON(response.data)
        if (200..<300).contains(response.status),
           let token = json?["access_token"] as? String, !token.isEmpty {
            return .complete(token)
        }
        switch json?["error"] as? String {
        case "authorization_pending":
            return .pending
        case "slow_down":
            return .slowDown(intervalSeconds: metaPositiveNumber(json?["interval"]))
        case "access_denied":
            return .failed("Meta login was denied.")
        case "expired_token":
            return .failed("Meta device authorization expired. Please restart login.")
        default:
            return .failed("Meta device token request failed with status \(response.status)\(metaErrorDetail(json))")
        }
    }
}

private func mintMetaAPIKey(
    identityToken: String,
    signal: CancellationToken?,
    httpClient: MetaOAuthHTTPClient,
    now: @Sendable () -> Double
) async throws -> OAuthCredentials {
    try throwIfOAuthCancelled(signal)
    var request = URLRequest(url: metaKeyMintURL)
    request.httpMethod = "POST"
    request.timeoutInterval = Double(metaRequestTimeoutMs) / 1000
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(identityToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("1.0.0", forHTTPHeaderField: "x-api-version")
    request.httpBody = Data("{}".utf8)
    let response = try await httpClient.send(request, signal)
    let json = metaJSON(response.data)
    if response.status == 401 || response.status == 403 {
        throw OAuthError.refreshFailed(
            "Meta session expired (status \(response.status)). Run `/login meta` to sign in again.\(metaErrorDetail(json))"
        )
    }
    guard (200..<300).contains(response.status) else {
        throw OAuthError.tokenExchangeFailed(
            "Meta API key mint failed with status \(response.status)\(metaErrorDetail(json))"
        )
    }
    guard let apiKey = json?["api_key"] as? String, !apiKey.isEmpty else {
        let action = metaTrustedURL(json?["action_url"]).map { " Complete setup at \($0)" } ?? ""
        throw OAuthError.tokenExchangeFailed("Meta did not issue an API key.\(action)")
    }
    return OAuthCredentials(refresh: identityToken, access: apiKey, expires: now() + metaKeyLifetimeMs)
}

public func loginMeta(_ callbacks: OAuthLoginCallbacks) async throws -> OAuthCredentials {
    try await loginMeta(callbacks, httpClient: .live)
}

func loginMeta(
    _ callbacks: OAuthLoginCallbacks,
    httpClient: MetaOAuthHTTPClient,
    now: @Sendable () -> Double = nowMs
) async throws -> OAuthCredentials {
    do {
        let device = try await startMetaDeviceAuthorization(signal: callbacks.signal, httpClient: httpClient)
        await callbacks.onAuth(OAuthAuthInfo(
            url: device.verificationURI,
            instructions: "Enter code: \(device.userCode)"
        ))
        let identityToken = try await pollMetaIdentityToken(
            device: device, signal: callbacks.signal, httpClient: httpClient
        )
        await callbacks.onProgress?("Enabling Meta Model API access...")
        return try await mintMetaAPIKey(
            identityToken: identityToken, signal: callbacks.signal, httpClient: httpClient, now: now
        )
    } catch {
        if callbacks.signal?.isCancelled == true || Task.isCancelled { throw OAuthError.cancelled }
        throw error
    }
}

public func refreshMetaToken(_ identityToken: String, signal: CancellationToken? = nil) async throws -> OAuthCredentials {
    try await refreshMetaToken(identityToken, signal: signal, httpClient: .live)
}

func refreshMetaToken(
    _ identityToken: String,
    signal: CancellationToken? = nil,
    httpClient: MetaOAuthHTTPClient,
    now: @Sendable () -> Double = nowMs
) async throws -> OAuthCredentials {
    try await mintMetaAPIKey(identityToken: identityToken, signal: signal, httpClient: httpClient, now: now)
}
