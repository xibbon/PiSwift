import PiSwiftChord

extension ToolExecutionApi {
    public func snapshot<Value: Codable & Sendable>(_ token: SessionDocToken<Value>, context: PiSwiftChord.Context) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().snapshot(token, context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: SessionDocFamilyToken<Value, Seed>, key: String, context: PiSwiftChord.Context) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().snapshot(token, key: key, context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable>(_ token: ConversationDocToken<Value>, conversationId: ConversationID, context: PiSwiftChord.Context) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().snapshot(token, conversationId: conversationId, context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: ConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: PiSwiftChord.Context) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().snapshot(token, conversationId: conversationId, key: key, context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, context: PiSwiftChord.Context) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().snapshot(token, conversationId: conversationId, context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: PiSwiftChord.Context) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().snapshot(token, conversationId: conversationId, key: key, context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable>(_ token: TaskDocToken<Value>, taskId: TaskID, context: PiSwiftChord.Context) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().snapshot(token, taskId: taskId, context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: TaskDocFamilyToken<Value, Seed>, taskId: TaskID, key: String, context: PiSwiftChord.Context) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().snapshot(token, taskId: taskId, key: key, context: context)
        }
    }
    public func watchDoc<Value: Codable & Sendable>(_ token: SessionDocToken<Value>, context: PiSwiftChord.Context) async throws -> CommittedWatch<Value?>? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().watchDoc(token, context: context)
        }
    }
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: SessionDocFamilyToken<Value, Seed>, key: String, context: PiSwiftChord.Context) async throws -> CommittedWatch<Value?>? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().watchDoc(token, key: key, context: context)
        }
    }
    public func watchDoc<Value: Codable & Sendable>(_ token: ConversationDocToken<Value>, conversationId: ConversationID, context: PiSwiftChord.Context) async throws -> CommittedWatch<Value?>? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().watchDoc(token, conversationId: conversationId, context: context)
        }
    }
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: ConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: PiSwiftChord.Context) async throws -> CommittedWatch<Value?>? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().watchDoc(token, conversationId: conversationId, key: key, context: context)
        }
    }
    public func watchDoc<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, context: PiSwiftChord.Context) async throws -> CommittedWatch<Value?>? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().watchDoc(token, conversationId: conversationId, context: context)
        }
    }
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: PiSwiftChord.Context) async throws -> CommittedWatch<Value?>? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().watchDoc(token, conversationId: conversationId, key: key, context: context)
        }
    }
    public func watchDoc<Value: Codable & Sendable>(_ token: TaskDocToken<Value>, taskId: TaskID, context: PiSwiftChord.Context) async throws -> CommittedWatch<Value?>? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().watchDoc(token, taskId: taskId, context: context)
        }
    }
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: TaskDocFamilyToken<Value, Seed>, taskId: TaskID, key: String, context: PiSwiftChord.Context) async throws -> CommittedWatch<Value?>? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().watchDoc(token, taskId: taskId, key: key, context: context)
        }
    }
    public func snapshotAsOf<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, at: EntryID, context: PiSwiftChord.Context) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().snapshotAsOf(token, conversationId: conversationId, at: at, context: context)
        }
    }
    public func snapshotAsOf<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, at: EntryID, context: PiSwiftChord.Context) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().snapshotAsOf(token, conversationId: conversationId, key: key, at: at, context: context)
        }
    }
}
