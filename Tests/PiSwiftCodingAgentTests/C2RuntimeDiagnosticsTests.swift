import Foundation
import PiSwiftAI
import PiSwiftAgent
import Testing
@testable import PiSwiftCodingAgent

@Suite struct C2RuntimeDiagnosticsTests {
    private let missingScope = #"No models match pattern "github-copilot/missing-model""#
    private let modelFallback = "Could not restore model gone/missing-model. Using fake/fake-model"

    @Test("returns each diagnostic once, at startup and after replacements")
    func returnsEachDiagnosticOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let warning = ResourceDiagnostic(type: "warning", message: "settings warning", path: "old")
        let nextDiagnostics = LockedState([warning])
        let initial = fixture.session(diagnostics: nextDiagnostics.withLock { $0 })
        let runtime = AgentSessionRuntime(agentDir: fixture.agentDir.path, factory: { args in
            fixture.session(manager: args.sessionManager, diagnostics: nextDiagnostics.withLock { $0 })
        }, initialSession: initial)
        defer { runtime.dispose() }

        #expect(runtime.takeUnreportedDiagnostics().map(\.message) == ["settings warning"])
        #expect(runtime.takeUnreportedDiagnostics().isEmpty)

        nextDiagnostics.withLock {
            $0 = [
                ResourceDiagnostic(type: "warning", message: "settings warning", path: "new"),
                ResourceDiagnostic(type: "error", message: "extension failed"),
                ResourceDiagnostic(type: "error", message: "settings warning")
            ]
        }
        let replacement = try await runtime.newSessionRebinding()
        #expect(replacement !== initial)
        let diagnostics = runtime.takeUnreportedDiagnostics()
        #expect(diagnostics.map(\.message) == ["extension failed", "settings warning"])
        #expect(diagnostics.map(\.type) == ["error", "error"])
        #expect(runtime.takeUnreportedDiagnostics().isEmpty)

        try await runtime.newSessionRebinding()
        #expect(runtime.takeUnreportedDiagnostics().isEmpty)
    }

    @Test("reports unmatched enabledModels patterns once at startup, not again on new_session")
    func reportsUnmatchedEnabledModelsOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeSettings(["fake/fake-model", "github-copilot/missing-model"])
        let result = try await createAgentSession(fixture.options())
        let runtime = fixture.runtime(result.session)
        defer { runtime.dispose() }

        #expect(result.session.scopedModels.map(\.model.id) == ["fake-model"])
        let startup = runtime.takeUnreportedDiagnostics()
        #expect(startup.map(\.message) == [missingScope])
        #expect(startup.map(\.type) == ["warning"])
        try await runtime.newSessionRebinding()
        #expect(runtime.takeUnreportedDiagnostics().isEmpty)
    }

    @Test("is written to stderr in RPC mode when switch_session falls back to another model")
    func exposesSwitchSessionFallback() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeSettings([])
        let sessionPath = try fixture.saveMissingModelSession()
        let result = try await createAgentSession(fixture.options())
        let runtime = fixture.runtime(result.session)
        defer { runtime.dispose() }

        #expect(runtime.takeUnreportedDiagnostics().isEmpty)
        let replacement = try await runtime.switchSessionRebinding(sessionPath)
        #expect(replacement.agent.state.model.id == "fake-model")
        let diagnostics = runtime.takeUnreportedDiagnostics()
        #expect(diagnostics.map(\.message) == [modelFallback])
        #expect(diagnostics.map(\.type) == ["warning"])

        try await runtime.switchSessionRebinding(sessionPath)
        #expect(runtime.takeUnreportedDiagnostics().isEmpty)
    }

    @Test("renders startup diagnostics inside the transcript")
    func exposesInvalidSettingsOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("{no-json".utf8).write(to: fixture.settingsFile)
        let options = fixture.options()
        let result = try await createAgentSession(options)
        let runtime = fixture.runtime(result.session)
        defer { runtime.dispose() }

        let diagnostics = runtime.takeUnreportedDiagnostics()
        #expect(diagnostics.map(\.type) == ["warning"])
        #expect(diagnostics.first?.message.hasPrefix("Invalid settings file \(fixture.settingsFile.path): ") == true)
        try await runtime.newSessionRebinding()
        #expect(runtime.takeUnreportedDiagnostics().isEmpty)
    }

    @Test("writes a diagnostic that first appears on new_session to stderr once")
    func exposesNewScopeDiagnosticOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeSettings(["fake/fake-model"])
        let result = try await createAgentSession(fixture.options())
        let runtime = fixture.runtime(result.session)
        defer { runtime.dispose() }

        #expect(runtime.takeUnreportedDiagnostics().isEmpty)
        try await runtime.newSessionRebinding()
        #expect(runtime.takeUnreportedDiagnostics().isEmpty)
        try fixture.writeSettings(["fake/fake-model", "github-copilot/missing-model"])
        try await runtime.newSessionRebinding()
        #expect(runtime.takeUnreportedDiagnostics().map(\.message) == [missingScope])
        try await runtime.newSessionRebinding()
        #expect(runtime.takeUnreportedDiagnostics().isEmpty)
    }

    @Test func sameCwdLegacyReplacementsReportNewDiagnostics() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeSettings([])
        let sessionPath = try fixture.saveMissingModelSession()
        let result = try await createAgentSession(fixture.options())
        let runtime = fixture.runtime(result.session)
        defer { runtime.dispose() }

        #expect(runtime.takeUnreportedDiagnostics().isEmpty)
        try fixture.writeSettings(["github-copilot/missing-model"])
        #expect(await result.session.newSession())
        #expect(runtime.session === result.session)
        #expect(runtime.takeUnreportedDiagnostics().map(\.message) == [missingScope])
        #expect(await runtime.switchSession(sessionPath))
        #expect(runtime.session === result.session)
        #expect(runtime.takeUnreportedDiagnostics().map(\.message) == [modelFallback])
        #expect(await runtime.switchSession(sessionPath))
        #expect(runtime.takeUnreportedDiagnostics().isEmpty)
    }

    @Test func startupCarriesExtensionFailureAndModelFallback() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeSettings([])
        let sessionPath = try fixture.saveMissingModelSession()
        var options = fixture.options(manager: try SessionManager.openValidated(sessionPath))
        options.modelPatterns = ["github-copilot/missing-model"]
        options.inlineExtensions = [InlineExtension(name: "broken") { _ in throw FixtureError() }]
        let result = try await createAgentSession(options)
        let runtime = fixture.runtime(result.session)
        defer { runtime.dispose() }

        #expect(result.modelFallbackMessage == modelFallback)
        let diagnostics = runtime.takeUnreportedDiagnostics()
        #expect(diagnostics.map(\.message) == result.diagnostics.map(\.message))
        #expect(diagnostics.filter { $0.type == "warning" }.map(\.message) == [missingScope, modelFallback])
        let error = try #require(diagnostics.first { $0.type == "error" })
        #expect(error.message.hasPrefix("Failed to load extension \""))
        #expect(error.message.contains("broken"))
        #expect(runtime.takeUnreportedDiagnostics().isEmpty)
    }

    private struct FixtureError: LocalizedError {
        var errorDescription: String? { "extension failed" }
    }

    private struct Fixture: Sendable {
        let root: URL
        let cwd: URL
        let agentDir: URL
        let registry: ModelRegistry
        let model: Model

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("c2-diagnostics-\(UUID())")
            cwd = root.appendingPathComponent("project")
            agentDir = root.appendingPathComponent("agent")
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
            registry = ModelRegistry(AuthStorage(":memory:"), agentDir.path)
            registry.registerProvider(HookProviderConfig(provider: "fake", api: .openAICompletions,
                baseUrl: "http://127.0.0.1:9/v1", apiKey: "test", models: [HookProviderModel(id: "fake-model")]),
                sourceId: "c2-fixture")
            model = try #require(registry.find("fake", "fake-model"))
        }

        var settingsFile: URL { agentDir.appendingPathComponent("settings.json") }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func writeSettings(_ enabledModels: [String]) throws {
            let settings = ["defaultProvider": "fake", "defaultModel": "fake-model", "enabledModels": enabledModels] as [String: Any]
            try JSONSerialization.data(withJSONObject: settings).write(to: settingsFile, options: .atomic)
        }

        func saveMissingModelSession() throws -> String {
            let manager = SessionManager.create(cwd.path, root.appendingPathComponent("sessions").path)
            manager.appendMessage(.user(UserMessage(content: .text("hello"))))
            manager.appendMessage(.assistant(AssistantMessage(content: [.text(TextContent(text: "hi"))],
                api: .openAICompletions, provider: "gone", model: "missing-model",
                usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2),
                stopReason: .stop, timestamp: 1)))
            return try #require(manager.getSessionFile())
        }

        func options(manager: SessionManager? = nil) -> CreateAgentSessionOptions {
            CreateAgentSessionOptions(cwd: cwd.path, agentDir: agentDir.path, modelRegistry: registry, offline: true,
                noTools: .all, resourceLoader: TestResourceLoader(), hooks: [],
                sessionManager: manager ?? SessionManager.inMemory(cwd.path))
        }

        func runtime(_ initial: AgentSession) -> AgentSessionRuntime {
            AgentSessionRuntime(agentDir: agentDir.path, initialSession: initial, configure: { args in
                self.options(manager: args.sessionManager)
            })
        }

        func session(manager: SessionManager? = nil, diagnostics: [ResourceDiagnostic]) -> AgentSession {
            let agent = Agent(AgentOptions(initialState: AgentState(model: model)))
            return AgentSession(config: AgentSessionConfig(agent: agent,
                sessionManager: manager ?? SessionManager.inMemory(cwd.path),
                settingsManager: SettingsManager.inMemory(), resourceLoader: TestResourceLoader(),
                modelRegistry: registry, diagnostics: diagnostics))
        }
    }
}
