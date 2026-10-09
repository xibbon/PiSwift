import Synchronization
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable

/// Model scripts, settings, and registry retained across a Harness reopen.
public final class HarnessChatSetup: Sendable {
    /// The model service used by this harness or task.
    public let models: FakeDurableModels
    /// The installed extension and task definitions used by this harness.
    public let registry: Registry
    /// Errors captured from concurrent test handlers.
    public let reports = HarnessReports()
    /// The time source used for task sleeps and retry deadlines.
    public let clock: any DurableClock
    private let settingsState: Mutex<HarnessSettings>
    /// Creates fake model scripts and settings that can survive a harness reopen.
    public init(options: FauxRegistrationOptions = .init(), registry: Registry = createRegistry(),
                settings: HarnessSettings = .init(), clock: any DurableClock = SystemDurableClock()) {
        models = FakeDurableModels(options: options)
        self.registry = registry; self.clock = clock; settingsState = Mutex(settings)
    }
    /// The current host settings or resolved task settings.
    public var settings: HarnessSettings { settingsState.withLock { $0 } }
    /// Changes the test settings under their synchronization lock.
    public func updateSettings(_ change: (inout HarnessSettings) -> Void) { settingsState.withLock { change(&$0) } }
    /// A callback that reads the test settings at the next policy check.
    public var settingsProvider: HarnessSettingsProvider { HarnessSettingsProvider { [self] in settings } }
}

/// An opened test harness and its root conversation.
public struct OpenChatResult: Sendable {
    /// The opened harness returned by test setup.
    public let harness: Harness
    /// The root conversation returned by test setup.
    public let root: Conversation
    /// Pairs an opened test harness with its root conversation.
    public init(harness: Harness, root: Conversation) { self.harness = harness; self.root = root }
}

/// Opens a faux-model test harness and configures its root conversation.
public func openChat(storage: any DurableStorage = MemoryStorage(), setup: HarnessChatSetup,
                     models: (any DurableModels)? = nil,
                     context: ChordContext = .background) async throws -> OpenChatResult {
    let harness = try await Harness.open(storage: storage,
        options: HarnessOptions(models: models ?? setup.models, registry: setup.registry,
            settings: setup.settingsProvider, clock: setup.clock, onReport: { setup.reports.append($0) }), context: context)
    let root = try await harness.root(options: .init(agent: AgentChange(model: .set(ModelRef(provider: "faux", modelId: "faux-1")))), context: context)
    return OpenChatResult(harness: harness, root: root)
}

/// Reads all visible entries in ascending order for a test conversation.
public func allEntries(_ conversation: Conversation, context: ChordContext = .background) async throws -> [EntryRecord] {
    try await scanAll { cursor in
        try await conversation.entries(order: .ascending, limit: 1000, cursor: cursor, context: context)
    }
}

/// Creates a text response from the deterministic faux model for a test.
public func chatAssistant(_ text: String, reason: StopReason = .stop, error: String? = nil) -> AssistantMessage {
    AssistantMessage(content: [.text(TextContent(text: text))], api: .openAICompletions, provider: "faux", model: "faux-1",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: reason,
        errorMessage: error, timestamp: 1)
}

/// Returns the first text block of a user, assistant, or tool-result message.
public func textOf(_ message: Message?) -> String? {
    switch message {
    case .user(let message):
        if case .text(let text) = message.content { return text }
        if case .blocks(let blocks) = message.content { return blocks.compactMap { if case .text(let text) = $0 { text.text } else { nil } }.first }
        return nil
    case .assistant(let message): return message.content.compactMap { if case .text(let text) = $0 { text.text } else { nil } }.first
    case .toolResult(let message): return message.content.compactMap { if case .text(let text) = $0 { text.text } else { nil } }.first
    default: return nil
    }
}

/// One signal that can be awaited before or after it fires.
public final class HarnessChatSignal: Sendable {
    private struct State: Sendable {
        var signalled = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())
    /// Creates a signal that has not yet fired.
    public init() {}
    /// Whether this test signal has fired.
    public var isSignalled: Bool { state.withLock { $0.signalled } }
    /// Waits until signal() fires; a prior signal completes this wait immediately.
    public func wait() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { value in
                if value.signalled { return true }
                value.waiters.append(continuation); return false
            }
            if ready { continuation.resume() }
        }
    }
    /// Releases current waiters and makes later waits complete immediately.
    public func signal() {
        let waiters = state.withLock { value in
            value.signalled = true; let waiters = value.waiters; value.waiters.removeAll(); return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// A model step that holds the request until its cancellation token is signalled.
public struct HarnessUnanswered: Sendable {
    /// Fires when the scripted model step starts.
    public let reached = HarnessChatSignal()
    /// Creates a model step that waits for request cancellation.
    public init() {}
    /// The scripted model callback supplied by this test gate.
    public var step: FakeDurableResponseStep {
        .factory { [reached] _, options, _, _ in
            reached.signal()
            guard let token = options?.signal else { throw TestDeadlineError() }
            let cancelled = HarnessChatSignal()
            let remove = token.onCancel { cancelled.signal() }
            defer { remove() }
            await cancelled.wait()
            throw CancellationError()
        }
    }
}

/// A response with an explicit release signal. Cancellation also ends the wait.
public final class HarnessGatedResponse: Sendable {
    /// Fires when the scripted model step starts.
    public let reached = HarnessChatSignal()
    private let gate = HarnessChatSignal()
    private let message: AssistantMessage
    /// Stores the response released by this explicit test gate.
    public init(message: AssistantMessage) { self.message = message }
    /// Releases all test operations waiting at this gate.
    public func release() { gate.signal() }
    /// The scripted model callback supplied by this test gate.
    public var step: FakeDurableResponseStep {
        .factory { [self] _, options, _, _ in
            reached.signal()
            let remove = options?.signal?.onCancel { self.gate.signal() }
            defer { remove?() }
            await gate.wait()
            if options?.signal?.isCancelled == true { throw CancellationError() }
            return message
        }
    }
}
