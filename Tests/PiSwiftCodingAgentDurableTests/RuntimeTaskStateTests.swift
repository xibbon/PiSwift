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

    // Save upstream task states without starting their handlers.
    func seed(tool: Bool, sleepingUntil: Int64? = nil) async throws -> TaskID {
        let location = try await selectSession(cwd, continueSession: false, agentDirectory: agent)
        defer { location.release() }
        let setup = HarnessChatSetup()
        let opened = try await openChat(storage: SqliteStorage.open(path: location.database), setup: setup)
        do {
            _ = try await opened.root.submit(.input(content: .text("Saved input")), context: .background)
            let live = try #require(try await opened.harness.snapshot(LiveDoc, conversationId: rootConversationID, context: .background))
            let generation = try #require(live.run?.taskId)
            let target: TaskID
            if tool {
                let saved = try await opened.root.commit({ tx in
                    _ = try #require(try await tx.task(generation))
                    var message = chatAssistant("", reason: .toolUse)
                    message.content = [.toolCall(.init(id: "saved-read", name: "read", arguments: ["path": AnyCodable("input.txt")]))]
                    let assistant = try await tx.appendEntry(rootConversationID, value: EntryDraft(kind: "pi.assistant",
                        model: EntryRecord.encodeMessages([.assistant(message)])))
                    let id = try await tx.createTask(toolTask, input: .init(assistant: assistant.id, callId: "saved-read"),
                        options: .init(ownership: .task(taskId: generation)))
                    return (id, assistant.id)
                }, context: .background)
                try await opened.root.commit({ tx in
                    let record = try #require(try await tx.task(generation))
                    let toolRecord = try #require(try await tx.task(saved.0))
                    let draft = try await tx.doc(LiveDoc, conversationId: rootConversationID)
                    try tx.setTask(toolRecord.replacing(restarts: .some(5)))
                    try tx.setTask(record.replacing(state: try generationTask.waiting(
                        .init(phase: .tools, assistant: saved.1, tools: [saved.0]), on: [saved.0], policy: .allSettled)))
                    try draft.set("tools", JSONValue(encoding: [ToolSlot(callId: "saved-read", name: "read", taskId: saved.0)]))
                }, context: .background)
                target = saved.0
            } else {
                try await opened.root.commit({ tx in
                    let record = try #require(try await tx.task(generation))
                    let draft = try await tx.doc(LiveDoc, conversationId: rootConversationID)
                    if let until = sleepingUntil {
                        let checkpoint = GenerationCheckpoint(phase: .retry, attempt: 1, until: until)
                        try tx.setTask(record.replacing(state: try generationTask.sleeping(checkpoint, until: Double(until))))
                        try draft.set("generation", JSONValue(encoding: LiveGeneration(attempt: 1,
                            retry: LiveRetry(at: until, error: "503 Service Unavailable"))))
                    } else {
                        try tx.setTask(record.replacing(restarts: .some(5)))
                    }
                }, context: .background)
                target = generation
            }
            try await opened.harness.close(context: .background)
            return target
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

private func expectParked(_ result: OpenDurableResult, id: TaskID, tool: Bool) async throws {
    try await eventually { result.view.current().parkedTasks.contains { $0.id == id } }
    let view = result.view.current()
    let task = try #require(view.parkedTasks.first { $0.id == id })
    #expect(task.kind == (tool ? "pi.tool" : "pi.generation"))
    #expect(task.reason == .restartLimit)
    #expect(task.restarts == 5)
    #expect(view.activity == .parked)
    #expect(view.sleepingTasks.isEmpty)
}

@Suite(.timeLimit(.minutes(1))) struct RuntimeTaskStateTests {
    @Test(arguments: [false, true], [false, true])
    func parkedTaskStaysVisibleWhenHiddenAndReopenedThenAcceptsControl(tool: Bool, abort: Bool) async throws {
        let directory = try TaskStateDirectory()
        defer { directory.remove() }
        let id = try await directory.seed(tool: tool)
        let models = FakeDurableModels(responses: [.message(chatAssistant("Recovered answer"))])
        let first = try await directory.open(models)
        let sessionID = first.view.current().session.id
        do {
            await first.controller.toggleTasks()
            #expect(first.view.current().tasks == nil)
            try await expectParked(first, id: id, tool: tool)
            #expect(models.calls().streamSimple == 0)
            try await eventually { first.view.current().notices.contains { $0.category == .taskParked && $0.taskId == id } }
            let notice = try #require(first.view.current().notices.first { $0.category == .taskParked && $0.taskId == id })
            #expect(notice.taskKind == (tool ? "pi.tool" : "pi.generation"))
            #expect(notice.message == runtimeParkingReport(id: id, kind: tool ? "pi.tool" : "pi.generation", restarts: 5))
        } catch { await first.close(); throw error }
        await first.close()

        let second = try await directory.open(models)
        do {
            #expect(second.view.current().session.id == sessionID)
            await second.controller.toggleTasks()
            #expect(second.view.current().tasks == nil)
            try await expectParked(second, id: id, tool: tool)
            #expect(models.calls().streamSimple == 0)
            if abort { await second.controller.abortTask(id) }
            else { await second.controller.retryTask(id) }
            try await eventually {
                try second.view.current().parkedTasks.isEmpty
                    && decodeLiveOf(second.view.current().conversation).run == nil
                    && second.view.current().activity == .idle
            }
            #expect(second.view.current().tasks == nil)
            #expect(second.view.current().activity == .idle)
            if !abort || tool {
                try await eventually { try taskStateTexts(second.view.current(), kind: "pi.assistant").contains("Recovered answer") }
                #expect(models.calls().streamSimple == 1)
            } else {
                #expect(models.calls().streamSimple == 0)
            }
            if tool {
                let results = try taskStateTexts(second.view.current(), kind: "pi.tool-result")
                #expect(results.contains { $0.contains(abort ? "was aborted" : "Saved tool output") })
            }
            #expect(second.view.current().terminal == nil)
        } catch { await second.close(); throw error }
        await second.close()
    }

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
        let id = try await directory.seed(tool: false, sleepingUntil: until)
        let models = FakeDurableModels()
        let result = try await directory.open(models)
        do {
            await result.controller.toggleTasks()
            try await eventually { result.view.current().sleepingTasks.contains { $0.id == id } }
            let view = result.view.current()
            let sleeping = try #require(view.sleepingTasks.first { $0.id == id })
            #expect(view.tasks == nil)
            #expect(view.activity == .sleeping)
            #expect(view.parkedTasks.isEmpty)
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
