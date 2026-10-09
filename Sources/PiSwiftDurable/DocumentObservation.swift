import PiSwiftChord

/// One document incarnation. A nil value marks retirement.
public typealias DocumentWatch<Value: Sendable> = CommittedWatch<Value?>
/// A retained document value that follows committed JSON operations.
public typealias DocumentState<Value: Sendable> = AttachedReplicatedState<Value?>

/// Acquire a watch without creating a document.
public protocol DocumentObserver: Sendable {
    /// Attaches a stream of committed document values, or nil when no document exists.
    func watchDoc<Value: Codable & Sendable>(_ token: SessionDocToken<Value>, context: ChordContext) async throws -> CommittedWatch<Value?>?
    /// Attaches a stream of committed document values, or nil when no document exists.
    func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: SessionDocFamilyToken<Value, Seed>, key: String, context: ChordContext) async throws -> CommittedWatch<Value?>?
    /// Attaches a stream of committed document values, or nil when no document exists.
    func watchDoc<Value: Codable & Sendable>(_ token: ConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> CommittedWatch<Value?>?
    /// Attaches a stream of committed document values, or nil when no document exists.
    func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: ConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> CommittedWatch<Value?>?
    /// Attaches a stream of committed document values, or nil when no document exists.
    func watchDoc<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID, context: ChordContext) async throws -> CommittedWatch<Value?>?
    /// Attaches a stream of committed document values, or nil when no document exists.
    func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, context: ChordContext) async throws -> CommittedWatch<Value?>?
    /// Attaches a stream of committed document values, or nil when no document exists.
    func watchDoc<Value: Codable & Sendable>(_ token: TaskDocToken<Value>, taskId: TaskID, context: ChordContext) async throws -> CommittedWatch<Value?>?
    /// Attaches a stream of committed document values, or nil when no document exists.
    func watchDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: TaskDocFamilyToken<Value, Seed>, taskId: TaskID, key: String, context: ChordContext) async throws -> CommittedWatch<Value?>?
}

extension Session: DocumentObserver {}
