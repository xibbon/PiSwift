import Foundation
import PiSwiftChord
import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentDurable
@testable import PiSwiftDurable
import PiSwiftDurableTesting
import Synchronization
import Testing

private func typedReportView() -> DurableView {
    .init(session: .init(id: "typed", directory: "/session", cwd: "/project"),
          conversation: .init(conversation: .init(id: rootConversationID), entries: [], docs: [:]),
          conversations: [], models: [])
}

// v1.5.2 D5a types.ts:155–204: the host receives one tagged report for each failure.
@Test func typedReportsKeepSourceAndDistinctDisplayWordsWithIdenticalErrors() throws {
    let source = RuntimeViewSource(typedReportView(), schedule: { _ in })
    let reports = RuntimeReports()
    let task = ReportTask(id: try TaskID(2), kind: "test.task", conversationId: rootConversationID)
    let error = SessionError.message("same error")
    reports.report(Report(.taskInterrupted(task: task, extension: "run", reason: .restartLimit, restarts: 5), error: error))
    reports.report(error, info: .taskFaulted(task: task, extension: "fault", reason: .threw))
    reports.report(error, info: .extensionError(extension: "extension", task: task))
    reports.report(error, info: .storageFailed)
    reports.attach(source)
    let view = source.current()
    #expect(view.notices.map(\.displayMessage) == [
        "Runtime report: same error", "Task fault: same error",
        "Extension error: same error", "Session failed: same error",
    ])
    #expect(view.notices.map(\.reportType) == ["task_interrupted", "task_faulted", "extension_error", "storage_failed"])
    #expect(view.notices.map(\.extensionName) == ["run", "fault", "extension", nil])
    #expect(view.notices.prefix(3).allSatisfy { $0.taskId == task.id && $0.taskKind == task.kind && $0.conversationId == task.conversationId })
    #expect(view.notices.map(\.reportInfo) == [
        .taskInterrupted(task: task, extension: "run", reason: .restartLimit, restarts: 5),
        .taskFaulted(task: task, extension: "fault", reason: .threw),
        .extensionError(extension: "extension", task: task), .storageFailed,
    ])
    #expect(view.terminal == nil)
    source.terminate(.failed(error))
    #expect(source.current().terminal == .failed(message: "same error"))
    #expect(source.current().notices.filter { $0.category == .sessionFailed }.count == 1)
    #expect(try JSONValue(encoding: view).decode(DurableView.self) == view)
}

@Test func typedFaultMatchesTaskIdentityAndDoesNotConsumeAnUnrelatedReport() throws {
    let source = RuntimeViewSource(typedReportView(), schedule: { _ in })
    let reports = RuntimeReports()
    reports.attach(source)
    let task = ReportTask(id: try TaskID(2), kind: "test.task", conversationId: rootConversationID)
    source.record(.init(seq: try Seq(1), changes: [.task(.init(id: task.id,
        conversationId: task.conversationId, kind: task.kind, version: 1, input: [:],
        state: .terminal(outcome: .faulted(error: .init(message: "same error")))))]))
    reports.report(SessionError.message("same error"), info: .extensionError(extension: "other"))
    reports.report(SessionError.message("same error"), info: .taskFaulted(task: task, extension: "original", reason: .threw))
    #expect(source.current().notices.count == 2)
    #expect(source.current().notices.first?.extensionName == "original")
    #expect(source.current().notices.last?.extensionName == "other")
    #expect(source.current().terminal == nil)
}

// v1.5.2 D5a types.ts:193–204: listener_error stays distinct from task endings.
@Test func typedListenerReportDoesNotUseTaskEndingTextToClassifyTheError() throws {
    let source = RuntimeViewSource(typedReportView(), schedule: { _ in })
    let reports = RuntimeReports()
    reports.attach(source)
    let text = "Task 2 (test.task) was cut off 5 times without progress"
    reports.report(SessionError.message(text), info: .listenerError)
    let notice = try #require(source.current().notices.first)
    #expect(notice.category == .report)
    #expect(notice.reportType == "listener_error")
    #expect(notice.taskId == nil)
    #expect(source.current().terminal == nil)
    let old = try JSONValue.object(["id": 1, "level": "warning", "message": "Old report"]).decode(Notice.self)
    #expect(old.reportInfo == nil)
    #expect(old.reportType == nil)
    #expect(old.extensionName == nil)
    #expect(old.conversationId == nil)
}

@Test func noticeRoundTripKeepsFaultReasonAndHostCallback() throws {
    let source = RuntimeViewSource(typedReportView(), schedule: { _ in })
    let reports = RuntimeReports()
    reports.attach(source)
    let task = ReportTask(id: try TaskID(2), kind: "test.task", conversationId: rootConversationID)
    let fault = ReportInfo.taskFaulted(task: task, extension: "fault", reason: .restartLimit)
    let host = ReportInfo.hostError(callback: .settings, task: task)
    reports.report(SessionError.message("same error"), info: fault)
    reports.report(SessionError.message("same error"), info: host)
    let view = source.current()
    #expect(view.notices.map(\.reportInfo) == [fault, host])
    let decoded = try JSONValue(encoding: view).decode(DurableView.self)
    #expect(decoded == view)
    #expect(decoded.notices.map(\.reportInfo) == [fault, host])
    #expect(decoded.notices.last?.reportType == "host_error")
    #expect(decoded.terminal == nil)
}

@Test func unknownDeferredToolHasCodingAgentSource() throws {
    let settings = SettingsManager.inMemory()
    settings.setDurableDeferredTools(["missing-tool", "missing-tool"])
    let infos = Mutex<[ReportInfo]>([])
    _ = try createCodingRegistry(settingsManager: settings, cwd: "/project", onReport: { _, info in
        infos.withLock { $0.append(info) }
    })
    #expect(infos.withLock { $0 } == [.extensionError(extension: "coding-agent")])
}

@Suite(.timeLimit(.minutes(1))) struct TypedReportHostTests {
    // v1.5.2 D5a harness-blocked.test.ts:134–183: an extension task ends faulted at the limit.
    @Test func restartLimitFaultIsVisibleWithTaskPanelHidden() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("typed-report-host-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let cwd = base.appendingPathComponent("project").path
        let agent = base.appendingPathComponent("agent").path
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: agent, withIntermediateDirectories: true)
        let location = try await selectSession(cwd, continueSession: false, agentDirectory: agent)
        let saved = try await openChat(storage: SqliteStorage.open(path: location.database), setup: HarnessChatSetup())
        let id: TaskID
        do {
            id = try await saved.root.commit({ tx in
                try await tx.createTask(toolTask, input: .init(assistant: EntryID(999_999), callId: "unused"),
                    options: .init(ownership: .conversation()))
            }, context: .background)
            try await saved.root.commit({ tx in
                let record = try #require(try await tx.task(id))
                try tx.setTask(TaskRecord(id: record.id, conversationId: record.conversationId,
                    kind: "test.host-crash-loop", version: 1, input: record.input, state: record.state,
                    restarts: 5))
            }, context: .background)
            try await saved.harness.close(context: .background)
        } catch {
            try? await saved.harness.close(context: .background)
            location.release()
            throw error
        }
        location.release()
        let models = FakeDurableModels(responses: [.message(chatAssistant("Recovered answer"))])
        let result = try await openDurable(.init(cwd: cwd, continueSession: true), dependencies: .init(
            agentDirectory: agent, makeModels: { _ in
                .init(models: models, available: models.models, initial: { _ in
                    .init(model: .init(provider: "faux", modelId: "faux-1"))
                })
            }))
        do {
            await result.controller.toggleTasks()
            try await eventually { result.view.current().notices.contains { $0.category == .taskFault && $0.taskId == id } }
            #expect(result.view.current().tasks == nil)
            #expect(result.view.current().terminal == nil)
            #expect(result.failure == nil)
            #expect(models.calls().streamSimple == 0)
            #expect(result.view.current().notices.contains {
                $0.reportType == "task_faulted" && $0.reportInfo == .taskFaulted(
                    task: ReportTask(id: id, kind: "test.host-crash-loop", conversationId: rootConversationID),
                    reason: .restartLimit)
            })
            #expect(result.view.current().blockedTasks.isEmpty)
            #expect(result.view.current().activity == .idle)
            #expect(result.view.current().terminal == nil)
            #expect(result.failure == nil)
        } catch { await result.close(); throw error }
        await result.close()
        #expect(result.view.current().terminal == .closed)
    }
}
