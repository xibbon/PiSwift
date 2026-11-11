import PiSwiftChord

extension Harness {
    /// Reads a detached current document value, or nil when no incarnation exists.
    public func snapshot<Value: Codable & Sendable>(_ token: SessionDocToken<Value>, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.snapshot(token, context: context)
        }
    }
    /// Reads a detached current document value, or nil when no incarnation exists.
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: SessionDocFamilyToken<Value, Seed>, key: String, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.snapshot(token, key: key, context: context)
        }
    }
    /// Reads a detached current document value, or nil when no incarnation exists.
    public func snapshot<Value: Codable & Sendable>(_ token: ConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.snapshot(token, conversationId: conversationId, context: context)
        }
    }
    /// Reads a detached current document value, or nil when no incarnation exists.
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: ConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.snapshot(token, conversationId: conversationId, key: key, context: context)
        }
    }
    /// Reads a detached current document value, or nil when no incarnation exists.
    public func snapshot<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.snapshot(token, conversationId: conversationId, context: context)
        }
    }
    /// Reads a detached current document value, or nil when no incarnation exists.
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.snapshot(token, conversationId: conversationId, key: key, context: context)
        }
    }
    /// Reads a detached current document value, or nil when no incarnation exists.
    public func snapshot<Value: Codable & Sendable>(_ token: TaskDocToken<Value>, taskId: TaskID, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.snapshot(token, taskId: taskId, context: context)
        }
    }
    /// Reads a detached current document value, or nil when no incarnation exists.
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: TaskDocFamilyToken<Value, Seed>, taskId: TaskID, key: String, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.snapshot(token, taskId: taskId, key: key, context: context)
        }
    }
    /// Attaches a stream of committed document values, or nil when no document exists.
    public func watchDoc<Value: Codable & Sendable>(_ token: SessionDocToken<Value>, context: ChordContext) async throws -> Watch<Value>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.watchDoc(token, context: context)
        }
    }
    /// Observe document changes on the Session line, or return nil when no document exists.
    public func observeDoc<Value: Codable & Sendable>(_ token: SessionDocToken<Value>, observer: Observer<Value>, context: ChordContext) async throws -> Observation<Value>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.observeDoc(token, observer: observer, context: context)
        }
    }
    /// Attaches a stream of committed document values, or nil when no document exists.
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: SessionDocFamilyToken<Value, Seed>, key: String, context: ChordContext) async throws -> Watch<Value>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.watchDoc(token, key: key, context: context)
        }
    }
    /// Observe document changes on the Session line, or return nil when no document exists.
    public func observeDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: SessionDocFamilyToken<Value, Seed>, key: String, observer: Observer<Value>, context: ChordContext) async throws -> Observation<Value>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.observeDoc(token, key: key, observer: observer, context: context)
        }
    }
    /// Attaches a stream of committed document values, or nil when no document exists.
    public func watchDoc<Value: Codable & Sendable>(_ token: ConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> Watch<Value>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.watchDoc(token, conversationId: conversationId, context: context)
        }
    }
    /// Observe document changes on the Session line, or return nil when no document exists.
    public func observeDoc<Value: Codable & Sendable>(_ token: ConversationDocToken<Value>, conversationId: ConversationID, observer: Observer<Value>, context: ChordContext) async throws -> Observation<Value>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.observeDoc(token, conversationId: conversationId, observer: observer, context: context)
        }
    }
    /// Attaches a stream of committed document values, or nil when no document exists.
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: ConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> Watch<Value>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.watchDoc(token, conversationId: conversationId, key: key, context: context)
        }
    }
    /// Observe document changes on the Session line, or return nil when no document exists.
    public func observeDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: ConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, observer: Observer<Value>, context: ChordContext) async throws -> Observation<Value>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.observeDoc(token, conversationId: conversationId, key: key, observer: observer, context: context)
        }
    }
    /// Attaches a stream of committed document values, or nil when no document exists.
    public func watchDoc<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> Watch<Value>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.watchDoc(token, conversationId: conversationId, context: context)
        }
    }
    /// Observe document changes on the Session line, or return nil when no document exists.
    public func observeDoc<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, observer: Observer<Value>, context: ChordContext) async throws -> Observation<Value>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.observeDoc(token, conversationId: conversationId, observer: observer, context: context)
        }
    }
    /// Attaches a stream of committed document values, or nil when no document exists.
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> Watch<Value>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.watchDoc(token, conversationId: conversationId, key: key, context: context)
        }
    }
    /// Observe document changes on the Session line, or return nil when no document exists.
    public func observeDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, observer: Observer<Value>, context: ChordContext) async throws -> Observation<Value>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.observeDoc(token, conversationId: conversationId, key: key, observer: observer, context: context)
        }
    }
    /// Attaches a stream of committed document values, or nil when no document exists.
    public func watchDoc<Value: Codable & Sendable>(_ token: TaskDocToken<Value>, taskId: TaskID, context: ChordContext) async throws -> Watch<Value>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.watchDoc(token, taskId: taskId, context: context)
        }
    }
    /// Observe document changes on the Session line, or return nil when no document exists.
    public func observeDoc<Value: Codable & Sendable>(_ token: TaskDocToken<Value>, taskId: TaskID, observer: Observer<Value>, context: ChordContext) async throws -> Observation<Value>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.observeDoc(token, taskId: taskId, observer: observer, context: context)
        }
    }
    /// Attaches a stream of committed document values, or nil when no document exists.
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: TaskDocFamilyToken<Value, Seed>, taskId: TaskID, key: String, context: ChordContext) async throws -> Watch<Value>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.watchDoc(token, taskId: taskId, key: key, context: context)
        }
    }
    /// Observe document changes on the Session line, or return nil when no document exists.
    public func observeDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: TaskDocFamilyToken<Value, Seed>, taskId: TaskID, key: String, observer: Observer<Value>, context: ChordContext) async throws -> Observation<Value>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.observeDoc(token, taskId: taskId, key: key, observer: observer, context: context)
        }
    }
    /// Attaches a document value to committed changes. Cancel the attachment to release it.
    public func documentState<Value: Codable & Sendable>(_ token: SessionDocToken<Value>, context: ChordContext) async throws -> AttachedReplicatedState<Value?>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.documentState(token, context: context)
        }
    }
    /// Attaches a document value to committed changes. Cancel the attachment to release it.
    public func documentState<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: SessionDocFamilyToken<Value, Seed>, key: String, context: ChordContext) async throws -> AttachedReplicatedState<Value?>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.documentState(token, key: key, context: context)
        }
    }
    /// Attaches a document value to committed changes. Cancel the attachment to release it.
    public func documentState<Value: Codable & Sendable>(_ token: ConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> AttachedReplicatedState<Value?>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.documentState(token, conversationId: conversationId, context: context)
        }
    }
    /// Attaches a document value to committed changes. Cancel the attachment to release it.
    public func documentState<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: ConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> AttachedReplicatedState<Value?>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.documentState(token, conversationId: conversationId, key: key, context: context)
        }
    }
    /// Attaches a document value to committed changes. Cancel the attachment to release it.
    public func documentState<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> AttachedReplicatedState<Value?>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.documentState(token, conversationId: conversationId, context: context)
        }
    }
    /// Attaches a document value to committed changes. Cancel the attachment to release it.
    public func documentState<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> AttachedReplicatedState<Value?>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.documentState(token, conversationId: conversationId, key: key, context: context)
        }
    }
    /// Attaches a document value to committed changes. Cancel the attachment to release it.
    public func documentState<Value: Codable & Sendable>(_ token: TaskDocToken<Value>, taskId: TaskID, context: ChordContext) async throws -> AttachedReplicatedState<Value?>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.documentState(token, taskId: taskId, context: context)
        }
    }
    /// Attaches a document value to committed changes. Cancel the attachment to release it.
    public func documentState<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: TaskDocFamilyToken<Value, Seed>, taskId: TaskID, key: String, context: ChordContext) async throws -> AttachedReplicatedState<Value?>? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.documentState(token, taskId: taskId, key: key, context: context)
        }
    }
    /// Reads a detached historical document value through the inclusive entry.
    public func snapshotAsOf<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, at: EntryID, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.snapshotAsOf(token, conversationId: conversationId, at: at, context: context)
        }
    }
    /// Reads a detached historical document value through the inclusive entry.
    public func snapshotAsOf<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, at: EntryID, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted(); return try await session.snapshotAsOf(token, conversationId: conversationId, key: key, at: at, context: context)
        }
    }
}
