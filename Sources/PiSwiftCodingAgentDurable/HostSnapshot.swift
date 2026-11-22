import PiSwiftChord
import PiSwiftDurable

/// One transcript row. Its ID does not depend on the row position.
public struct DurableTranscriptRow: Sendable, Equatable, Identifiable {
    public enum ID: Sendable, Equatable, Hashable {
        case entry(ConversationID, EntryID)
        case gap(ConversationID, TranscriptGap)
        case earlier(ConversationID)
    }
    public let id: ID
    public let item: TranscriptItem

    public init(conversationId: ConversationID, item: TranscriptItem) {
        self.item = item
        switch item {
        case .entry(let entry): id = .entry(conversationId, entry.id)
        case .gap(let gap): id = .gap(conversationId, gap)
        case .earlier: id = .earlier(conversationId)
        }
    }
}

/// The saved result of a task that has ended.
public struct DurableTaskOutcome: Sendable, Equatable, Identifiable {
    public let id: TaskID
    public let kind: String
    public let conversationId: ConversationID
    public let outcome: TaskOutcome

    public init(id: TaskID, kind: String, conversationId: ConversationID, outcome: TaskOutcome) {
        self.id = id; self.kind = kind; self.conversationId = conversationId; self.outcome = outcome
    }
}

/// A run that ended without an answer.
public struct DurableRunEnding: Sendable, Equatable {
    public let failure: RunFailure
    public var reason: RunFailureReason { failure.reason }
    public var detail: String? { failure.detail }
    public var taskId: TaskID { failure.taskId }
    public var inputs: [SubmissionID] { failure.inputs }
    public var first: EntryID? { failure.first }

    public init(_ failure: RunFailure) { self.failure = failure }

    /// Short text for the saved reason. The detail remains available separately.
    public var text: String {
        switch reason {
        case .modelError: "Model request failed"
        case .noModel: "No model"
        case .aborted: "Run aborted"
        case .reset: "Run reset"
        case .faulted: "Run faulted"
        case .orphaned: "Run orphaned"
        case .interrupted: "Run interrupted"
        case .restartLimit: "Restart limit"
        case .nothingToAnswer: "No answer needed"
        case .turnLimit: "Turn limit reached"
        }
    }

    /// The fixed explanation. `detail` retains the exact saved diagnostic.
    public var explanation: String {
        switch reason {
        case .modelError: "The model returned an error."
        case .noModel: "Select a model for this conversation."
        case .aborted: "Work was stopped."
        case .reset: "The conversation context was reset."
        case .faulted: "A task failed."
        case .orphaned: "The saved task could not resume."
        case .interrupted: "Work stopped before an answer."
        case .restartLimit: "A task stopped after repeated restarts."
        case .nothingToAnswer: "The run had no input to answer."
        case .turnLimit: "The run used its allowed tool rounds."
        }
    }

    public var action: String {
        switch reason {
        case .modelError: "Continue or change model"
        case .noModel: "Select model"
        case .aborted, .reset, .interrupted, .orphaned, .restartLimit: "Continue"
        case .faulted: "Inspect task and continue"
        case .nothingToAnswer: "Submit input"
        case .turnLimit: "Continue"
        }
    }
}

/// Values for a mobile or desktop durable session interface.
public enum DurableRunActivity: String, Sendable, Equatable {
    case idle, progressing, sleeping, blocked
}

/// A tool call parked by a gate or by its execution callback.
public struct DurableParkedTool: Sendable, Equatable {
    public let slot: ToolSlot
    public let phase: String?
    public let until: Double?
    public let signals: [SignalKey]
    public let waitingOn: [TaskID]
    public let waitingPolicy: JoinPolicy?
    /// A call-phase wait can be an approval gate. The host owns the signal kind.
    public var isGated: Bool { phase == "call" }

    public init(slot: ToolSlot, phase: String? = nil, until: Double? = nil, signals: [SignalKey] = [],
                waitingOn: [TaskID] = [], waitingPolicy: JoinPolicy? = nil) {
        self.slot = slot; self.phase = phase; self.until = until; self.signals = signals
        self.waitingOn = waitingOn; self.waitingPolicy = waitingPolicy
    }
}

public struct DurableHostView: Sendable {
    public let transcript: TranscriptView
    public let rows: [DurableTranscriptRow]
    public let live: LiveState
    /// An appended answer still under review; the run's inputs remain open.
    public let pendingReview: LiveYield?
    public let inbox: InboxState
    public let agent: PiSwiftDurable.AgentState
    public let usage: UsageState
    public let tasks: TaskGraph?
    public let outcomes: [DurableTaskOutcome]
    public let ending: DurableRunEnding?
    public let notices: [Notice]
    public let session: DurableSessionView
    public let conversations: [ConversationSummary]
    public let models: [ModelSummary]
    public let terminal: DurableSessionTerminal?
    public let openMode: DurableOpenMode
    public let activity: DurableRunActivity
    public let sleepingTasks: [DurableSleepingTask]
    public let signalSleepingTasks: [DurableSignalSleepingTask]
    /// Sleeping or waiting top-level tool calls, with their task wake conditions.
    public let parkedTools: [DurableParkedTool]
    /// Queued inputs that survive conversation abort.
    public let keptInputs: [InboxItem]
    /// Tool result duration from first start through settlement, including parked time.
    public let toolDurationMs: [String: Int]
    public let documentError: String?

    /// Reads typed documents and retains a diagnostic if a document is invalid.
    public init(legacy: DurableView, transcript: TranscriptView, mode: DurableOpenMode,
                graph: TaskGraph? = nil,
                outcomes: [DurableTaskOutcome] = []) {
        let view = ConversationView(conversation: transcript.conversation, entries: [], docs: transcript.docs)
        var errors: [String] = []
        let live: LiveState
        do { live = try decodeLiveOf(view) }
        catch { live = LiveState(); errors.append("Live state: \(error)") }
        self.transcript = transcript
        rows = transcript.items.map { DurableTranscriptRow(conversationId: transcript.conversation.id, item: $0) }
        self.live = live
        pendingReview = live.run?.yield
        do { agent = try decodeAgentOf(view) }
        catch { agent = PiSwiftDurable.AgentState(); errors.append("Agent: \(error)") }
        if let document = transcript.docs["pi.usage"] {
            do { usage = try JSONValue.object(document).decode(UsageState.self) }
            catch { usage = UsageState(); errors.append("Usage: \(error)") }
        } else { usage = UsageState() }
        if let document = transcript.docs["pi.inbox"] {
            do { inbox = try JSONValue.object(document).decode(InboxState.self) }
            catch { inbox = InboxState(); errors.append("Inbox: \(error)") }
        } else { inbox = InboxState() }
        documentError = errors.isEmpty ? nil : errors.joined(separator: "; ")
        tasks = graph ?? legacy.tasks
        self.outcomes = outcomes
        ending = live.runFailure.map(DurableRunEnding.init)
        // The old TUI still receives its restart-limit parking notice. A new
        // consumer receives final task outcomes and typed reports instead.
        notices = legacy.notices
        session = legacy.session
        conversations = legacy.conversations
        models = legacy.models
        terminal = legacy.terminal
        openMode = mode
        switch legacy.activity {
        case .idle: activity = .idle
        case .progressing: activity = .progressing
        case .sleeping: activity = .sleeping
        case .blocked: activity = .blocked
        }
        sleepingTasks = legacy.sleepingTasks
        signalSleepingTasks = legacy.signalSleepingTasks
        keptInputs = inbox.items.filter { $0.onAbort == .keep }
        let graph = tasks
        parkedTools = (live.tools ?? []).filter { $0.status == .sleeping || $0.status == .waiting }.map { slot in
            let node = slot.taskId.flatMap { graph?.tasks[String($0.rawValue)] }
            let phase: String?
            let until: Double?
            let signals: [SignalKey]
            let waitingOn: [TaskID]
            let waitingPolicy: JoinPolicy?
            switch node?.state {
            case .sleeping(let value, let deadline):
                phase = value; until = deadline; signals = []; waitingOn = []; waitingPolicy = nil
            case .signalSleeping(let value, let deadline, let keys):
                phase = value; until = deadline; signals = keys; waitingOn = []; waitingPolicy = nil
            case .waiting(let value, let children, let policy):
                phase = value; until = nil; signals = []; waitingOn = children; waitingPolicy = policy
            default:
                phase = nil; until = nil; signals = []; waitingOn = []; waitingPolicy = nil
            }
            return DurableParkedTool(slot: slot, phase: phase, until: until, signals: signals,
                                     waitingOn: waitingOn, waitingPolicy: waitingPolicy)
        }
        var durations: [String: Int] = [:]
        for item in transcript.items {
            guard case .entry(let entry) = item else { continue }
            for message in (try? entry.messages()) ?? [] {
                if case .toolResult(let result) = message, let duration = result.durationMs {
                    durations[result.toolCallId] = duration
                }
            }
        }
        toolDurationMs = durations
    }
}

extension Notice {
    /// A label from the typed report. Unknown report kinds retain their saved name.
    public var reportLabel: String? {
        guard let kind = reportInfo?.kind ?? reportType else { return nil }
        switch kind {
        case "storage_failed": return "Storage failed"
        case "task_interrupted": return "Task interrupted"
        case "task_faulted": return "Task failed"
        case "migration_failed": return "Migration failed"
        case "task_error": return "Task error"
        case "task_outdated": return "Task definition unavailable"
        case "extension_error": return "Extension error"
        case "host_error": return "Host callback failed"
        case "listener_error": return "Listener failed"
        default: return kind
        }
    }
}
