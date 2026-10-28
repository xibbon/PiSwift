import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
import Synchronization
import Testing
@testable import PiSwiftDurable

private final class RoutingTimerHost: Sendable {
    struct Timer: Sendable { let id: Int; let delay: Double; let background: Bool; let callback: @Sendable () -> Void }
    private struct State: Sendable {
        var now: Int64 = 1000
        var nextID = 0
        var pending: [Int: Timer] = [:]
        var attempts: [(Double, Bool)] = []
    }
    private let state = Mutex(State())
    let declineBackground: Bool
    init(declineBackground: Bool = false) { self.declineBackground = declineBackground }
    var now: Int64 { get { state.withLock { $0.now } } set { state.withLock { $0.now = newValue } } }
    var pending: [Timer] { state.withLock { $0.pending.values.sorted { $0.id < $1.id } } }
    var backgroundAttempts: Int { state.withLock { $0.attempts.filter { $0.1 }.count } }
    var setTimer: HarnessSetTimer {
        { [self] callback, delay, options in
            let id = state.withLock { state -> Int? in
                state.attempts.append((delay, options.background))
                if options.background && declineBackground { return nil }
                state.nextID += 1
                let id = state.nextID
                state.pending[id] = Timer(id: id, delay: delay, background: options.background, callback: callback)
                return id
            }
            guard let id else { return nil }
            return { [self] in _ = state.withLock { $0.pending.removeValue(forKey: id) } }
        }
    }
    func fire(_ timer: Timer) {
        let pending = state.withLock { $0.pending.removeValue(forKey: timer.id) }
        pending?.callback()
    }
    func foreground(_ delay: Double) -> Timer? { pending.first { !$0.background && $0.delay == delay } }
    func background(_ delay: Double) -> Timer? { pending.first { $0.background && $0.delay == delay } }
}

@Test func sessionEvictionUsesHostTimeAndRechecksAnEarlyTimer() async throws {
    let host = RoutingTimerHost()
    let token = try SessionDocToken<JSONObject>(kind: "test.host-clock-retention", version: 1, initial: { ["value": 1] })
    let session = try await Session.open(storage: MemoryStorage(), now: { host.now }, documentRetentionMs: 500,
                                         setTimer: host.setTimer, context: .background)
    try await session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
    try await harnessEventually { host.background(500) != nil }
    #expect(session.documentCacheSizes.cached == 1)
    host.now = 1200
    host.fire(try #require(host.background(500)))
    try await harnessEventually { host.background(300) != nil }
    #expect(session.documentCacheSizes.cached == 1)
    host.now = 1500
    host.fire(try #require(host.background(300)))
    try await harnessEventually { session.documentCacheSizes.cached == 0 }
    try await session.close(context: .background)
}

@Test func sessionEvictionCanBeDeclinedWithoutAForegroundFallback() async throws {
    let host = RoutingTimerHost(declineBackground: true)
    let reports = SessionTestLog<String>()
    let token = try SessionDocToken<JSONObject>(kind: "test.host-clock-declined", version: 1, initial: { ["value": 1] })
    let session = try await Session.open(storage: MemoryStorage(), now: { host.now }, documentRetentionMs: 500,
        setTimer: host.setTimer, onReport: { reports.append(String(describing: $0)) }, context: .background)
    try await session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
    try await harnessEventually { host.backgroundAttempts == 1 }
    #expect(host.pending.isEmpty)
    #expect(reports.values.isEmpty)
    #expect(session.documentCacheSizes.cached == 1)
    try await session.close(context: .background)
}

@Test func generationPartialsAndContextEvictionUseTheHostClock() async throws {
    let host = RoutingTimerHost(), unusedClock = TestClock(now: 9000)
    let setup = HarnessChatSetup(settings: .init(progress: .init(partialIntervalMs: 100), contextRetentionMs: 700,
                                                documentRetentionMs: .infinity))
    let models = HarnessManualModels(base: setup.models)
    let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: models, registry: setup.registry,
        settings: setup.settingsProvider, clock: unusedClock, now: { host.now }, setTimer: host.setTimer,
        onReport: { setup.reports.append($0) }), context: .background)
    let root = try await harness.root(options: .init(agent: .init(model: .set(.init(provider: "faux", modelId: "faux-1")))), context: .background)
    let opened = OpenChatResult(harness: harness, root: root)
    let submission = try await generationSubmit(opened)
    try await harnessEventually { !models.seen.withLock { $0.isEmpty } }
    generationPartial(models, text: "partial")
    try await harnessEventually { host.foreground(100) != nil }
    #expect(unusedClock.pendingSleeperCount == 0)
    host.now = 1040
    host.fire(try #require(host.foreground(100)))
    try await harnessEventually { host.foreground(60) != nil }
    #expect(try await generationLive(opened)?.generation?.message == nil)
    host.now = 1100
    host.fire(try #require(host.foreground(60)))
    try await harnessEventually { try await generationLive(opened)?.generation?.message?["content"]?[0]?["text"] == "partial" }
    generationFinal(models)
    #expect(try await submission.wait(context: .background).status == "done")
    try await harness.waitForIdle(context: .background)
    try await harnessEventually { host.background(700) != nil }
    #expect(harness.tasks.state.withLock { $0.contexts[root.id] != nil })
    host.now = 1800
    host.fire(try #require(host.background(700)))
    try await harnessEventually { harness.tasks.state.withLock { $0.contexts[root.id] == nil } }
    #expect(unusedClock.now() == 9000)
    #expect(unusedClock.pendingSleeperCount == 0)
    #expect(setup.reports.values.isEmpty)
    try await harness.close(context: .background)
}

@Test func toolProgressUsesInvocationTimersAndTheHostClock() async throws {
    let host = RoutingTimerHost(declineBackground: true), unusedClock = TestClock(now: 9000)
    let setup = HarnessChatSetup(settings: .init(progress: .init(outputIntervalMs: 100), contextRetentionMs: 0,
                                                documentRetentionMs: .infinity))
    let next = HarnessChatSignal(), finish = HarnessChatSignal()
    let clockValues = SessionTestLog<Int64>()
    let tool = try ToolRegistration(name: "clock-output", description: "Writes output", parameters: ["type": "object"]) { _, api, _ in
        clockValues.append(try api.now())
        try api.output(.text("first"), nil)
        await next.wait()
        try api.output(.text(" second"), nil)
        await finish.wait()
        return .init()
    }
    try setup.registry.install(Extension(name: "clock-output", tools: [tool]))
    setup.models.setResponses([.message(try toolCalls([("clock-output", [:], "clock-call")])), .message(chatAssistant("done"))])
    let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: setup.models, registry: setup.registry,
        settings: setup.settingsProvider, clock: unusedClock, now: { host.now }, setTimer: host.setTimer,
        onReport: { setup.reports.append($0) }), context: .background)
    let root = try await harness.root(options: .init(agent: .init(model: .set(.init(provider: "faux", modelId: "faux-1")))), context: .background)
    let opened = OpenChatResult(harness: harness, root: root)
    let submission = try await generationSubmit(opened)
    try await harnessEventually { try await generationLive(opened)?.tools?.first?.output == "first" }
    host.now = 1040
    next.signal()
    try await harnessEventually { host.foreground(60) != nil }
    host.now = 1080
    host.fire(try #require(host.foreground(60)))
    try await harnessEventually { host.foreground(20) != nil }
    #expect(try await generationLive(opened)?.tools?.first?.output == "first")
    host.now = 1100
    host.fire(try #require(host.foreground(20)))
    try await harnessEventually { try await generationLive(opened)?.tools?.first?.output == "first second" }
    finish.signal()
    #expect(try await submission.wait(context: .background).status == "done")
    #expect(clockValues.values == [1000])
    #expect(unusedClock.now() == 9000)
    #expect(unusedClock.pendingSleeperCount == 0)
    #expect(setup.reports.values.isEmpty)
    try await harness.close(context: .background)
}
