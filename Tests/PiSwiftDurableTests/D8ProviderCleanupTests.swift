import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
import Synchronization
import Testing
@testable import PiSwiftDurable

@Suite struct D8ProviderCleanupTests {
    // v1.6.0 harness-lifecycle.test.ts:321–347.
    @Test func cleansUpProviderSessionResourcesAfterRunningTasksJoin() async throws {
        let expected = Mutex<String?>(nil)
        let calls = Mutex<[String]>([])
        let unregister = registerSessionResourceCleanup { id in
            if let id, id == expected.withLock({ $0 }) { calls.withLock { $0.append(id) } }
        }
        defer { unregister() }
        let setup = HarnessChatSetup()
        let entered = SessionTestGate(), release = SessionTestGate()
        setup.models.setResponses([.factory { _, _, _, _ in
            entered.release()
            await release.wait()
            return chatAssistant("done")
        }])
        let opened = try await openChat(setup: setup)
        let id = try #require(await opened.harness.snapshot(ProviderDoc, conversationId: opened.root.id, context: .background)?.sessionId)
        expected.withLock { $0 = id }
        _ = try await generationSubmit(opened)
        await entered.wait()
        let closing = settled { try await opened.harness.close(context: .background) }
        #expect(calls.withLock { $0 }.isEmpty)
        #expect(!closing.isSettled)
        release.release()
        try await harnessEventually { closing.isSettled }
        #expect(calls.withLock { $0 } == [id])
    }

    // v1.6.0 harness.ts:446–452: a cleanup failure is reported as host_error/models.
    @Test func cleanupFailureIsReportedAndCloseCompletes() async throws {
        let expected = Mutex<String?>(nil)
        let calls = Mutex<[String]>([])
        let unregister = registerSessionResourceCleanup { id in
            if let id, id == expected.withLock({ $0 }) {
                calls.withLock { $0.append(id) }
                throw TaskDefinitionError("cleanup failed")
            }
        }
        defer { unregister() }
        let setup = HarnessChatSetup()
        setup.models.setResponses([.message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup)
        let id = try #require(await opened.harness.snapshot(ProviderDoc, conversationId: opened.root.id, context: .background)?.sessionId)
        expected.withLock { $0 = id }
        _ = try await generationSubmit(opened).wait(context: .background)
        try await opened.harness.close(context: .background)
        #expect(calls.withLock { $0 } == [id])
        #expect(setup.taggedReports.withLock { $0 }.contains { $0.info == .hostError(callback: .models) })
    }

    // v1.6.0 harness-lifecycle.test.ts:350–365.
    @Test func cleansUpProviderSessionResourcesWhenTheHarnessFails() async throws {
        let expected = Mutex<String?>(nil), calls = Mutex<[String]>([])
        let unregister = registerSessionResourceCleanup { id in
            if let id, id == expected.withLock({ $0 }) { calls.withLock { $0.append(id) } }
        }
        defer { unregister() }
        let storage = ControlledStorage(), setup = HarnessChatSetup()
        setup.models.setResponses([.message(chatAssistant("done"))])
        let opened = try await openChat(storage: storage, setup: setup)
        let id = try #require(await opened.harness.snapshot(ProviderDoc, conversationId: opened.root.id, context: .background)?.sessionId)
        expected.withLock { $0 = id }
        _ = try await generationSubmit(opened).wait(context: .background)
        await storage.failNextCommit(TaskDefinitionError("disk failed"))
        await #expect(throws: (any Error).self) {
            try await opened.root.commit({ tx in
                _ = try await tx.appendEntry(opened.root.id, value: .init(kind: "note"))
            }, context: .background)
        }
        _ = await opened.harness.closed
        #expect(calls.withLock { $0 } == [id])
        try await opened.harness.close(context: .background)
    }

    // v1.6.0 harness-lifecycle.test.ts:368–399.
    @Test func doesNotCleanUpResourcesOwnedByAnotherHarness() async throws {
        let calls = Mutex<[String]>([])
        let unregister = registerSessionResourceCleanup { id in
            if let id { calls.withLock { $0.append(id) } }
        }
        defer { unregister() }
        let first = HarnessChatSetup(), second = HarnessChatSetup()
        first.models.setResponses([.message(chatAssistant("first")), .message(chatAssistant("child"))])
        second.models.setResponses([.message(chatAssistant("second"))])
        let a = try await openChat(setup: first), b = try await openChat(setup: second)
        let child = try await a.harness.createConversation(options: .init(ownership: .ownerless(),
            agent: .init(model: .set(ModelRef(provider: "faux", modelId: "faux-1")))), context: .background)
        let firstID = try #require(await a.harness.snapshot(ProviderDoc, conversationId: a.root.id, context: .background)?.sessionId)
        let childID = try #require(await a.harness.snapshot(ProviderDoc, conversationId: child.id, context: .background)?.sessionId)
        let secondID = try #require(await b.harness.snapshot(ProviderDoc, conversationId: b.root.id, context: .background)?.sessionId)
        _ = try await generationSubmit(a).wait(context: .background)
        _ = try await child.submit(.input(content: .text("child")), context: .background).wait(context: .background)
        _ = try await generationSubmit(b).wait(context: .background)
        try await a.harness.close(context: .background)
        #expect(calls.withLock { $0 }.contains(firstID))
        #expect(calls.withLock { $0 }.contains(childID))
        #expect(!calls.withLock { $0 }.contains(secondID))
        try await b.harness.close(context: .background)
        #expect(calls.withLock { $0 }.contains(secondID))
    }
}
