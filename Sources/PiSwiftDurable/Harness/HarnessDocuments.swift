import PiSwiftChord

extension Harness {
    public func snapshot<Value: Codable & Sendable>(_ token: SessionDocToken<Value>, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.snapshot(token, context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: SessionDocFamilyToken<Value, Seed>, key: String, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.snapshot(token, key: key, context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable>(_ token: ConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.snapshot(token, conversationId: conversationId, context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: ConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.snapshot(token, conversationId: conversationId, key: key, context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.snapshot(token, conversationId: conversationId, context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.snapshot(token, conversationId: conversationId, key: key, context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable>(_ token: TaskDocToken<Value>, taskId: TaskID, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.snapshot(token, taskId: taskId, context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: TaskDocFamilyToken<Value, Seed>, taskId: TaskID, key: String, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.snapshot(token, taskId: taskId, key: key, context: context)
        }
    }
    public func watchDoc<Value: Codable & Sendable>(_ token: SessionDocToken<Value>, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.watchDoc(token, context: context)
        }
    }
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: SessionDocFamilyToken<Value, Seed>, key: String, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.watchDoc(token, key: key, context: context)
        }
    }
    public func watchDoc<Value: Codable & Sendable>(_ token: ConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.watchDoc(token, conversationId: conversationId, context: context)
        }
    }
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: ConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.watchDoc(token, conversationId: conversationId, key: key, context: context)
        }
    }
    public func watchDoc<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.watchDoc(token, conversationId: conversationId, context: context)
        }
    }
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.watchDoc(token, conversationId: conversationId, key: key, context: context)
        }
    }
    public func watchDoc<Value: Codable & Sendable>(_ token: TaskDocToken<Value>, taskId: TaskID, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.watchDoc(token, taskId: taskId, context: context)
        }
    }
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: TaskDocFamilyToken<Value, Seed>, taskId: TaskID, key: String, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.watchDoc(token, taskId: taskId, key: key, context: context)
        }
    }
    public func documentState<Value: Codable & Sendable>(_ token: SessionDocToken<Value>, context: ChordContext) async throws -> AttachedReplicatedState<Value?>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.documentState(token, context: context)
        }
    }
    public func documentState<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: SessionDocFamilyToken<Value, Seed>, key: String, context: ChordContext) async throws -> AttachedReplicatedState<Value?>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.documentState(token, key: key, context: context)
        }
    }
    public func documentState<Value: Codable & Sendable>(_ token: ConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> AttachedReplicatedState<Value?>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.documentState(token, conversationId: conversationId, context: context)
        }
    }
    public func documentState<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: ConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> AttachedReplicatedState<Value?>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.documentState(token, conversationId: conversationId, key: key, context: context)
        }
    }
    public func documentState<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> AttachedReplicatedState<Value?>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.documentState(token, conversationId: conversationId, context: context)
        }
    }
    public func documentState<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> AttachedReplicatedState<Value?>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.documentState(token, conversationId: conversationId, key: key, context: context)
        }
    }
    public func documentState<Value: Codable & Sendable>(_ token: TaskDocToken<Value>, taskId: TaskID, context: ChordContext) async throws -> AttachedReplicatedState<Value?>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.documentState(token, taskId: taskId, context: context)
        }
    }
    public func documentState<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: TaskDocFamilyToken<Value, Seed>, taskId: TaskID, key: String, context: ChordContext) async throws -> AttachedReplicatedState<Value?>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.documentState(token, taskId: taskId, key: key, context: context)
        }
    }
    public func snapshotAsOf<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, at: EntryID, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.snapshotAsOf(token, conversationId: conversationId, at: at, context: context)
        }
    }
    public func snapshotAsOf<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, at: EntryID, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.snapshotAsOf(token, conversationId: conversationId, key: key, at: at, context: context)
        }
    }
}
