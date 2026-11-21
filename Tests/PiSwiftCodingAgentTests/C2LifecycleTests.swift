import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private final class C2LifecycleTrace: Sendable {
    let lines = LockedState<[String]>([])
    let cancelSwitch = LockedState(false)
    let cancelFork = LockedState(false)
    func add(_ line: String) { lines.withLock { $0.append(line) } }
    func take() -> [String] { lines.withLock { $0 } }
    func clear() { lines.withLock { $0.removeAll() } }
}

private func c2LifecycleSession(_ manager: SessionManager, _ trace: C2LifecycleTrace,
                                _ label: String) -> AgentSession {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let registry = ModelRegistry(.inMemory([model.provider: .apiKey(ApiKeyCredential(key: "test"))]))
    let api = HookAPI()
    let resourceHandlerInstalled = LockedState(false)
    api.on("session_start") { [weak api] (event: SessionStartEvent, _: HookContext) in
        trace.add("\(label).extension:session_start:\(event.reason.rawValue)")
        api?.appendEntry("c2-start", ["reason": event.reason.rawValue])
        let install = resourceHandlerInstalled.withLock { installed -> Bool in
            guard !installed else { return false }
            installed = true
            return true
        }
        if install {
            api?.on("resources_discover") { (event: ResourcesDiscoverEvent, _: HookContext) in
                trace.add("\(label).extension:resources_discover:\(event.reason.rawValue)")
                return ResourcesDiscoverResult()
            }
        }
        return nil
    }
    api.on("session_shutdown") { (event: SessionShutdownEvent, _: HookContext) in
        trace.add("\(label).extension:session_shutdown:\(event.reason.rawValue)")
        return nil
    }
    api.on("session_before_switch") { (event: SessionBeforeSwitchEvent, _: HookContext) in
        trace.add("\(label).extension:session_before_switch:\(event.reason.rawValue)")
        return trace.cancelSwitch.withLock { value -> SessionBeforeSwitchResult? in
            guard value else { return nil }
            value = false
            return SessionBeforeSwitchResult(cancel: true)
        }
    }
    api.on("session_before_fork") { (event: SessionBeforeForkEvent, _: HookContext) in
        trace.add("\(label).extension:session_before_fork:\(event.position.rawValue)")
        return trace.cancelFork.withLock { value -> SessionBeforeForkResult? in
            guard value else { return nil }
            value = false
            return SessionBeforeForkResult(cancel: true)
        }
    }
    let hook = LoadedHook(path: "c2-\(label)", resolvedPath: "c2-\(label)", handlers: api.handlers,
        currentHandlers: { api.handlers }, commands: api.commands, currentCommands: { api.commands },
        setAppendEntryHandler: { api.setAppendEntryHandler($0) }, isExtension: true)
    let runner = HookRunner([hook], manager.getCwd(), manager, registry)
    _ = runner.addEventObserver { event in
        if let event = event as? SessionStartEvent {
            trace.add("\(label).host:session_start:\(event.reason.rawValue)")
        } else if let event = event as? ResourcesDiscoverEvent {
            trace.add("\(label).host:resources_discover:\(event.reason.rawValue)")
        } else if let event = event as? SessionShutdownEvent {
            trace.add("\(label).host:session_shutdown:\(event.reason.rawValue)")
        } else if let event = event as? SessionBeforeSwitchEvent {
            trace.add("\(label).host:session_before_switch:\(event.reason.rawValue)")
        } else if let event = event as? SessionBeforeForkEvent {
            trace.add("\(label).host:session_before_fork:\(event.position.rawValue)")
        }
    }
    let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "test", model: model, tools: []),
        getApiKey: { _ in "test" }))
    let session = AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager,
        settingsManager: .inMemory(), resourceLoader: TestResourceLoader(),
        hookRunner: runner, modelRegistry: registry,
        reloadExtensionsHook: {
            let refreshed = LoadedHook(path: "c2-\(label)", resolvedPath: "c2-\(label)", handlers: api.handlers,
                currentHandlers: { api.handlers }, commands: api.commands,
                currentCommands: { api.commands }, setAppendEntryHandler: { api.setAppendEntryHandler($0) },
                isExtension: true)
            return LoadExtensionsResult(hooks: [refreshed])
        }))
    _ = session.subscribe { event in
        if case .entryAppended = event { trace.add("\(label).host:entry_appended") }
    }
    return session
}

@Suite("C2 extension lifecycle order")
struct C2LifecycleTests {
    private func forkTrace(clone: Bool) async throws -> [String] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("c2-fork-\(UUID())")
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = SessionManager.create(root.path, sessions.path)
        manager.appendMessage(.user(UserMessage(content: .text("fork here"))))
        let entryId = try #require(manager.getLeafId())
        let trace = C2LifecycleTrace()
        let first = c2LifecycleSession(manager, trace, "old")
        await first.startExtensions()
        trace.clear()
        let runtime = AgentSessionRuntime(agentDir: root.path, factory: { args in
            c2LifecycleSession(args.sessionManager, trace, "next")
        }, initialSession: first)
        runtime.setRebindSession { _ in trace.add("host:rebind") }
        if clone {
            _ = try await runtime.cloneAtLeafRebinding()
        } else {
            _ = try await runtime.forkRebinding(entryId)
        }
        let events = trace.take()
        runtime.dispose()
        return events
    }

    private func switchTrace(targetIsOtherCwd: Bool) async throws -> [String] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("c2-switch-\(UUID())")
        let firstCwd = root.appendingPathComponent("first")
        let otherCwd = root.appendingPathComponent("other")
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: firstCwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherCwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let targetCwd = targetIsOtherCwd ? otherCwd.path : firstCwd.path
        let target = SessionManager.create(targetCwd, sessions.path)
        target.appendMessage(.user(UserMessage(content: .text("saved"))))
        let path = try #require(target.getSessionFile())
        let trace = C2LifecycleTrace()
        let first = c2LifecycleSession(.inMemory(firstCwd.path), trace, "old")
        await first.startExtensions()
        trace.clear()
        let runtime = AgentSessionRuntime(agentDir: root.path, factory: { args in
            c2LifecycleSession(args.sessionManager, trace, "next")
        }, initialSession: first)
        runtime.setRebindSession { _ in trace.add("host:rebind") }
        _ = try await runtime.switchSessionRebinding(path)
        let events = trace.take()
        runtime.dispose()
        return events
    }

    @Test("streams entries appended by the startup session_start")
    func firstSessionOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("c2-lifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = C2LifecycleTrace()
        let session = c2LifecycleSession(.inMemory(root.path), trace, "first")
        defer { session.dispose() }
        session.hookRunner?.initialize(getModel: { [weak session] in session?.agent.state.model },
            appendEntryHandler: { [weak session] type, data in
                _ = session?.appendExtensionEntry(type, data)
            })
        await session.startExtensions()
        // v1.6.0 agent-session.ts:3448-3452: bind emits start, then discovers resources.
        #expect(trace.take() == [
            "first.host:session_start:startup",
            "first.extension:session_start:startup",
            "first.host:entry_appended",
            "first.host:resources_discover:startup",
            "first.extension:resources_discover:startup"
        ])
    }

    @Test("new_session")
    func factoryNewSessionOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("c2-lifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = C2LifecycleTrace()
        let first = c2LifecycleSession(.inMemory(root.path), trace, "old")
        await first.startExtensions()
        trace.clear()
        let runtime = AgentSessionRuntime(agentDir: root.path, factory: { args in
            c2LifecycleSession(args.sessionManager, trace, "next")
        }, initialSession: first)
        runtime.setBeforeSessionInvalidate { trace.add("host:beforeInvalidate") }
        runtime.setRebindSession { _ in trace.add("host:rebind") }
        _ = try await runtime.newSessionRebinding()
        // v1.6.0 agent-session-runtime.ts:209-269, agent-session.ts:3448-3452.
        #expect(trace.take() == [
            "old.host:session_before_switch:new",
            "old.extension:session_before_switch:new",
            "old.host:session_shutdown:new",
            "old.extension:session_shutdown:new",
            "host:beforeInvalidate",
            "host:rebind",
            "next.host:session_start:new",
            "next.extension:session_start:new",
            "next.host:entry_appended",
            "next.host:resources_discover:startup",
            "next.extension:resources_discover:startup"
        ])
        runtime.dispose()
    }

    @Test("honors session_before_switch cancellation")
    func newCancellationOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("c2-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = C2LifecycleTrace()
        let first = c2LifecycleSession(.inMemory(root.path), trace, "old")
        await first.startExtensions()
        trace.clear()
        let runtime = AgentSessionRuntime(agentDir: root.path, factory: { args in
            c2LifecycleSession(args.sessionManager, trace, "next")
        }, initialSession: first)
        trace.cancelSwitch.withLock { $0 = true }
        await #expect(throws: AgentSessionRuntimeError.self) {
            _ = try await runtime.newSessionRebinding()
        }
        #expect(runtime.session === first)
        // v1.6.0 agent-session-runtime-events.test.ts:159-181.
        #expect(trace.take() == [
            "old.host:session_before_switch:new",
            "old.extension:session_before_switch:new"
        ])
        runtime.dispose()
    }

    @Test("switch_session")
    func resumeOtherCwdOrder() async throws {
        // v1.6.0 agent-session-runtime.ts:223-245; agent-session.ts:3448-3452.
        #expect(try await switchTrace(targetIsOtherCwd: true) == [
            "old.host:session_before_switch:resume",
            "old.extension:session_before_switch:resume",
            "old.host:session_shutdown:resume",
            "old.extension:session_shutdown:resume",
            "host:rebind",
            "next.host:session_start:resume",
            "next.extension:session_start:resume",
            "next.host:entry_appended",
            "next.host:resources_discover:startup",
            "next.extension:resources_discover:startup"
        ])
    }

    @Test("switch_session in the same cwd emits one start after rebind")
    func resumeSameCwdOrder() async throws {
        // v1.6.0 agent-session-runtime.ts:223-245; same factory path for the same cwd.
        #expect(try await switchTrace(targetIsOtherCwd: false) == [
            "old.host:session_before_switch:resume",
            "old.extension:session_before_switch:resume",
            "old.host:session_shutdown:resume",
            "old.extension:session_shutdown:resume",
            "host:rebind",
            "next.host:session_start:resume",
            "next.extension:session_start:resume",
            "next.host:entry_appended",
            "next.host:resources_discover:startup",
            "next.extension:resources_discover:startup"
        ])
    }

    @Test("fork")
    func forkOrder() async throws {
        // v1.6.0 agent-session-runtime.ts:287-368; agent-session.ts:3448-3452.
        let actual = try await forkTrace(clone: false)
        #expect(actual == [
            "old.host:session_before_fork:before",
            "old.extension:session_before_fork:before",
            "old.host:session_shutdown:fork",
            "old.extension:session_shutdown:fork",
            "host:rebind",
            "next.host:session_start:fork",
            "next.extension:session_start:fork",
            "next.host:entry_appended",
            "next.host:resources_discover:startup",
            "next.extension:resources_discover:startup"
        ])
    }

    @Test("emits session_before_fork and honors cancellation")
    func forkCancellationOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("c2-fork-cancel-\(UUID())")
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = SessionManager.create(root.path, sessions.path)
        manager.appendMessage(.user(UserMessage(content: .text("fork here"))))
        let entryId = try #require(manager.getLeafId())
        let trace = C2LifecycleTrace()
        let first = c2LifecycleSession(manager, trace, "old")
        await first.startExtensions()
        trace.clear()
        let runtime = AgentSessionRuntime(agentDir: root.path, factory: { args in
            c2LifecycleSession(args.sessionManager, trace, "next")
        }, initialSession: first)
        trace.cancelFork.withLock { $0 = true }
        await #expect(throws: AgentSessionRuntimeError.self) {
            _ = try await runtime.forkRebinding(entryId)
        }
        #expect(runtime.session === first)
        // v1.6.0 agent-session-runtime-events.test.ts:229-267.
        #expect(trace.take() == [
            "old.host:session_before_fork:before",
            "old.extension:session_before_fork:before"
        ])
        runtime.dispose()
    }

    @Test("clone")
    func cloneOrder() async throws {
        // v1.6.0 agent-session-runtime.ts:287-368, position at; agent-session.ts:3448-3452.
        let actual = try await forkTrace(clone: true)
        #expect(actual == [
            "old.host:session_before_fork:at",
            "old.extension:session_before_fork:at",
            "old.host:session_shutdown:fork",
            "old.extension:session_shutdown:fork",
            "host:rebind",
            "next.host:session_start:fork",
            "next.extension:session_start:fork",
            "next.host:entry_appended",
            "next.host:resources_discover:startup",
            "next.extension:resources_discover:startup"
        ])
    }

    @Test("legacy clone uses the at fork position")
    func legacyClonePosition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("c2-legacy-clone-\(UUID())")
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = SessionManager.create(root.path, sessions.path)
        manager.appendMessage(.user(UserMessage(content: .text("clone"))))
        let trace = C2LifecycleTrace()
        let session = c2LifecycleSession(manager, trace, "legacy")
        defer { session.dispose() }
        await session.startExtensions()
        trace.clear()
        #expect(try await session.cloneAtLeaf())
        // v1.6.0 agent-session-runtime.ts:287-368: /clone sends position "at".
        #expect(trace.take() == [
            "legacy.host:session_before_fork:at",
            "legacy.extension:session_before_fork:at",
            "legacy.host:session_start:fork",
            "legacy.extension:session_start:fork",
            "legacy.host:entry_appended",
            "legacy.host:resources_discover:startup",
            "legacy.extension:resources_discover:startup"
        ])
    }

    @Test("emits session_start after reload when extensions were bound without bindings")
    func emptyBindingReloadOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("c2-lifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = C2LifecycleTrace()
        let session = c2LifecycleSession(.inMemory(root.path), trace, "reload")
        defer { session.dispose() }
        // startExtensions() is the empty binding: the constructor supplied core wiring.
        await session.startExtensions()
        trace.clear()
        _ = try await session.reloadWithExtensions()
        // v1.6.0 agent-session.ts:3867-3871: even an empty bind is bound.
        #expect(trace.take() == [
            "reload.host:session_shutdown:reload",
            "reload.extension:session_shutdown:reload",
            "reload.host:session_start:reload",
            "reload.extension:session_start:reload",
            "reload.host:entry_appended",
            "reload.host:resources_discover:reload",
            "reload.extension:resources_discover:reload"
        ])
    }
}
