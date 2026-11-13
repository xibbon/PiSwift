import PiSwiftChord
@testable import PiSwiftCodingAgentDurable
import PiSwiftDurable
import Testing

@Suite struct D10HostSnapshotTests {
    @Test func runEndingsRetainEverySavedReason() throws {
        let cases: [(RunFailureReason, String)] = [
            (.modelError, "Model request failed"), (.noModel, "No model"),
            (.aborted, "Run aborted"), (.reset, "Run reset"),
            (.faulted, "Run faulted"), (.orphaned, "Run orphaned"),
            (.interrupted, "Run interrupted"), (.restartLimit, "Restart limit"),
            (.nothingToAnswer, "No answer needed"), (.turnLimit, "Turn limit reached"),
        ]
        var snapshot: [String] = []
        for (reason, text) in cases {
            let failure = RunFailure(taskId: try TaskID(2), inputs: [try SubmissionID(3)],
                reason: reason, detail: "Saved detail", first: try EntryID(4))
            let ending = DurableRunEnding(failure)
            #expect(ending.failure == failure)
            #expect(ending.reason == reason)
            #expect(ending.text == text)
            #expect(ending.detail == "Saved detail")
            #expect(ending.taskId == failure.taskId)
            #expect(ending.inputs == failure.inputs)
            #expect(ending.first == failure.first)
            snapshot.append("\(reason.rawValue) | \(ending.text) | \(ending.explanation) | \(ending.action)")
        }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/D10-run-endings.txt")
        let expected = try String(contentsOf: fixture, encoding: .utf8)
        #expect(snapshot.joined(separator: "\n") + "\n" == expected)
    }

    @Test func transcriptRowsKeepIdentityWhenEarlierRowsAreAdded() throws {
        let conversation = ConversationRecord(id: rootConversationID)
        let entry = EntryRecord(id: try EntryID(5), conversationId: conversation.id, kind: "chat", data: "five")
        let gap = TranscriptGap(after: try EntryID(2), upTo: entry.id)
        let later = TranscriptView(conversation: conversation, docs: [:], items: [.entry(entry)])
        let loaded = TranscriptView(conversation: conversation, docs: [:], items: [.earlier, .gap(gap), .entry(entry)])
        let legacy = legacyView(conversation: conversation)
        let first = DurableHostView(legacy: legacy, transcript: later, mode: .write)
        let second = DurableHostView(legacy: legacy, transcript: loaded, mode: .write)
        #expect(first.rows[0].id == second.rows[2].id)
        #expect(second.rows.map(\.id) == [.earlier(conversation.id), .gap(conversation.id, gap), .entry(conversation.id, entry.id)])
        #expect(second.rows.map(\.item) == loaded.items)
        let other = try ConversationID(9)
        #expect(DurableTranscriptRow(conversationId: other, item: .entry(entry)).id != first.rows[0].id)
    }

    @Test func snapshotReadsTypedDocumentsAndPreservesHostData() throws {
        let conversation = ConversationRecord(id: rootConversationID)
        let task = try TaskID(2)
        let input = try SubmissionID(3)
        let failure = RunFailure(taskId: task, inputs: [input], reason: .turnLimit, detail: "Two turns")
        let live = LiveState(generation: .init(attempt: 2, retry: .init(at: 123, error: "Retry")), runFailure: failure)
        let inbox = InboxState(items: [.init(id: input, mode: .followUp, content: "Next input")])
        let docs: [String: JSONObject] = [
            "pi.live": try #require(JSONValue(encoding: live).objectValue),
            "pi.inbox": try #require(JSONValue(encoding: inbox).objectValue),
        ]
        let info = ReportInfo.taskInterrupted(task: .init(id: task, kind: "pi.generation", conversationId: conversation.id),
            reason: .restartLimit, restarts: 5)
        let notice = Notice(id: 1, level: .warning, message: "Work stopped", reportInfo: info)
        let legacy = legacyView(conversation: conversation, notices: [notice])
        let transcript = TranscriptView(conversation: conversation, docs: docs, items: [])
        let outcome = DurableTaskOutcome(id: task, kind: "pi.generation", conversationId: conversation.id,
            outcome: .aborted(reason: "User stopped work"))
        let snapshot = DurableHostView(legacy: legacy, transcript: transcript, mode: .readOnly, outcomes: [outcome])
        #expect(snapshot.live == live)
        #expect(snapshot.inbox == inbox)
        #expect(snapshot.ending == DurableRunEnding(failure))
        #expect(snapshot.documentError == nil)
        #expect(snapshot.notices == [notice])
        #expect(snapshot.notices.first?.reportInfo == info)
        #expect(snapshot.notices.first?.reportLabel == "Task interrupted")
        #expect(snapshot.outcomes == [outcome])
        #expect(snapshot.session == legacy.session)
        #expect(snapshot.models == legacy.models)
        #expect(snapshot.conversations == legacy.conversations)
        #expect(snapshot.terminal == .closed)
        #expect(snapshot.openMode == .readOnly)
    }

    @Test func invalidDocumentsHaveAnExplicitDiagnostic() {
        let conversation = ConversationRecord(id: rootConversationID)
        let transcript = TranscriptView(conversation: conversation,
            docs: ["pi.live": ["run": "invalid"], "pi.inbox": ["items": "invalid"]], items: [])
        let snapshot = DurableHostView(legacy: legacyView(conversation: conversation), transcript: transcript, mode: .write)
        #expect(snapshot.live == LiveState())
        #expect(snapshot.inbox == InboxState())
        #expect(snapshot.documentError?.contains("Live state:") == true)
        #expect(snapshot.documentError?.contains("Inbox:") == true)
    }

    @Test func noticeLabelsUseTypedReportsBeforeLegacyStrings() {
        let notice = Notice(id: 1, level: .error, message: "Failure", reportType: "storage_failed", reportInfo: .listenerError)
        #expect(notice.reportLabel == "Listener failed")
        #expect(Notice(id: 2, level: .info, message: "Info").reportLabel == nil)
        #expect(Notice(id: 3, level: .warning, message: "New report", reportType: "future_kind").reportLabel == "future_kind")
    }

    @Test func everyCurrentReportKindKeepsSeverityAndIdentity() throws {
        let task = ReportTask(id: try TaskID(8), kind: "pi.tool", conversationId: rootConversationID)
        let cases: [(ReportInfo, Notice.Level)] = [
            (.storageFailed, .error),
            (.taskInterrupted(task: task, reason: .restartLimit, restarts: 5), .error),
            (.taskFaulted(task: task, reason: .restartLimit), .error),
            (.migrationFailed(task: task), .error),
            (.taskError(task: task), .warning),
            (.taskOutdated(task: task, reason: .missingTask), .warning),
            (.extensionError(extension: "demo", task: task, conversationId: rootConversationID), .warning),
            (.hostError(callback: .models, task: task), .error),
            (.listenerError, .warning),
        ]
        let source = RuntimeViewSource(legacyView(conversation: .init(id: rootConversationID)),
                                       schedule: { _ in })
        for (info, level) in cases {
            source.report(RuntimeReport(Report(info, error: SessionError.message("test cause"))))
            let notice = try #require(source.current().notices.last)
            #expect(notice.reportInfo == info)
            #expect(notice.reportType == info.kind)
            #expect(notice.level == level)
            #expect(notice.taskId == info.task?.id)
            #expect(notice.extensionName == info.extension)
        }
    }

    private func legacyView(conversation: ConversationRecord, notices: [Notice] = []) -> DurableView {
        DurableView(session: .init(id: "session", directory: "/sessions/session", cwd: "/project"),
            conversation: .init(conversation: conversation, entries: [], docs: [:]),
            conversations: [.init(id: conversation.id, label: "Main")],
            models: [.init(provider: "faux", modelId: "faux-1", name: "Test model", contextWindow: 1000)],
            notices: notices, terminal: .closed)
    }
}
import Foundation
