import Testing
import PiSwiftChord
import PiSwiftDurable

private let reportTask = ReportTask(id: try! TaskID(1), kind: "test.task", conversationId: rootConversationID)

@Test(arguments: [
    ReportInfo.storageFailed,
    .taskInterrupted(task: reportTask, reason: .restartLimit, restarts: 5),
    .taskInterrupted(task: reportTask, extension: "test", reason: .interrupted, restarts: 3),
    ReportInfo.sessionFailed,
    .taskFaulted(task: reportTask, extension: "test", reason: .threw),
    .taskFaulted(task: reportTask, reason: .restartLimit),
    .taskParked(task: reportTask, extension: "test"),
    .migrationFailed(task: reportTask),
    .taskError(task: reportTask, extension: "test"),
    .taskOutdated(task: reportTask, reason: .missingTask),
    .taskOutdated(task: reportTask, reason: .taskTooOld),
    .taskOutdated(task: reportTask, reason: .migrationFailed),
    .taskOutdated(task: reportTask, extension: "test", reason: .incompatibleTask),
    .extensionError(),
    .extensionError(extension: "test", task: reportTask, conversationId: rootConversationID),
    .hostError(callback: .env),
    .hostError(callback: .models, task: reportTask),
    .hostError(callback: .telemetry),
    .listenerError
])
func reportInfoUsesTheUpstreamTaggedJSONShape(info: ReportInfo) throws {
    let json = try JSONValue(encoding: info)
    // v1.5.2 D5a types.ts:173–206: reports use the kind tag.
    #expect(json["kind"] == .string(info.kind))
    #expect(try json.decode(ReportInfo.self) == info)
    let taskJSON = try info.task.map { try JSONValue(encoding: $0) }
    #expect(json["task"] == taskJSON)
    #expect(json["extension"] == info.extension.map(JSONValue.string))
    switch info {
    case .taskFaulted(_, _, let reason): #expect(json["reason"] == .string(reason.rawValue))
    case .taskInterrupted(_, _, let reason, let restarts):
        #expect(json["reason"] == .string(reason.rawValue))
        #expect(json["restarts"] == .number(restarts))
    case .taskOutdated(_, _, let reason): #expect(json["reason"] == .string(reason.rawValue))
    case .hostError(let callback, _): #expect(json["callback"] == .string(callback.rawValue))
    default: #expect(json["reason"] == nil && json["callback"] == nil)
    }
}

@Test func reportSourcesKeepTheUpstreamStringValues() {
    // v1.5.2 D5a types.ts:148–151: telemetry is a named host callback.
    #expect(HostCallback.allCases.map(\.rawValue) == ["now", "settings", "registry", "env", "models", "setTimer", "onWake", "telemetry"])
    #expect(ReportFrom.extension().type == "extension")
    #expect(ReportFrom.host(callback: .now).type == "host")
    #expect(ReportInfo.FaultReason.restartLimit.rawValue == "restart_limit")
    #expect(ReportInfo.OutdatedReason.missingTask.rawValue == "missing_task")
    #expect(ReportInfo.OutdatedReason.incompatibleTask.rawValue == "incompatible_task")
}

// v1.5.2 D5a types.ts:173–206: one callback argument carries the flat tag and error.
@Test func reportEncodesItsTaggedFieldsInOneObject() throws {
    let report = Report(.taskInterrupted(task: reportTask, extension: "test", reason: .interrupted, restarts: 3),
        error: SessionError.message("request stopped"))
    let value = try JSONValue(encoding: report)
    #expect(value["kind"] == "task_interrupted")
    #expect(value["task"] == (try JSONValue(encoding: reportTask)))
    #expect(value["extension"] == "test")
    #expect(value["reason"] == "interrupted")
    #expect(value["restarts"] == 3)
    #expect(value["error"] == "request stopped")
    #expect(report.kind == "task_interrupted" && report.reason == "interrupted" && report.restarts == 3)
    #expect(try value.decode(Report.self).kind == report.kind)
}
