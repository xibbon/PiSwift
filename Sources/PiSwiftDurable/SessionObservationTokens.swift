import PiSwiftChord

extension Session {
    /// Attaches a stream of committed document values, or nil when no document exists.
    public func watchDoc<Value: Codable & Sendable>(_ token: SessionDocToken<Value>, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await currentWatch(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .session()), context: context)
    }
    /// Attaches a stream of committed document values, or nil when no document exists.
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: SessionDocFamilyToken<Value, Seed>, key: String, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await currentWatch(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .session(), key: key), context: context)
    }
    /// Attaches a stream of committed document values, or nil when no document exists.
    public func watchDoc<Value: Codable & Sendable>(_ token: ConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await currentWatch(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId)), context: context)
    }
    /// Attaches a stream of committed document values, or nil when no document exists.
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: ConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await currentWatch(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId), key: key), context: context)
    }
    /// Attaches a stream of committed document values, or nil when no document exists.
    public func watchDoc<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await currentWatch(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId)), context: context)
    }
    /// Attaches a stream of committed document values, or nil when no document exists.
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await currentWatch(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId), key: key), context: context)
    }
    /// Attaches a stream of committed document values, or nil when no document exists.
    public func watchDoc<Value: Codable & Sendable>(_ token: TaskDocToken<Value>, taskId: TaskID, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await currentWatch(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .task(taskId: taskId)), context: context)
    }
    /// Attaches a stream of committed document values, or nil when no document exists.
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: TaskDocFamilyToken<Value, Seed>, taskId: TaskID, key: String, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await currentWatch(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .task(taskId: taskId), key: key), context: context)
    }
    /// Attaches a document value to committed changes. Cancel the attachment to release it.
    public func documentState<Value: Codable & Sendable>(_ token: SessionDocToken<Value>, context: ChordContext) async throws -> AttachedReplicatedState<Value?>? {
        try await currentDocumentState(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .session()), context: context)
    }
    /// Attaches a document value to committed changes. Cancel the attachment to release it.
    public func documentState<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: SessionDocFamilyToken<Value, Seed>, key: String, context: ChordContext) async throws -> AttachedReplicatedState<Value?>? {
        try await currentDocumentState(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .session(), key: key), context: context)
    }
    /// Attaches a document value to committed changes. Cancel the attachment to release it.
    public func documentState<Value: Codable & Sendable>(_ token: ConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> AttachedReplicatedState<Value?>? {
        try await currentDocumentState(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId)), context: context)
    }
    /// Attaches a document value to committed changes. Cancel the attachment to release it.
    public func documentState<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: ConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> AttachedReplicatedState<Value?>? {
        try await currentDocumentState(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId), key: key), context: context)
    }
    /// Attaches a document value to committed changes. Cancel the attachment to release it.
    public func documentState<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> AttachedReplicatedState<Value?>? {
        try await currentDocumentState(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId)), context: context)
    }
    /// Attaches a document value to committed changes. Cancel the attachment to release it.
    public func documentState<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> AttachedReplicatedState<Value?>? {
        try await currentDocumentState(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId), key: key), context: context)
    }
    /// Attaches a document value to committed changes. Cancel the attachment to release it.
    public func documentState<Value: Codable & Sendable>(_ token: TaskDocToken<Value>, taskId: TaskID, context: ChordContext) async throws -> AttachedReplicatedState<Value?>? {
        try await currentDocumentState(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .task(taskId: taskId)), context: context)
    }
    /// Attaches a document value to committed changes. Cancel the attachment to release it.
    public func documentState<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: TaskDocFamilyToken<Value, Seed>, taskId: TaskID, key: String, context: ChordContext) async throws -> AttachedReplicatedState<Value?>? {
        try await currentDocumentState(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .task(taskId: taskId), key: key), context: context)
    }
}
