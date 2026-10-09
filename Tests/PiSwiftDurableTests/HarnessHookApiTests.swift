import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessHookApiTests {
    @Test func hookApiSharesRuntimeMemosAndReadsAndEndsWithInvocation() async throws {
        let token = try SessionDocToken<JSONObject>(kind: "h5.hook-api", version: 1, initial: { ["text": "committed"] })
        let retained = Mutex<HookApi?>(nil)
        let definition = harnessOneStep("h5.hook-api") { _, runtime, context in
            let api = runtime.hookApi
            retained.withLock { $0 = api }
            #expect(api.taskId == runtime.taskId); #expect(api.conversationId == runtime.conversationId)
            let apiModels = try #require(api.models as? FakeDurableModels)
            let runtimeModels = try #require(runtime.models as? FakeDurableModels)
            #expect(apiModels === runtimeModels)
            let value = try await api.read.snapshot(token, context: context)
            #expect(value == ["text": "committed"])
            let first = try await api.memo("shared", .number(7), context)
            let second = try await runtime.memo("shared", value: .number(9), context: context)
            #expect(first == .number(7)); #expect(second == .number(7))
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)])
        try await harness.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        let root = try await harness.root(context: .background); let id = try await harnessStart(root, definition)
        _ = try await harness.waitForTask(id: id, context: .background)
        try await harnessEventually { harness.tasks.state.withLock { $0.invocations[id] == nil } }
        let api = try #require(retained.withLock { $0 })
        await #expect(throws: (any Error).self) { _ = try await api.memo("shared", nil, .background) }
        await #expect(throws: (any Error).self) { _ = try await api.read.snapshot(token, context: .background) }
        try await harness.close(context: .background)
    }
    @Test func explicitToolCallbacksKeepPrecedenceWhenRuntimeIsSupplied() async throws {
        let observed = Mutex<[String]>([])
        let definition = harnessOneStep("h5.tool-callbacks") { _, runtime, context in
            let api = ToolExecutionApi(taskId: runtime.taskId, conversationId: runtime.conversationId,
                callId: "test", registry: runtime.registry, models: runtime.models, runtime: runtime,
                agent: { _ in observed.withLock { $0.append("agent") }; return Agent(cwd: "/custom") },
                memo: { name, _, _ in observed.withLock { $0.append(name) }; return .string("custom") })
            let agent = try await api.agent(context)
            let memo = try await api.memo("memo", nil, context)
            #expect(agent.cwd == "/custom"); #expect(memo == .string("custom"))
            #expect(try await runtime.memo("memo", context: context) == nil)
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)]); let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, definition)
        _ = try await harness.waitForTask(id: id, context: .background)
        #expect(observed.withLock { $0 } == ["agent", "memo"])
        try await harness.close(context: .background)
    }
}
