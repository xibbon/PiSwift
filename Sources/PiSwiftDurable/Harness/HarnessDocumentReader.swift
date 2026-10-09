import PiSwiftChord

extension HarnessDocumentReader {
    public func snapshot<Value: Codable & Sendable>(_ token: SessionDocToken<Value>, context: PiSwiftChord.Context) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try await readerSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .session()), context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: SessionDocFamilyToken<Value, Seed>, key: String, context: PiSwiftChord.Context) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try await readerSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .session(), key: key), context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable>(_ token: ConversationDocToken<Value>, conversationId: ConversationID, context: PiSwiftChord.Context) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try await readerSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId)), context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: ConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: PiSwiftChord.Context) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try await readerSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId), key: key), context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, context: PiSwiftChord.Context) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try await readerSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId)), context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: PiSwiftChord.Context) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try await readerSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId), key: key), context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable>(_ token: TaskDocToken<Value>, taskId: TaskID, context: PiSwiftChord.Context) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try await readerSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .task(taskId: taskId)), context: context)
        }
    }
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: TaskDocFamilyToken<Value, Seed>, taskId: TaskID, key: String, context: PiSwiftChord.Context) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try await readerSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .task(taskId: taskId), key: key), context: context)
        }
    }
    public func snapshotAsOf<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, at: EntryID, context: PiSwiftChord.Context) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            return try await readerHistorical(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId)), at: at, context: context)
        }
    }
    public func snapshotAsOf<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, at: EntryID, context: PiSwiftChord.Context) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            return try await readerHistorical(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId), key: key), at: at, context: context)
        }
    }

    private func readerSnapshot<Value: Codable & Sendable>(_ definition: DocumentDefinition, address: DocumentAddress, context: PiSwiftChord.Context) async throws -> Value? {
        try context.abortSignal?.throwIfAborted()
        let object: JSONObject?
        if let typedRead { object = try await typedRead(definition, address, context) }
        else {
            let id: ConversationID?
            switch address.scope {
            case .session: id = nil
            case .conversation(let conversationId, _): id = conversationId
            case .task: throw DocumentDefinitionError("This document reader has no task scope adapter")
            }
            if address.key != nil { throw DocumentDefinitionError("This document reader has no family adapter") }
            object = try await snapshot(definition.kind, id, context)
        }
        return try object.map { try JSONValue.object($0).decode(Value.self) }
    }
    private func readerHistorical<Value: Codable & Sendable>(_ definition: DocumentDefinition, address: DocumentAddress, at: EntryID, context: PiSwiftChord.Context) async throws -> Value? {
        try context.abortSignal?.throwIfAborted()
        let object: JSONObject?
        if let typedHistoricalRead { object = try await typedHistoricalRead(definition, address, at, context) }
        else {
            guard case .conversation(let id, _) = address.scope, address.key == nil else { throw DocumentDefinitionError("This document reader has no historical family adapter") }
            object = try await snapshotAsOf(definition.kind, id, at, context)
        }
        return try object.map { try JSONValue.object($0).decode(Value.self) }
    }
}
