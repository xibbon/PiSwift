import Foundation
import Testing
@testable import PiSwiftAI

@Test func f5ProviderEnvironmentPrecedence() {
    #expect(getProviderEnvValue("HOME", env: ["HOME": "scoped"]) == "scoped")
    #expect(getProviderEnvValue("HOME", env: ["HOME": ""]) == ProcessInfo.processInfo.environment["HOME"])
    #expect(getEnvApiKey(provider: "openai", env: ["OPENAI_API_KEY": "scoped-key"]) == "scoped-key")
    #expect(getEnvApiKey(provider: "anthropic", env: ["ANTHROPIC_AUTH_TOKEN": "scoped-token"]) == "scoped-token")
    #expect(usesAnthropicBearerTransport("scoped-token", env: ["ANTHROPIC_AUTH_TOKEN": "scoped-token"]))
    #expect(providerEnvironment(["PI_F5_PRIVATE": "value"])["PI_F5_PRIVATE"] == "value")
    #expect(ProcessInfo.processInfo.environment["PI_F5_PRIVATE"] == nil)
}

@Test func f5ProviderOptionMappingsRetainEnvironment() throws {
    let env = ["OPENAI_API_KEY": "key", "HTTP_PROXY": "http://proxy.test:8080"]
    let model = try #require(getModels(provider: .openai).first)
    let options = SimpleStreamOptions(env: env)
    #expect(mapOpenAICompletionsSimpleOptions(model: model, options: options, apiKey: "key").env == env)
    #expect(mapOpenAIResponsesSimpleOptions(model: model, options: options, apiKey: "key").env == env)
    #expect(mapAzureOpenAIResponsesSimpleOptions(model: model, options: options, apiKey: "key").env == env)
    #expect(mapOpenAICodexResponsesSimpleOptions(model: model, options: options, apiKey: "key").env == env)
    #expect(mapAnthropicSimpleOptions(model: model, context: normalizeContext(Context(messages: [])), options: options, apiKey: "key").env == env)
    #expect(mapGoogleSimpleOptions(model: model, options: options, apiKey: "key").env == env)
    #expect(mapGoogleVertexSimpleOptions(model: model, options: options, apiKey: "key").env == env)
    #expect(mapBedrockSimpleOptions(model: model, options: options).env == env)
}

@Test func f5BedrockScopedCredentials() throws {
    #expect(try resolvedBedrockAccessKeyId(options: BedrockOptions(env: [
        "AWS_ACCESS_KEY_ID": "scoped-access", "AWS_SECRET_ACCESS_KEY": "scoped-secret"
    ])) == "scoped-access")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("f5-aws-profile-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("credentials")
    try "[scoped]\naws_access_key_id=profile-access\naws_secret_access_key=profile-secret\n"
        .write(to: file, atomically: true, encoding: .utf8)
    // v0.99.1: stored scoped AWS_PROFILE wins over access-key env values.
    #expect(try resolvedBedrockAccessKeyId(options: BedrockOptions(env: [
        "AWS_PROFILE": "scoped", "AWS_SHARED_CREDENTIALS_FILE": file.path,
        "AWS_ACCESS_KEY_ID": "env-access", "AWS_SECRET_ACCESS_KEY": "env-secret"
    ])) == "profile-access")
}

@Test func f5ScopedProxyAliasesPrecedeProcessAliases() throws {
    let ambient = ["https_proxy": "http://process-lower.test", "HTTPS_PROXY": "http://process-upper.test",
                   "no_proxy": "process.test"]
    let scoped = ["HTTPS_PROXY": "http://scoped-upper.test", "NO_PROXY": "scoped.test"]
    let env = providerProxyEnvironment(scoped, processEnvironment: ambient)
    #expect(env["HTTPS_PROXY"] == "http://scoped-upper.test")
    #expect(parseNoProxy(env: env) == ["scoped.test"])
    #expect(providerProxyEnvironment(["https_proxy": "http://scoped-lower.test", "HTTPS_PROXY": "http://scoped-upper.test"], processEnvironment: ambient)["HTTPS_PROXY"] == "http://scoped-lower.test")
    #expect(providerProxyEnvironment(["HTTPS_PROXY": ""], processEnvironment: ambient)["HTTPS_PROXY"] == "http://process-lower.test")
    #if os(macOS)
    #expect(selectedProxyURL(for: URL(string: "https://target.test"), env: env)?.host == "scoped-upper.test")
    #expect(selectedProxyURL(for: URL(string: "https://target.test"), env: ["HTTP_PROXY": "http://http.test"]) == nil)
    #endif
}

private struct F5EnvHTTPClient: ProviderHTTPClient {
    let requests: LockedState<[URLRequest]>
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.withLock { $0.append(request) }
        return ProviderHTTPResponse(statusCode: 200, body: Data("data: [DONE]\n\n".utf8))
    }
}

@Test func f5ScopedCloudflareRequestAndCacheRetention() async throws {
    let requests = LockedState<[URLRequest]>([])
    let model = Model(id: "demo", name: "demo", api: .openAICompletions, provider: "cloudflare-workers-ai",
        baseUrl: "https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/ai/v1",
        reasoning: false, input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 100, maxTokens: 10)
    let options = SimpleStreamOptions(env: ["CLOUDFLARE_API_KEY": "scoped-token", "CLOUDFLARE_ACCOUNT_ID": "scoped-account"], httpClient: F5EnvHTTPClient(requests: requests))
    _ = await (try streamSimple(model: model, context: Context(messages: [.user(UserMessage(content: .text("Hi")))]), options: options)).result()
    let request = try #require(requests.withLock { $0.first })
    #expect(request.url?.absoluteString.contains("accounts/scoped-account") == true)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer scoped-token")
    #expect(resolveCacheRetention(nil, env: ["PI_CACHE_RETENTION": "long"]) == .long)
    #expect(anthropicCacheTtl(baseUrl: "https://api.anthropic.com", env: ["PI_CACHE_RETENTION": "long"]) == "1h")
    #if os(macOS)
    #expect(selectedProxyURL(for: URL(string: "wss://example.test"), env: ["HTTP_PROXY": "http://http.test", "HTTPS_PROXY": "http://https.test"])?.host == "https.test")
    #endif
}

@Test func f5ScopedVertexRequestConfiguration() async throws {
    let requests = LockedState<[URLRequest]>([])
    let model = Model(id: "demo", name: "demo", api: .googleVertex, provider: "google-vertex",
        baseUrl: "https://{location}-aiplatform.googleapis.com", reasoning: false, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 100, maxTokens: 10)
    let options = GoogleVertexOptions(env: ["GOOGLE_CLOUD_PROJECT": "scoped-project", "GOOGLE_CLOUD_LOCATION": "us-scoped1", "GOOGLE_ACCESS_TOKEN": "scoped-token"], httpClient: F5EnvHTTPClient(requests: requests))
    _ = await streamGoogleVertex(model: model, context: normalizeContext(Context(messages: [.user(UserMessage(content: .text("Hi")))])), options: options).result()
    let request = try #require(requests.withLock { $0.first })
    #expect(request.url?.host == "us-scoped1-aiplatform.googleapis.com")
    #expect(request.url?.path.contains("projects/scoped-project/locations/us-scoped1") == true)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer scoped-token")
}
