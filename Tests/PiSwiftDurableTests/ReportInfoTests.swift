import Testing
import PiSwiftChord
import PiSwiftDurable

private let reportTask = ReportTask(id: try! TaskID(1), kind: "test.task", conversationId: rootConversationID)

@Test(arguments: [
    ReportInfo.sessionFailed,
    .taskFaulted(task: reportTask, extension: "test", reason: .threw),
    .taskFaulted(task: reportTask, reason: .restartLimit),
    .taskParked(task: reportTask, extension: "test"),
    .migrationFailed(task: reportTask),
    .taskError(task: reportTask, extension: "test"),
    .taskOutdated(task: reportTask, reason: .missingTask),
    .taskOutdated(task: reportTask, extension: "test", reason: .incompatibleTask),
    .extensionError(),
    .extensionError(extension: "test", task: reportTask, conversationId: rootConversationID),
    .hostError(callback: .env),
    .hostError(callback: .models, task: reportTask),
    .listenerError
])
func reportInfoUsesTheUpstreamTaggedJSONShape(info: ReportInfo) throws {
    let json = try JSONValue(encoding: info)
    #expect(json["type"] == .string(info.type))
    #expect(try json.decode(ReportInfo.self) == info)
    let taskJSON = try info.task.map { try JSONValue(encoding: $0) }
    #expect(json["task"] == taskJSON)
    #expect(json["extension"] == info.extension.map(JSONValue.string))
    switch info {
    case .taskFaulted(_, _, let reason): #expect(json["reason"] == .string(reason.rawValue))
    case .taskOutdated(_, _, let reason): #expect(json["reason"] == .string(reason.rawValue))
    case .hostError(let callback, _): #expect(json["callback"] == .string(callback.rawValue))
    default: #expect(json["reason"] == nil && json["callback"] == nil)
    }
}

@Test func reportSourcesKeepTheUpstreamStringValues() {
    #expect(HostCallback.allCases.map(\.rawValue) == ["now", "settings", "registry", "env", "models", "setTimer", "onWake"])
    #expect(ReportFrom.extension().type == "extension")
    #expect(ReportFrom.host(callback: .now).type == "host")
    #expect(ReportInfo.FaultReason.restartLimit.rawValue == "restart_limit")
    #expect(ReportInfo.OutdatedReason.missingTask.rawValue == "missing_task")
    #expect(ReportInfo.OutdatedReason.incompatibleTask.rawValue == "incompatible_task")
}
