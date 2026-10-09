import PiSwiftChord
import PiSwiftAI

/// A handle for one durable conversation. Compare handles by ID.
public final class Conversation: Sendable {
    public let id: ConversationID
    internal let harness: Harness
    private let binding: InvocationBinding?
    internal init(id: ConversationID, harness: Harness, binding: InvocationBinding? = nil) { self.id = id; self.harness = harness; self.binding = binding }
    internal func bound(_ context: PiSwiftChord.Context) throws -> PiSwiftChord.Context {
        try binding?.check()
        return binding.map { context.withAbortSignal($0.signal) } ?? context
    }
    public func agent(context: PiSwiftChord.Context) async throws -> Agent {
        try await withTaskCancellationContext(try bound(context)) { try await harness.resolveConversationAgent(id: id, context: $0) }
    }
    public func configure(change: AgentChange, context: PiSwiftChord.Context) async throws {
        try await commit({ tx in try await PiSwiftDurable.configure(tx: tx, conversationId: id, change: change) }, context: context)
    }
    public func submit(_ draft: SubmissionDraft, context: PiSwiftChord.Context) async throws -> Submission {
        try await withTaskCancellationContext(try bound(context)) { context in
            try harness.assertOpen()
            return try await harness.submissions.submit(conversationId: id, draft: draft, context: context).bound(binding)
        }
    }
    public func compact(instructions: String? = nil, context: PiSwiftChord.Context) async throws -> TaskID {
        try await withTaskCancellationContext(try bound(context)) { context in
            try harness.assertOpen()
            harness.tasks.resume()
            return try await harness.session.commitWith({ tx in
                try await createCompaction(tx: tx, conversationId: id,
                    input: CompactionInput(reason: .manual, instructions: instructions))
            }, context: context)
        }
    }
    public func reset(handoff: String? = nil, context: PiSwiftChord.Context) async throws {
        let now = harness.options.now?() ?? harness.options.clock.now()
        let model = try handoff.map { try EntryRecord.encodeMessages([.user(UserMessage(content: .text($0), timestamp: now))]) }
        _ = try await submit(.write(entry: EntryDraft(kind: resetEntry.kind, model: model, head: .self)), context: context)
    }
    public func commit<T>(_ change: (Transaction) async throws -> T, context: PiSwiftChord.Context) async throws -> T {
        try await withTaskCancellationContext(try bound(context)) { context in
            try harness.assertOpen()
            return try await harness.session.commitWith(change, context: context, scope: TransactionScope(conversationId: id))
        }
    }
    public func context(at: EntryID? = nil, context: PiSwiftChord.Context) async throws -> ContextView {
        try await withTaskCancellationContext(try bound(context)) { context in
            try harness.assertOpen(); try context.abortSignal?.throwIfAborted()
            return try await readContextFrom(session: harness.session, storage: harness.storage, id: id, context: context, at: at).view
        }
    }
    public func entries(minEntryId: EntryID? = nil, maxEntryId: EntryID? = nil, order: ScanOrder? = nil,
                        limit: Int, cursor: Cursor? = nil, context: PiSwiftChord.Context) async throws -> Page<EntryRecord, Cursor> {
        try await withTaskCancellationContext(try bound(context)) { context in
            try harness.assertOpen(); try context.abortSignal?.throwIfAborted()
            return try await harness.session.readOnLine {
                try await harness.storage.scanEntries(EntryQuery(conversationId: id, minEntryId: minEntryId, maxEntryId: maxEntryId, order: order), limit: limit, cursor: cursor, context: context)
            }
        }
    }
    public func fork(at: EntryID, options: ConversationCreateOptions, context: PiSwiftChord.Context) async throws -> Conversation {
        try await harness.create(.fork(id, at, options.ownership), agent: options.agent, initialize: options.initialize, context: try bound(context))
    }
    public func abort(background: Bool = false, context: PiSwiftChord.Context) async throws {
        try await withTaskCancellationContext(try bound(context)) { context in
            try harness.assertOpen()
            try await harness.tasks.abortConversation(id: id, background: background, context: context)
        }
    }
    public func waitForIdle(context: PiSwiftChord.Context) async throws {
        try await withTaskCancellationContext(try bound(context)) { context in
            try harness.assertOpen(); harness.tasks.resume()
            try await harness.tasks.waitForIdle(conversationId: id, context: context)
        }
    }
}

/// Invocation-bound conversation operations. The invocation checks each call.
public struct ConversationHandle: Sendable {
    public let id: ConversationID
    private let conversation: Conversation
    internal init(_ conversation: Conversation) { self.conversation = conversation; id = conversation.id }
    public func submit(_ draft: SubmissionDraft, context: PiSwiftChord.Context) async throws -> Submission {
        guard case .input = draft else { throw SessionError.message("A conversation handle can submit only input") }
        return try await conversation.submit(draft, context: context)
    }
    public func abort(background: Bool = false, context: PiSwiftChord.Context) async throws {
        try await conversation.abort(background: background, context: context)
    }
    public func waitForIdle(context: PiSwiftChord.Context) async throws {
        try await conversation.waitForIdle(context: context)
    }
}
