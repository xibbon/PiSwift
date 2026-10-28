import Testing
import Synchronization
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

struct E2HarnessModelsTests {
    // Upstream harness-host-inputs.test.ts:52,61.
    @Test(arguments: [false, true]) func generationReadsCurrentModels(dynamic: Bool) async throws {
        let first = FakeDurableModels(responses: [.message(chatAssistant("first"))])
        let second = FakeDurableModels(responses: [.message(chatAssistant("second"))])
        let current = Mutex<any DurableModels>(first)
        let options: HarnessOptions
        if dynamic { options = .init(models: { current.withLock { $0 } }, registry: createRegistry()) }
        else { options = .init(models: first, registry: createRegistry()) }
        let opened = try await open(options)
        #expect(try await turn(opened.root) == "first")
        if dynamic {
            current.withLock { $0 = second }
            #expect(try await turn(opened.root) == "second")
        }
        try await opened.harness.close(context: .background)
    }

    // Upstream harness-host-inputs.test.ts:67; hooks use the same live getter.
    @Test func toolsAndHooksReadModelsAgainAtEachAccess() async throws {
        let setup = HarnessChatSetup()
        let second = FakeDurableModels(options: .init(provider: "second-only"))
        let current = Mutex<any DurableModels>(setup.models)
        let seen = Mutex<[Bool]>([])
        try installHarnessTool(harnessTestTool("probe", execute: { _, api, _ in
            seen.withLock { $0.append(api.models.getModel(provider: "second-only", modelId: "faux-1") != nil) }
            current.withLock { $0 = second }
            seen.withLock { $0.append(api.models.getModel(provider: "second-only", modelId: "faux-1") != nil) }
            current.withLock { $0 = setup.models }
            return .init(output: [])
        }), setup: setup)
        try setup.registry.install(Extension(name: "hook-probe", hooks: [hook(ToolHooks(beforeTool: { _, api, _ in
            seen.withLock { $0.append(api.models.getModel(provider: "second-only", modelId: "faux-1") != nil) }
            current.withLock { $0 = second }
            seen.withLock { $0.append(api.models.getModel(provider: "second-only", modelId: "faux-1") != nil) }
            current.withLock { $0 = setup.models }
            return nil
        }))]))
        setup.models.setResponses([.message(try toolCalls([("probe", [:], "c1")])), .message(chatAssistant("done"))])
        let opened = try await open(.init(models: { current.withLock { $0 } }, registry: setup.registry))
        #expect(try await turn(opened.root) == "done")
        #expect(seen.withLock { $0 } == [false, true, false, true])
        try await opened.harness.close(context: .background)
    }

    // Upstream harness-host-inputs.test.ts:107.
    @Test func generationReadsCurrentSettings() async throws {
        let setup = HarnessChatSetup(settings: .init(stream: .init(timeoutMs: 1000)))
        let timeouts = Mutex<[Int?]>([])
        setup.models.setResponses((0..<2).map { _ in .factory { _, options, _, _ in
            timeouts.withLock { $0.append(options?.timeoutMs) }; return chatAssistant("ok")
        } })
        let opened = try await openChat(setup: setup)
        _ = try await turn(opened.root)
        setup.updateSettings { $0.stream = .init(timeoutMs: 2000) }
        _ = try await turn(opened.root)
        #expect(timeouts.withLock { $0 } == [1000, 2000])
        try await opened.harness.close(context: .background)
    }

    @Test func requestKeepsCheckpointOptionsWhileModelsChangeInHook() async throws {
        let setup = HarnessChatSetup(settings: .init(stream: .init(timeoutMs: 1000)))
        let second = FakeDurableModels()
        let current = Mutex<any DurableModels>(setup.models)
        let seen = Mutex<[Int?]>([])
        second.setResponses([.factory { _, options, _, _ in
            seen.withLock { $0.append(options?.timeoutMs) }; return chatAssistant("second")
        }])
        try setup.registry.install(Extension(name: "swap-models", hooks: [hook(GenerationHooks(beforeRequest: { _, _, _ in
            current.withLock { $0 = second }
            setup.updateSettings { $0.stream = .init(timeoutMs: 2000) }
            return nil
        }))]))
        let opened = try await open(.init(models: { current.withLock { $0 } }, registry: setup.registry, settings: setup.settingsProvider))
        #expect(try await turn(opened.root) == "second")
        #expect(seen.withLock { $0 } == [1000])
        #expect(setup.models.state().callCount == 0)
        try await opened.harness.close(context: .background)
    }

    @Test func compactionReadsCurrentModelsAndSendsIdentity() async throws {
        let first = FakeDurableModels(responses: (0..<3).map { _ in .message(chatAssistant(String(repeating: "history ", count: 50))) })
        let second = FakeDurableModels()
        let current = Mutex<any DurableModels>(first)
        let seen = Mutex<[SimpleStreamOptions?]>([])
        second.setResponses([.factory { _, options, _, _ in
            seen.withLock { $0.append(options) }; return chatAssistant("summary")
        }])
        let settings = HarnessSettingsProvider { .init(stream: .init(timeoutMs: 1234),
            compaction: .init(enabled: false, reserveTokens: 1000, keepRecentTokens: 1, backgroundTokens: 0)) }
        let opened = try await open(.init(models: { current.withLock { $0 } }, registry: createRegistry(),
            identity: .init(userAgent: .short), settings: settings))
        for _ in 0..<3 { _ = try await turn(opened.root) }
        current.withLock { $0 = second }
        let id = try await opened.root.compact(context: .background)
        #expect(try await opened.harness.waitForTask(id: id, context: .background).outcome.status == "completed")
        let requests = seen.withLock { $0 }
        #expect(requests.count == 1)
        #expect(requests.first??.identity == ClientIdentity(userAgent: .short, attribution: .value(PI_ATTRIBUTION)))
        #expect(requests.first??.timeoutMs == 1234)
        try await opened.harness.close(context: .background)
    }

    @Test func providerFailureReportsModelsHostError() async throws {
        let reports = Mutex<[ReportInfo]>([]), fail = Mutex(true)
        let recovered = FakeDurableModels(responses: [.message(chatAssistant("recovered"))])
        let opened = try await open(.init(models: {
            if fail.withLock({ $0 }) { throw TaskDefinitionError("models failed") }
            return recovered
        }, registry: createRegistry(),
            onReport: { _, info in reports.withLock { $0.append(info) } }))
        let settled = try await opened.root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        #expect(settled.status == "unanswered")
        let seen = reports.withLock { $0 }
        #expect(!seen.isEmpty)
        for info in seen {
            if case .hostError(let callback, let task) = info {
                #expect(callback == .models)
                #expect(task?.conversationId == opened.root.id)
            } else { Issue.record("A model provider failure must be a host error") }
        }
        #expect(opened.harness.failure == nil)
        fail.withLock { $0 = false }
        #expect(try await turn(opened.root) == "recovered")
        try await opened.harness.close(context: .background)
    }

    // Upstream harness-generation.test.ts:389.
    @Test func generationUsesPiIdentityAndHostOverrides() async throws {
        let acme = ClientAttribution(name: "acme", url: "https://acme.example")
        for host in [nil, ClientIdentity(userAgent: .short, attribution: .value(acme)), ClientIdentity(attribution: .disabled)] {
            let models = FakeDurableModels()
            let seen = Mutex<[ClientIdentity?]>([])
            models.setResponses([.factory { _, options, _, _ in
                seen.withLock { $0.append(options?.identity) }
                return chatAssistant("ok")
            }])
            let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: models,
                registry: createRegistry(), identity: host), context: .background)
            let root = try await harness.root(options: .init(agent: .init(model: .set(.init(provider: "faux", modelId: "faux-1")))), context: .background)
            let settled = try await root.submit(.input(content: .text("hi")), context: .background).wait(context: .background)
            #expect(settled.status == "done")
            #expect(seen.withLock { $0 } == [mergeClientIdentity(DEFAULT_HARNESS_IDENTITY, host)])
            try await harness.close(context: .background)
        }
    }

    // Upstream harness-tools.test.ts:681 (#10858).
    @Test func terminateFalseContinuesGeneration() async throws {
        let setup = HarnessChatSetup()
        try installHarnessTool(harnessTestTool("keep", execute: { _, _, _ in
            ToolExecutionResult(output: [], control: .init(terminate: false))
        }), setup: setup)
        let (opened, entries) = try await runHarnessTools(setup, calls: [("keep", [:], "c1")])
        #expect(entries.last?.kind == assistantEntry.kind)
        #expect(textOf(try entries.last?.messages()?.first) == "done")
        #expect(setup.models.state().callCount == 2)
        try await opened.harness.close(context: .background)
    }

    private func open(_ options: HarnessOptions) async throws -> OpenChatResult {
        let harness = try await Harness.open(storage: MemoryStorage(), options: options, context: .background)
        let root = try await harness.root(options: .init(agent: .init(model: .set(.init(provider: "faux", modelId: "faux-1")))), context: .background)
        return .init(harness: harness, root: root)
    }

    private func turn(_ root: Conversation) async throws -> String? {
        let result = try await root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        #expect(result.status == "done")
        return textOf(try await allEntries(root).last?.messages()?.first)
    }
}
