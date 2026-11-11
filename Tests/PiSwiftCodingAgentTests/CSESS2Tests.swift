import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private final class CSESS2Counter: Sendable {
    private let value = LockedState(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

@Suite("C-SESS2 session replacement and extension actions")
struct CSESS2Tests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("csess2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func options(_ cwd: String, manager: SessionManager) -> CreateAgentSessionOptions {
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        return CreateAgentSessionOptions(cwd: cwd, agentDir: cwd,
            authStorage: .inMemory([model.provider: .apiKey(ApiKeyCredential(key: "test"))]),
            model: model, offline: true, sessionManager: manager, settingsManager: .inMemory())
    }

    @Test("continue rebuilds cwd-bound tools, prompt and resources; the source header stays unchanged")
    func continueRebinds() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old")
        let current = root.appendingPathComponent("current")
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try "current resource".write(to: current.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "current tool".write(to: current.appendingPathComponent("sample.txt"), atomically: true, encoding: .utf8)
        let source = SessionManager.create(old.path, sessions.path)
        source.appendMessage(.user(UserMessage(content: .text("source"))))
        let sourcePath = try #require(source.getSessionFile())
        let originalBytes = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
        try FileManager.default.removeItem(at: old)
        let initial = try await createAgentSession(options(current.path, manager: .create(current.path, sessions.path))).session
        let runtime = AgentSessionRuntime(agentDir: current.path, initialSession: initial, configure: { args in
            let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
            return CreateAgentSessionOptions(
                authStorage: .inMemory([model.provider: .apiKey(ApiKeyCredential(key: "test"))]),
                model: model, offline: true, settingsManager: .inMemory())
        })
        let next = try await runtime.continueMissingCwd(sourcePath, in: current.path)
        #expect(next.sessionManager.getCwd() == current.path)
        #expect(next.getCurrentSystemPromptOptions().cwd == current.path)
        #expect(try buildSystemPrompt(next.getCurrentSystemPromptOptions()).contains(current.path))
        #expect(next.resourceLoader.getAgentsFiles().contains { $0.content.contains("current resource") })
        let read = try #require(next.agent.state.tools.first { $0.name == "read" })
        let result = try await read.execute("csess2-read", ["path": AnyCodable("sample.txt")], nil, nil)
        #expect(result.content.contains { if case .text(let text) = $0 { return text.text.contains("current tool") }; return false })
        #expect(try Data(contentsOf: URL(fileURLWithPath: sourcePath)) == originalBytes)
        next.sessionManager.appendMessage(.user(UserMessage(content: .text("next"))))
        #expect(next.sessionManager.getEntries().count >= 2)
        #expect(SessionManager.open(sourcePath).getHeader()?.cwd == old.path)
        runtime.dispose()
    }

    @Test("fork and import use the current cwd and remove failed copies")
    func forkAndImport() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old")
        let current = root.appendingPathComponent("current")
        let sources = root.appendingPathComponent("sources")
        let imports = root.appendingPathComponent("imports")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        let source = SessionManager.create(old.path, sources.path)
        source.appendMessage(.user(UserMessage(content: .text("source"))))
        let sourcePath = try #require(source.getSessionFile())
        let sourceBytes = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
        try FileManager.default.removeItem(at: old)
        let initial = try await createAgentSession(options(current.path, manager: .create(current.path, imports.path))).session
        let runtime = AgentSessionRuntime(agentDir: current.path, initialSession: initial, configure: { _ in
            let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
            return CreateAgentSessionOptions(authStorage: .inMemory([model.provider: .apiKey(ApiKeyCredential(key: "test"))]),
                model: model, offline: true, settingsManager: .inMemory())
        })
        let fork = try await runtime.forkAndSwitch(sourcePath, into: current.path, sessionDir: imports.path)
        #expect(fork.sessionManager.getSessionId() != source.getSessionId())
        #expect(fork.sessionManager.getCwd() == current.path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: sourcePath)) == sourceBytes)
        let result = try await runtime.importFromJsonl(sourcePath, fallbackCwd: current.path)
        #expect(!result.cancelled)
        let imported = try #require(runtime.session)
        #expect(imported.sessionManager.getCwd() == current.path)
        #expect(SessionManager.open(try #require(imported.sessionFile)).getHeader()?.cwd == old.path)
        runtime.dispose()
    }

    @Test("direct import applies a run-only fallback and keeps the copied header")
    func directImportFallback() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old")
        let current = root.appendingPathComponent("current")
        let sources = root.appendingPathComponent("sources")
        let imports = root.appendingPathComponent("imports")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        let source = SessionManager.create(old.path, sources.path)
        source.appendMessage(.user(UserMessage(content: .text("source"))))
        let sourcePath = try #require(source.getSessionFile())
        try FileManager.default.removeItem(at: old)
        let session = try await createAgentSession(options(current.path, manager: .create(current.path, imports.path))).session
        defer { session.dispose() }
        let result = try await session.importFromJsonl(sourcePath, fallbackCwd: current.path)
        #expect(!result.cancelled)
        #expect(session.sessionManager.getCwd() == current.path)
        let copy = try #require(session.sessionFile)
        #expect(SessionManager.open(copy).getHeader()?.cwd == old.path)
        session.sessionManager.appendMessage(.user(UserMessage(content: .text("after import"))))
        #expect(SessionManager.open(copy).getEntries().count >= 2)
    }

    @Test("import removes a copied file when replacement construction fails")
    func failedImportRemovesCopy() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old")
        let current = root.appendingPathComponent("current")
        let sources = root.appendingPathComponent("sources")
        let imports = root.appendingPathComponent("imports")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        let source = SessionManager.create(old.path, sources.path)
        source.appendMessage(.user(UserMessage(content: .text("source"))))
        let sourcePath = try #require(source.getSessionFile())
        try FileManager.default.removeItem(at: old)
        let initial = try await createAgentSession(options(current.path, manager: .create(current.path, imports.path))).session
        struct FactoryFailure: Error {}
        let runtime = AgentSessionRuntime(agentDir: current.path, factory: { _ in throw FactoryFailure() }, initialSession: initial)
        await #expect(throws: FactoryFailure.self) {
            try await runtime.importFromJsonl(sourcePath, fallbackCwd: current.path)
        }
        #expect(runtime.session === initial)
        #expect(try FileManager.default.contentsOfDirectory(atPath: imports.path).filter { $0.hasSuffix(".jsonl") }.isEmpty)
        #expect(FileManager.default.fileExists(atPath: sourcePath))
        runtime.dispose()
    }

    @Test("replacement emits shutdown before start with the chosen reason")
    func replacementLifecycleEvents() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = LockedState<[String]>([])
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        let registry = ModelRegistry(.inMemory([model.provider: .apiKey(ApiKeyCredential(key: "test"))]))
        let oldManager = SessionManager.inMemory(root.path)
        let nextManager = SessionManager.inMemory(root.path)
        let oldAPI = HookAPI()
        oldAPI.on("session_shutdown") { (event: SessionShutdownEvent, _: HookContext) in
            trace.withLock { $0.append("shutdown:\(event.reason.rawValue)") }
        }
        let nextAPI = HookAPI()
        nextAPI.on("session_start") { (event: SessionStartEvent, _: HookContext) in
            trace.withLock { $0.append("start:\(event.reason.rawValue)") }
        }
        func makeSession(_ manager: SessionManager, _ api: HookAPI) -> AgentSession {
            let hook = LoadedHook(path: "csess2", resolvedPath: "csess2", handlers: api.handlers,
                currentHandlers: { api.handlers }, commands: api.commands,
                currentCommands: { api.commands }, isExtension: true)
            let runner = HookRunner([hook], root.path, manager, registry)
            let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "test", model: model, tools: []),
                getApiKey: { _ in "test" }))
            return AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager,
                settingsManager: .inMemory(), resourceLoader: TestResourceLoader(),
                hookRunner: runner, modelRegistry: registry))
        }
        let old = makeSession(oldManager, oldAPI)
        let next = makeSession(nextManager, nextAPI)
        let runtime = AgentSessionRuntime(agentDir: root.path, factory: { _ in next }, initialSession: old)
        // v1.5.2 agent-session-runtime.ts:189-196: the host rebind is awaited before session_start.
        runtime.setRebindSession { session in
            await Task.yield()
            trace.withLock { $0.append("rebind:\(session === next)") }
        }
        _ = try await runtime.replaceSession(args: AgentSessionRuntimeFactoryArgs(
            cwd: root.path, agentDir: root.path, sessionManager: nextManager,
            sessionStartEvent: AgentSessionStartEvent(reason: .resume)))
        #expect(trace.withLock { $0 } == ["shutdown:resume", "rebind:true", "start:resume"])
        runtime.dispose()
    }

    @Test("failed fork replacement removes its file and preserves the outgoing provider state")
    func failedForkKeepsOldSession() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = root.appendingPathComponent("cwd")
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let source = SessionManager.create(cwd.path, sessions.path)
        source.appendMessage(.user(UserMessage(content: .text("source"))))
        let sourcePath = try #require(source.getSessionFile())
        let initial = try await createAgentSession(options(cwd.path, manager: .inMemory(cwd.path))).session
        let oldID = initial.sessionId
        let cleanups = CSESS2Counter()
        let removeCleanup = registerSessionResourceCleanup { id in
            if id == oldID { cleanups.increment() }
        }
        defer { removeCleanup() }
        struct FactoryFailure: Error {}
        let runtime = AgentSessionRuntime(agentDir: cwd.path, factory: { _ in throw FactoryFailure() }, initialSession: initial)
        await #expect(throws: FactoryFailure.self) {
            try await runtime.forkAndSwitch(sourcePath, into: cwd.path, sessionDir: sessions.path)
        }
        #expect(runtime.session === initial)
        #expect(cleanups.count == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: sessions.path).filter { $0.hasSuffix(".jsonl") }.count == 1)
        runtime.dispose()
        #expect(cleanups.count == 1)
    }

    @Test("switch options reach the host, and shutdown reaches both extension contexts")
    func actionsReachHost() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = SessionManager.inMemory(root.path)
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        let registry = ModelRegistry(.inMemory([model.provider: .apiKey(ApiKeyCredential(key: "test"))]))
        let runner = HookRunner([], root.path, manager, registry)
        let shutdowns = CSESS2Counter()
        let switches = CSESS2Counter()
        let callbacks = CSESS2Counter()
        runner.initialize(getModel: { model }, switchSessionOptionsHandler: { [weak runner] path, options in
            if path == "target" && options?.withSession != nil { switches.increment() }
            if let callback = options?.withSession, let runner { await callback(runner.createCommandContext()) }
            return HookCommandResult(cancelled: false)
        }, shutdownHandler: { shutdowns.increment() })
        runner.createShortcutContext().shutdown()
        let command = runner.createCommandContext()
        command.shutdown()
        let tool = CustomToolContext(sessionManager: manager, modelRegistry: registry, model: model,
            isIdle: { true }, hasPendingMessages: { false }, abort: {},
            events: createEventBus(), sendMessage: { _, _ in })
        tool.shutdown()
        #expect(shutdowns.count == 3)
        let result = await command.switchSession("target", options: HookSwitchSessionOptions(withSession: { _ in callbacks.increment() }))
        #expect(!result.cancelled)
        #expect(switches.count == 1)
        #expect(callbacks.count == 1)
        runner.dispose()
        tool.shutdown()
        #expect(shutdowns.count == 3)
    }
}
