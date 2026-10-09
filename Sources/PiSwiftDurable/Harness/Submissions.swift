import PiSwiftAI
import PiSwiftChord
import Synchronization

/// User text or content blocks submitted to a conversation.
public typealias UserInput = UserContent
/// Selects steering, follow-up, or rejection when a conversation is active.
public enum WhenBusy: String, Sendable {
    /// Admits input at the next steering boundary.
    case steer
    /// Queues input for the next follow-up boundary.
    case followUp
    /// Rejects input while the conversation has active work.
    case reject
}
/// User input or an entry write offered to a conversation.
public enum SubmissionDraft: Sendable {
    /// Offers user content with an optional busy policy and request key.
    case input(content: UserInput, whenBusy: WhenBusy? = nil, requestId: String? = nil)
    /// Offers an entry draft with an optional request key.
    case write(entry: EntryDraft, requestId: String? = nil)
    /// An optional conversation-scoped key that makes request admission idempotent.
    public var requestId: String? { switch self { case .input(_, _, let id), .write(_, let id): id } }
    /// The stored input or write submission tag.
    public var type: String { switch self { case .input: "input"; case .write: "write" } }
}
/// An input with reject-on-busy policy could not enter the conversation.
public struct ConversationBusy: Error, Sendable, CustomStringConvertible {
    /// The conversation that owns or is addressed by this value.
    public let conversationId: ConversationID
    /// Records the conversation that rejected input while busy.
    public init(conversationId: ConversationID) { self.conversationId = conversationId }
    /// Text that describes this value or error to the caller.
    public var description: String { "Conversation \(conversationId.rawValue) is busy" }
}
/// The result of an attempt to remove a submission before it is placed.
public enum SubmissionAbortResult: String, Sendable {
    /// The queued submission was withdrawn before placement.
    case aborted
    /// The submission already has a placement entry.
    case alreadyPlaced = "already_placed"
    /// The submission or transaction already has a final state.
    case settled
    /// No submission exists with the supplied ID.
    case notFound = "not_found"
}
/// The final stored submission, including its answer or unanswered reason.
public struct SettledSubmission: Sendable, Equatable {
    /// The durable record from which this typed value is derived.
    public let record: SubmissionRecord
    /// The stable identifier of this record or handle.
    public var id: SubmissionID { record.id }
    /// The conversation that owns or is addressed by this value.
    public var conversationId: ConversationID { record.conversationId }
    /// The stored execution or submission state tag.
    public var status: String { record.status }
    /// The answer entry of a done input submission, or nil for other settlements.
    public var answer: EntryID? { if case .input(_, _, _, .done(_, let answer, _)) = record { return answer }; return nil }
    /// The unanswered reason, or nil when the submission has an answer.
    public var reason: String? {
        switch record { case .input(_, _, _, .unanswered(let reason, _, _, _)), .write(_, _, _, .unanswered(let reason, _, _)): reason; default: nil }
    }
    internal init(_ record: SubmissionRecord) { self.record = record }
}
/// The final submission receipt returned by a submission wait.
public typealias SettledSubmissionRecord = SettledSubmission
/// A handle that reads, waits for, or aborts one durable submission.
public struct Submission: Sendable {
    /// The stable identifier of this record or handle.
    public let id: SubmissionID
    private let submissions: Submissions
    private let binding: InvocationBinding?
    internal init(id: SubmissionID, submissions: Submissions, binding: InvocationBinding? = nil) {
        self.id = id; self.submissions = submissions; self.binding = binding
    }
    internal func bound(_ binding: InvocationBinding?) -> Submission { Submission(id: id, submissions: submissions, binding: binding) }
    private func context(_ context: ChordContext) throws -> ChordContext {
        try binding?.check(); return binding.map { context.withAbortSignal($0.signal) } ?? context
    }
    /// Reads the latest durable submission record.
    public func status(context: ChordContext) async throws -> SubmissionRecord {
        try await withTaskCancellationContext(try self.context(context)) { try await submissions.status(id: id, context: $0) }
    }
    /// Resumes scheduling and waits for this submission to settle, or for caller cancellation.
    public func wait(context: ChordContext) async throws -> SettledSubmission {
        try await withTaskCancellationContext(try self.context(context)) { try await submissions.wait(id: id, context: $0) }
    }
    /// Withdraws this submission if it has not been placed. Throws if the submission is absent.
    public func abort(context: ChordContext) async throws -> SubmissionAbortResult {
        let result = try await withTaskCancellationContext(try self.context(context)) { try await submissions.abort(id: id, context: $0) }
        if result == .notFound { throw SessionError.message("Submission \(id.rawValue) does not exist") }
        return result
    }
}
internal final class Submissions: Sendable {
    private let session: Session
    private let storage: any DurableStorage
    private let now: @Sendable () -> Int64
    private let settings: @Sendable () -> Settings
    private let resume: @Sendable () -> Void
    private let waiters = Waiters<SubmissionID, SettledSubmission>()
    private struct State: Sendable { var closed = false; var subscriptions: [SessionSubscription] = [] }
    private let state = Mutex(State())
    internal func hasPendingWait(id: SubmissionID) -> Bool { waiters.keys.contains(id) }
    init(session: Session, storage: any DurableStorage, now: @escaping @Sendable () -> Int64,
         settings: @escaping @Sendable () -> Settings, resume: @escaping @Sendable () -> Void) throws {
        self.session = session; self.storage = storage; self.now = now; self.settings = settings; self.resume = resume
        let commits = try session.subscribeCommits { [weak self] publication, _ in self?.observe(publication) }
        let close = try session.subscribeClose { [weak self] in
            self?.state.withLock { $0.closed = true }; self?.waiters.rejectAll(closedError())
        }
        state.withLock { $0.subscriptions = [commits, close] }
    }
    func submit(conversationId: ConversationID, draft: SubmissionDraft, context: ChordContext) async throws -> Submission {
        resume()
        let id = try await session.commit({ tx in
            try await admitSubmission(tx: tx, conversationId: conversationId, draft: draft, now: now(), queueModes: settings())
        }, context: context)
        return Submission(id: id, submissions: self)
    }
    func get(id: SubmissionID, context: ChordContext) async throws -> Submission? {
        try context.abortSignal?.throwIfAborted()
        let record = try await session.readOnLine { try await storage.submission(id, context: context) }
        return record.map { Submission(id: $0.id, submissions: self) }
    }
    func status(id: SubmissionID, context: ChordContext) async throws -> SubmissionRecord {
        try context.abortSignal?.throwIfAborted()
        guard let record = try await session.readOnLine({ try await storage.submission(id, context: context) }) else {
            throw SessionError.message("Submission \(id.rawValue) does not exist")
        }
        return record
    }
    func wait(id: SubmissionID, context: ChordContext) async throws -> SettledSubmission {
        resume()
        let promise: HarnessPromise<SettledSubmission> = try await session.readOnLine {
            try context.abortSignal?.throwIfAborted()
            guard let record = try await storage.submission(id, context: context) else { throw SessionError.message("Submission \(id.rawValue) does not exist") }
            if isSettled(record) { let promise = HarnessPromise<SettledSubmission>(); promise.finish(.success(SettledSubmission(record))); return promise }
            if state.withLock({ $0.closed }) { throw closedError() }
            return try waiters.add(id, context: context)
        }
        return try await promise.value()
    }
    func abort(id: SubmissionID, context: ChordContext, conversationId: ConversationID? = nil) async throws -> SubmissionAbortResult {
        try await session.commit({ tx in
            guard let record = try await tx.submission(id), conversationId == nil || record.conversationId == conversationId else { return .notFound }
            if record.status == "queued" {
                try tx.settleSubmission(id, settlement: .unanswered(reason: "aborted"))
                try await removeInboxItem(tx: tx, conversationId: record.conversationId, id: id)
                return .aborted
            }
            return record.status == "placed" ? .alreadyPlaced : .settled
        }, context: context)
    }
    private func observe(_ publication: CommitPublication) {
        for change in publication.changes {
            if case .submission(let value) = change, isSettled(value) { waiters.resolve(value.id, value: SettledSubmission(value)) }
        }
    }
}
private func isSettled(_ record: SubmissionRecord) -> Bool { record.status == "done" || record.status == "unanswered" }

internal func admitSubmission(tx: Transaction, conversationId: ConversationID, draft: SubmissionDraft, now: Int64, queueModes: Settings) async throws -> SubmissionID {
    if let requestId = draft.requestId, let existing = try await tx.submissionByRequest(conversationId, requestId: requestId) {
        guard existing.type == draft.type else { throw SessionError.message("Request \(requestId) already identifies a submission of type \(existing.type)") }
        return existing.id
    }
    let live = try await tx.doc(LiveDoc, conversationId: conversationId)
    let busy = try live.get("run") != nil
    if busy, case .input(_, .reject, _) = draft { throw ConversationBusy(conversationId: conversationId) }
    let boundary = busy ? nil : try await prepareBoundary(tx: tx, conversationId: conversationId, modes: queueModes)
    let queued = try boundary?.inbox.child("items")?.count() ?? 0
    if boundary == nil || queued > 0 {
        let record = try await tx.createSubmission(draft.type == "input" ? .input(conversationId: conversationId, requestId: draft.requestId) : .write(conversationId: conversationId, requestId: draft.requestId))
        let inbox: JSONDraft
        if let boundary { inbox = boundary.inbox } else { inbox = try await tx.doc(InboxDoc, conversationId: conversationId) }
        let item: InboxItem
        switch draft {
        case .input(let content, let whenBusy, _):
            item = InboxItem(id: record.id, mode: whenBusy == .steer ? .steer : .followUp, content: try inputContentJSON(content))
        case .write(let entry, _): item = InboxItem(id: record.id, mode: .write, entry: entry)
        }
        try inbox.child("items")!.append(JSONValue(encoding: item))
        if let boundary {
            let result = try await applyBoundary(tx: tx, boundary: boundary, at: .final, now: now)
            if !result.users.isEmpty { try await startRun(tx: tx, conversationId: conversationId, live: live, inputs: result.users) }
        }
        return record.id
    }
    switch draft {
    case .write(let entry, let requestId):
        if isStale(boundary: boundary!, entry: entry) {
            return try await tx.createSubmission(.write(conversationId: conversationId, requestId: requestId, state: .unanswered(reason: "stale"))).id
        }
        let appended = try await tx.appendEntry(conversationId, value: entry)
        return try await tx.createSubmission(.write(conversationId: conversationId, requestId: requestId, state: .done(entry: appended.id))).id
    case .input(let content, _, let requestId):
        let messages = try EntryRecord.encodeMessages([.user(UserMessage(content: content, timestamp: now))])
        let entry = try await tx.appendEntry(conversationId, value: EntryDraft(kind: userEntry.kind, model: messages))
        let record = try await tx.createSubmission(.input(conversationId: conversationId, requestId: requestId, state: .placed(entry: entry.id)))
        try await startRun(tx: tx, conversationId: conversationId, live: live, inputs: [record.id])
        return record.id
    }
}
private func inputContentJSON(_ content: UserInput) throws -> JSONValue {
    try EntryRecord.encodeMessages([.user(UserMessage(content: content, timestamp: 0))])[0].objectValue!["content"]!
}
