import PiSwiftChord
import PiSwiftAI

/// A handle for one durable conversation. Compare handles by ID.
public final class Conversation: Sendable {
    /// The stable identifier of this record or handle.
    public let id: ConversationID
    internal let harness: Harness
    private let binding: InvocationBinding?
    internal init(id: ConversationID, harness: Harness, binding: InvocationBinding? = nil) { self.id = id; self.harness = harness; self.binding = binding }
    internal func bound(_ context: ChordContext) throws -> ChordContext {
        try binding?.check()
        return binding.map { context.withAbortSignal($0.signal) } ?? context
    }
    /// Returns the resolved agent configuration for the conversation.
    public func agent(context: ChordContext) async throws -> Agent {
        try await withTaskCancellationContext(try bound(context)) { try await harness.resolveConversationAgent(id: id, context: $0) }
    }
    /// Writes partial agent changes within the conversation transaction.
    public func configure(change: AgentChange, context: ChordContext) async throws {
        try await commit({ tx in try await PiSwiftDurable.configure(tx: tx, conversationId: id, change: change) }, context: context)
    }
    /// Durably admits user input or an entry write and returns its submission handle.
    public func submit(_ draft: SubmissionDraft, context: ChordContext) async throws -> Submission {
        try await withTaskCancellationContext(try bound(context)) { context in
            try harness.assertOpen()
            return try await harness.submissions.submit(conversationId: id, draft: draft, context: context).bound(binding)
        }
    }
    /// Creates a manual compaction task for the conversation.
    public func compact(instructions: String? = nil, context: ChordContext) async throws -> TaskID {
        try await withTaskCancellationContext(try bound(context)) { context in
            try harness.assertOpen()
            harness.tasks.resume()
            return try await harness.session.commitWith({ tx in
                try await createCompaction(tx: tx, conversationId: id,
                    input: CompactionInput(reason: .manual, instructions: instructions))
            }, context: context)
        }
    }
    /// Writes a reset boundary and optional handoff text for the conversation.
    public func reset(handoff: String? = nil, context: ChordContext) async throws {
        let now = harness.options.now?() ?? harness.options.clock.now()
        let model = try handoff.map { try EntryRecord.encodeMessages([.user(UserMessage(content: .text($0), timestamp: now))]) }
        _ = try await submit(.write(entry: EntryDraft(kind: resetEntry.kind, model: model, head: .self)), context: context)
    }
    /// Commits the supplied changes atomically and publishes them after storage succeeds.
    public func commit<T>(_ change: (Transaction) async throws -> T, context: ChordContext) async throws -> T {
        try await withTaskCancellationContext(try bound(context)) { context in
            try harness.assertOpen()
            return try await harness.session.commitWith(change, context: context, scope: TransactionScope(conversationId: id))
        }
    }
    /// Reads the visible model context through the optional inclusive entry boundary.
    public func context(at: EntryID? = nil, context: ChordContext) async throws -> ContextView {
        try await withTaskCancellationContext(try bound(context)) { context in
            try harness.assertOpen(); try context.abortSignal?.throwIfAborted()
            return try await readContextFrom(session: harness.session, storage: harness.storage, id: id, context: context, at: at).view
        }
    }
    /// Reads a page of visible entries with an optional inclusive range.
    public func entries(minEntryId: EntryID? = nil, maxEntryId: EntryID? = nil, order: ScanOrder? = nil,
                        limit: Int, cursor: Cursor? = nil, context: ChordContext) async throws -> Page<EntryRecord, Cursor> {
        try await withTaskCancellationContext(try bound(context)) { context in
            try harness.assertOpen(); try context.abortSignal?.throwIfAborted()
            return try await harness.session.readOnLine {
                try await harness.storage.scanEntries(EntryQuery(conversationId: id, minEntryId: minEntryId, maxEntryId: maxEntryId, order: order), limit: limit, cursor: cursor, context: context)
            }
        }
    }
    /// Creates a conversation that inherits history through the selected entry.
    public func fork(at: EntryID, options: ConversationCreateOptions, context: ChordContext) async throws -> Conversation {
        try await harness.create(.fork(id, at, options.ownership), agent: options.agent, initialize: options.initialize, context: try bound(context))
    }
    /// Requests abort for conversation tasks; background work is included only when requested.
    public func abort(background: Bool = false, context: ChordContext) async throws {
        try await withTaskCancellationContext(try bound(context)) { context in
            try harness.assertOpen()
            try await harness.tasks.abortConversation(id: id, background: background, context: context)
        }
    }
    /// Waits until the conversation has no active run or ordinary owned task.
    public func waitForIdle(context: ChordContext) async throws {
        try await withTaskCancellationContext(try bound(context)) { context in
            try harness.assertOpen(); harness.tasks.resume()
            try await harness.tasks.waitForIdle(conversationId: id, context: context)
        }
    }
}

/// Invocation-bound conversation operations. The invocation checks each call.
public struct ConversationHandle: Sendable {
    /// The stable identifier of this record or handle.
    public let id: ConversationID
    private let conversation: Conversation
    internal init(_ conversation: Conversation) { self.conversation = conversation; id = conversation.id }
    /// Durably admits user input or an entry write and returns its submission handle.
    public func submit(_ draft: SubmissionDraft, context: ChordContext) async throws -> Submission {
        guard case .input = draft else { throw SessionError.message("A conversation handle can submit only input") }
        return try await conversation.submit(draft, context: context)
    }
    /// Requests abort for conversation tasks; background work is included only when requested.
    public func abort(background: Bool = false, context: ChordContext) async throws {
        try await conversation.abort(background: background, context: context)
    }
    /// Waits until the conversation has no active run or ordinary owned task.
    public func waitForIdle(context: ChordContext) async throws {
        try await conversation.waitForIdle(context: context)
    }
}
