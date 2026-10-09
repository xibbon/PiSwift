import PiSwiftChord

extension Harness {
    public func submission(id: SubmissionID, context: PiSwiftChord.Context) async throws -> Submission? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); return try await submissions.get(id: id, context: context)
        }
    }
    public func abortSubmission(id: SubmissionID, conversationId: ConversationID? = nil, context: PiSwiftChord.Context) async throws -> SubmissionAbortResult {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); return try await submissions.abort(id: id, context: context, conversationId: conversationId)
        }
    }
}
