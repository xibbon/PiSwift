import Foundation
import PiSwiftAI
import PiSwiftAgent
import Testing
@testable import PiSwiftCodingAgent

@Suite("v1.6.0 pi.events handler errors", .timeLimit(.minutes(1)))
struct C2EventBusErrorsTests {
    @Test("reports a throwing handler to the extension error listener instead of stderr")
    func reportsThrowingHandlerToExtensionErrorListener() async throws {
        let bus = EventBusDriver()
        let session = try makeSession(bus: bus) { api in
            api.events.on("test:boom") { _ in throw HandlerError("handler failed") }
        }
        defer { session.dispose() }
        let runner = try #require(session.hookRunner)
        let errors = LockedState<[HookError]>([])
        _ = runner.onError { error in errors.withLock { $0.append(error) } }

        // An error that escapes this callback would reach the base bus's stderr fallback.
        let handler = try bus.handler(for: "test:boom")
        try await handler(nil)

        let reports = errors.withLock { $0 }
        #expect(reports.count == 1)
        let report = try #require(reports.first)
        #expect(report.hookPath == "<inline:boom>")
        #expect(report.event == "events:test:boom")
        #expect(report.error == "handler failed")
        #expect(report.stack?.isEmpty == false)
    }

    @Test("drops an error from a handler that fails after its session was disposed")
    func dropsErrorAfterSessionDisposal() async throws {
        let gate = HandlerGate()
        let bus = EventBusDriver()
        let session = try makeSession(bus: bus, factory: gate.register)
        defer { session.dispose() }
        let runner = try #require(session.hookRunner)
        let errors = LockedState<[HookError]>([])
        let unsubscribe = runner.onError { error in errors.withLock { $0.append(error) } }
        defer { unsubscribe() }

        let handler = try bus.handler(for: "test:late")
        let delivery = Task { try await handler(nil) }
        await gate.waitUntilEntered()
        session.dispose()
        gate.release()
        try await delivery.value

        #expect(errors.withLock { $0 }.isEmpty)
    }

    @Test("drops a pending error after an in-place session switch and return")
    func dropsErrorAfterReturningToTheOriginalSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SessionManager.create(directory.path, directory.path)
        let originalId = manager.getSessionId()
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        manager.appendMessage(.assistant(AssistantMessage(
            content: [.text(TextContent(text: "original"))], api: model.api, provider: model.provider, model: model.id,
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop
        )))
        let path = try #require(manager.getSessionFile())
        let gate = HandlerGate()
        let bus = EventBusDriver()
        let session = try makeSession(bus: bus, manager: manager, factory: gate.register)
        defer { session.dispose() }
        let runner = try #require(session.hookRunner)
        let errors = LockedState<[HookError]>([])
        _ = runner.onError { error in errors.withLock { $0.append(error) } }

        let handler = try bus.handler(for: "test:late")
        let delivery = Task { try await handler(nil) }
        await gate.waitUntilEntered()
        let didCreate = await session.newSession()
        let didReturn = await session.switchSession(path)
        gate.release()
        try await delivery.value

        #expect(didCreate && didReturn)
        #expect(session.sessionId == originalId)
        #expect(session.hookRunner === runner)
        #expect(errors.withLock { $0 }.isEmpty)
    }

    private func makeSession(
        bus: EventBusDriver,
        manager: SessionManager = .inMemory(),
        factory: @escaping @Sendable (HookAPI) -> Void
    ) throws -> AgentSession {
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        let registry = ModelRegistry(.inMemory())
        let loaded = ExtensionLoader.load(InlineExtension(name: "boom", factory: factory),
                                          cwd: manager.getCwd(), eventBus: bus)
        let hook = try #require(loaded.hook)
        let runner = HookRunner([hook], manager.getCwd(), manager, registry)
        let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "", model: model, tools: [])))
        return AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager,
            settingsManager: .inMemory(), resourceLoader: TestResourceLoader(), hookRunner: runner, modelRegistry: registry))
    }
}

private struct HandlerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) {
        self.message = message
    }
}

private final class EventBusDriver: EventBus {
    private let handlers = LockedState<[String: [UUID: EventBusHandler]]>([:])

    func on(_ channel: String, _ handler: @escaping EventBusHandler) -> @Sendable () -> Void {
        let id = UUID()
        handlers.withLock { $0[channel, default: [:]][id] = handler }
        return { [weak self] in
            self?.handlers.withLock { $0[channel]?[id] = nil }
        }
    }

    func emit(_ channel: String, _ data: (any Sendable)?) {
        let snapshot = handlers.withLock { $0[channel] ?? [:] }
        for handler in snapshot.values {
            Task { try? await handler(data) }
        }
    }

    // Await a full delivery and detect a throw without redirecting process-wide stderr.
    func handler(for channel: String) throws -> EventBusHandler {
        try #require(handlers.withLock { $0[channel]?.values.first })
    }
}

private struct HandlerGate: Sendable {
    private let entered = AsyncStream<Void>.makeStream()
    private let released = AsyncStream<Void>.makeStream()

    func register(_ api: HookAPI) {
        api.events.on("test:late") { _ in
            entered.continuation.yield(())
            var iterator = released.stream.makeAsyncIterator()
            _ = await iterator.next()
            throw HandlerError("late failure")
        }
    }

    func waitUntilEntered() async {
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() {
        released.continuation.finish()
    }
}
