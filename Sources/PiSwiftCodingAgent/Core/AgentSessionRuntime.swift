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
public final class AgentSessionRuntime: @unchecked Sendable {
    private let factory: CreateAgentSessionRuntimeFactory
    private let agentDirState: LockedState<String>
    private let sessionState: LockedState<AgentSession?>

    public init(
        agentDir: String,
        factory: @escaping CreateAgentSessionRuntimeFactory,
        initialSession: AgentSession
    ) {
        self.factory = factory
        self.agentDirState = LockedState(agentDir)
        self.sessionState = LockedState(initialSession)
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

    /// Fork the conversation at the given entry id.
    @discardableResult
    public func fork(_ entryId: String) async throws -> (selectedText: String, cancelled: Bool) {
        guard let s = session else { return ("", true) }
        return try await s.fork(entryId)
    }

    /// Replace the current session with a freshly-built one. Use for cross-cwd switches
    /// where the existing session's services aren't valid in the new cwd.
    ///
    /// Calls the factory closure with `args` describing the target cwd / sessionManager
    /// and the `session_start` event the new session should observe.
    @discardableResult
    public func replaceSession(args: AgentSessionRuntimeFactoryArgs) async throws -> AgentSession {
        if let prev = session {
            await prev.abort()
            prev.dispose()
        }
        let next = try await factory(args)
        sessionState.withLock { $0 = next }
        return next
    }

    /// Tear down the runtime and the live session.
    public func dispose() {
        if let s = session {
            s.dispose()
        }
        sessionState.withLock { $0 = nil }
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
