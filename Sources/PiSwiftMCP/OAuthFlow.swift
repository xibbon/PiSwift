import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PiSwiftAI

public enum McpOAuthFlowResult: Sendable, Equatable {
    case authorized
    case redirect
}

public protocol McpOAuthClientProvider: Sendable {
    var redirectURL: URL { get }
    var clientMetadata: McpOAuthClientMetadata { get }
    var clientMetadataURL: URL? { get }
    func state() async throws -> String?
    func clientInformation() async throws -> McpOAuthClientInformation?
    func saveClientInformation(_ information: McpOAuthClientInformation) async throws
    func tokens() async throws -> McpOAuthTokens?
    func saveTokens(_ tokens: McpOAuthTokens) async throws
    func redirectToAuthorization(_ url: URL) async throws
    func saveCodeVerifier(_ verifier: String) async throws
    func codeVerifier() async throws -> String
    func invalidateCredentials(_ kind: McpOAuthCredentialKind) async throws
    func saveDiscoveryState(_ state: McpOAuthDiscoveryState) async throws
    func discoveryState() async throws -> McpOAuthDiscoveryState?
    func addClientAuthentication(tokenURL: URL, metadata: McpOAuthAuthorizationServerMetadata?) async throws -> McpOAuthClientAuthentication?
}

public extension McpOAuthClientProvider {
    var clientMetadataURL: URL? { nil }
    func addClientAuthentication(tokenURL: URL, metadata: McpOAuthAuthorizationServerMetadata?) async throws -> McpOAuthClientAuthentication? { nil }
}

public struct McpOAuthClientAuthentication: Sendable {
    public var headers: [String: String]
    public var parameters: [String: String]

    public init(headers: [String: String] = [:], parameters: [String: String] = [:]) {
        self.headers = headers
        self.parameters = parameters
    }
}

public enum McpOAuthCredentialKind: String, Sendable {
    case all, client, tokens, verifier, discovery
}

public struct McpOAuthFlowOptions: Sendable {
    public var serverURL: URL
    public var authorizationCode: String?
    public var scope: String?
    public var resourceMetadataURL: URL?
    public var skipIssuerValidation: Bool
    public var skipRefresh: Bool

    public init(serverURL: URL, authorizationCode: String? = nil, scope: String? = nil,
                resourceMetadataURL: URL? = nil, skipIssuerValidation: Bool = false, skipRefresh: Bool = false) {
        self.serverURL = serverURL
        self.authorizationCode = authorizationCode
        self.scope = scope
        self.resourceMetadataURL = resourceMetadataURL
        self.skipIssuerValidation = skipIssuerValidation
        self.skipRefresh = skipRefresh
    }
}

public struct McpOAuthAuthorization: Sendable {
    public var authorizationURL: URL
    public var codeVerifier: String
}

public enum McpOAuthFlow {
    /// Validate a callback or pasted redirect URL before exchanging its code.
    public static func completeRedirect(
        provider: any McpOAuthClientProvider, callbackURL: URL,
        serverURL: URL, http: any McpOAuthHTTPClient = McpURLSessionOAuthHTTPClient()
    ) async throws -> McpOAuthTokens {
        let expected = provider.redirectURL
        guard callbackURL.scheme == expected.scheme, callbackURL.host == expected.host,
              callbackURL.port == expected.port, callbackURL.path == expected.path,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw McpOAuthError.invalidRedirect
        }
        let parameter: (String) -> String? = { name in
            components.queryItems?.first { $0.name == name }?.value
        }
        if let error = parameter("error") {
            throw McpOAuthError.authorization(code: error,
                message: parameter("error_description") ?? error, uri: parameter("error_uri"))
        }
        guard let state = parameter("state"), state == (try await provider.state()) else {
            throw McpOAuthError.invalidState
        }
        guard let code = parameter("code"), !code.isEmpty else { throw McpOAuthError.invalidRedirect }
        let result = try await authorize(provider: provider,
            options: McpOAuthFlowOptions(serverURL: serverURL, authorizationCode: code), http: http)
        guard result == .authorized, let tokens = try await provider.tokens() else {
            throw McpOAuthError.authorizationRequired
        }
        return tokens
    }

    public static func startAuthorization(
        authorizationServerURL: URL, metadata: McpOAuthAuthorizationServerMetadata? = nil,
        clientInformation: McpOAuthClientInformation, redirectURL: URL,
        scope: String? = nil, state: String? = nil, resource: String? = nil
    ) throws -> McpOAuthAuthorization {
        if let metadata, !metadata.responseTypesSupported.contains("code") {
            throw McpOAuthError.invalidMetadata("authorization codes are unsupported")
        }
        if let methods = metadata?.codeChallengeMethodsSupported, !methods.contains("S256") {
            throw McpOAuthError.invalidMetadata("PKCE S256 is unsupported")
        }
        guard let url = URL(string: metadata?.authorizationEndpoint ?? "/authorize", relativeTo: authorizationServerURL)?.absoluteURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw McpOAuthError.invalidMetadata("authorization endpoint")
        }
        let pair = try generatePKCE()
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientInformation.clientID),
            URLQueryItem(name: "code_challenge", value: pair.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
        ]
        if let state { items.append(URLQueryItem(name: "state", value: state)) }
        if let scope {
            items.append(URLQueryItem(name: "scope", value: scope))
            if scope.split(whereSeparator: { $0.isWhitespace }).contains("offline_access") {
                items.append(URLQueryItem(name: "prompt", value: "consent"))
            }
        }
        if let resource { items.append(URLQueryItem(name: "resource", value: resource)) }
        components.queryItems = items
        guard let authorizationURL = components.url else { throw McpOAuthError.invalidMetadata("authorization URL") }
        return McpOAuthAuthorization(authorizationURL: authorizationURL, codeVerifier: pair.verifier)
    }

    public static func registerClient(
        authorizationServerURL: URL, metadata: McpOAuthAuthorizationServerMetadata? = nil,
        clientMetadata: McpOAuthClientMetadata, scope: String? = nil,
        http: any McpOAuthHTTPClient = McpURLSessionOAuthHTTPClient()
    ) async throws -> McpOAuthClientInformation {
        if metadata != nil && metadata?.registrationEndpoint == nil {
            throw McpOAuthError.invalidMetadata("dynamic client registration unsupported")
        }
        guard let endpoint = URL(string: metadata?.registrationEndpoint ?? "/register", relativeTo: authorizationServerURL)?.absoluteURL else {
            throw McpOAuthError.invalidMetadata("registration endpoint")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(clientMetadata)) as? [String: Any] ?? [:]
        if let scope { body["scope"] = scope }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw McpOAuthError.registration(status: response.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        var information = try JSONDecoder().decode(McpOAuthClientInformation.self, from: data)
        information.metadata = try? JSONDecoder().decode(McpOAuthClientMetadata.self, from: data)
        guard !information.clientID.isEmpty else { throw McpOAuthError.invalidMetadata("client_id") }
        return information
    }

    public static func exchangeAuthorizationCode(
        authorizationServerURL: URL, metadata: McpOAuthAuthorizationServerMetadata? = nil,
        clientInformation: McpOAuthClientInformation, code: String, codeVerifier: String,
        redirectURL: URL, resource: String? = nil,
        clientAuthentication: (any McpOAuthClientProvider)? = nil,
        http: any McpOAuthHTTPClient = McpURLSessionOAuthHTTPClient()
    ) async throws -> McpOAuthTokens {
        try await tokenRequest(authorizationServerURL: authorizationServerURL, metadata: metadata,
            clientInformation: clientInformation,
            parameters: ["grant_type": "authorization_code", "code": code,
                         "code_verifier": codeVerifier, "redirect_uri": redirectURL.absoluteString],
            resource: resource, clientAuthentication: clientAuthentication, http: http)
    }

    public static func refreshAuthorization(
        authorizationServerURL: URL, metadata: McpOAuthAuthorizationServerMetadata? = nil,
        clientInformation: McpOAuthClientInformation, refreshToken: String,
        resource: String? = nil, clientAuthentication: (any McpOAuthClientProvider)? = nil,
        http: any McpOAuthHTTPClient = McpURLSessionOAuthHTTPClient()
    ) async throws -> McpOAuthTokens {
        var result = try await tokenRequest(authorizationServerURL: authorizationServerURL, metadata: metadata,
            clientInformation: clientInformation,
            parameters: ["grant_type": "refresh_token", "refresh_token": refreshToken],
            resource: resource, clientAuthentication: clientAuthentication, http: http)
        if result.refreshToken == nil { result.refreshToken = refreshToken }
        return result
    }

    public static func authorize(
        provider: any McpOAuthClientProvider, options: McpOAuthFlowOptions,
        http: any McpOAuthHTTPClient = McpURLSessionOAuthHTTPClient()
    ) async throws -> McpOAuthFlowResult {
        for attempt in 0..<2 {
            do { return try await runFlow(provider: provider, options: options, http: http) }
            catch let error as McpOAuthError {
                guard attempt == 0 else { throw error }
                if case .authorization(let code, _, _) = error {
                    if code == "invalid_client" || code == "unauthorized_client" {
                        try await provider.invalidateCredentials(.all)
                        continue
                    }
                    if code == "invalid_grant" {
                        try await provider.invalidateCredentials(.tokens)
                        continue
                    }
                }
                throw error
            }
        }
        throw McpOAuthError.authorizationRequired
    }

    private static func runFlow(
        provider: any McpOAuthClientProvider, options: McpOAuthFlowOptions, http: any McpOAuthHTTPClient
    ) async throws -> McpOAuthFlowResult {
        let cached = try await provider.discoveryState()
        let info: McpOAuthServerInfo
        if let cached, let url = URL(string: cached.authorizationServerURL) {
            let serverMetadata: McpOAuthAuthorizationServerMetadata?
            if let saved = cached.authorizationServerMetadata {
                serverMetadata = saved
            } else {
                serverMetadata = try await McpOAuthDiscovery.authorizationServerMetadata(
                    issuer: url, http: http, skipIssuerValidation: options.skipIssuerValidation)
            }
            info = McpOAuthServerInfo(
                authorizationServerURL: url,
                authorizationServerMetadata: serverMetadata,
                resourceMetadata: cached.resourceMetadata)
        } else {
            info = try await McpOAuthDiscovery.serverInfo(serverURL: options.serverURL,
                resourceMetadataURL: options.resourceMetadataURL, http: http,
                skipIssuerValidation: options.skipIssuerValidation)
        }
        try await provider.saveDiscoveryState(McpOAuthDiscoveryState(
            authorizationServerURL: info.authorizationServerURL.absoluteString,
            authorizationServerMetadata: info.authorizationServerMetadata,
            resourceMetadata: info.resourceMetadata,
            resourceMetadataURL: options.resourceMetadataURL?.absoluteString))
        let resource = try McpOAuthDiscovery.selectResource(serverURL: options.serverURL, metadata: info.resourceMetadata)
        let scope = options.scope ?? info.resourceMetadata?.scopesSupported?.joined(separator: " ") ?? provider.clientMetadata.scope
        var client = try await provider.clientInformation()
        if client == nil {
            if options.authorizationCode != nil { throw McpOAuthError.invalidMetadata("client information missing during code exchange") }
            if info.authorizationServerMetadata?.clientIDMetadataDocumentSupported == true,
               let url = provider.clientMetadataURL {
                guard url.scheme == "https", url.path != "/", !url.path.isEmpty else {
                    throw McpOAuthError.invalidMetadata("client metadata URL")
                }
                client = McpOAuthClientInformation(clientID: url.absoluteString)
            } else {
                client = try await registerClient(authorizationServerURL: info.authorizationServerURL,
                    metadata: info.authorizationServerMetadata, clientMetadata: provider.clientMetadata,
                    scope: scope, http: http)
            }
            if let client { try await provider.saveClientInformation(client) }
        }
        guard let client else { throw McpOAuthError.invalidMetadata("client information") }
        if let code = options.authorizationCode {
            let tokens = try await exchangeAuthorizationCode(authorizationServerURL: info.authorizationServerURL,
                metadata: info.authorizationServerMetadata, clientInformation: client,
                code: code, codeVerifier: try await provider.codeVerifier(),
                redirectURL: provider.redirectURL, resource: resource,
                clientAuthentication: provider, http: http)
            try await provider.saveTokens(tokens)
            return .authorized
        }
        if !options.skipRefresh, let refresh = try await provider.tokens()?.refreshToken {
            do {
                let tokens = try await refreshAuthorization(authorizationServerURL: info.authorizationServerURL,
                    metadata: info.authorizationServerMetadata, clientInformation: client,
                    refreshToken: refresh, resource: resource,
                    clientAuthentication: provider, http: http)
                try await provider.saveTokens(tokens)
                return .authorized
            } catch let error as McpOAuthError {
                if case .insecureEndpoint = error { throw error }
                if case .authorization(let code, _, _) = error, code != "server_error" { throw error }
            }
        }
        let authorization = try startAuthorization(authorizationServerURL: info.authorizationServerURL,
            metadata: info.authorizationServerMetadata, clientInformation: client,
            redirectURL: provider.redirectURL, scope: scope, state: try await provider.state(), resource: resource)
        try await provider.saveCodeVerifier(authorization.codeVerifier)
        try await provider.redirectToAuthorization(authorization.authorizationURL)
        return .redirect
    }

    private static func tokenRequest(
        authorizationServerURL: URL, metadata: McpOAuthAuthorizationServerMetadata?,
        clientInformation: McpOAuthClientInformation, parameters: [String: String],
        resource: String?, clientAuthentication: (any McpOAuthClientProvider)?,
        http: any McpOAuthHTTPClient
    ) async throws -> McpOAuthTokens {
        guard let url = URL(string: metadata?.tokenEndpoint ?? "/token", relativeTo: authorizationServerURL)?.absoluteURL else {
            throw McpOAuthError.invalidMetadata("token endpoint")
        }
        guard url.scheme == "https" || ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host ?? "") else {
            throw McpOAuthError.insecureEndpoint(url.absoluteString)
        }
        var values = parameters
        if let resource { values["resource"] = resource }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let custom = try await clientAuthentication?.addClientAuthentication(tokenURL: url, metadata: metadata) {
            values.merge(custom.parameters) { _, new in new }
            for (key, value) in custom.headers { request.setValue(value, forHTTPHeaderField: key) }
        } else {
            let supported = metadata?.tokenEndpointAuthMethodsSupported ?? []
            let hint = clientInformation.metadata?.tokenEndpointAuthMethod
            let method: String
            if let hint, ["none", "client_secret_basic", "client_secret_post"].contains(hint),
               supported.isEmpty || supported.contains(hint) { method = hint }
            else if supported.isEmpty { method = clientInformation.clientSecret == nil ? "none" : "client_secret_basic" }
            else if clientInformation.clientSecret != nil && supported.contains("client_secret_basic") { method = "client_secret_basic" }
            else if clientInformation.clientSecret != nil && supported.contains("client_secret_post") { method = "client_secret_post" }
            else if supported.contains("none") { method = "none" }
            else { method = clientInformation.clientSecret == nil ? "none" : "client_secret_post" }
            if method == "client_secret_basic" {
                guard let secret = clientInformation.clientSecret else { throw McpOAuthError.invalidMetadata("client secret") }
                let encoded = Data("\(clientInformation.clientID):\(secret)".utf8).base64EncodedString()
                request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
            } else {
                values["client_id"] = clientInformation.clientID
                if method == "client_secret_post", let secret = clientInformation.clientSecret { values["client_secret"] = secret }
            }
        }
        var form = URLComponents()
        form.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await http.send(request)
        let body = String(decoding: data, as: UTF8.self)
        if let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = value["error"] as? String {
            throw McpOAuthError.authorization(code: code,
                message: (value["error_description"] as? String) ?? code,
                uri: value["error_uri"] as? String)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw McpOAuthError.authorization(code: "server_error", message: "HTTP \(response.statusCode): \(body)", uri: nil)
        }
        let tokens = try JSONDecoder().decode(McpOAuthTokens.self, from: data)
        guard !tokens.accessToken.isEmpty, !tokens.tokenType.isEmpty,
              tokens.expiresIn.map({ $0.isFinite }) ?? true else {
            throw McpOAuthError.invalidMetadata("token response")
        }
        return tokens
    }
}

/// Serializes refreshes so rotating refresh tokens are spent once.
public actor McpOAuthAuthAdapter: McpAuthProvider {
    private let provider: any McpOAuthClientProvider
    private let http: any McpOAuthHTTPClient
    private var refreshTask: Task<Void, Error>?

    public init(provider: any McpOAuthClientProvider, http: any McpOAuthHTTPClient = McpURLSessionOAuthHTTPClient()) {
        self.provider = provider
        self.http = http
    }

    public func token() async throws -> String? { try await provider.tokens()?.accessToken }

    public func onUnauthorized(challenge: String?, serverURL: URL, rejectedToken: String?) async throws {
        let parsed = McpOAuthDiscovery.parseWWWAuthenticate(challenge)
        let insufficientScope = parsed.error == "insufficient_scope"
        if !insufficientScope, refreshTask == nil, let rejectedToken,
           let current = try await provider.tokens()?.accessToken, current != rejectedToken { return }
        if refreshTask == nil {
            let provider = self.provider
            let http = self.http
            refreshTask = Task {
                let result = try await McpOAuthFlow.authorize(provider: provider,
                    options: McpOAuthFlowOptions(serverURL: serverURL,
                        scope: parsed.scope, resourceMetadataURL: parsed.resourceMetadataURL,
                        skipRefresh: insufficientScope), http: http)
                if result == .redirect { throw McpOAuthError.authorizationRequired }
            }
        }
        defer { refreshTask = nil }
        try await refreshTask?.value
    }
}
