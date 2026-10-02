import Foundation
import PiSwiftAI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum McpOAuthError: Error, LocalizedError, Sendable {
    case invalidMetadata(String)
    case httpStatus(Int, String)
    case issuerMismatch(expected: String, received: String?)
    case insecureEndpoint(String)
    case registration(status: Int, body: String)
    case authorization(code: String, message: String, uri: String?)
    case authorizationRequired
    case missingCodeVerifier
    case invalidRedirect
    case invalidState

    public var errorDescription: String? {
        switch self {
        case .invalidMetadata(let field): "Invalid OAuth metadata: \(field)"
        case .httpStatus(let status, let body): "OAuth HTTP \(status): \(body)"
        case .issuerMismatch(let expected, let received): "OAuth issuer mismatch: expected \(expected), received \(received ?? "none")"
        case .insecureEndpoint(let url): "Refusing to send OAuth credentials to non-HTTPS endpoint \(url)"
        case .registration(let status, let body): "OAuth dynamic client registration failed with status \(status): \(body)"
        case .authorization(_, let message, _): message
        case .authorizationRequired: "MCP OAuth authorization requires user interaction"
        case .missingCodeVerifier: "No OAuth PKCE code verifier is stored"
        case .invalidRedirect: "Invalid OAuth redirect URL"
        case .invalidState: "Invalid OAuth state"
        }
    }
}

public struct McpOAuthChallenge: Sendable, Equatable {
    public var resourceMetadataURL: URL?
    public var scope: String?
    public var error: String?
    public var errorDescription: String?

    public init(resourceMetadataURL: URL? = nil, scope: String? = nil, error: String? = nil, errorDescription: String? = nil) {
        self.resourceMetadataURL = resourceMetadataURL
        self.scope = scope
        self.error = error
        self.errorDescription = errorDescription
    }
}

public struct McpOAuthProtectedResourceMetadata: Codable, Sendable, Equatable {
    public var resource: String
    public var authorizationServers: [String]?
    public var scopesSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
    }

    public init(resource: String, authorizationServers: [String]? = nil, scopesSupported: [String]? = nil) {
        self.resource = resource
        self.authorizationServers = authorizationServers
        self.scopesSupported = scopesSupported
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        resource = try values.decodeRequiredOAuthURL(forKey: .resource)
        authorizationServers = try values.decodeIfPresent([String].self, forKey: .authorizationServers)
        for url in authorizationServers ?? [] {
            try McpOAuthDiscovery.validateURL(url, field: "authorization_servers")
        }
        scopesSupported = try values.decodeIfPresent([String].self, forKey: .scopesSupported)
    }
}

public struct McpOAuthAuthorizationServerMetadata: Codable, Sendable, Equatable {
    public var issuer: String
    public var authorizationEndpoint: String
    public var tokenEndpoint: String
    public var registrationEndpoint: String?
    public var scopesSupported: [String]?
    public var responseTypesSupported: [String]
    public var grantTypesSupported: [String]?
    public var tokenEndpointAuthMethodsSupported: [String]?
    public var codeChallengeMethodsSupported: [String]?
    public var clientIDMetadataDocumentSupported: Bool?
    public var authorizationResponseIssParameterSupported: Bool?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case scopesSupported = "scopes_supported"
        case responseTypesSupported = "response_types_supported"
        case grantTypesSupported = "grant_types_supported"
        case tokenEndpointAuthMethodsSupported = "token_endpoint_auth_methods_supported"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case clientIDMetadataDocumentSupported = "client_id_metadata_document_supported"
        case authorizationResponseIssParameterSupported = "authorization_response_iss_parameter_supported"
    }

    public init(issuer: String, authorizationEndpoint: String, tokenEndpoint: String,
                registrationEndpoint: String? = nil, scopesSupported: [String]? = nil,
                responseTypesSupported: [String] = ["code"], grantTypesSupported: [String]? = nil,
                tokenEndpointAuthMethodsSupported: [String]? = nil, codeChallengeMethodsSupported: [String]? = nil,
                clientIDMetadataDocumentSupported: Bool? = nil, authorizationResponseIssParameterSupported: Bool? = nil) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.scopesSupported = scopesSupported
        self.responseTypesSupported = responseTypesSupported
        self.grantTypesSupported = grantTypesSupported
        self.tokenEndpointAuthMethodsSupported = tokenEndpointAuthMethodsSupported
        self.codeChallengeMethodsSupported = codeChallengeMethodsSupported
        self.clientIDMetadataDocumentSupported = clientIDMetadataDocumentSupported
        self.authorizationResponseIssParameterSupported = authorizationResponseIssParameterSupported
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        issuer = try values.decodeRequiredOAuthURL(forKey: .issuer)
        authorizationEndpoint = try values.decodeRequiredOAuthURL(forKey: .authorizationEndpoint)
        tokenEndpoint = try values.decodeRequiredOAuthURL(forKey: .tokenEndpoint)
        registrationEndpoint = try values.decodeOptionalOAuthURL(forKey: .registrationEndpoint)
        scopesSupported = try values.decodeIfPresent([String].self, forKey: .scopesSupported)
        responseTypesSupported = try values.decode([String].self, forKey: .responseTypesSupported)
        grantTypesSupported = try values.decodeIfPresent([String].self, forKey: .grantTypesSupported)
        tokenEndpointAuthMethodsSupported = try values.decodeIfPresent([String].self, forKey: .tokenEndpointAuthMethodsSupported)
        codeChallengeMethodsSupported = try values.decodeIfPresent([String].self, forKey: .codeChallengeMethodsSupported)
        clientIDMetadataDocumentSupported = try? values.decode(Bool.self, forKey: .clientIDMetadataDocumentSupported)
        authorizationResponseIssParameterSupported = try? values.decode(Bool.self, forKey: .authorizationResponseIssParameterSupported)
    }
}

public struct McpOAuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var tokenType: String
    public var expiresIn: Double?
    public var scope: String?
    public var refreshToken: String?
    public var idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
        case refreshToken = "refresh_token"
        case idToken = "id_token"
    }

    public init(accessToken: String, tokenType: String, expiresIn: Double? = nil, scope: String? = nil,
                refreshToken: String? = nil, idToken: String? = nil) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
        self.scope = scope
        self.refreshToken = refreshToken
        self.idToken = idToken
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try values.decodeRequiredOAuthString(forKey: .accessToken)
        tokenType = try values.decodeRequiredOAuthString(forKey: .tokenType)
        expiresIn = try values.decodeOptionalOAuthNumber(forKey: .expiresIn)
        scope = try values.decodeOptionalOAuthString(forKey: .scope)
        refreshToken = try values.decodeOptionalOAuthString(forKey: .refreshToken)
        idToken = try values.decodeOptionalOAuthString(forKey: .idToken)
    }
}

public struct McpOAuthClientMetadata: Codable, Sendable, Equatable {
    public var redirectURIs: [String]
    public var tokenEndpointAuthMethod: String?
    public var grantTypes: [String]?
    public var responseTypes: [String]?
    public var clientName: String?
    public var clientURI: String?
    public var logoURI: String?
    public var scope: String?
    public var contacts: [String]?
    public var tosURI: String?
    public var policyURI: String?
    public var jwksURI: String?
    public var jwks: AnyCodable?
    public var softwareID: String?
    public var softwareVersion: String?
    public var softwareStatement: String?

    enum CodingKeys: String, CodingKey {
        case redirectURIs = "redirect_uris"
        case tokenEndpointAuthMethod = "token_endpoint_auth_method"
        case grantTypes = "grant_types"
        case responseTypes = "response_types"
        case clientName = "client_name"
        case clientURI = "client_uri"
        case logoURI = "logo_uri"
        case scope, contacts
        case tosURI = "tos_uri"
        case policyURI = "policy_uri"
        case jwksURI = "jwks_uri"
        case jwks
        case softwareID = "software_id"
        case softwareVersion = "software_version"
        case softwareStatement = "software_statement"
    }

    public init(redirectURIs: [String] = [], tokenEndpointAuthMethod: String? = nil,
                grantTypes: [String]? = nil, responseTypes: [String]? = nil, clientName: String? = nil,
                clientURI: String? = nil, logoURI: String? = nil, scope: String? = nil,
                contacts: [String]? = nil, tosURI: String? = nil, policyURI: String? = nil,
                jwksURI: String? = nil, jwks: AnyCodable? = nil,
                softwareID: String? = nil, softwareVersion: String? = nil,
                softwareStatement: String? = nil) {
        self.redirectURIs = redirectURIs
        self.tokenEndpointAuthMethod = tokenEndpointAuthMethod
        self.grantTypes = grantTypes
        self.responseTypes = responseTypes
        self.clientName = clientName
        self.clientURI = clientURI
        self.logoURI = logoURI
        self.scope = scope
        self.contacts = contacts
        self.tosURI = tosURI
        self.policyURI = policyURI
        self.jwksURI = jwksURI
        self.jwks = jwks
        self.softwareID = softwareID
        self.softwareVersion = softwareVersion
        self.softwareStatement = softwareStatement
    }
}

public struct McpOAuthClientInformation: Codable, Sendable, Equatable {
    public var clientID: String
    public var clientSecret: String?
    public var clientIDIssuedAt: Double?
    public var clientSecretExpiresAt: Double?
    public var metadata: McpOAuthClientMetadata?

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientSecret = "client_secret"
        case clientIDIssuedAt = "client_id_issued_at"
        case clientSecretExpiresAt = "client_secret_expires_at"
    }

    public init(clientID: String, clientSecret: String? = nil, clientIDIssuedAt: Double? = nil,
                clientSecretExpiresAt: Double? = nil, metadata: McpOAuthClientMetadata? = nil) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.clientIDIssuedAt = clientIDIssuedAt
        self.clientSecretExpiresAt = clientSecretExpiresAt
        self.metadata = metadata
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        clientID = try values.decodeRequiredOAuthString(forKey: .clientID)
        clientSecret = try values.decodeOptionalOAuthString(forKey: .clientSecret)
        clientIDIssuedAt = try? values.decode(Double.self, forKey: .clientIDIssuedAt)
        clientSecretExpiresAt = try? values.decode(Double.self, forKey: .clientSecretExpiresAt)
        metadata = nil
    }
}

public struct McpOAuthDiscoveryState: Codable, Sendable, Equatable {
    public var authorizationServerURL: String
    public var authorizationServerMetadata: McpOAuthAuthorizationServerMetadata?
    public var resourceMetadata: McpOAuthProtectedResourceMetadata?
    public var resourceMetadataURL: String?

    public init(authorizationServerURL: String, authorizationServerMetadata: McpOAuthAuthorizationServerMetadata? = nil,
                resourceMetadata: McpOAuthProtectedResourceMetadata? = nil, resourceMetadataURL: String? = nil) {
        self.authorizationServerURL = authorizationServerURL
        self.authorizationServerMetadata = authorizationServerMetadata
        self.resourceMetadata = resourceMetadata
        self.resourceMetadataURL = resourceMetadataURL
    }
}

public struct McpOAuthServerInfo: Sendable, Equatable {
    public var authorizationServerURL: URL
    public var authorizationServerMetadata: McpOAuthAuthorizationServerMetadata?
    public var resourceMetadata: McpOAuthProtectedResourceMetadata?
}

public protocol McpOAuthHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct McpURLSessionOAuthHTTPClient: McpOAuthHTTPClient {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw McpOAuthError.invalidMetadata("HTTP response")
        }
        return (data, response)
    }
}

private extension KeyedDecodingContainer {
    func decodeRequiredOAuthString(forKey key: Key) throws -> String {
        let value = try decode(String.self, forKey: key)
        guard !value.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Invalid \(key.stringValue)")
        }
        return value
    }

    func decodeOptionalOAuthString(forKey key: Key) throws -> String? {
        guard let value = try decodeIfPresent(String.self, forKey: key), !value.isEmpty else { return nil }
        return value
    }

    func decodeRequiredOAuthURL(forKey key: Key) throws -> String {
        let value = try decodeRequiredOAuthString(forKey: key)
        try McpOAuthDiscovery.validateURL(value, field: key.stringValue)
        return value
    }

    func decodeOptionalOAuthURL(forKey key: Key) throws -> String? {
        guard let value = try decodeOptionalOAuthString(forKey: key) else { return nil }
        try McpOAuthDiscovery.validateURL(value, field: key.stringValue)
        return value
    }

    func decodeOptionalOAuthNumber(forKey key: Key) throws -> Double? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        let number: Double
        if let value = try? decode(Double.self, forKey: key) {
            number = value
        } else if let text = try? decode(String.self, forKey: key) {
            if text.isEmpty { return nil }
            guard let value = Double(text) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Invalid \(key.stringValue)")
            }
            number = value
        } else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Invalid \(key.stringValue)")
        }
        guard number.isFinite else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Invalid \(key.stringValue)")
        }
        return number
    }
}
