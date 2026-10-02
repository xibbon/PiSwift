import Foundation
import CoreFoundation

/// Return only the configured federation variables. All three required values must be nonempty.
public func anthropicFederationEnv(env: [String: String]) -> [String: String]? {
    let required = ["ANTHROPIC_FEDERATION_RULE_ID", "ANTHROPIC_ORGANIZATION_ID", "ANTHROPIC_IDENTITY_TOKEN_FILE"]
    guard required.allSatisfy({ env[$0]?.isEmpty == false }) else { return nil }
    let names = required + ["ANTHROPIC_SERVICE_ACCOUNT_ID", "ANTHROPIC_WORKSPACE_ID"]
    return env.filter { names.contains($0.key) && !$0.value.isEmpty }
}

public struct AnthropicFederationConfig: Sendable, Hashable {
    public let federationRuleId: String
    public let organizationId: String
    public let identityTokenFile: String
    public let serviceAccountId: String?
    public let workspaceId: String?

    public init?(env: [String: String]) {
        guard let bag = anthropicFederationEnv(env: env),
              let rule = bag["ANTHROPIC_FEDERATION_RULE_ID"],
              let organization = bag["ANTHROPIC_ORGANIZATION_ID"],
              let file = bag["ANTHROPIC_IDENTITY_TOKEN_FILE"] else { return nil }
        federationRuleId = rule
        organizationId = organization
        identityTokenFile = file
        serviceAccountId = bag["ANTHROPIC_SERVICE_ACCOUNT_ID"]
        workspaceId = bag["ANTHROPIC_WORKSPACE_ID"]
    }
}

public struct AnthropicFederationError: Error, LocalizedError, Sendable {
    public let message: String
    public let statusCode: Int?
    public let requestId: String?
    public var errorDescription: String? { message }

    init(_ message: String, statusCode: Int? = nil, requestId: String? = nil) {
        self.message = message
        self.statusCode = statusCode
        self.requestId = requestId
    }
}

/// Accept the same nonempty request credentials as the upstream Anthropic adapter.
func hasRequestAuth(apiKey: String?, headers: ProviderHeaders?) -> Bool {
    if let apiKey, !apiKey.isEmpty { return true }
    return ["authorization", "x-api-key", "cf-aig-authorization"].contains { name in
        guard let value = providerHeaderValue(headers, name: name) else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct AnthropicFederationToken: Sendable {
    let value: String
    let expiresAt: Double
}

struct AnthropicFederationCacheKey: Hashable, Sendable {
    let baseUrl: String
    let config: AnthropicFederationConfig
}

/// One memory cache for all callers. Each base URL and configuration has its own token.
actor AnthropicFederationTokenCache {
    private struct Entry {
        var token: AnthropicFederationToken?
        var pending: Task<AnthropicFederationToken, Error>?
        var generation: UUID?
        var lastAdvisoryError: Double?
        var advisory = false
    }
    private var entries: [AnthropicFederationCacheKey: Entry] = [:]
    private let clock: @Sendable () -> Double

    init(clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.clock = clock
    }

    func reset() {
        for entry in entries.values { entry.pending?.cancel() }
        entries.removeAll()
    }

    func token(
        key: AnthropicFederationCacheKey,
        forceRefresh: Bool = false,
        now: Double? = nil,
        exchange: @escaping @Sendable () async throws -> AnthropicFederationToken
    ) async throws -> String {
        let now = now ?? clock()
        let entry = entries[key] ?? Entry()
        if !forceRefresh, let token = entry.token {
            let remaining = token.expiresAt - now
            if remaining > 120 { return token.value }
            if remaining > 30 {
                if entry.pending == nil, entry.lastAdvisoryError.map({ now - $0 >= 5 }) ?? true {
                    let (task, generation) = beginRefresh(key: key, advisory: true, exchange: exchange)
                    Task { _ = try? await finishRefresh(key: key, task: task, generation: generation) }
                }
                return token.value
            }
        }
        if !forceRefresh, let task = entry.pending, let generation = entry.generation {
            return try await finishRefresh(key: key, task: task, generation: generation).value
        }
        if forceRefresh { entries[key]?.token = nil }
        let (task, generation) = beginRefresh(key: key, exchange: exchange)
        return try await finishRefresh(key: key, task: task, generation: generation).value
    }

    // Wait for an advisory exchange in controlled cache tests.
    func waitForPendingRefresh(key: AnthropicFederationCacheKey) async {
        guard let task = entries[key]?.pending, let generation = entries[key]?.generation else { return }
        _ = try? await finishRefresh(key: key, task: task, generation: generation)
    }

    private func beginRefresh(
        key: AnthropicFederationCacheKey,
        advisory: Bool = false,
        exchange: @escaping @Sendable () async throws -> AnthropicFederationToken
    ) -> (Task<AnthropicFederationToken, Error>, UUID) {
        let generation = UUID()
        let task = Task { try await exchange() }
        var entry = entries[key] ?? Entry()
        entry.pending = task
        entry.generation = generation
        entry.advisory = advisory
        entries[key] = entry
        return (task, generation)
    }

    private func finishRefresh(
        key: AnthropicFederationCacheKey, task: Task<AnthropicFederationToken, Error>, generation: UUID
    ) async throws -> AnthropicFederationToken {
        do {
            let token = try await task.value
            if entries[key]?.generation == generation {
                entries[key]?.token = token
                entries[key]?.pending = nil
                entries[key]?.generation = nil
            }
            return token
        } catch {
            if entries[key]?.generation == generation {
                if entries[key]?.advisory == true { entries[key]?.lastAdvisoryError = clock() }
                entries[key]?.pending = nil
                entries[key]?.generation = nil
            }
            throw error
        }
    }
}

private let anthropicFederationCache = AnthropicFederationTokenCache()

/// Clear the memory cache. Tests can use this function before a controlled request sequence.
public func resetAnthropicFederationCache() async {
    await anthropicFederationCache.reset()
}

func anthropicFederationToken(
    config: AnthropicFederationConfig, baseUrl: String, client: any ProviderHTTPClient,
    forceRefresh: Bool = false
) async throws -> String {
    let key = AnthropicFederationCacheKey(baseUrl: baseUrl, config: config)
    return try await anthropicFederationCache.token(key: key, forceRefresh: forceRefresh) {
        try await exchangeAnthropicFederationToken(config: config, baseUrl: baseUrl, client: client)
    }
}

func exchangeAnthropicFederationToken(
    config: AnthropicFederationConfig, baseUrl: String, client: any ProviderHTTPClient
) async throws -> AnthropicFederationToken {
    let base = baseUrl.isEmpty ? "https://api.anthropic.com" : baseUrl
    guard let baseURL = URL(string: base), let scheme = baseURL.scheme, let host = baseURL.host else {
        throw AnthropicFederationError("Invalid token endpoint base URL \"\(base)\"")
    }
    let localHosts = ["localhost", "127.0.0.1", "::1", "[::1]"]
    guard scheme.lowercased() == "https" || (scheme.lowercased() == "http" && localHosts.contains(host.lowercased())) else {
        throw AnthropicFederationError("Refusing to send credential over non-https token endpoint \"\(base)\"")
    }
    let assertion: String
    do {
        assertion = try String(contentsOfFile: config.identityTokenFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        throw AnthropicFederationError("Failed to read identity token file at \(config.identityTokenFile): \(error.localizedDescription)")
    }
    guard !assertion.isEmpty else {
        throw AnthropicFederationError("Identity token file at \(config.identityTokenFile) is empty")
    }
    guard assertion.utf16.count <= 16 * 1024 else {
        throw AnthropicFederationError("Identity token is \(Int(ceil(Double(assertion.utf16.count) / 1024))) KiB, exceeds the 16 KiB assertion limit")
    }
    var body = ["grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": assertion,
                "federation_rule_id": config.federationRuleId, "organization_id": config.organizationId]
    body["service_account_id"] = config.serviceAccountId
    body["workspace_id"] = config.workspaceId
    let endpoint = base.replacingOccurrences(of: "/+$", with: "", options: .regularExpression) + "/v1/oauth/token"
    guard let url = URL(string: endpoint) else { throw AnthropicFederationError("Invalid token endpoint base URL \"\(base)\"") }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("oauth-2025-04-20,oidc-federation-2026-04-01", forHTTPHeaderField: "anthropic-beta")
    request.setValue(getPiUserAgent(), forHTTPHeaderField: "User-Agent")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let response: ProviderHTTPResponse
    do { response = try await client.send(request) }
    catch { throw AnthropicFederationError("Failed to reach token endpoint \(endpoint): \(error.localizedDescription)") }
    let requestId = response.headers.first { $0.key.lowercased() == "request-id" }?.value
    if !(200..<300).contains(response.statusCode) {
        let data = (try? await collectProviderHTTPBody(response.body)) ?? Data()
        let redacted = redactAnthropicFederationBody(data)
        var hint = ""
        if response.statusCode == 401 {
            hint = " Ensure your federation rule matches your identity token. "
            if config.workspaceId == nil {
                hint += "If your federation rule is scoped to multiple workspaces, set the ANTHROPIC_WORKSPACE_ID environment variable, the 'workspace_id' config key, or the `workspaceId` option. "
            }
            hint += "View your authentication events in the Workload identity page of Claude Console for more details."
        }
        let id = requestId.map { " (request-id \($0))" } ?? ""
        throw AnthropicFederationError("Token exchange failed with status \(response.statusCode)\(id): \(redacted)\(hint)",
                                       statusCode: response.statusCode, requestId: requestId)
    }
    var data = Data()
    for try await chunk in response.body {
        let remaining = (1 << 20) - data.count
        if chunk.count > remaining {
            data.append(chunk.prefix(remaining))
            break
        }
        data.append(chunk)
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw AnthropicFederationError("Token endpoint returned non-JSON response (status \(response.statusCode))", statusCode: response.statusCode, requestId: requestId)
    }
    guard let token = object["access_token"] as? String, !token.isEmpty else {
        throw AnthropicFederationError("Token endpoint response missing access_token: \(redactAnthropicFederationBody(data))", statusCode: response.statusCode, requestId: requestId)
    }
    if let rawType = object["token_type"], anthropicFederationJSONTruthy(rawType) {
        guard let type = rawType as? String, type.lowercased() == "bearer" else {
            throw AnthropicFederationError("Token endpoint response: unsupported token_type \"\(String(describing: rawType))\" (want Bearer)", statusCode: response.statusCode, requestId: requestId)
        }
    }
    // The SDK applies Number() before the finite check, so numeric strings are valid.
    let expires = anthropicFederationNumber(object["expires_in"])
    guard let expires, expires.isFinite else {
        throw AnthropicFederationError("Token endpoint response missing required fields: \(redactAnthropicFederationBody(data))", statusCode: response.statusCode, requestId: requestId)
    }
    return AnthropicFederationToken(value: token, expiresAt: Date().timeIntervalSince1970 + expires)
}

private func redactAnthropicFederationBody(_ data: Data) -> String {
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        let safe = object.filter { ["error", "error_description", "error_uri"].contains($0.key) }
        return (try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
    let text = String(data: data, encoding: .utf8) ?? ""
    guard text.count > 2000 else { return text }
    return String(text.prefix(2000)) + "... <\(text.count - 2000) more chars>"
}

// Preserve the SDK Number() conversion of JSON values before its finite check.
private func anthropicFederationNumber(_ value: Any?) -> Double? {
    guard let value else { return nil }
    if value is NSNull { return 0 }
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return 0 }
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] {
            if text.lowercased().hasPrefix(prefix) {
                return UInt64(text.dropFirst(2), radix: radix).map(Double.init)
            }
        }
        return Double(text)
    }
    if let value = value as? [Any] {
        return anthropicFederationNumber(anthropicFederationJSONString(value))
    }
    return nil
}

private func anthropicFederationJSONTruthy(_ value: Any) -> Bool {
    if value is NSNull { return false }
    if let value = value as? String { return !value.isEmpty }
    if let value = value as? NSNumber { return value.doubleValue != 0 }
    return true
}

private func anthropicFederationJSONString(_ value: Any) -> String {
    if value is NSNull { return "null" }
    if let value = value as? String { return value }
    if let value = value as? NSNumber {
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return value.boolValue ? "true" : "false" }
        return value.stringValue
    }
    if let value = value as? [Any] {
        return value.map { $0 is NSNull ? "" : anthropicFederationJSONString($0) }.joined(separator: ",")
    }
    return "[object Object]"
}
