import PiSwiftAI
import PiSwiftChord
import Synchronization

public typealias UserInput = UserContent
public enum WhenBusy: String, Sendable { case steer, followUp, reject }
public enum SubmissionDraft: Sendable {
    case input(content: UserInput, whenBusy: WhenBusy? = nil, requestId: String? = nil)
    case write(entry: EntryDraft, requestId: String? = nil)
    public var requestId: String? { switch self { case .input(_, _, let id), .write(_, let id): id } }
    public var type: String { switch self { case .input: "input"; case .write: "write" } }
}
public struct ConversationBusy: Error, Sendable, CustomStringConvertible {
    public let conversationId: ConversationID
    public init(conversationId: ConversationID) { self.conversationId = conversationId }
    public var description: String { "Conversation \(conversationId.rawValue) is busy" }
}
public enum SubmissionAbortResult: String, Sendable { case aborted, alreadyPlaced = "already_placed", settled, notFound = "not_found" }
public struct SettledSubmission: Sendable, Equatable {
    public let record: SubmissionRecord
    public var id: SubmissionID { record.id }
    public var conversationId: ConversationID { record.conversationId }
    public var status: String { record.status }
    public var answer: EntryID? { if case .input(_, _, _, .done(_, let answer, _)) = record { return answer }; return nil }
    public var reason: String? {
        switch record { case .input(_, _, _, .unanswered(let reason, _, _, _)), .write(_, _, _, .unanswered(let reason, _, _)): reason; default: nil }
    }
    internal init(_ record: SubmissionRecord) { self.record = record }
}
public typealias SettledSubmissionRecord = SettledSubmission
public struct Submission: Sendable {
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
    public func status(context: ChordContext) async throws -> SubmissionRecord {
        try await withTaskCancellationContext(try self.context(context)) { try await submissions.status(id: id, context: $0) }
    }
    public func wait(context: ChordContext) async throws -> SettledSubmission {
        try await withTaskCancellationContext(try self.context(context)) { try await submissions.wait(id: id, context: $0) }
    }
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

public func admitSubmission(tx: Transaction, conversationId: ConversationID, draft: SubmissionDraft, now: Int64, queueModes: Settings) async throws -> SubmissionID {
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
