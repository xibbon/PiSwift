import Foundation
import Testing
@testable import PiSwiftAI

private struct A1AuthTrace: Sendable {
    var prompts: [ProviderAuthPrompt] = []
    var events: [ProviderAuthEvent] = []
    var replies: [String]
}

private func a1Interaction(_ replies: [String], signal: CancellationToken? = nil) -> (ProviderAuthInteraction, LockedState<A1AuthTrace>) {
    let trace = LockedState(A1AuthTrace(replies: replies))
    return (ProviderAuthInteraction(
        prompt: { prompt in
            trace.withLock {
                $0.prompts.append(prompt)
                return $0.replies.isEmpty ? "" : $0.replies.removeFirst()
            }
        },
        notify: { event in trace.withLock { $0.events.append(event) } },
        signal: signal
    ), trace)
}

@Suite("A1 provider auth")
struct A1ProviderAuthTests {
    @Test func descriptorsIncludeAllKnownLoginProvidersAndTypeSafe() {
        let descriptors = getBuiltinProviderAuth()
        #expect(descriptors.count == 41)
        #expect(descriptors.map(\.id) == descriptors.map(\.id).sorted())
        #expect(Set(descriptors.map(\.id)).count == 41)
        #expect(descriptors.allSatisfy { KnownProvider(rawValue: $0.id) != nil })
        #expect(descriptors.contains { $0.id == "typesafe" })
        #expect(!descriptors.contains { ["radius", "google-gemini-cli", "google-antigravity"].contains($0.id) })
        #expect(getBuiltinProviderAuth("openai-codex")?.apiKey == nil)
        #expect(descriptors.filter { $0.apiKey != nil }.allSatisfy { $0.apiKey?.login != nil })
        #expect(getBuiltinProviderDisplayName("openai") == "OpenAI")
        #expect(getBuiltinProviderDisplayName("github-copilot") == "GitHub Copilot")
        #expect(getBuiltinProviderDisplayName("zai") == "Z.AI")
        #expect(getBuiltinProviderDisplayName("unknown") == nil)
    }

    @Test func descriptorsUseMatchingOAuthMetadata() {
        let providers = getOAuthProviders()
        for descriptor in getBuiltinProviderAuth() {
            let matching = providers.first { $0.id.rawValue == descriptor.id }
            #expect(descriptor.oauth?.id == matching?.id)
            #expect(descriptor.oauth?.loginLabel == matching?.loginLabel)
            #expect(descriptor.oauth?.isSubscription == matching?.isSubscription)
        }
        #expect(providers.allSatisfy { $0.isSubscription == ($0.id != .openRouter) })
        #expect(providers.first { $0.id == .kimiCoding }?.loginLabel == "Sign in with Kimi Code")
        #expect(providers.first { $0.id == .meta }?.loginLabel == "Sign in with Meta")
        #expect(providers.first { $0.id == .openRouter }?.loginLabel == "Sign in with OpenRouter")
        #expect(providers.first { $0.id == .xai }?.loginLabel == "Sign in with SuperGrok or X Premium")
    }

    @Test(.timeLimit(.minutes(1))) func standardLoginPromptsOnceForASecret() async throws {
        let (interaction, trace) = a1Interaction(["secret"])
        let result = try await envApiKeyLogin(name: "OpenAI API key")(interaction)
        #expect(result == ApiKeyLoginResult(key: "secret"))
        let prompts = trace.withLock { $0.prompts }
        #expect(prompts.count == 1)
        guard case .secret(let message, let placeholder) = try #require(prompts.first) else {
            Issue.record("Expected a secret prompt"); return
        }
        #expect(message == "Enter OpenAI API key")
        #expect(placeholder == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["bearer-token", "aws-profile", "credential-chain"])
    func bedrockLoginFlows(method: String) async throws {
        let login = try #require(getBuiltinProviderAuth("amazon-bedrock")?.apiKey?.login)
        let (interaction, trace) = a1Interaction([method, method == "credential-chain" ? "" : "value"])
        let result = try await login(interaction)
        switch method {
        case "bearer-token": #expect(result == ApiKeyLoginResult(key: "value"))
        case "aws-profile": #expect(result == ApiKeyLoginResult(env: ["AWS_PROFILE": "value"]))
        default: #expect(result == ApiKeyLoginResult())
        }
        let snapshot = trace.withLock { $0 }
        guard case .select(let select) = try #require(snapshot.prompts.first) else {
            Issue.record("Expected a select prompt"); return
        }
        #expect(select.message == "Select Amazon Bedrock authentication method:")
        #expect(select.options == [
            OAuthSelectOption(id: "bearer-token", label: "Bearer token"),
            OAuthSelectOption(id: "aws-profile", label: "AWS profile"),
            OAuthSelectOption(id: "credential-chain", label: "Existing AWS credential chain"),
        ])
        #expect(snapshot.prompts.count == 2)
        if method == "bearer-token" {
            #expect(snapshot.events.isEmpty)
            guard case .secret(let message, _) = snapshot.prompts[1] else { Issue.record("Expected secret"); return }
            #expect(message == "Enter Amazon Bedrock bearer token")
        } else {
            #expect(snapshot.events.count == 1)
            guard case .info(let message, let links) = try #require(snapshot.events.first) else { Issue.record("Expected info"); return }
            #expect(message == "Amazon Bedrock supports AWS profiles, IAM credentials, and role-based credentials.")
            #expect(links == [AuthInfoLink(url: "https://docs.aws.amazon.com/sdkref/latest/guide/standardized-credentials.html", label: "AWS credential provider chain")])
            guard case .text(let prompt, _) = snapshot.prompts[1] else { Issue.record("Expected text"); return }
            #expect(prompt == (method == "aws-profile" ? "Enter AWS profile name" : "Configure AWS credentials, then press Enter to continue"))
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["api-key", "adc", "service-account"])
    func vertexLoginFlows(method: String) async throws {
        let login = try #require(getBuiltinProviderAuth("google-vertex")?.apiKey?.login)
        let replies = method == "api-key" ? [method, "secret"] : [method, "project", "us-central1", "/credentials.json"]
        let (interaction, trace) = a1Interaction(replies)
        let result = try await login(interaction)
        let snapshot = trace.withLock { $0 }
        guard case .select(let select) = try #require(snapshot.prompts.first) else { Issue.record("Expected select"); return }
        #expect(select.message == "Select Google Vertex AI authentication method:")
        #expect(select.options == [
            OAuthSelectOption(id: "api-key", label: "Google Cloud API key"),
            OAuthSelectOption(id: "adc", label: "Application Default Credentials"),
            OAuthSelectOption(id: "service-account", label: "Service account credentials file"),
        ])
        if method == "api-key" {
            #expect(result == ApiKeyLoginResult(key: "secret"))
            #expect(snapshot.events.isEmpty)
            guard case .secret(let message, _) = snapshot.prompts[1] else { Issue.record("Expected secret"); return }
            #expect(message == "Enter Google Cloud API key")
        } else {
            var env = ["GOOGLE_CLOUD_PROJECT": "project", "GOOGLE_CLOUD_LOCATION": "us-central1"]
            if method == "service-account" { env["GOOGLE_APPLICATION_CREDENTIALS"] = "/credentials.json" }
            #expect(result == ApiKeyLoginResult(env: env))
            #expect(snapshot.events.count == 1)
            guard case .info(_, let links) = try #require(snapshot.events.first) else { Issue.record("Expected info"); return }
            #expect(links == [AuthInfoLink(url: "https://cloud.google.com/docs/authentication/provide-credentials-adc", label: "Application Default Credentials")])
            let messages = snapshot.prompts.dropFirst().compactMap { prompt -> String? in
                if case .text(let message, _) = prompt { return message }; return nil
            }
            #expect(messages == ["Enter Google Cloud project ID", "Enter Google Cloud location"] + (method == "service-account" ? ["Enter service account credentials file path"] : []))
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["cloudflare-workers-ai", "cloudflare-ai-gateway"])
    func cloudflareLoginStoresProviderEnvironment(provider: String) async throws {
        let login = try #require(getBuiltinProviderAuth(provider)?.apiKey?.login)
        let (interaction, trace) = a1Interaction(["secret", "account", "gateway"])
        let result = try await login(interaction)
        let gateway = provider == "cloudflare-ai-gateway"
        #expect(result == ApiKeyLoginResult(key: "secret", env: gateway
            ? ["CLOUDFLARE_ACCOUNT_ID": "account", "CLOUDFLARE_GATEWAY_ID": "gateway"]
            : ["CLOUDFLARE_ACCOUNT_ID": "account"]))
        let prompts = trace.withLock { $0.prompts }
        #expect(prompts.count == (gateway ? 3 : 2))
        guard case .secret(let message, _) = prompts[0] else { Issue.record("Expected secret"); return }
        #expect(message == "Enter Cloudflare API key")
        guard case .text(let accountMessage, _) = prompts[1] else { Issue.record("Expected text"); return }
        #expect(accountMessage == "Enter Cloudflare account ID")
        if gateway {
            guard case .text(let gatewayMessage, _) = prompts[2] else { Issue.record("Expected text"); return }
            #expect(gatewayMessage == "Enter Cloudflare AI Gateway ID")
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["amazon-bedrock", "google-vertex"])
    func unknownMethodFailsWithProviderName(provider: String) async throws {
        let login = try #require(getBuiltinProviderAuth(provider)?.apiKey?.login)
        let (interaction, _) = a1Interaction(["unknown"])
        do { _ = try await login(interaction); Issue.record("Expected unknown method") }
        catch {
            #expect(error.localizedDescription == "Unknown \(provider == "amazon-bedrock" ? "Amazon Bedrock" : "Google Vertex AI") auth method: unknown")
        }
    }

    @Test(.timeLimit(.minutes(1))) func cancelledLoginDoesNotPromptOrReturnAKey() async {
        let signal = CancellationToken()
        signal.cancel()
        let (interaction, trace) = a1Interaction(["secret"], signal: signal)
        do { _ = try await envApiKeyLogin(name: "API key")(interaction); Issue.record("Expected cancellation") }
        catch { #expect(error.localizedDescription == "Login cancelled") }
        #expect(trace.withLock { $0.prompts.isEmpty })
        let duringPrompt = CancellationToken()
        let pending = ProviderAuthInteraction(prompt: { _ in duringPrompt.cancel(); return "secret" }, notify: { _ in }, signal: duringPrompt)
        do { _ = try await envApiKeyLogin(name: "API key")(pending); Issue.record("Expected cancellation") }
        catch { #expect(error.localizedDescription == "Login cancelled") }
    }

    @Test func ambientBedrockSourcesFollowUpstreamOrder() {
        let cases: [([String: String], String)] = [
            (["AWS_BEARER_TOKEN_BEDROCK": "secret", "AWS_PROFILE": "dev"], "AWS_BEARER_TOKEN_BEDROCK"),
            (["AWS_PROFILE": "dev"], "AWS_PROFILE"),
            (["AWS_ACCESS_KEY_ID": "id", "AWS_SECRET_ACCESS_KEY": "secret"], "AWS access keys"),
            (["AWS_CONTAINER_CREDENTIALS_RELATIVE_URI": "/path"], "ECS task role"),
            (["AWS_CONTAINER_CREDENTIALS_FULL_URI": "http://localhost"], "ECS task role"),
            (["AWS_WEB_IDENTITY_TOKEN_FILE": "/token"], "web identity token"),
        ]
        for (env, source) in cases { #expect(ambientAuthSource(provider: "amazon-bedrock", env: env) == source) }
        #expect(ambientAuthSource(provider: "amazon-bedrock", env: [:]) == nil)
        #expect(ambientAuthSource(provider: "amazon-bedrock", env: ["AWS_ACCESS_KEY_ID": "id"]) == nil)
        #expect(ambientAuthSource(provider: "amazon-bedrock", env: ["AWS_PROFILE": " \n "]) == nil)
    }

    @Test func ambientVertexAndFederationSources() throws {
        #expect(ambientAuthSource(provider: "google-vertex", env: ["GOOGLE_CLOUD_API_KEY": "secret"]) == "GOOGLE_CLOUD_API_KEY")
        #expect(ambientAuthSource(provider: "google-vertex", env: [:]) == nil)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("{}".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let env = ["GOOGLE_APPLICATION_CREDENTIALS": file.path, "GCLOUD_PROJECT": "project", "GOOGLE_CLOUD_LOCATION": "us-central1"]
        #expect(ambientAuthSource(provider: "google-vertex", env: env) == "gcloud application default credentials")
        #expect(ambientAuthSource(provider: "google-vertex", env: ["GOOGLE_APPLICATION_CREDENTIALS": file.path]) == nil)
        let federation = ["ANTHROPIC_FEDERATION_RULE_ID": "rule", "ANTHROPIC_ORGANIZATION_ID": "org", "ANTHROPIC_IDENTITY_TOKEN_FILE": "/token"]
        #expect(ambientAuthSource(provider: "anthropic", env: federation) == "workload identity federation")
        #expect(ambientAuthSource(provider: "anthropic", env: [:]) == nil)
    }

    @Test func newlySupportedEnvironmentKeys() {
        let rows = [
            ("ant-ling", "ANT_LING_API_KEY"), ("nvidia", "NVIDIA_API_KEY"), ("zai-coding-cn", "ZAI_CODING_CN_API_KEY"),
            ("moonshotai", "MOONSHOT_API_KEY"), ("moonshotai-cn", "MOONSHOT_API_KEY"), ("together", "TOGETHER_API_KEY"),
            ("xiaomi", "XIAOMI_API_KEY"), ("xiaomi-token-plan-ams", "XIAOMI_TOKEN_PLAN_AMS_API_KEY"),
            ("xiaomi-token-plan-cn", "XIAOMI_TOKEN_PLAN_CN_API_KEY"), ("xiaomi-token-plan-sgp", "XIAOMI_TOKEN_PLAN_SGP_API_KEY"),
        ]
        for (provider, variable) in rows {
            #expect(getEnvApiKey(provider: provider, env: [variable: "secret"]) == "secret")
            #expect(findEnvKeys(provider: provider, env: [variable: "secret"]) == [variable])
            #expect(getBuiltinProviderAuth(provider)?.apiKey?.envVars == [variable])
        }
        #expect(getEnvApiKey(provider: "github-copilot", env: ["GH_TOKEN": "old", "GITHUB_TOKEN": "old"]) == nil)
        #expect(findEnvKeys(provider: "github-copilot", env: ["GH_TOKEN": "old", "GITHUB_TOKEN": "old"]) == nil)
        #expect(getEnvApiKey(provider: "github-copilot", env: ["COPILOT_GITHUB_TOKEN": "new", "GITHUB_TOKEN": "old"]) == "new")
        #expect(getEnvApiKey(provider: "openai-codex", env: ["OPENAI_API_KEY": "secret"]) == nil)
        #expect(findEnvKeys(provider: "openai-codex", env: ["OPENAI_API_KEY": "secret"]) == nil)
    }
}
