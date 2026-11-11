import PiSwiftChord

// v1.5.2 CH3 durable/src/index.ts:1: expose the shared types without exporting unrelated chord names.
public typealias Watch<Value: Sendable> = PiSwiftChord.Watch<Value>
public typealias WatchHandle<Value: Sendable> = PiSwiftChord.WatchHandle<Value>
public typealias WatchCall<Value: Sendable> = PiSwiftChord.WatchCall<Value>
public typealias WatchEnd = PiSwiftChord.WatchEnd

/// A document address. Retirement is a tagged call and does not end the watch.
public typealias DocumentWatch<Value: Sendable> = Watch<Value>
/// A retained document value that follows committed JSON operations.
public typealias DocumentState<Value: Sendable> = AttachedReplicatedState<Value?>

/// Acquire a watch without creating a document.
public protocol DocumentObserver: Sendable {
    /// Attaches a stream of committed document values, or nil when no document exists.
    func watchDoc<Value: Codable & Sendable>(_ token: SessionDocToken<Value>, context: ChordContext) async throws -> Watch<Value>?
    /// Attaches a stream of committed document values, or nil when no document exists.
    func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: SessionDocFamilyToken<Value, Seed>, key: String, context: ChordContext) async throws -> Watch<Value>?
    /// Attaches a stream of committed document values, or nil when no document exists.
    func watchDoc<Value: Codable & Sendable>(_ token: ConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> Watch<Value>?
    /// Attaches a stream of committed document values, or nil when no document exists.
    func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: ConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> Watch<Value>?
    /// Attaches a stream of committed document values, or nil when no document exists.
    func watchDoc<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> Watch<Value>?
    /// Attaches a stream of committed document values, or nil when no document exists.
    func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> Watch<Value>?
    /// Attaches a stream of committed document values, or nil when no document exists.
    func watchDoc<Value: Codable & Sendable>(_ token: TaskDocToken<Value>, taskId: TaskID, context: ChordContext) async throws -> Watch<Value>?
    /// Attaches a stream of committed document values, or nil when no document exists.
    func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: TaskDocFamilyToken<Value, Seed>, taskId: TaskID, key: String, context: ChordContext) async throws -> Watch<Value>?
}

extension Session: DocumentObserver {}
