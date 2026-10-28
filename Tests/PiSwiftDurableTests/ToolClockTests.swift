import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting
import Synchronization
import Testing

@Test func handBuiltToolApiUsesItsExplicitClock() throws {
    let time = Mutex<Int64>(1234)
    let api = ToolExecutionApi(taskId: try TaskID(2), conversationId: rootConversationID, callId: "clock",
                               registry: .init(), models: FakeDurableModels(), now: { time.withLock { $0 } }, agent: { _ in Agent() })
    #expect(try api.now() == 1234)
    time.withLock { $0 = 2345 }
    #expect(try api.now() == 2345)
}

@Test func codemodeUsesHarnessTimeForStartDeliveryAndWallTime() async throws {
    let time = Mutex<Int64>(5000)
    let seen = Mutex<[Int64]>([])
    let sandbox = DeterministicCodemodeSandbox { state in
        if state.seq == 0 {
            #expect(state.now == 5000)
            return .init(calls: [.init(target: .global, name: "advance", args: nil)])
        }
        #expect(state.now == 5250)
        #expect(state.deliveries.last?.now == 5250)
        return .init(result: .init(value: .number(state.now)))
    }
    let setup = HarnessChatSetup()
    let global = CodemodeGlobal(name: "advance") { _, api, _ in
        let initial = try api.now()
        seen.withLock { $0.append(initial) }
        time.withLock { $0 += 250 }
        return .number(Double(try api.now()))
    }
    try setup.registry.install(createCodemodeExtension(options: .init(sandbox: sandbox, models: false, globals: [global])))
    setup.models.setResponses([.message(e10Call()), .message(chatAssistant("done"))])
    let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: setup.models, registry: setup.registry,
        settings: setup.settingsProvider, now: { time.withLock { $0 } }, onReport: { setup.reports.append($0) }), context: .background)
    let root = try await harness.root(options: .init(agent: .init(model: .set(.init(provider: "faux", modelId: "faux-1")))), context: .background)
    let submission = try await root.submit(.input(content: .text("go")), context: .background)
    #expect(try await submission.wait(context: .background).status == "done")
    try await harness.waitForIdle(context: .background)
    #expect(seen.withLock { $0 } == [5000])
    #expect(await sandbox.starts.first?.options.startedAt == 5000)
    let message = try await e10Message(root)
    #expect(e10Text(message).contains("Wall time 0.3 seconds"))
    #expect(setup.reports.values.isEmpty)
    try await harness.close(context: .background)
}
