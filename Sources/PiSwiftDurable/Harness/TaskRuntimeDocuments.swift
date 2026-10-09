import Foundation
import PiSwiftChord

extension TaskRuntime {
    /// Reads a detached current document value, or nil when no incarnation exists.
    public func snapshot<Value: Codable & Sendable>(_ token: SessionDocToken<Value>, context: ChordContext) async throws -> Value? {
        try await runtimeSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .session()), context: context)
    }
    /// Reads a detached current document value, or nil when no incarnation exists.
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: SessionDocFamilyToken<Value, Seed>, key: String, context: ChordContext) async throws -> Value? {
        try await runtimeSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .session(), key: key), context: context)
    }
    /// Reads a detached current document value, or nil when no incarnation exists.
    public func snapshot<Value: Codable & Sendable>(_ token: ConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> Value? {
        try await runtimeSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId)), context: context)
    }
    /// Reads a detached current document value, or nil when no incarnation exists.
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: ConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> Value? {
        try await runtimeSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId), key: key), context: context)
    }
    /// Reads a detached current document value, or nil when no incarnation exists.
    public func snapshot<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> Value? {
        try await runtimeSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId)), context: context)
    }
    /// Reads a detached historical document value through the inclusive entry.
    public func snapshotAsOf<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, at: EntryID, context: ChordContext) async throws -> Value? {
        try await runtimeHistoricalSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId)), at: at, context: context)
    }
    /// Reads a detached current document value, or nil when no incarnation exists.
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> Value? {
        try await runtimeSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId), key: key), context: context)
    }
    /// Reads a detached historical document value through the inclusive entry.
    public func snapshotAsOf<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, at: EntryID, context: ChordContext) async throws -> Value? {
        try await runtimeHistoricalSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId), key: key), at: at, context: context)
    }
    /// Reads a detached current document value, or nil when no incarnation exists.
    public func snapshot<Value: Codable & Sendable>(_ token: TaskDocToken<Value>, taskId: TaskID, context: ChordContext) async throws -> Value? {
        try await runtimeSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .task(taskId: taskId)), context: context)
    }
    /// Reads a detached current document value, or nil when no incarnation exists.
    public func snapshot<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: TaskDocFamilyToken<Value, Seed>, taskId: TaskID, key: String, context: ChordContext) async throws -> Value? {
        try await runtimeSnapshot(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .task(taskId: taskId), key: key), context: context)
    }
    /// Attaches a stream of committed document values, or nil when no document exists.
    public func watchDoc<Value: Codable & Sendable>(_ token: SessionDocToken<Value>, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await runtimeWatch(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .session()), context: context)
    }
    /// Attaches a stream of committed document values, or nil when no document exists.
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: SessionDocFamilyToken<Value, Seed>, key: String, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await runtimeWatch(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .session(), key: key), context: context)
    }
    /// Attaches a stream of committed document values, or nil when no document exists.
    public func watchDoc<Value: Codable & Sendable>(_ token: ConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await runtimeWatch(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId)), context: context)
    }
    /// Attaches a stream of committed document values, or nil when no document exists.
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: ConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await runtimeWatch(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId), key: key), context: context)
    }
    /// Attaches a stream of committed document values, or nil when no document exists.
    public func watchDoc<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await runtimeWatch(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId)), context: context)
    }
    /// Attaches a stream of committed document values, or nil when no document exists.
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await runtimeWatch(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId), key: key), context: context)
    }
    /// Attaches a stream of committed document values, or nil when no document exists.
    public func watchDoc<Value: Codable & Sendable>(_ token: TaskDocToken<Value>, taskId: TaskID, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await runtimeWatch(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .task(taskId: taskId)), context: context)
    }
    /// Attaches a stream of committed document values, or nil when no document exists.
    public func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: TaskDocFamilyToken<Value, Seed>, taskId: TaskID, key: String, context: ChordContext) async throws -> CommittedWatch<Value?>? {
        try await runtimeWatch(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .task(taskId: taskId), key: key), context: context)
    }
}

extension TaskRuntime: DocumentObserver {}

extension TaskRuntime {
    private func runtimeSnapshot<Value: Codable & Sendable>(
        _ definition: DocumentDefinition, address: DocumentAddress, context: ChordContext
    ) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try invocation.check()
            return try await scheduler.session.currentSnapshot(definition, address: address, context: context)
        }
    }
    private func runtimeHistoricalSnapshot<Value: Codable & Sendable>(
        _ definition: DocumentDefinition, address: DocumentAddress, at: EntryID, context: ChordContext
    ) async throws -> Value? {
        try await withTaskCancellationContext(context) { context in
            try invocation.check()
            return try await scheduler.session.historicalSnapshot(definition, address: address, at: at, context: context)
        }
    }
    private func runtimeWatch<Value: Codable & Sendable>(
        _ definition: DocumentDefinition, address: DocumentAddress, context: ChordContext
    ) async throws -> CommittedWatch<Value?>? {
        try await withTaskCancellationContext(context) { context in
            try invocation.check()
            guard let watch: CommittedWatch<Value?> = try await scheduler.session.currentWatch(definition, address: address, context: context) else {
                return nil
            }
            let id = UUID()
            let active = invocation.state.withLock { state in
                guard !state.ended else { return false }
                state.watches[id] = { watch.stopForInvocation() }
                return true
            }
            guard active else {
                _ = await watch.stop()
                try invocation.check()
                throw SessionError.message("Task invocation has ended")
            }
            Task { [weak invocation, watch] in
                _ = await watch.closed
                _ = invocation?.state.withLock { $0.watches.removeValue(forKey: id) }
            }
            try context.abortSignal?.throwIfAborted()
            return watch
        }
    }
}
