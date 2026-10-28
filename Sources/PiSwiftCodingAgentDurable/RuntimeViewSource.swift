import Dispatch
import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable
import Synchronization

/// Stores view changes and schedules one notification for each group of changes.
/// Listeners run on a private serial queue, after the change (upstream `setImmediate`),
/// never on the main thread by default: a UI host hops to its main actor itself.
internal final class RuntimeViewSource: DurableViewSource {
    private static let notifications = DispatchQueue(label: "PiSwiftCodingAgentDurable.view-notifications")

    private struct State: Sendable {
        var view: DurableView
        var listeners: [Int: @Sendable () -> Void] = [:]
        var nextListener = 0
        var nextNotice: Int
        var scheduled = false
        var finished = false
        var graph: TaskGraph?
        var tasksVisible = false
        var restarts: [TaskID: Double] = [:]
        var faultedTasks = Set<TaskID>()
        var faultReports: [String: Int] = [:]
        var parkedNotices = Set<TaskID>()
    }

    private let state: Mutex<State>
    private let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void

    init(_ view: DurableView,
         schedule: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil) {
        state = Mutex(State(view: view, nextNotice: (view.notices.map(\.id).max() ?? 0) + 1,
                            graph: view.tasks, tasksVisible: view.tasks != nil))
        self.schedule = schedule ?? { callback in Self.notifications.async(execute: callback) }
    }

    func current() -> DurableView { state.withLock { $0.view } }

    func subscribe(_ listener: @escaping @Sendable () -> Void) -> DurableViewSubscription {
        let id = state.withLock { state -> Int? in
            guard !state.finished else { return nil }
            let id = state.nextListener
            state.nextListener += 1
            state.listeners[id] = listener
            return id
        }
        return DurableViewSubscription { [weak self] in
            guard let id else { return }
            self?.state.withLock { $0.listeners[id] = nil }
        }
    }

    func updateConversation(_ value: ConversationView) {
        update { view in
            view = DurableView(session: view.session, conversation: value,
                               conversations: view.conversations, models: view.models,
                               notices: view.notices, tasks: view.tasks, terminal: view.terminal)
        }
    }

    func updateTasks(_ value: TaskGraph?, visible: Bool = true) {
        change { state in
            if let value { state.graph = value }
            state.tasksVisible = visible && value != nil
        }
    }

    /// Seeds counts through the public record read before restored work starts.
    func recordRestarts(_ record: TaskRecord) {
        change { $0.restarts[record.id] = record.restarts }
    }

    func record(_ publication: CommitPublication, graph: TaskGraph? = nil) {
        change { state in
            if let graph { state.graph = graph }
            var summaries = state.view.conversations
            for change in publication.changes {
                switch change {
                case .conversation(let record):
                    summaries.append(ConversationSummary(
                        id: record.id,
                        label: record.id == rootConversationID ? "main" : "subagent \(record.id.rawValue)"))
                case .entry(let entry):
                    guard let title = runtimeTitle(of: entry) else { continue }
                    summaries = summaries.map { summary in
                        guard summary.id == entry.conversationId, summary.title == nil else { return summary }
                        return ConversationSummary(id: summary.id, label: summary.label, title: title)
                    }
                case .task(let record):
                    state.restarts[record.id] = record.state.status == "terminal" ? nil : record.restarts
                    let outcome: TaskOutcome
                    switch record.state {
                    case .completing(let value, _), .terminal(let value, _): outcome = value
                    default: continue
                    }
                    if case .faulted(let error, _) = outcome,
                       state.faultedTasks.insert(record.id).inserted {
                        Self.appendNotice(&state, .error, error.message, category: .taskFault,
                                          taskId: record.id, taskKind: record.kind)
                        state.faultReports[error.message, default: 0] += 1
                    }
                default: break
                }
            }
            let view = state.view
            state.view = DurableView(session: view.session, conversation: view.conversation,
                               conversations: summaries, models: view.models,
                               notices: view.notices, tasks: view.tasks, terminal: view.terminal)
        }
    }

    func notice(_ level: Notice.Level, _ message: String) {
        change { Self.appendNotice(&$0, level, message) }
    }

    private static func appendNotice(_ state: inout State, _ level: Notice.Level, _ message: String,
                                     category: Notice.Category = .operation,
                                     taskId: TaskID? = nil, taskKind: String? = nil) {
        let view = state.view
        let notice = Notice(id: state.nextNotice, level: level, message: message,
                            category: category, taskId: taskId, taskKind: taskKind)
        state.nextNotice += 1
        state.view = DurableView(session: view.session, conversation: view.conversation,
                                 conversations: view.conversations, models: view.models,
                                 notices: Array((view.notices + [notice]).suffix(20)), tasks: view.tasks,
                                 terminal: view.terminal)
    }

    func report(_ report: RuntimeReport) {
        change { state in
            // The fault commit arrives before its callback. Keep one notice with its task data.
            if let count = state.faultReports[report.description], count > 0 {
                state.faultReports[report.description] = count == 1 ? nil : count - 1
                return
            }
            if let parked = report.parked,
               let node = state.graph?.tasks[String(parked.id.rawValue)],
               node.blocked == .restartLimit, node.kind == parked.kind {
                guard state.parkedNotices.insert(parked.id).inserted else { return }
                Self.appendNotice(&state, .warning, report.message, category: .taskParked,
                                  taskId: parked.id, taskKind: parked.kind)
            } else {
                Self.appendNotice(&state, .warning, report.message, category: .report,
                                  taskId: report.taskId, taskKind: report.taskKind)
            }
        }
    }

    func fail(_ error: any Error) { notice(.error, runtimeErrorMessage(error)) }

    /// Records the first terminal result and its failure notice in one change.
    func terminate(_ result: SessionCloseResult) {
        change { state in
            let view = state.view
            guard view.terminal == nil else { return }
            let terminal: DurableSessionTerminal
            var notices = view.notices
            switch result {
            case .closed: terminal = .closed
            case .failed(let error):
                let message = runtimeErrorMessage(error)
                terminal = .failed(message: message)
                notices = Array((notices + [Notice(id: state.nextNotice, level: .error, message: message,
                                                  category: .sessionFailed)]).suffix(20))
                state.nextNotice += 1
            }
            state.view = DurableView(session: view.session, conversation: view.conversation,
                                     conversations: view.conversations, models: view.models,
                                     notices: notices, tasks: view.tasks, terminal: terminal)
        }
    }

    func finish(deliverFinal: Bool = false) {
        let listeners = state.withLock { state -> [@Sendable () -> Void] in
            guard !state.finished else { return [] }
            let deliverPending = deliverFinal && state.scheduled
            state.finished = true
            state.scheduled = false
            let listeners = deliverPending ? state.listeners.sorted { $0.key < $1.key }.map(\.value) : []
            state.listeners.removeAll()
            return listeners
        }
        if !listeners.isEmpty { schedule { for listener in listeners { listener() } } }
    }

    private func update(_ body: (inout DurableView) -> Void) {
        change { body(&$0.view) }
    }

    private func change(_ body: (inout State) -> Void) {
        let shouldSchedule = state.withLock { state in
            guard !state.finished else { return false }
            let previous = state.view
            body(&state)
            refreshWork(&state)
            guard state.view != previous, !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        if shouldSchedule {
            schedule { [weak self] in self?.notify() }
        }
    }

    private func refreshWork(_ state: inout State) {
        let work = runtimeWork(graph: state.graph, conversation: state.view.conversation, restarts: state.restarts)
        // A saved pending task can already be parked at open, without a new core report.
        let parked = state.graph?.tasks.values.filter { $0.blocked == .restartLimit } ?? []
        state.parkedNotices.formIntersection(Set(parked.map(\.id)))
        for node in parked.sorted(by: { $0.id < $1.id }) {
            guard let count = state.restarts[node.id], state.parkedNotices.insert(node.id).inserted else { continue }
            let report = runtimeParkingReport(id: node.id, kind: node.kind, restarts: count)
            Self.appendNotice(&state, .warning, report, category: .taskParked,
                              taskId: node.id, taskKind: node.kind)
        }
        let view = state.view
        state.view = DurableView(session: view.session, conversation: view.conversation,
                                 conversations: view.conversations, models: view.models, notices: view.notices,
                                 tasks: state.tasksVisible ? state.graph : nil, terminal: view.terminal,
                                 blockedTasks: work.blocked, sleepingTasks: work.sleeping,
                                 activity: work.activity, queuedInputs: work.queued)
    }

    private func notify() {
        let listeners = state.withLock { state -> [@Sendable () -> Void] in
            guard !state.finished else { return [] }
            state.scheduled = false
            return state.listeners.sorted { $0.key < $1.key }.map(\.value)
        }
        for listener in listeners { listener() }
    }
}

/// Holds reports until the view can show them.
internal final class RuntimeReports: Sendable {
    private struct State: Sendable {
        var source: RuntimeViewSource?
        var pending: [RuntimeReport] = []
        var draining = false
    }
    private let state = Mutex(State())

    func report(_ error: any Error) {
        let report = RuntimeReport(error)
        let drain = state.withLock { state in
            state.pending.append(report)
            guard state.source != nil, !state.draining else { return false }
            state.draining = true
            return true
        }
        if drain { flush() }
    }

    func attach(_ source: RuntimeViewSource) {
        let drain = state.withLock { state in
            state.source = source
            guard !state.draining, !state.pending.isEmpty else { return false }
            state.draining = true
            return true
        }
        if drain { flush() }
    }

    private func flush() {
        while let batch = state.withLock({ state -> (RuntimeViewSource, [RuntimeReport])? in
            guard let source = state.source, !state.pending.isEmpty else {
                state.draining = false
                return nil
            }
            let messages = state.pending
            state.pending.removeAll()
            return (source, messages)
        }) {
            for report in batch.1 { batch.0.report(report) }
        }
    }
}

/// Gets the text from the first user model message and removes extra spaces.
internal func runtimeTitle(of entry: EntryRecord) -> String? {
    guard entry.kind == "pi.user" || (!entry.kind.isEmpty && !entry.kind.hasPrefix("pi.")),
          let raw = entry.model else { return nil }
    // Decode the complete contribution before selecting its first user message.
    // A malformed contribution cannot supply a conversation title.
    let messages: [Message]
    do { messages = try entry.messages() ?? [] }
    catch { return nil }
    for (value, message) in zip(raw, messages) {
        guard case .user(let user) = message else { continue }
        guard let content = value.objectValue?["content"] else { return nil }
        let text: String
        switch (content, user.content) {
        case (.string, .text(let value)): text = value
        case (.array(let rawBlocks), .blocks(let blocks)):
            if entry.kind != "pi.user" {
                guard rawBlocks.allSatisfy({ block in
                    guard let object = block.objectValue else { return false }
                    switch object["type"] {
                    case .string("text"): return object["text"]?.stringValue != nil
                    case .string("image"):
                        return object["data"]?.stringValue != nil && object["mimeType"]?.stringValue != nil
                    default: return false
                    }
                }) else { return nil }
            }
            text = blocks.compactMap { block -> String? in
                if case .text(let value) = block { return value.text }
                return nil
            }.joined(separator: " ")
        default: return nil
        }
        return text.unicodeScalars.split(whereSeparator: runtimeTitleSpace).map(String.init).joined(separator: " ")
    }
    return nil
}

/// Uses the ECMAScript whitespace and line terminator set.
private func runtimeTitleSpace(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x0009...0x000D, 0x0020, 0x00A0, 0x1680, 0x2000...0x200A,
         0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
        true
    default:
        false
    }
}

internal func runtimeErrorMessage(_ error: any Error) -> String {
    if let failed = error as? SessionFailed { return runtimeErrorMessage(failed.cause) }
    return (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
}
