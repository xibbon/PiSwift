import Synchronization
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable

/// Model scripts, settings, and registry retained across a Harness reopen.
public final class HarnessChatSetup: Sendable {
    public let models: FakeDurableModels
    public let registry: Registry
    public let reports = HarnessReports()
    public let clock: any DurableClock
    private let settingsState: Mutex<HarnessSettings>
    public init(options: FauxRegistrationOptions = .init(), registry: Registry = createRegistry(),
                settings: HarnessSettings = .init(), clock: any DurableClock = SystemDurableClock()) {
        models = FakeDurableModels(options: options)
        self.registry = registry; self.clock = clock; settingsState = Mutex(settings)
    }
    public var settings: HarnessSettings { settingsState.withLock { $0 } }
    public func updateSettings(_ change: (inout HarnessSettings) -> Void) { settingsState.withLock { change(&$0) } }
    public var settingsProvider: HarnessSettingsProvider { HarnessSettingsProvider { [self] in settings } }
}

public struct OpenChatResult: Sendable {
    public let harness: Harness
    public let root: Conversation
    public init(harness: Harness, root: Conversation) { self.harness = harness; self.root = root }
}

public func openChat(storage: any DurableStorage = MemoryStorage(), setup: HarnessChatSetup,
                     models: (any DurableModels)? = nil,
                     context: ChordContext = .background) async throws -> OpenChatResult {
    let harness = try await Harness.open(storage: storage,
        options: HarnessOptions(models: models ?? setup.models, registry: setup.registry,
            settings: setup.settingsProvider, clock: setup.clock, onReport: { setup.reports.append($0) }), context: context)
    let root = try await harness.root(options: .init(agent: AgentChange(model: .set(ModelRef(provider: "faux", modelId: "faux-1")))), context: context)
    return OpenChatResult(harness: harness, root: root)
}

public func allEntries(_ conversation: Conversation, context: ChordContext = .background) async throws -> [EntryRecord] {
    try await scanAll { cursor in
        try await conversation.entries(order: .ascending, limit: 1000, cursor: cursor, context: context)
    }
}

public func chatAssistant(_ text: String, reason: StopReason = .stop, error: String? = nil) -> AssistantMessage {
    AssistantMessage(content: [.text(TextContent(text: text))], api: .openAICompletions, provider: "faux", model: "faux-1",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: reason,
        errorMessage: error, timestamp: 1)
}

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
    public init() {}
    public var isSignalled: Bool { state.withLock { $0.signalled } }
    public func wait() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { value in
                if value.signalled { return true }
                value.waiters.append(continuation); return false
            }
            if ready { continuation.resume() }
        }
    }
    public func signal() {
        let waiters = state.withLock { value in
            value.signalled = true; let waiters = value.waiters; value.waiters.removeAll(); return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// A model step that holds the request until its cancellation token is signalled.
public struct HarnessUnanswered: Sendable {
    public let reached = HarnessChatSignal()
    public init() {}
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
    public let reached = HarnessChatSignal()
    private let gate = HarnessChatSignal()
    private let message: AssistantMessage
    public init(message: AssistantMessage) { self.message = message }
    public func release() { gate.signal() }
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
