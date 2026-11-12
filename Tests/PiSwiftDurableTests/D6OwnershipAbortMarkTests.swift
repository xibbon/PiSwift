import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

@Suite("PiSwiftDurableTests.D6OwnershipAbortMark", .timeLimit(.minutes(1)))
struct D6OwnershipAbortMarkTests {
    // v1.5.2 harness-ownership.test.ts:1068–1152, especially :1141 and :1145.
    @Test func childSubmissionQueuedBehindParentAbortMarkIsThenAborted() async throws {
        let storage = ControlledStorage(), setup = HarnessChatSetup()
        let ready = HarnessChatSignal(), go = HarnessChatSignal(), queued = HarnessChatSignal()
        let enteredLine = HarnessChatSignal(), releaseLine = HarnessChatSignal()
        let child = Mutex<ConversationID?>(nil), owner = Mutex<TaskID?>(nil)
        let submitting = Mutex<SettledObserver<Submission>?>(nil)
        try installHarnessTool(harnessTestTool("delegate", execute: { _, api, context in
            let created = try await api.commit({ tx in
                try await tx.createConversation(ownership: .task(taskId: api.taskId)).id
            }, context: context)
            let handle = try #require(try await api.conversation(id: created, context: context))
            child.withLock { $0 = created }; owner.withLock { $0 = api.taskId }
            ready.signal(); await go.wait()
            submitting.withLock { $0 = settled { try await handle.submit(.input(content: .text("late"), requestId: "d6-late"), context: .background) } }
            queued.signal()
            try await harnessToolAwaitAbort(context)
            return .init()
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("delegate", [:], "c1")]))])
        let opened = try await openChat(storage: storage, setup: setup)
        _ = try await opened.root.submit(.input(content: .text("go")), context: .background)
        await ready.wait()
        let ownerID = try #require(owner.withLock { $0 })
        let gate = await storage.holdTaskAbortMark(ownerID)
        defer { Task { await gate.release() }; releaseLine.signal(); go.signal() }
        let holding = Task {
            try await opened.root.commit({ _ in enteredLine.signal(); await releaseLine.wait() }, context: .background)
        }
        await enteredLine.wait()
        let aborting = Task { try await opened.harness.abortTask(id: ownerID, context: .background) }
        // v1.5.2 D6 harness-ownership.test.ts:1127–1131 calls abortTask
        // synchronously before resolving the tool's gate. A Swift Task must
        // first reserve its Session ticket to preserve that order.
        try await eventually { opened.harness.session.line.queuedCount >= 1 }
        go.signal(); await queued.wait()
        // v1.5.2 D6 harness-ownership.test.ts:1130–1134 creates the submit
        // promise while the Session line is held. Wait until its ticket is
        // queued behind the abort mark before releasing that line.
        try await eventually { opened.harness.session.line.queuedCount >= 2 }
        releaseLine.signal(); try await holding.value
        await gate.waitUntilEntered()
        let observer = try #require(submitting.withLock { $0 })
        let childID = try #require(child.withLock { $0 })
        // v1.5.2 D6 harness-ownership.test.ts:1132–1145 yields a turn so the
        // child submit is admitted before the held abort mark publishes. The
        // Session writer holds its storage call until the abort mark finishes.
        // Its request key shows that the Session line admitted the child.
        let requestKey = SessionKeys.requestKey(childID, "d6-late")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !opened.harness.session.hasPendingWrite(requestKey) {
            if let result = observer.result {
                throw TaskDefinitionError("Child submit settled before abort mark publication: \(result)")
            }
            guard ContinuousClock.now < deadline else {
                throw TaskDefinitionError("Child submit was not admitted before abort mark publication: " +
                    "queued=\(opened.harness.session.line.queuedCount), markPending=\(opened.harness.session.hasPendingWrite(SessionKeys.taskKey(ownerID))), " +
                    "childPending=\(opened.harness.session.hasPendingWrite(SessionKeys.conversationKey(childID))), observer=\(String(describing: observer.result))")
            }
            await Task.yield()
        }
        await gate.release()
        try await eventually { observer.isSettled }
        let submitted = try #require(observer.result).get()
        _ = try await aborting.value
        let childHandle = try #require(try await opened.harness.conversation(id: childID, context: .background))
        try await childHandle.waitForIdle(context: .background)
        let restored = try #require(try await opened.harness.submission(id: submitted.id, context: .background))
        let status = try await restored.status(context: .background)
        let encodedStatus = try JSONValue(encoding: status)
        #expect(status.status == "unanswered" && encodedStatus["reason"] == "aborted")
        #expect(try await allEntries(childHandle).map(\.kind) == ["pi.user"])
        try await opened.harness.close(context: .background)
    }
}
