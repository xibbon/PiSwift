import Foundation
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

typealias AgentThinkingLevel = PiSwiftAgent.ThinkingLevel

private let RUN_ANTHROPIC_TESTS: Bool = {
    let env = ProcessInfo.processInfo.environment
    let flag = (env["PI_RUN_ANTHROPIC_TESTS"] ?? env["PI_RUN_LIVE_TESTS"])?.lowercased()
    return flag == "1" || flag == "true" || flag == "yes"
}()

let API_KEY: String? = {
    guard RUN_ANTHROPIC_TESTS else { return nil }
    let env = ProcessInfo.processInfo.environment
    return env["ANTHROPIC_OAUTH_TOKEN"] ?? env["ANTHROPIC_API_KEY"]
}()

let PI_AGENT_DIR = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".pi")
    .appendingPathComponent("agent")
    .path

private let AUTH_PATH = URL(fileURLWithPath: PI_AGENT_DIR).appendingPathComponent("auth.json").path

final class TestResourceLoader: ResourceLoader {
    func getExtensions() -> ExtensionsResult {
        ExtensionsResult(paths: [], diagnostics: [])
    }

    func getSkills() -> (skills: [Skill], diagnostics: [ResourceDiagnostic]) {
        ([], [])
    }

    func getPrompts() -> (prompts: [PromptTemplate], diagnostics: [ResourceDiagnostic]) {
        ([], [])
    }

    func getThemes() -> (themes: [HookThemeInfo], diagnostics: [ResourceDiagnostic]) {
        ([], [])
    }

    func getAgentsFiles() -> [ContextFile] {
        []
    }

    func getSystemPrompt() -> String? {
        nil
    }

    func getAppendSystemPrompt() -> [String] {
        []
    }

    func getPathMetadata() -> [String: PathMetadata] {
        [:]
    }

    func extendResources(_ paths: ResourceExtensionPaths) {}

    func reload() async {}
}

func getRealAuthStorage() -> AuthStorage {
    AuthStorage(AUTH_PATH)
}

func hasAuthForProvider(_ provider: String) -> Bool {
    getRealAuthStorage().has(provider)
}

func resolveApiKey(_ provider: String) async -> String? {
    await getRealAuthStorage().getApiKey(provider)
}

func userMsg(_ text: String, timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> AgentMessage {
    .user(UserMessage(content: .text(text), timestamp: timestamp))
}

func assistantMsg(_ text: String, timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> AgentMessage {
    let usage = Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2)
    let msg = AssistantMessage(
        content: [.text(TextContent(text: text))],
        api: .anthropicMessages,
        provider: "anthropic",
        model: "test",
        usage: usage,
        stopReason: .stop,
        timestamp: timestamp
    )
    return .assistant(msg)
}

struct TestSessionOptions {
    var inMemory: Bool = false
    var systemPrompt: String?
    var settingsOverrides: Settings?
    var model: Model?
    var thinkingLevel: AgentThinkingLevel?
    var apiKey: String?
}

struct TestSessionContext {
    var session: AgentSession
    var sessionManager: SessionManager
    var tempDir: String
    var cleanup: () -> Void
}

func createTestSession(options: TestSessionOptions = TestSessionOptions()) -> TestSessionContext {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-test-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)

    let apiKey = options.apiKey ?? API_KEY
    let model = options.model ?? getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
    let thinkingLevel: AgentThinkingLevel = options.thinkingLevel ?? .off
    let agent = Agent(AgentOptions(
        initialState: AgentState(
            systemPrompt: options.systemPrompt ?? "You are a helpful assistant.",
            model: model,
            thinkingLevel: thinkingLevel
        ),
        convertToLlm: { messages in
            convertToLlm(messages)
        },
        getApiKey: { _ in apiKey }
    ))

    let sessionManager = options.inMemory ? SessionManager.inMemory() : SessionManager.create(tempDir, tempDir)
    let settingsManager = SettingsManager.create(tempDir, tempDir)
    if let overrides = options.settingsOverrides {
        settingsManager.applyOverrides(overrides)
    }
    let authStorage = AuthStorage(URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path)
    let modelRegistry = ModelRegistry(authStorage, tempDir)

    if let apiKey {
        authStorage.setRuntimeApiKey(model.provider, apiKey)
    }

    let session = AgentSession(config: AgentSessionConfig(
        agent: agent,
        sessionManager: sessionManager,
        settingsManager: settingsManager,
        resourceLoader: TestResourceLoader(),
        modelRegistry: modelRegistry
    ))

    _ = session.subscribe { _ in }

    let cleanup = {
        session.dispose()
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    return TestSessionContext(session: session, sessionManager: sessionManager, tempDir: tempDir, cleanup: cleanup)
}

func buildTestTree(session: SessionManager, messages: [(role: String, text: String, branchFrom: String?)]) -> [String: String] {
    var ids: [String: String] = [:]
    for message in messages {
        if let branchFrom = message.branchFrom, let branchId = ids[branchFrom] {
            try? session.branch(branchId)
        }

        let id: String
        if message.role == "user" {
            id = session.appendMessage(userMsg(message.text))
        } else {
            id = session.appendMessage(assistantMsg(message.text))
        }
        ids[message.text] = id
    }
    return ids
}
