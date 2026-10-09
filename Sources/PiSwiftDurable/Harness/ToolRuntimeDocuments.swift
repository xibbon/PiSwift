import PiSwiftChord

extension ToolExecutionApi {
    public func snapshot<Value: Codable & Sendable>(_ token: SessionDocToken<Value>, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().snapshot(token, context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: SessionDocFamilyToken<Value, Seed>, key: String, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().snapshot(token, key: key, context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable>(_ token: ConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().snapshot(token, conversationId: conversationId, context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: ConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().snapshot(token, conversationId: conversationId, key: key, context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().snapshot(token, conversationId: conversationId, context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().snapshot(token, conversationId: conversationId, key: key, context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable>(_ token: TaskDocToken<Value>, taskId: TaskID, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().snapshot(token, taskId: taskId, context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: TaskDocFamilyToken<Value, Seed>, taskId: TaskID, key: String, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().snapshot(token, taskId: taskId, key: key, context: context)
        }
    }
    public func watchDoc<Value: Codable & Sendable>(_ token: SessionDocToken<Value>, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().watchDoc(token, context: context)
        }
    }
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: SessionDocFamilyToken<Value, Seed>, key: String, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().watchDoc(token, key: key, context: context)
        }
    }
    public func watchDoc<Value: Codable & Sendable>(_ token: ConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().watchDoc(token, conversationId: conversationId, context: context)
        }
    }
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: ConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().watchDoc(token, conversationId: conversationId, key: key, context: context)
        }
    }
    public func watchDoc<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().watchDoc(token, conversationId: conversationId, context: context)
        }
    }
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().watchDoc(token, conversationId: conversationId, key: key, context: context)
        }
    }
    public func watchDoc<Value: Codable & Sendable>(_ token: TaskDocToken<Value>, taskId: TaskID, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().watchDoc(token, taskId: taskId, context: context)
        }
    }
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: TaskDocFamilyToken<Value, Seed>, taskId: TaskID, key: String, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().watchDoc(token, taskId: taskId, key: key, context: context)
        }
    }
    public func snapshotAsOf<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, at: EntryID, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().snapshotAsOf(token, conversationId: conversationId, at: at, context: context)
        }
    }
    public func snapshotAsOf<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, at: EntryID, context: ChordContext) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            return try await taskRuntime().snapshotAsOf(token, conversationId: conversationId, key: key, at: at, context: context)
        }
    }
}

/// Keeps direct reader operations within the task invocation's lifetime.
internal func toolBoundReader(_ reader: HarnessDocumentReader,
                              check: @escaping @Sendable () throws -> Void) -> HarnessDocumentReader {
    let snapshot: @Sendable (String, ConversationID?, ChordContext) async throws -> JSONObject? = { kind, id, context in
        try check()
        let value = try await reader.snapshot(kind, id, context)
        try check()
        return value
    }
    let historical: @Sendable (String, ConversationID, EntryID, ChordContext) async throws -> JSONObject? = { kind, id, at, context in
        try check()
        let value = try await reader.snapshotAsOf(kind, id, at, context)
        try check()
        return value
    }
    guard let typedRead = reader.typedRead, let typedHistoricalRead = reader.typedHistoricalRead else {
        return HarnessDocumentReader(snapshot: snapshot, snapshotAsOf: historical)
    }
    return HarnessDocumentReader(snapshot: snapshot, snapshotAsOf: historical,
        typedRead: { definition, address, context in
            try check()
            let value = try await typedRead(definition, address, context)
            try check()
            return value
        }, typedHistoricalRead: { definition, address, at, context in
            try check()
            let value = try await typedHistoricalRead(definition, address, at, context)
            try check()
            return value
        })
}
