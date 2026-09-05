import Foundation
import Testing
@testable import PiSwiftAI

private enum UserAgent085Adapter: String, CaseIterable, Sendable {
    case anthropic, anthropicOAuth, copilot, kimiCoding
    case completions, responses, azure, google, vertex, codex

    var api: Api {
        switch self {
        case .anthropic, .anthropicOAuth, .copilot, .kimiCoding: .anthropicMessages
        case .completions: .openAICompletions
        case .responses: .openAIResponses
        case .azure: .azureOpenAIResponses
        case .google: .googleGenerativeAI
        case .vertex: .googleVertex
        case .codex: .openAICodexResponses
        }
    }

    var provider: String {
        switch self {
        case .anthropic, .anthropicOAuth: "anthropic"
        case .copilot: "github-copilot"
        case .kimiCoding: "kimi-coding"
        case .completions, .responses: "openai"
        case .azure: "azure-openai-responses"
        case .google: "google"
        case .vertex: "google-vertex"
        case .codex: "openai-codex"
        }
    }

    var defaultUserAgent: String {
        switch self {
        case .anthropicOAuth: "claude-cli/2.1.251"
        case .copilot: "GitHubCopilotChat/0.35.0"
        default: getPiUserAgent()
        }
    }
}

private enum UserAgent085Override: CaseIterable, Sendable {
    case option, model, deletedByOption, deletedByModel
}

private actor UserAgent085HTTPClient: ProviderHTTPClient {
    private var request: URLRequest?

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        self.request = request
        return ProviderHTTPResponse(statusCode: 403, body: Data(#"{"error":{"message":"request captured"}}"#.utf8))
    }

    func capturedRequest() -> URLRequest? { request }
}

private func userAgent085Request(
    adapter: UserAgent085Adapter,
    modelHeaders: ProviderHeaders? = nil,
    optionHeaders: ProviderHeaders? = nil
) async throws -> URLRequest {
    let client = UserAgent085HTTPClient()
    let defaultModelHeaders: ProviderHeaders? = adapter == .copilot
        ? ["User-Agent": "GitHubCopilotChat/0.35.0"] : nil
    let model = Model(id: "test-model", name: "Test", api: adapter.api, provider: adapter.provider,
        baseUrl: "https://user-agent.example/v1", reasoning: false, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 32_768, maxTokens: 4096,
        headers: mergeProviderHeaders(defaultModelHeaders, modelHeaders))
    let context = Context(messages: [.user(UserMessage(content: .text("Hi")))])
    let stream: AssistantMessageEventStream
    switch adapter {
    case .anthropic, .anthropicOAuth, .copilot, .kimiCoding:
        let key = adapter == .anthropicOAuth ? "sk-ant-oat01-test-token" : "test-key"
        stream = streamAnthropic(model: model, context: context,
            options: AnthropicOptions(apiKey: key, httpClient: client, headers: optionHeaders, maxRetries: 0))
    case .completions:
        stream = streamOpenAICompletions(model: model, context: context,
            options: OpenAICompletionsOptions(apiKey: "test-key", httpClient: client, headers: optionHeaders, maxRetries: 0))
    case .responses:
        stream = streamOpenAIResponses(model: model, context: context,
            options: OpenAIResponsesOptions(apiKey: "test-key", httpClient: client, headers: optionHeaders, maxRetries: 0))
    case .azure:
        var options = AzureOpenAIResponsesOptions(apiKey: "test-key", httpClient: client, headers: optionHeaders, maxRetries: 0)
        options.azureBaseUrl = "https://ua-test.openai.azure.com"
        options.azureApiVersion = "v1"
        options.azureDeploymentName = "test-deployment"
        stream = streamAzureOpenAIResponses(model: model, context: context, options: options)
    case .google:
        stream = streamGoogle(model: model, context: context,
            options: GoogleOptions(apiKey: "test-key", httpClient: client, headers: optionHeaders, maxRetries: 0))
    case .vertex:
        stream = streamGoogleVertex(model: model, context: context,
            options: GoogleVertexOptions(apiKey: "explicit-access-token", httpClient: client, headers: optionHeaders,
                project: "test-project", location: "us-central1", maxRetries: 0))
    case .codex:
        let tokenPayload = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"acc_test"}}"#.utf8).base64EncodedString()
        stream = streamOpenAICodexResponses(model: model, context: context,
            options: OpenAICodexResponsesOptions(apiKey: "e30.\(tokenPayload).sig", httpClient: client,
                transport: .sse, headers: optionHeaders, maxRetries: 0))
    }
    _ = await stream.result()
    return try #require(await client.capturedRequest())
}

// Port of the User-Agent cases in anthropic-auth-token.test.ts,
// azure-openai-base-url.test.ts, google-raw-stop-reason.test.ts,
// google-vertex-api-key-resolution.test.ts, and openai-codex-stream.test.ts.
@Test(arguments: UserAgent085Adapter.allCases)
private func provider085UserAgentDefaults(adapter: UserAgent085Adapter) async throws {
    let request = try await userAgent085Request(adapter: adapter)
    #expect(request.value(forHTTPHeaderField: "User-Agent") == adapter.defaultUserAgent)
    if adapter == .azure {
        #expect(request.url?.host == "ua-test.openai.azure.com")
        #expect(request.url?.path.hasPrefix("/openai/v1/") == true)
    }
    if adapter == .vertex {
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer explicit-access-token")
    }
}

// Header names are case-insensitive. Model/option overrides, including explicit
// deletion, take precedence over the new User-Agent defaults.
@Test(arguments: UserAgent085Adapter.allCases, UserAgent085Override.allCases)
private func provider085UserAgentOverrides(adapter: UserAgent085Adapter, override: UserAgent085Override) async throws {
    let modelHeaders: ProviderHeaders?
    let optionHeaders: ProviderHeaders?
    let expected: String?
    switch override {
    case .option:
        modelHeaders = ["USER-AGENT": "model-client"]
        optionHeaders = ["user-agent": "option-client"]
        expected = "option-client"
    case .model:
        modelHeaders = ["user-agent": "model-client"]
        optionHeaders = nil
        expected = "model-client"
    case .deletedByOption:
        modelHeaders = ["User-Agent": "model-client"]
        optionHeaders = ["USER-AGENT": nil]
        expected = nil
    case .deletedByModel:
        modelHeaders = ["user-agent": nil]
        optionHeaders = nil
        expected = nil
    }
    let request = try await userAgent085Request(adapter: adapter, modelHeaders: modelHeaders, optionHeaders: optionHeaders)
    #expect(request.value(forHTTPHeaderField: "User-Agent") == expected)
}
