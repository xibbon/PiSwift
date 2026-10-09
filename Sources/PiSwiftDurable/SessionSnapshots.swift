import PiSwiftChord

extension Session {
    public func snapshot<Value: Codable & Sendable>(_ token: SessionDocToken<Value>, context: PiSwiftChord.Context) async throws -> Value? {
        try await currentSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .session()), context: context)
    }
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: SessionDocFamilyToken<Value, Seed>, key: String, context: PiSwiftChord.Context) async throws -> Value? {
        try await currentSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .session(), key: key), context: context)
    }
    public func snapshot<Value: Codable & Sendable>(_ token: ConversationDocToken<Value>, conversationId: ConversationID, context: PiSwiftChord.Context) async throws -> Value? {
        try await currentSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId)), context: context)
    }
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: ConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: PiSwiftChord.Context) async throws -> Value? {
        try await currentSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId), key: key), context: context)
    }
    public func snapshot<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, context: PiSwiftChord.Context) async throws -> Value? {
        try await currentSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId)), context: context)
    }
    public func snapshotAsOf<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, at: EntryID, context: PiSwiftChord.Context) async throws -> Value? {
        try await historicalSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId)), at: at, context: context)
    }
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: PiSwiftChord.Context) async throws -> Value? {
        try await currentSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId), key: key), context: context)
    }
    public func snapshotAsOf<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, at: EntryID, context: PiSwiftChord.Context) async throws -> Value? {
        try await historicalSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId), key: key), at: at, context: context)
    }
    public func snapshot<Value: Codable & Sendable>(_ token: TaskDocToken<Value>, taskId: TaskID, context: PiSwiftChord.Context) async throws -> Value? {
        try await currentSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .task(taskId: taskId)), context: context)
    }
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: TaskDocFamilyToken<Value, Seed>, taskId: TaskID, key: String, context: PiSwiftChord.Context) async throws -> Value? {
        try await currentSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .task(taskId: taskId), key: key), context: context)
    }
}
