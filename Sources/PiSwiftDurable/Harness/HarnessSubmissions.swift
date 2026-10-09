import PiSwiftChord

extension Harness {
    /// Returns the current durable submission, or nil when it is absent.
    public func submission(id: SubmissionID, context: ChordContext) async throws -> Submission? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); return try await submissions.get(id: id, context: context)
        }
    }
    /// Attempts to withdraw the submission before a generation places it.
    public func abortSubmission(id: SubmissionID, conversationId: ConversationID? = nil, context: ChordContext) async throws -> SubmissionAbortResult {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); return try await submissions.abort(id: id, context: context, conversationId: conversationId)
        }
    }
}
