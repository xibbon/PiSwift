import Foundation
import PiSwiftAgent
import PiSwiftAI

/// v0.65.0: closure-based session-replacement runtime.
///
/// Upstream removed `AgentSession.{newSession,switchSession,fork,importFromJsonl}` and replaced
/// them with an `AgentSessionRuntime` whose factory closure is invoked on every session switch.
/// The factory recreates cwd-bound services (auth storage, model registry, hooks, resource
/// loaders) per session so state doesn't leak across switches — particularly important when
/// `/fork` lands in a different worktree.
///
/// In the Swift port, the legacy `AgentSession.{newSession,switchSession,fork}` methods are
/// retained for source compatibility. The runtime is the recommended path forward and matches
/// the upstream extension migration shape (`session_start.reason` discriminator on the event).
///
/// The runtime supports two modes:
///   1. **Same-cwd replacement** (default): delegates to the existing `AgentSession` legacy
///      methods. No factory invocation. Cheap.
///   2. **Cross-cwd / full rebuild**: invokes the factory closure to construct a fresh session
///      against a new cwd / SessionManager. Use this for `/fork` into a different worktree
///      or `switchSession` into a session whose stored cwd differs from the current one.
///
/// SAFETY: mutable runtime state is stored in `LockedState`; the factory closure is
/// `@Sendable` and invoked from async methods that publish the replacement only after
/// construction succeeds.
public final class AgentSessionRuntime: Sendable {
    private let factory: CreateAgentSessionRuntimeFactory
    private let agentDirState: LockedState<String>
    private let sessionState: LockedState<AgentSession?>
    private let rebindState = LockedState<(@Sendable (AgentSession) async -> Void)?>(nil)

    public init(
        agentDir: String,
        factory: @escaping CreateAgentSessionRuntimeFactory,
        initialSession: AgentSession
    ) {
        self.factory = factory
        self.agentDirState = LockedState(agentDir)
        self.sessionState = LockedState(initialSession)
    }

    /// Build each replacement from the host's session options. The host supplies its
    /// inline configuration once; cwd-bound options must be made for each invocation.
    public convenience init(
        agentDir: String,
        initialSession: AgentSession,
        configure: @escaping @Sendable (AgentSessionRuntimeFactoryArgs) async throws -> CreateAgentSessionOptions,
        bindSession: @escaping @Sendable (AgentSession) -> Void = { _ in }
    ) {
        self.init(agentDir: agentDir, factory: { args in
            var options = try await configure(args)
            options.cwd = args.cwd
            options.agentDir = args.agentDir
            options.sessionManager = args.sessionManager
            let session = try await createAgentSession(options).session
            bindSession(session)
            return session
        }, initialSession: initialSession)
    }

    /// v1.5.2 agent-session-runtime.ts:189-196 (`finishSessionReplacement`): the host's mode
    /// binds its UI and handlers to the replacement here. The runtime awaits it after the
    /// swap and before it emits `session_start` on the new session.
    public func setRebindSession(_ handler: (@Sendable (AgentSession) async -> Void)?) {
        rebindState.withLock { $0 = handler }
    }

    /// The current live session. `nil` only after `dispose()`.
    public var session: AgentSession? {
        sessionState.withLock { $0 }
    }

    public var agentDir: String {
        agentDirState.withLock { $0 }
    }

    /// Create a fresh session within the current cwd / SessionManager.
    /// Equivalent to upstream `runtime.newSession()` for the common single-cwd case.
    /// Delegates to the existing `AgentSession.newSession(_:)` rather than re-creating
    /// the session entirely — fast path.
    @discardableResult
    public func newSession(_ options: NewSessionOptions? = nil) async -> Bool {
        guard let s = session else { return false }
        return await s.newSession(options)
    }

    /// Resume an existing session by file path.
    @discardableResult
    public func switchSession(_ sessionPath: String) async -> Bool {
        guard let s = session else { return false }
        return await s.switchSession(sessionPath)
    }

    /// Rebuild the complete session for the target cwd. A veto or a build error leaves
    /// the current session and its provider state live.
    @discardableResult
    public func switchSessionRebinding(_ sessionPath: String, cwdOverride: String? = nil) async throws -> AgentSession {
        let manager = try SessionManager.openValidated(sessionPath, nil, cwdOverride)
        if let issue = getMissingSessionCwdIssue(manager, fallbackCwd: session?.sessionManager.getCwd() ?? manager.getCwd()) {
            throw AgentSessionRuntimeError.missingSessionCwd(issue)
        }
        try await checkBeforeSwitch(sessionPath)
        return try await replaceSession(args: AgentSessionRuntimeFactoryArgs(
            cwd: manager.getCwd(), agentDir: agentDir, sessionManager: manager,
            sessionStartEvent: AgentSessionStartEvent(reason: .resume, previousSessionFile: session?.sessionFile)))
    }

    /// Create a fork and switch to it as one transaction. A veto or failed build
    /// removes the new file and keeps the old session active.
    @discardableResult
    public func forkAndSwitch(_ sourcePath: String, into cwd: String, sessionDir: String? = nil) async throws -> AgentSession {
        let manager = try SessionManager.forkFrom(sourcePath, cwd, sessionDir)
        guard let path = manager.getSessionFile() else { throw SessionManagerError.invalidSessionFile(sourcePath) }
        do {
            try await checkBeforeSwitch(path)
            return try await replaceSession(args: AgentSessionRuntimeFactoryArgs(
                cwd: cwd, agentDir: agentDir, sessionManager: manager,
                sessionStartEvent: AgentSessionStartEvent(reason: .fork, previousSessionFile: session?.sessionFile)),
                rollbackSessionFile: path)
        } catch {
            try? FileManager.default.removeItem(atPath: path)
            throw error
        }
    }

    /// Fork the conversation at the given entry id.
    @discardableResult
    public func fork(_ entryId: String) async throws -> (selectedText: String, cancelled: Bool) {
        guard let s = session else { return ("", true) }
        return try await s.fork(entryId)
    }

    public func importFromJsonl(_ inputPath: String, fallbackCwd: String? = nil) async throws -> HookCommandResult {
        guard let session else { return HookCommandResult(cancelled: true) }
        let source = URL(fileURLWithPath: (inputPath as NSString).expandingTildeInPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw SessionImportError.fileNotFound(source.path)
        }
        let sourceManager = try SessionManager.openValidated(source.path)
        if fallbackCwd == nil,
           let issue = getMissingSessionCwdIssue(sourceManager, fallbackCwd: session.sessionManager.getCwd()) {
            throw AgentSessionRuntimeError.missingSessionCwd(issue)
        }
        let dir = session.sessionManager.getSessionDir()
        let directory = URL(fileURLWithPath: dir.isEmpty ? URL(fileURLWithPath: getSessionsDir()).appendingPathComponent("imports").path : dir)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent(source.lastPathComponent).standardizedFileURL
        let stored = source == original
        var destination = original
        var suffix = 1
        if !stored {
            while FileManager.default.fileExists(atPath: destination.path) {
                let extensionPart = original.pathExtension.isEmpty ? "" : "." + original.pathExtension
                destination = directory.appendingPathComponent(original.deletingPathExtension().lastPathComponent + "-\(suffix)" + extensionPart)
                suffix += 1
            }
        }
        do {
            try await checkBeforeSwitch(destination.path)
            if !stored { try FileManager.default.copyItem(at: source, to: destination) }
            let manager = try SessionManager.openValidated(destination.path, directory.path, fallbackCwd)
            if let issue = getMissingSessionCwdIssue(manager, fallbackCwd: session.sessionManager.getCwd()) {
                throw AgentSessionRuntimeError.missingSessionCwd(issue)
            }
            _ = try await replaceSession(args: AgentSessionRuntimeFactoryArgs(
                cwd: manager.getCwd(), agentDir: agentDir, sessionManager: manager,
                sessionStartEvent: AgentSessionStartEvent(reason: .resume, previousSessionFile: session.sessionFile)))
            return HookCommandResult(cancelled: false)
        } catch {
            if !stored { try? FileManager.default.removeItem(at: destination) }
            if case AgentSessionRuntimeError.switchCancelled = error { return HookCommandResult(cancelled: true) }
            throw error
        }
    }

    /// Replace the current session with a freshly-built one. Use for cross-cwd switches
    /// where the existing session's services aren't valid in the new cwd.
    ///
    /// Calls the factory closure with `args` describing the target cwd / sessionManager
    /// and the `session_start` event the new session should observe.
    @discardableResult
    public func replaceSession(args: AgentSessionRuntimeFactoryArgs, rollbackSessionFile: String? = nil) async throws -> AgentSession {
        // Build before invalidating the current session. A failed factory leaves the live
        // session untouched and removes a provisional fork, when the caller supplied one.
        let next: AgentSession
        do {
            next = try await factory(args)
        } catch {
            if let rollbackSessionFile { try? FileManager.default.removeItem(atPath: rollbackSessionFile) }
            throw error
        }
        if let prev = session {
            await prev.abort()
            if let runner = prev.hookRunner {
                let reason = SessionShutdownReason(rawValue: args.sessionStartEvent.reason.rawValue) ?? .resume
                _ = await runner.emit(SessionShutdownEvent(reason: reason,
                    targetSessionFile: args.sessionManager.getSessionFile()))
            }
            prev.dispose()
        }
        sessionState.withLock { $0 = next }
        if let rebind = rebindState.withLock({ $0 }) { await rebind(next) }
        if let runner = next.hookRunner {
            let reason = SessionStartReason(rawValue: args.sessionStartEvent.reason.rawValue) ?? .resume
            _ = await runner.emit(SessionStartEvent(reason: reason,
                previousSessionFile: args.sessionStartEvent.previousSessionFile))
        }
        return next
    }

    private func checkBeforeSwitch(_ targetSessionFile: String) async throws {
        guard let runner = session?.hookRunner, runner.hasHandlers("session_before_switch") else { return }
        let result = await runner.emit(SessionBeforeSwitchEvent(reason: .resume, targetSessionFile: targetSessionFile))
        if (result as? SessionBeforeSwitchResult)?.cancel == true {
            throw AgentSessionRuntimeError.switchCancelled
        }
    }

    /// Continue a session with a missing stored cwd in the host's current directory.
    /// The session header stays unchanged, so resume asks again next time.
    @discardableResult
    public func continueMissingCwd(_ sourcePath: String, in fallbackCwd: String) async throws -> AgentSession {
        let manager = try SessionManager.openValidated(sourcePath, nil, fallbackCwd)
        guard getMissingSessionCwdIssue(SessionManager.open(sourcePath), fallbackCwd: fallbackCwd) != nil else {
            throw AgentSessionRuntimeError.sessionCwdExists
        }
        try await checkBeforeSwitch(sourcePath)
        return try await replaceSession(args: AgentSessionRuntimeFactoryArgs(
            cwd: fallbackCwd, agentDir: agentDir, sessionManager: manager,
            sessionStartEvent: AgentSessionStartEvent(reason: .resume, previousSessionFile: session?.sessionFile)))
    }

    /// Fork a session with a missing stored cwd into the host's current directory.
    /// The fork gets a new ID; failure in the factory removes its provisional file.
    @discardableResult
    public func forkMissingCwd(_ sourcePath: String, into fallbackCwd: String,
                               sessionDir: String? = nil) async throws -> AgentSession {
        let source = try SessionManager.openValidated(sourcePath)
        guard getMissingSessionCwdIssue(source, fallbackCwd: fallbackCwd) != nil else {
            throw AgentSessionRuntimeError.sessionCwdExists
        }
        return try await forkAndSwitch(sourcePath, into: fallbackCwd, sessionDir: sessionDir)
    }

    /// Abort the current run, settle its tool results, release session resources, then wait for
    /// credential writes already in progress. Disposal never starts an OAuth refresh.
    public func disposeAndWait() async {
        if let session {
            let registry = session.modelRegistry
            await session.abort()
            session.dispose()
            await registry.settleCredentialWrites()
        }
        sessionState.withLock { $0 = nil }
    }

    /// Tear down the runtime and the live session synchronously. This compatibility API does not
    /// wait for tool settlement or pending credential writes; use `disposeAndWait()` for shutdown.
    public func dispose() {
        if let s = session {
            s.dispose()
        }
        sessionState.withLock { $0 = nil }
    }
}

public enum AgentSessionRuntimeError: LocalizedError, Sendable {
    case sessionCwdExists
    case missingSessionCwd(SessionCwdIssue)
    case switchCancelled

    public var errorDescription: String? {
        switch self {
        case .sessionCwdExists: return "Stored session working directory exists."
        case .missingSessionCwd(let issue): return issue.errorMessage
        case .switchCancelled: return "Session switch cancelled"
        }
    }
}

/// Arguments passed to the runtime factory closure on every session creation/switch.
public struct AgentSessionRuntimeFactoryArgs: Sendable {
    public var cwd: String
    public var agentDir: String
    public var sessionManager: SessionManager
    public var sessionStartEvent: AgentSessionStartEvent

    public init(cwd: String, agentDir: String, sessionManager: SessionManager, sessionStartEvent: AgentSessionStartEvent) {
        self.cwd = cwd
        self.agentDir = agentDir
        self.sessionManager = sessionManager
        self.sessionStartEvent = sessionStartEvent
    }
}

/// Factory closure type. Builds an `AgentSession` for the given runtime args.
public typealias CreateAgentSessionRuntimeFactory = @Sendable (AgentSessionRuntimeFactoryArgs) async throws -> AgentSession

/// v0.65.0 + v0.69.0: session_start lifecycle event with reason discriminator.
///
/// Replaces the legacy `session_switch` and `session_fork` events. Extensions can distinguish
/// "startup" (initial load), "reload" (settings/extension reload), "new" (`/new`),
/// "resume" (`/resume`, also import), and "fork" (`/fork`, `/clone`).
public struct AgentSessionStartEvent: Sendable {
    public enum Reason: String, Sendable {
        case startup
        case reload
        case new
        case resume
        case fork
    }

    public var reason: Reason
    /// Previous session file path. Set for `.new`, `.resume`, `.fork`. Nil for `.startup` / `.reload`.
    public var previousSessionFile: String?

    public init(reason: Reason, previousSessionFile: String? = nil) {
        self.reason = reason
        self.previousSessionFile = previousSessionFile
    }
}

/// Convenience constructor.
public func createAgentSessionRuntime(
    agentDir: String,
    initialSession: AgentSession,
    factory: @escaping CreateAgentSessionRuntimeFactory
) -> AgentSessionRuntime {
    AgentSessionRuntime(
        agentDir: agentDir,
        factory: factory,
        initialSession: initialSession
    )
}

public enum SessionImportError: LocalizedError, Sendable {
    case fileNotFound(String)
    public var errorDescription: String? {
        switch self { case .fileNotFound(let path): return "File not found: \(path)" }
    }
}
