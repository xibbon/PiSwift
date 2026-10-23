import Dispatch
import Foundation
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
    }

    private let state: Mutex<State>
    private let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void

    init(_ view: DurableView,
         schedule: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil) {
        state = Mutex(State(view: view, nextNotice: (view.notices.map(\.id).max() ?? 0) + 1))
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

    func updateTasks(_ value: TaskGraph?) {
        update { view in
            view = DurableView(session: view.session, conversation: view.conversation,
                               conversations: view.conversations, models: view.models,
                               notices: view.notices, tasks: value, terminal: view.terminal)
        }
    }

    func record(_ publication: CommitPublication) {
        update { view in
            var summaries = view.conversations
            for change in publication.changes {
                switch change {
                case .conversation(let record):
                    summaries.append(ConversationSummary(
                        id: record.id,
                        label: record.id == rootConversationID ? "main" : "subagent \(record.id.rawValue)"))
                case .entry(let entry) where entry.kind == "pi.user":
                    guard let title = runtimeTitle(of: entry) else { continue }
                    summaries = summaries.map { summary in
                        guard summary.id == entry.conversationId, summary.title == nil else { return summary }
                        return ConversationSummary(id: summary.id, label: summary.label, title: title)
                    }
                default: break
                }
            }
            view = DurableView(session: view.session, conversation: view.conversation,
                               conversations: summaries, models: view.models,
                               notices: view.notices, tasks: view.tasks, terminal: view.terminal)
        }
    }

    func notice(_ level: Notice.Level, _ message: String) {
        change { state in
            let view = state.view
            let notice = Notice(id: state.nextNotice, level: level, message: message)
            state.nextNotice += 1
            state.view = DurableView(session: view.session, conversation: view.conversation,
                                     conversations: view.conversations, models: view.models,
                                     notices: Array((view.notices + [notice]).suffix(20)), tasks: view.tasks,
                                     terminal: view.terminal)
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
                notices = Array((notices + [Notice(id: state.nextNotice, level: .error, message: message)]).suffix(20))
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
            guard state.view != previous, !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        if shouldSchedule {
            schedule { [weak self] in self?.notify() }
        }
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
        var pending: [String] = []
        var draining = false
    }
    private let state = Mutex(State())

    func report(_ error: any Error) {
        let message = runtimeErrorMessage(error)
        let drain = state.withLock { state in
            state.pending.append(message)
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
        while let batch = state.withLock({ state -> (RuntimeViewSource, [String])? in
            guard let source = state.source, !state.pending.isEmpty else {
                state.draining = false
                return nil
            }
            let messages = state.pending
            state.pending.removeAll()
            return (source, messages)
        }) {
            for message in batch.1 { batch.0.notice(.warning, message) }
        }
    }
}

/// Gets the text from the first user model message and removes extra spaces.
internal func runtimeTitle(of entry: EntryRecord) -> String? {
    guard entry.kind == "pi.user", let message = entry.model?.first?.objectValue,
          message["role"] == .string("user") else { return nil }
    let text: String
    switch message["content"] {
    case .string(let value): text = value
    case .array(let blocks):
        text = blocks.compactMap { block -> String? in
            guard let object = block.objectValue, object["type"] == .string("text"),
                  case .string(let value) = object["text"] else { return nil }
            return value
        }.joined(separator: " ")
    default: return nil
    }
    return text.unicodeScalars.split(whereSeparator: runtimeTitleSpace).map(String.init).joined(separator: " ")
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
