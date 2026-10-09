import PiSwiftChord

extension Session {
    /// Reads a detached current document value, or nil when no incarnation exists.
    public func snapshot<Value: Codable & Sendable>(_ token: SessionDocToken<Value>, context: ChordContext) async throws -> Value? {
        try await currentSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .session()), context: context)
    }
    /// Reads a detached current document value, or nil when no incarnation exists.
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: SessionDocFamilyToken<Value, Seed>, key: String, context: ChordContext) async throws -> Value? {
        try await currentSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .session(), key: key), context: context)
    }
    /// Reads a detached current document value, or nil when no incarnation exists.
    public func snapshot<Value: Codable & Sendable>(_ token: ConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> Value? {
        try await currentSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId)), context: context)
    }
    /// Reads a detached current document value, or nil when no incarnation exists.
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: ConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> Value? {
        try await currentSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId), key: key), context: context)
    }
    /// Reads a detached current document value, or nil when no incarnation exists.
    public func snapshot<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> Value? {
        try await currentSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId)), context: context)
    }
    /// Reads a detached historical document value through the inclusive entry.
    public func snapshotAsOf<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, at: EntryID, context: ChordContext) async throws -> Value? {
        try await historicalSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId)), at: at, context: context)
    }
    /// Reads a detached current document value, or nil when no incarnation exists.
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> Value? {
        try await currentSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId), key: key), context: context)
    }
    /// Reads a detached historical document value through the inclusive entry.
    public func snapshotAsOf<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, at: EntryID, context: ChordContext) async throws -> Value? {
        try await historicalSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId), key: key), at: at, context: context)
    }
    /// Reads a detached current document value, or nil when no incarnation exists.
    public func snapshot<Value: Codable & Sendable>(_ token: TaskDocToken<Value>, taskId: TaskID, context: ChordContext) async throws -> Value? {
        try await currentSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .task(taskId: taskId)), context: context)
    }
    /// Reads a detached current document value, or nil when no incarnation exists.
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: TaskDocFamilyToken<Value, Seed>, taskId: TaskID, key: String, context: ChordContext) async throws -> Value? {
        try await currentSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .task(taskId: taskId), key: key), context: context)
    }
}
