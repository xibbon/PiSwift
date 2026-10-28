import Foundation
import PiSwiftChord
import PiSwiftDurable

/// Retains typed report data while the runtime opens.
internal struct RuntimeReport: Sendable {
    let info: ReportInfo?
    let message: String
    let description: String
    let parked: DurableBlockedTask?
    let taskId: TaskID?
    let taskKind: String?

    init(_ error: any Error, info: ReportInfo? = nil) {
        self.info = info
        message = runtimeErrorMessage(error)
        description = String(describing: error)
        if let task = info?.task {
            taskId = task.id; taskKind = task.kind
        } else if let handover = error as? TaskHandoverError {
            taskId = handover.taskId; taskKind = handover.kind
        } else {
            taskId = nil; taskKind = nil
        }
        if info == nil, let error = error as? SessionError, case .message(let text) = error {
            parked = runtimeParkedReport(text)
        } else { parked = nil }
    }
}

internal func runtimeParkingReport(id: TaskID, kind: String, restarts: Double) -> String {
    let count = (try? JSONValue.number(restarts).jsonText()) ?? String(restarts)
    return "Task \(id.rawValue) (\(kind)) was cut off \(count) times without progress; it is parked until retryTask()"
}

/// Matches only the complete D3 SessionError message, then checks its exact reconstruction.
private func runtimeParkedReport(_ text: String) -> DurableBlockedTask? {
    let suffix = " times without progress; it is parked until retryTask()"
    guard text.hasPrefix("Task "), text.hasSuffix(suffix) else { return nil }
    let body = text.dropFirst(5).dropLast(suffix.count)
    guard let start = body.range(of: " ("),
          let end = body.range(of: ") was cut off ", options: .backwards),
          start.upperBound <= end.lowerBound,
          let rawId = Int64(body[..<start.lowerBound]), let id = try? TaskID(rawId),
          let restarts = Double(body[end.upperBound...]), restarts.isFinite, restarts >= 0 else { return nil }
    let kind = String(body[start.upperBound..<end.lowerBound])
    guard runtimeParkingReport(id: id, kind: kind, restarts: restarts) == text else { return nil }
    return DurableBlockedTask(id: id, kind: kind, reason: .restartLimit, restarts: restarts, report: text)
}

internal struct RuntimeWork {
    var blocked: [DurableBlockedTask] = []
    var sleeping: [DurableSleepingTask] = []
    var activity: DurableActivity = .idle
    var queued: [InboxItem] = []
}

/// Keeps the status independent of task panel visibility and live.run's lifetime.
internal func runtimeWork(graph: TaskGraph?, conversation: ConversationView,
                          restarts: [TaskID: Double]) -> RuntimeWork {
    var work = RuntimeWork()
    if let inbox = conversation.docs["pi.inbox"],
       let value = try? JSONValue.object(inbox).decode(InboxState.self) {
        work.queued = value.items.filter { $0.mode != .write }
    }
    guard let graph else { return work }
    let nodes = graph.tasks.values.sorted { $0.id < $1.id }
    var included = Set<TaskID>()
    var conversations: Set<ConversationID> = [conversation.conversation.id]
    // Include child conversations and tasks reached through the ownership graph.
    var changed = true
    while changed {
        changed = false
        for node in nodes where !included.contains(node.id) {
            if conversations.contains(node.conversationId) || node.owner.map({ included.contains($0) }) == true {
                included.insert(node.id)
                conversations.formUnion(node.conversations)
                changed = true
            }
        }
    }
    var active = false
    for node in nodes where included.contains(node.id) {
        if let reason = node.blocked {
            let count = restarts[node.id] ?? 0
            work.blocked.append(.init(id: node.id, kind: node.kind, reason: reason, restarts: count,
                report: reason == .restartLimit ? runtimeParkingReport(id: node.id, kind: node.kind, restarts: count) : nil))
        }
        if case .sleeping(let phase, let until) = node.state {
            work.sleeping.append(.init(id: node.id, kind: node.kind, phase: phase, until: until))
        }
        guard node.blocked == nil else { continue }
        switch node.state {
        case .pending, .running: active = true
        case .sleeping, .waiting, .completing: break
        }
    }
    if active { work.activity = .progressing }
    else if work.blocked.contains(where: { $0.reason == .restartLimit }) { work.activity = .parked }
    else if !work.blocked.isEmpty { work.activity = .blocked }
    else if !work.sleeping.isEmpty { work.activity = .sleeping }
    else if !included.isEmpty { work.activity = .progressing }
    return work
}
