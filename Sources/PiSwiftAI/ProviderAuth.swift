import Foundation

public enum ProviderAuthPrompt: Sendable {
    case text(message: String, placeholder: String? = nil)
    case secret(message: String, placeholder: String? = nil)
    case select(OAuthSelectPrompt)
}

public struct AuthInfoLink: Sendable, Equatable {
    public var url: String
    public var label: String?

    public init(url: String, label: String? = nil) {
        self.url = url
        self.label = label
    }
}

public enum ProviderAuthEvent: Sendable {
    case info(message: String, links: [AuthInfoLink])
    case progress(String)
}

public struct ProviderAuthInteraction: Sendable {
    public var prompt: @MainActor @Sendable (ProviderAuthPrompt) async throws -> String
    public var notify: @MainActor @Sendable (ProviderAuthEvent) -> Void
    public var signal: CancellationToken?

    public init(
        prompt: @escaping @MainActor @Sendable (ProviderAuthPrompt) async throws -> String,
        notify: @escaping @MainActor @Sendable (ProviderAuthEvent) -> Void,
        signal: CancellationToken? = nil
    ) {
        self.prompt = prompt
        self.notify = notify
        self.signal = signal
    }
}

public struct ApiKeyLoginResult: Sendable, Equatable {
    public var key: String?
    public var env: [String: String]?

    public init(key: String? = nil, env: [String: String]? = nil) {
        self.key = key
        self.env = env
    }
}

public struct ApiKeyAuthMethod: Sendable {
    public var name: String
    public var envVars: [String]
    public var login: (@Sendable (ProviderAuthInteraction) async throws -> ApiKeyLoginResult)?

    public init(
        name: String,
        envVars: [String],
        login: (@Sendable (ProviderAuthInteraction) async throws -> ApiKeyLoginResult)? = nil
    ) {
        self.name = name
        self.envVars = envVars
        self.login = login
    }
}

public struct ProviderAuthDescriptor: Sendable {
    public var id: String
    public var name: String
    public var apiKey: ApiKeyAuthMethod?
    public var oauth: OAuthProviderInfo?

    public init(id: String, name: String, apiKey: ApiKeyAuthMethod? = nil, oauth: OAuthProviderInfo? = nil) {
        self.id = id
        self.name = name
        self.apiKey = apiKey
        self.oauth = oauth
    }
}

public enum ProviderAuthError: Error, LocalizedError, Sendable {
    case unknownMethod(provider: String, id: String)

    public var errorDescription: String? {
        switch self {
        case .unknownMethod(let provider, let id): return "Unknown \(provider) auth method: \(id)"
        }
    }
}

/// Make a login function that asks for a key in one secret prompt.
public func envApiKeyLogin(name: String) -> @Sendable (ProviderAuthInteraction) async throws -> ApiKeyLoginResult {
    { interaction in
        ApiKeyLoginResult(key: try await authPrompt(.secret(message: "Enter \(name)"), interaction: interaction))
    }
}

private func authPrompt(_ prompt: ProviderAuthPrompt, interaction: ProviderAuthInteraction) async throws -> String {
    try throwIfOAuthCancelled(interaction.signal)
    let value = try await interaction.prompt(prompt)
    try throwIfOAuthCancelled(interaction.signal)
    return value
}

private func bedrockLogin(_ interaction: ProviderAuthInteraction) async throws -> ApiKeyLoginResult {
    let method = try await authPrompt(.select(OAuthSelectPrompt(
        message: "Select Amazon Bedrock authentication method:",
        options: [
            OAuthSelectOption(id: "bearer-token", label: "Bearer token"),
            OAuthSelectOption(id: "aws-profile", label: "AWS profile"),
            OAuthSelectOption(id: "credential-chain", label: "Existing AWS credential chain"),
        ]
    )), interaction: interaction)
    if method == "bearer-token" {
        return ApiKeyLoginResult(key: try await authPrompt(.secret(message: "Enter Amazon Bedrock bearer token"), interaction: interaction))
    }
    await interaction.notify(.info(
        message: "Amazon Bedrock supports AWS profiles, IAM credentials, and role-based credentials.",
        links: [AuthInfoLink(url: "https://docs.aws.amazon.com/sdkref/latest/guide/standardized-credentials.html", label: "AWS credential provider chain")]
    ))
    if method == "aws-profile" {
        return ApiKeyLoginResult(env: ["AWS_PROFILE": try await authPrompt(.text(message: "Enter AWS profile name"), interaction: interaction)])
    }
    guard method == "credential-chain" else {
        throw ProviderAuthError.unknownMethod(provider: "Amazon Bedrock", id: method)
    }
    _ = try await authPrompt(.text(message: "Configure AWS credentials, then press Enter to continue"), interaction: interaction)
    return ApiKeyLoginResult()
}

private func vertexLogin(_ interaction: ProviderAuthInteraction) async throws -> ApiKeyLoginResult {
    let method = try await authPrompt(.select(OAuthSelectPrompt(
        message: "Select Google Vertex AI authentication method:",
        options: [
            OAuthSelectOption(id: "api-key", label: "Google Cloud API key"),
            OAuthSelectOption(id: "adc", label: "Application Default Credentials"),
            OAuthSelectOption(id: "service-account", label: "Service account credentials file"),
        ]
    )), interaction: interaction)
    if method == "api-key" {
        return ApiKeyLoginResult(key: try await authPrompt(.secret(message: "Enter Google Cloud API key"), interaction: interaction))
    }
    guard method == "adc" || method == "service-account" else {
        throw ProviderAuthError.unknownMethod(provider: "Google Vertex AI", id: method)
    }
    await interaction.notify(.info(
        message: method == "adc"
            ? "Run `gcloud auth application-default login`, then provide the project and location."
            : "Provide a service account credentials file, project, and location.",
        links: [AuthInfoLink(url: "https://cloud.google.com/docs/authentication/provide-credentials-adc", label: "Application Default Credentials")]
    ))
    let project = try await authPrompt(.text(message: "Enter Google Cloud project ID"), interaction: interaction)
    let location = try await authPrompt(.text(message: "Enter Google Cloud location"), interaction: interaction)
    var env = ["GOOGLE_CLOUD_PROJECT": project, "GOOGLE_CLOUD_LOCATION": location]
    if method == "service-account" {
        let path = try await authPrompt(.text(message: "Enter service account credentials file path"), interaction: interaction)
        if !path.isEmpty { env["GOOGLE_APPLICATION_CREDENTIALS"] = path }
    }
    return ApiKeyLoginResult(env: env)
}

private func cloudflareLogin(_ interaction: ProviderAuthInteraction, gateway: Bool) async throws -> ApiKeyLoginResult {
    let key = try await authPrompt(.secret(message: "Enter Cloudflare API key"), interaction: interaction)
    let accountId = try await authPrompt(.text(message: "Enter Cloudflare account ID"), interaction: interaction)
    var env = ["CLOUDFLARE_ACCOUNT_ID": accountId]
    if gateway {
        env["CLOUDFLARE_GATEWAY_ID"] = try await authPrompt(.text(message: "Enter Cloudflare AI Gateway ID"), interaction: interaction)
    }
    return ApiKeyLoginResult(key: key, env: env)
}

/// Return the ambient credential source. Do not return secret values.
public func ambientAuthSource(provider: String, env: [String: String]? = nil) -> String? {
    let env = providerEnvironment(env).filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func has(_ key: String) -> Bool { !(env[key] ?? "").isEmpty }
    switch provider {
    case "amazon-bedrock":
        if has("AWS_BEARER_TOKEN_BEDROCK") { return "AWS_BEARER_TOKEN_BEDROCK" }
        if has("AWS_PROFILE") { return "AWS_PROFILE" }
        if has("AWS_ACCESS_KEY_ID") && has("AWS_SECRET_ACCESS_KEY") { return "AWS access keys" }
        if has("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI") || has("AWS_CONTAINER_CREDENTIALS_FULL_URI") { return "ECS task role" }
        if has("AWS_WEB_IDENTITY_TOKEN_FILE") { return "web identity token" }
    case "google-vertex":
        if has("GOOGLE_CLOUD_API_KEY") { return "GOOGLE_CLOUD_API_KEY" }
        let project = env["GOOGLE_CLOUD_PROJECT"] ?? env["GCLOUD_PROJECT"]
        guard let project, !project.isEmpty, has("GOOGLE_CLOUD_LOCATION") else { return nil }
        let path: String
        if let credentials = env["GOOGLE_APPLICATION_CREDENTIALS"] {
            path = NSString(string: credentials).expandingTildeInPath
        } else {
            #if os(macOS) || os(Linux)
            path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/gcloud/application_default_credentials.json").path
            #else
            return nil
            #endif
        }
        if FileManager.default.fileExists(atPath: path) { return "gcloud application default credentials" }
    case "anthropic":
        if anthropicFederationEnv(env: env) != nil { return "workload identity federation" }
    default: break
    }
    return nil
}


/// Return all built-in provider auth descriptors in provider id order.
public func getBuiltinProviderAuth() -> [ProviderAuthDescriptor] {
    let oauth = Dictionary(uniqueKeysWithValues: getOAuthProviders().map { ($0.id.rawValue, $0) })
    let rows: [(id: String, name: String, method: String?, envVars: [String])] = [
        ("ant-ling", "Ant Ling", "Ant Ling API key", ["ANT_LING_API_KEY"]),
        ("anthropic", "Anthropic", "Anthropic API key", ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_OAUTH_TOKEN", "ANTHROPIC_API_KEY"]),
        ("azure", "Azure", "Azure OpenAI API key", ["AZURE_OPENAI_API_KEY"]),
        ("baseten", "Baseten", "Baseten API key", ["BASETEN_API_KEY"]),
        ("cerebras", "Cerebras", "Cerebras API key", ["CEREBRAS_API_KEY"]),
        ("deepseek", "DeepSeek", "DeepSeek API key", ["DEEPSEEK_API_KEY"]),
        ("fireworks", "Fireworks", "Fireworks API key", ["FIREWORKS_API_KEY"]),
        ("github-copilot", "GitHub Copilot", "GitHub Copilot token", ["COPILOT_GITHUB_TOKEN"]),
        ("google", "Google", "Gemini API key", ["GEMINI_API_KEY"]),
        ("groq", "Groq", "Groq API key", ["GROQ_API_KEY"]),
        ("huggingface", "Hugging Face", "Hugging Face token", ["HF_TOKEN"]),
        ("kimi-coding", "Kimi For Coding", "Kimi API key", ["KIMI_API_KEY"]),
        ("meta", "Meta", "Meta Model API key", ["META_API_KEY"]),
        ("minimax", "MiniMax", "MiniMax API key", ["MINIMAX_API_KEY"]),
        ("minimax-cn", "MiniMax CN", "MiniMax CN API key", ["MINIMAX_CN_API_KEY"]),
        ("mistral", "Mistral", "Mistral API key", ["MISTRAL_API_KEY"]),
        ("moonshotai", "Moonshot AI", "Moonshot AI API key", ["MOONSHOT_API_KEY"]),
        ("moonshotai-cn", "Moonshot AI CN", "Moonshot AI API key", ["MOONSHOT_API_KEY"]),
        ("nvidia", "NVIDIA", "NVIDIA API key", ["NVIDIA_API_KEY"]),
        ("openai", "OpenAI", "OpenAI API key", ["OPENAI_API_KEY"]),
        ("openai-codex", "OpenAI Codex (legacy)", nil, []),
        ("opencode", "OpenCode Zen", "OpenCode API key", ["OPENCODE_API_KEY"]),
        ("opencode-go", "OpenCode Go", "OpenCode API key", ["OPENCODE_API_KEY"]),
        ("openrouter", "OpenRouter", "OpenRouter API key", ["OPENROUTER_API_KEY"]),
        ("qwen-token-plan", "Qwen Token Plan", "Qwen Token Plan API key", ["QWEN_TOKEN_PLAN_API_KEY"]),
        ("qwen-token-plan-cn", "Qwen Token Plan CN", "Qwen Token Plan CN API key", ["QWEN_TOKEN_PLAN_CN_API_KEY"]),
        ("qwen-token-plan-individual", "Qwen Token Plan Individual", "Qwen Token Plan Individual API key", ["QWEN_TOKEN_PLAN_API_KEY"]),
        ("together", "Together", "Together API key", ["TOGETHER_API_KEY"]),
        ("typesafe", "TypeSafe", "TypeSafe API key", ["TYPESAFE_API_KEY"]),
        ("vercel-ai-gateway", "Vercel AI Gateway", "Vercel AI Gateway API key", ["AI_GATEWAY_API_KEY"]),
        ("xai", "xAI", "xAI API key", ["XAI_API_KEY"]),
        ("xiaomi", "Xiaomi", "Xiaomi API key", ["XIAOMI_API_KEY"]),
        ("xiaomi-token-plan-ams", "Xiaomi Token Plan AMS", "Xiaomi Token Plan AMS API key", ["XIAOMI_TOKEN_PLAN_AMS_API_KEY"]),
        ("xiaomi-token-plan-cn", "Xiaomi Token Plan CN", "Xiaomi Token Plan CN API key", ["XIAOMI_TOKEN_PLAN_CN_API_KEY"]),
        ("xiaomi-token-plan-sgp", "Xiaomi Token Plan SGP", "Xiaomi Token Plan SGP API key", ["XIAOMI_TOKEN_PLAN_SGP_API_KEY"]),
        ("zai", "Z.AI", "Z.AI API key", ["ZAI_API_KEY"]),
        ("zai-coding-cn", "Z.AI Coding CN", "Z.AI Coding CN API key", ["ZAI_CODING_CN_API_KEY"]),
    ]
    var descriptors = rows.map { row in
        ProviderAuthDescriptor(
            id: row.id, name: row.name,
            apiKey: row.method.map { ApiKeyAuthMethod(name: $0, envVars: row.envVars, login: envApiKeyLogin(name: $0)) },
            oauth: oauth[row.id]
        )
    }
    descriptors.append(ProviderAuthDescriptor(
        id: "amazon-bedrock", name: "Amazon Bedrock",
        apiKey: ApiKeyAuthMethod(name: "AWS credentials or bearer token", envVars: [
            "AWS_BEARER_TOKEN_BEDROCK", "AWS_PROFILE", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY",
            "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", "AWS_CONTAINER_CREDENTIALS_FULL_URI", "AWS_WEB_IDENTITY_TOKEN_FILE",
        ], login: bedrockLogin)
    ))
    descriptors.append(ProviderAuthDescriptor(
        id: "google-vertex", name: "Google Vertex AI",
        apiKey: ApiKeyAuthMethod(name: "Google Cloud credentials", envVars: [
            "GOOGLE_CLOUD_API_KEY", "GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_CLOUD_PROJECT", "GCLOUD_PROJECT", "GOOGLE_CLOUD_LOCATION",
        ], login: vertexLogin)
    ))
    for gateway in [false, true] {
        descriptors.append(ProviderAuthDescriptor(
            id: gateway ? "cloudflare-ai-gateway" : "cloudflare-workers-ai",
            name: gateway ? "Cloudflare AI Gateway" : "Cloudflare Workers AI",
            apiKey: ApiKeyAuthMethod(
                name: "Cloudflare API key",
                envVars: ["CLOUDFLARE_API_KEY", "CLOUDFLARE_ACCOUNT_ID"] + (gateway ? ["CLOUDFLARE_GATEWAY_ID"] : []),
                login: { try await cloudflareLogin($0, gateway: gateway) }
            )
        ))
    }
    return descriptors.sorted { $0.id < $1.id }
}

public func getBuiltinProviderAuth(_ id: String) -> ProviderAuthDescriptor? {
    getBuiltinProviderAuth().first { $0.id == id }
}

public func getBuiltinProviderDisplayName(_ id: String) -> String? {
    getBuiltinProviderAuth(id)?.name
}
