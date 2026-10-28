import PiSwiftChord
@testable import PiSwiftCodingAgentDurable
import PiSwiftDurable
import Testing

private func workView() -> DurableView {
    .init(session: .init(id: "session", directory: "/session", cwd: "/project"),
          conversation: .init(conversation: .init(id: rootConversationID), entries: [], docs: [:]),
          conversations: [], models: [])
}

private func workNode(_ id: Int64, kind: String = "pi.generation", conversation: Int64 = 1,
                      owner: Int64? = nil, conversations: [Int64] = [],
                      blocked: TaskBlockedReason? = nil, state: JSONObject = ["status": "pending", "phase": "request"]) -> JSONValue {
    var node: JSONObject = ["id": .number(Double(id)), "kind": .string(kind),
        "conversationId": .number(Double(conversation)), "background": false, "abortRequested": false,
        "state": .object(state), "conversations": .array(conversations.map { .number(Double($0)) })]
    if let owner { node["owner"] = .number(Double(owner)) }
    if let blocked { node["blocked"] = .string(blocked.rawValue) }
    return .object(node)
}

private func workGraph(_ nodes: [JSONValue]) throws -> TaskGraph {
    try JSONValue.object(["tasks": .object(JSONObject(nodes.map { node in
        (String(Int64(node["id"]!.numberValue!)), node)
    }))]).decode(TaskGraph.self)
}

private func faultRecord(_ id: TaskID, message: String, completing: Bool = false) -> TaskRecord {
    let outcome = TaskOutcome.faulted(error: .init(message: message))
    return .init(id: id, conversationId: rootConversationID, kind: "test.fault", version: 1,
                 input: [:], state: completing ? .completing(outcome: outcome) : .terminal(outcome: outcome))
}

@Test func durableWorkFieldsAndNoticeMetadataRoundTripAndOldJSONDefaults() throws {
    let id = try TaskID(2)
    let parking = runtimeParkingReport(id: id, kind: "pi.tool", restarts: 5)
    let original = workView()
    let view = DurableView(session: original.session, conversation: original.conversation,
        conversations: [], models: [],
        notices: [.init(id: 1, level: .warning, message: parking, category: .taskParked, taskId: id, taskKind: "pi.tool")],
        blockedTasks: [.init(id: id, kind: "pi.tool", reason: .restartLimit, restarts: 5, report: parking)],
        sleepingTasks: [.init(id: try TaskID(3), kind: "pi.generation", phase: "retry", until: 12_345.5)],
        activity: .parked, queuedInputs: [.init(id: try SubmissionID(4), mode: .followUp, content: "Wait")])
    let decoded = try JSONValue(encoding: view).decode(DurableView.self)
    #expect(decoded == view)
    #expect(decoded.tasks == nil)
    #expect(decoded.parkedTasks == view.blockedTasks)
    var old = try #require(JSONValue(encoding: original).objectValue)
    for key in ["blockedTasks", "sleepingTasks", "activity", "queuedInputs", "terminal"] { old[key] = nil }
    let legacy = try JSONValue.object(old).decode(DurableView.self)
    #expect(legacy == original)
    let notice = try JSONValue.object(["id": 1, "level": "warning", "message": "Old report"]).decode(Notice.self)
    #expect(notice.category == .operation)
    #expect(notice.taskId == nil)
    #expect(notice.taskKind == nil)
}

@Test(arguments: [TaskBlockedReason.missingTask, .taskTooOld, .migrationFailed, .restartLimit])
func hiddenWorkKeepsEachBlockedReasonAndCount(reason: TaskBlockedReason) throws {
    let source = RuntimeViewSource(workView(), schedule: { _ in })
    let id = try TaskID(2)
    source.recordRestarts(.init(id: id, conversationId: rootConversationID, kind: "pi.generation", version: 1,
        input: [:], state: .pending(checkpoint: ["phase": "request"]), restarts: 5))
    source.updateTasks(try workGraph([workNode(2, blocked: reason)]), visible: false)
    let blocked = try #require(source.current().blockedTasks.first)
    #expect(source.current().tasks == nil)
    #expect(source.current().activity == (reason == .restartLimit ? .parked : .blocked))
    #expect(blocked.id == id)
    #expect(blocked.kind == "pi.generation")
    #expect(blocked.reason == reason)
    #expect(blocked.restarts == 5)
    #expect(blocked.report == (reason == .restartLimit ? runtimeParkingReport(id: id, kind: blocked.kind, restarts: 5) : nil))
}

@Test func hiddenGraphChangesIncludeOwnedConversationsAndIndependentProgress() throws {
    let source = RuntimeViewSource(workView(), schedule: { _ in })
    let parent = workNode(2, conversations: [8], state: ["status": "waiting", "phase": "tools", "on": [3], "policy": "allSettled"])
    let parked = workNode(3, kind: "pi.tool", conversation: 8, blocked: .restartLimit)
    source.updateTasks(try workGraph([parent, parked]), visible: false)
    #expect(source.current().activity == .parked)
    #expect(source.current().parkedTasks.map(\.id) == [try TaskID(3)])
    source.updateTasks(try workGraph([parent, parked, workNode(4)]), visible: false)
    #expect(source.current().activity == .progressing)
    #expect(source.current().parkedTasks.count == 1)
    let sleeping = workNode(3, kind: "pi.tool", conversation: 8,
        state: ["status": "sleeping", "phase": "poll", "until": 1_000.5])
    source.updateTasks(try workGraph([parent, sleeping]), visible: false)
    #expect(source.current().activity == .sleeping)
    #expect(source.current().parkedTasks.isEmpty)
    #expect(source.current().sleepingTasks.first?.phase == "poll")
    #expect(source.current().sleepingTasks.first?.until == 1_000.5)
    #expect(source.current().tasks == nil)
    source.updateTasks(TaskGraph(), visible: false)
    #expect(source.current().activity == .idle)
}

@Test func faultCommitKeepsTaskIdentityAndTheCallbackDoesNotDuplicateIt() throws {
    let source = RuntimeViewSource(workView(), schedule: { _ in })
    let reports = RuntimeReports()
    reports.attach(source)
    let id = try TaskID(2)
    source.record(.init(seq: try Seq(1), changes: [.task(faultRecord(id, message: "Phase failed", completing: true))]))
    source.record(.init(seq: try Seq(2), changes: [.task(faultRecord(id, message: "Phase failed"))]))
    reports.report(SessionError.message("Phase failed"))
    #expect(source.current().notices.count == 1)
    #expect(source.current().notices.first?.category == .taskFault)
    #expect(source.current().notices.first?.level == .error)
    #expect(source.current().notices.first?.taskId == id)
    #expect(source.current().notices.first?.taskKind == "test.fault")
    #expect(source.current().terminal == nil)
    reports.report(SessionFailed(SessionError.message("Storage failed")))
    #expect(source.current().terminal == nil)
    source.terminate(.failed(SessionError.message("Storage failed")))
    #expect(source.current().notices.last?.category == .sessionFailed)
    #expect(source.current().terminal == .failed(message: "Storage failed"))
}

@Test func parkingReportsMatchExactCoreTextAndKeepTaskKindsWithPunctuation() throws {
    let source = RuntimeViewSource(workView(), schedule: { _ in })
    let reports = RuntimeReports()
    let id = try TaskID(2)
    let kind = "test.(tool) was cut off (again)"
    let text = runtimeParkingReport(id: id, kind: kind, restarts: 5)
    reports.report(SessionError.message(text))
    source.updateTasks(try workGraph([workNode(2, kind: kind, blocked: .restartLimit)]), visible: false)
    #expect(source.current().notices.isEmpty)
    source.recordRestarts(.init(id: id, conversationId: rootConversationID, kind: kind, version: 1,
        input: [:], state: .pending(checkpoint: ["phase": "work"]), restarts: 5))
    reports.attach(source)
    #expect(source.current().notices.count == 1)
    #expect(source.current().notices.first?.category == .taskParked)
    #expect(source.current().notices.first?.message == text)
    #expect(source.current().notices.first?.taskKind == kind)
    #expect(RuntimeReport(SessionError.message(text)).parked?.restarts == 5)
    #expect(RuntimeReport(SessionError.message(text + " extra")).parked == nil)
    reports.report(SessionError.message("Task 999 (missing) was cut off 5 times without progress; it is parked until retryTask()"))
    #expect(source.current().notices.last?.category == .report)
    #expect(source.current().terminal == nil)
}
