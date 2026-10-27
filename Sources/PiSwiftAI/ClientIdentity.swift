import Foundation

public let PI_AI_VERSION = "1.4.0"

/// The User-Agent mode. The JSON representation matches pi-ai.
public enum UserAgentMode: Sendable, Equatable, Codable {
    case detailed
    case short
    case custom(String)

    private enum CodingKeys: String, CodingKey { case custom }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            switch value {
            case "detailed": self = .detailed
            case "short": self = .short
            default:
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown User-Agent mode: \(value)")
            }
        } else {
            let object = try decoder.container(keyedBy: CodingKeys.self)
            self = .custom(try object.decode(String.self, forKey: .custom))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .detailed, .short:
            var container = encoder.singleValueContainer()
            try container.encode(self == .detailed ? "detailed" : "short")
        case .custom(let value):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(value, forKey: .custom)
        }
    }
}

public struct ClientAttribution: Sendable, Equatable, Codable {
    public var name: String
    public var url: String
    public var categories: [String]?

    public init(name: String, url: String, categories: [String]? = nil) {
        self.name = name
        self.url = url
        self.categories = categories
    }
}

/// A nil state inherits attribution. `.disabled` encodes as JSON null.
public enum ClientAttributionState: Sendable, Equatable, Codable {
    case disabled
    case value(ClientAttribution)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = container.decodeNil() ? .disabled : .value(try container.decode(ClientAttribution.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .disabled: try container.encodeNil()
        case .value(let attribution): try container.encode(attribution)
        }
    }
}

public let PI_ATTRIBUTION = ClientAttribution(name: "pi", url: "https://pi.dev", categories: ["cli-agent"])

/// Request identity. Omitted fields inherit defaults from earlier identities.
public struct ClientIdentity: Sendable, Equatable, Codable {
    public var userAgent: UserAgentMode?
    public var attribution: ClientAttributionState?
    public var version: String?

    public init(userAgent: UserAgentMode? = nil, attribution: ClientAttributionState? = nil, version: String? = nil) {
        self.userAgent = userAgent
        self.attribution = attribution
        self.version = version
    }

    private enum CodingKeys: String, CodingKey { case userAgent, attribution, version }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userAgent = try container.decodeIfPresent(UserAgentMode.self, forKey: .userAgent)
        attribution = container.contains(.attribution) ? try container.decode(ClientAttributionState.self, forKey: .attribution) : nil
        version = try container.decodeIfPresent(String.self, forKey: .version)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(userAgent, forKey: .userAgent)
        try container.encodeIfPresent(attribution, forKey: .attribution)
        try container.encodeIfPresent(version, forKey: .version)
    }
}

/// Later non-nil fields take precedence. An explicit disabled state also takes precedence.
public func mergeClientIdentity(_ sources: ClientIdentity?...) -> ClientIdentity? {
    var result: ClientIdentity?
    for source in sources {
        guard let source else { continue }
        var merged = result ?? ClientIdentity()
        if let value = source.userAgent { merged.userAgent = value }
        if let value = source.attribution { merged.attribution = value }
        if let value = source.version { merged.version = value }
        result = merged
    }
    return result
}

public func formatUserAgent(_ mode: UserAgentMode = .detailed) -> String {
    formatUserAgent(identity: ClientIdentity(userAgent: mode))
}

public func formatUserAgent(identity: ClientIdentity?) -> String {
    switch identity?.userAgent ?? .detailed {
    case .short: return "pi"
    case .custom(let value): return value
    case .detailed:
        #if os(iOS)
        let platform = "ios"
        #elseif os(macOS)
        let platform = "darwin"
        #elseif os(Linux)
        let platform = "linux"
        #elseif os(tvOS)
        let platform = "tvos"
        #elseif os(watchOS)
        let platform = "watchos"
        #elseif os(visionOS)
        let platform = "visionos"
        #else
        let platform = "unknown"
        #endif
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x64"
        #elseif arch(i386)
        let architecture = "ia32"
        #elseif arch(arm)
        let architecture = "arm"
        #else
        let architecture = "unknown"
        #endif
        return "pi/\(identity?.version ?? PI_AI_VERSION) (\(platform); swift; \(architecture))"
    }
}

/// Swift sends the reduced product in the AWS User-Agent field.
public func formatBedrockUserAgent(_ mode: UserAgentMode = .detailed) -> String {
    formatBedrockUserAgent(identity: ClientIdentity(userAgent: mode))
}

public func formatBedrockUserAgent(identity: ClientIdentity?) -> String {
    switch identity?.userAgent ?? .detailed {
    case .detailed: return "pi/\(identity?.version ?? PI_AI_VERSION)"
    case .short: return "pi"
    case .custom(let value): return value
    }
}

private func matchesIdentityHost(_ baseUrl: String, _ host: String) -> Bool {
    guard let url = URL(string: baseUrl), url.scheme != nil else { return false }
    return url.host?.lowercased() == host
}

func isOpenCodeTarget(provider: String, baseUrl: String) -> Bool {
    provider == "opencode" || provider == "opencode-go" || matchesIdentityHost(baseUrl, "opencode.ai")
}

public func attributionHeaders(provider: String, baseUrl: String, identity: ClientIdentity? = nil) -> ProviderHeaders {
    guard case .value(let attribution) = identity?.attribution else { return [:] }
    if provider == "openrouter" || baseUrl.contains("openrouter.ai") {
        var headers: ProviderHeaders = ["HTTP-Referer": attribution.url, "X-OpenRouter-Title": attribution.name]
        if let categories = attribution.categories, !categories.isEmpty {
            headers["X-OpenRouter-Categories"] = categories.joined(separator: ",")
        }
        return headers
    }
    if provider == "nvidia" || matchesIdentityHost(baseUrl, "integrate.api.nvidia.com") {
        return ["X-BILLING-INVOKE-ORIGIN": attribution.name.prefix(1).uppercased() + attribution.name.dropFirst()]
    }
    if isOpenCodeTarget(provider: provider, baseUrl: baseUrl) { return ["x-opencode-client": attribution.name] }
    return [:]
}

public func identityHeaders(provider: String, baseUrl: String, identity: ClientIdentity? = nil) -> ProviderHeaders {
    mergeProviderHeaders(["User-Agent": formatUserAgent(identity: identity)],
                         attributionHeaders(provider: provider, baseUrl: baseUrl, identity: identity)) ?? [:]
}

/// Request options that can inherit a default client identity.
public protocol ClientIdentityOptions: Sendable {
    var identity: ClientIdentity? { get set }
}

extension StreamOptions: ClientIdentityOptions {}
extension SimpleStreamOptions: ClientIdentityOptions {}
extension DeferredFetchOptions: ClientIdentityOptions {}
extension DeferredCancelOptions: ClientIdentityOptions {}
extension ImagesOptions: ClientIdentityOptions {}
extension ClassifierOptions: ClientIdentityOptions {}
extension OpenAIOptions: ClientIdentityOptions {}
extension OpenAICompletionsOptions: ClientIdentityOptions {}
extension OpenAIResponsesOptions: ClientIdentityOptions {}
extension AzureOpenAIResponsesOptions: ClientIdentityOptions {}
extension OpenAICodexResponsesOptions: ClientIdentityOptions {}
extension GoogleOptions: ClientIdentityOptions {}
extension GoogleGeminiCliOptions: ClientIdentityOptions {}
extension GoogleVertexOptions: ClientIdentityOptions {}
extension AnthropicOptions: ClientIdentityOptions {}
extension BedrockOptions: ClientIdentityOptions {}
extension MistralOptions: ClientIdentityOptions {}

/// Apply a default below the request's identity. Nested calls preserve field precedence.
public func withClientIdentity<Options: ClientIdentityOptions>(_ options: Options, _ identity: ClientIdentity?) -> Options {
    var request = options
    request.identity = mergeClientIdentity(identity, options.identity)
    return request
}
