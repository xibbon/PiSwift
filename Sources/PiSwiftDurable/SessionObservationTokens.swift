import PiSwiftChord

extension Session {
    public func watchDoc<Value: Codable & Sendable>(_ token: SessionDocToken<Value>, context: PiSwiftChord.Context) async throws -> CommittedWatch<Value?>? {
        try await currentWatch(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .session()), context: context)
    }
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: SessionDocFamilyToken<Value, Seed>, key: String, context: PiSwiftChord.Context) async throws -> CommittedWatch<Value?>? {
        try await currentWatch(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .session(), key: key), context: context)
    }
    public func watchDoc<Value: Codable & Sendable>(_ token: ConversationDocToken<Value>, conversationId: ConversationID, context: PiSwiftChord.Context) async throws -> CommittedWatch<Value?>? {
        try await currentWatch(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId)), context: context)
    }
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: ConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: PiSwiftChord.Context) async throws -> CommittedWatch<Value?>? {
        try await currentWatch(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId), key: key), context: context)
    }
    public func watchDoc<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, context: PiSwiftChord.Context) async throws -> CommittedWatch<Value?>? {
        try await currentWatch(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId)), context: context)
    }
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: PiSwiftChord.Context) async throws -> CommittedWatch<Value?>? {
        try await currentWatch(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId), key: key), context: context)
    }
    public func watchDoc<Value: Codable & Sendable>(_ token: TaskDocToken<Value>, taskId: TaskID, context: PiSwiftChord.Context) async throws -> CommittedWatch<Value?>? {
        try await currentWatch(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .task(taskId: taskId)), context: context)
    }
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: TaskDocFamilyToken<Value, Seed>, taskId: TaskID, key: String, context: PiSwiftChord.Context) async throws -> CommittedWatch<Value?>? {
        try await currentWatch(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .task(taskId: taskId), key: key), context: context)
    }
    public func documentState<Value: Codable & Sendable>(_ token: SessionDocToken<Value>, context: PiSwiftChord.Context) async throws -> AttachedReplicatedState<Value?>? {
        try await currentDocumentState(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .session()), context: context)
    }
    public func documentState<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: SessionDocFamilyToken<Value, Seed>, key: String, context: PiSwiftChord.Context) async throws -> AttachedReplicatedState<Value?>? {
        try await currentDocumentState(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .session(), key: key), context: context)
    }
    public func documentState<Value: Codable & Sendable>(_ token: ConversationDocToken<Value>, conversationId: ConversationID, context: PiSwiftChord.Context) async throws -> AttachedReplicatedState<Value?>? {
        try await currentDocumentState(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId)), context: context)
    }
    public func documentState<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: ConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: PiSwiftChord.Context) async throws -> AttachedReplicatedState<Value?>? {
        try await currentDocumentState(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId), key: key), context: context)
    }
    public func documentState<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, context: PiSwiftChord.Context) async throws -> AttachedReplicatedState<Value?>? {
        try await currentDocumentState(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId)), context: context)
    }
    public func documentState<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: PiSwiftChord.Context) async throws -> AttachedReplicatedState<Value?>? {
        try await currentDocumentState(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId), key: key), context: context)
    }
    public func documentState<Value: Codable & Sendable>(_ token: TaskDocToken<Value>, taskId: TaskID, context: PiSwiftChord.Context) async throws -> AttachedReplicatedState<Value?>? {
        try await currentDocumentState(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .task(taskId: taskId)), context: context)
    }
    public func documentState<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: TaskDocFamilyToken<Value, Seed>, taskId: TaskID, key: String, context: PiSwiftChord.Context) async throws -> AttachedReplicatedState<Value?>? {
        try await currentDocumentState(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .task(taskId: taskId), key: key), context: context)
    }
}
