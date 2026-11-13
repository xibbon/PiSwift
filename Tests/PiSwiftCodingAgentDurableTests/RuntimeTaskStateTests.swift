import Foundation
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftCodingAgentDurable
@testable import PiSwiftDurable
import PiSwiftDurableTesting
import Testing

private struct TaskStateDirectory: Sendable {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-task-state-" + UUID().uuidString)
    var cwd: String { base.appendingPathComponent("project").path }
    var agent: String { base.appendingPathComponent("agent").path }

    init() throws {
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: agent, withIntermediateDirectories: true)
        try Data("{\"retry\":{\"enabled\":false},\"compaction\":{\"enabled\":false}}".utf8)
            .write(to: URL(fileURLWithPath: agent).appendingPathComponent("settings.json"))
        try Data("Saved tool output".utf8).write(to: URL(fileURLWithPath: cwd).appendingPathComponent("input.txt"))
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    func open(_ models: FakeDurableModels, continued: Bool = true) async throws -> OpenDurableResult {
        try await openDurable(.init(cwd: cwd, continueSession: continued), dependencies: .init(
            agentDirectory: agent, makeModels: { _ in
                .init(models: models, available: models.models, initial: { _ in
                    .init(model: .init(provider: "faux", modelId: "faux-1"))
                })
            }))
    }

    // v1.5.2 D5a harness-restart-failure.test.ts:275–325: sleeping retry work is not charged by reopen.
    func seedSleeping(until: Int64) async throws -> TaskID {
        let location = try await selectSession(cwd, continueSession: false, agentDirectory: agent)
        defer { location.release() }
        let setup = HarnessChatSetup()
        let opened = try await openChat(storage: SqliteStorage.open(path: location.database), setup: setup)
        do {
            _ = try await opened.root.submit(.input(content: .text("Saved input")), context: .background)
            let live = try #require(try await opened.harness.snapshot(LiveDoc, conversationId: rootConversationID, context: .background))
            let generation = try #require(live.run?.taskId)
            try await opened.root.commit({ tx in
                let record = try #require(try await tx.task(generation))
                let draft = try await tx.doc(LiveDoc, conversationId: rootConversationID)
                let checkpoint = GenerationCheckpoint(phase: .retry, attempt: 1, until: until)
                try tx.setTask(record.replacing(state: try generationTask.sleeping(checkpoint, until: Double(until))))
                try draft.set("generation", JSONValue(encoding: LiveGeneration(attempt: 1,
                    retry: LiveRetry(at: until, error: "503 Service Unavailable"))))
            }, context: .background)
            try await opened.harness.close(context: .background)
            return generation
        } catch {
            try? await opened.harness.close(context: .background)
            throw error
        }
    }

    func seedFault() async throws -> TaskID {
        let location = try await selectSession(cwd, continueSession: false, agentDirectory: agent)
        defer { location.release() }
        let opened = try await openChat(storage: SqliteStorage.open(path: location.database), setup: HarnessChatSetup())
        do {
            // The saved assistant is absent. The installed tool handler must fault.
            let id = try await opened.root.commit({ tx in
                try await tx.createTask(toolTask, input: .init(assistant: EntryID(999_999), callId: "missing-call"),
                    options: .init(ownership: .conversation()))
            }, context: .background)
            try await opened.harness.close(context: .background)
            return id
        } catch {
            try? await opened.harness.close(context: .background)
            throw error
        }
    }

}

private func taskStateTexts(_ view: DurableView, kind: String) throws -> [String] {
    try view.conversation.entries.filter { $0.kind == kind }.flatMap { try $0.messages()?.compactMap { textOf($0) } ?? [] }
}

@Suite(.timeLimit(.minutes(1))) struct RuntimeTaskStateTests {
    // v1.5.2 D5a harness-blocked.test.ts:134–183 removes parked/retry control.
    // TypedReportHostTests.restartLimitFaultIsVisibleWithTaskPanelHidden is its successor.
    @Test func taskFaultShowsItsIdentityWithoutFailingTheSession() async throws {
        let directory = try TaskStateDirectory()
        defer { directory.remove() }
        let id = try await directory.seedFault()
        let models = FakeDurableModels()
        let result = try await directory.open(models)
        do {
            try await eventually { result.view.current().notices.contains { $0.category == .taskFault && $0.taskId == id } }
            let view = result.view.current()
            let notice = try #require(view.notices.first { $0.category == .taskFault && $0.taskId == id })
            #expect(notice.level == .error)
            #expect(notice.taskKind == "pi.tool")
            #expect(notice.message.contains("has no tool call missing-call"))
            #expect(view.terminal == nil)
            #expect(result.failure == nil)
            #expect(!view.notices.contains { $0.category == .sessionFailed })
            #expect(models.calls().streamSimple == 0)
        } catch { await result.close(); throw error }
        await result.close()
        #expect(result.view.current().terminal == .closed)
    }

    @Test func storedBackoffShowsItsDeadlineWhileTheTaskPanelIsHidden() async throws {
        let directory = try TaskStateDirectory()
        defer { directory.remove() }
        let until = Int64(Date().timeIntervalSince1970 * 1000) + 600_000
        let id = try await directory.seedSleeping(until: until)
        let models = FakeDurableModels()
        let result = try await directory.open(models)
        do {
            await result.controller.toggleTasks()
            try await eventually { result.view.current().sleepingTasks.contains { $0.id == id } }
            let view = result.view.current()
            let sleeping = try #require(view.sleepingTasks.first { $0.id == id })
            #expect(view.tasks == nil)
            #expect(view.activity == .sleeping)
            #expect(view.blockedTasks.isEmpty)
            #expect(sleeping.kind == "pi.generation")
            #expect(sleeping.phase == "retry")
            #expect(sleeping.until == Double(until))
            #expect(try decodeLiveOf(view.conversation).generation?.retry?.at == until)
            #expect(models.calls().streamSimple == 0)
        } catch { await result.close(); throw error }
        await result.close()
    }

    @Test func modelFailureKeepsQueuedInputsInTheViewAndOnReopen() async throws {
        let directory = try TaskStateDirectory()
        defer { directory.remove() }
        let response = HarnessGatedResponse(message: chatAssistant("", reason: .error, error: "Invalid request"))
        let models = FakeDurableModels(responses: [response.step])
        let first = try await directory.open(models, continued: false)
        var retained: [InboxItem] = []
        do {
            await first.controller.submit("First input", whenBusy: .followUp)
            try await eventually { response.reached.isSignalled }
            await first.controller.submit("Steering input", whenBusy: .steer)
            await first.controller.submit("Follow-up input", whenBusy: .followUp)
            try await eventually { first.view.current().queuedInputs.count == 2 }
            response.release()
            try await eventually {
                try decodeLiveOf(first.view.current().conversation).run == nil
                    && first.view.current().activity == .idle
            }
            let view = first.view.current()
            retained = view.queuedInputs
            #expect(retained.map(\.mode) == [.steer, .followUp])
            #expect(retained.map(\.content) == [.string("Steering input"), .string("Follow-up input")])
            #expect(try taskStateTexts(view, kind: "pi.user") == ["First input"])
            #expect(view.activity == .idle)
            #expect(view.terminal == nil)
            #expect(view.notices.contains { $0.message.contains("model_error") })
            #expect(models.calls().streamSimple == 1)
        } catch { await first.close(); throw error }
        await first.close()
        let second = try await directory.open(models)
        #expect(second.view.current().queuedInputs == retained)
        #expect(second.view.current().activity == .idle)
        #expect(models.calls().streamSimple == 1)
        await second.close()
    }
}
