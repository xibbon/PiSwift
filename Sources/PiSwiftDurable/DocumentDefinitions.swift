import PiSwiftChord
import Synchronization

/// The number of stored deltas before the change under consideration.
public struct CheckpointInfo: Sendable, Equatable {
    public let deltasSinceBase: Int
    public init(deltasSinceBase: Int) { self.deltasSinceBase = deltasSinceBase }
}

/// Errors at a document definition or access boundary.
public struct DocumentDefinitionError: Error, Sendable, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// The common definition used after a scope-specific token has resolved its address.
public struct DocumentDefinition: Sendable {
    public let kind: String
    public let version: Int
    public let semantics: DocumentSemantics
    public let family: Bool
    let initial: @Sendable (JSONValue?) throws -> JSONObject
    let migrate: (@Sendable (JSONObject, Int) throws -> JSONObject)?
    let checkpointWhen: (@Sendable (JSONObject, [Delta.Op], CheckpointInfo) throws -> Bool)?

    init<Value: Codable & Sendable>(kind: String, version: Int, semantics: DocumentSemantics, initial: @escaping @Sendable () throws -> Value, migrate: (@Sendable (JSONObject, Int) throws -> JSONObject)?, checkpointWhen: (@Sendable (JSONObject, [Delta.Op], CheckpointInfo) throws -> Bool)?) throws {
        try Self.validate(kind, version)
        self.kind = kind; self.version = version; self.semantics = semantics; family = false
        self.initial = { _ in try documentObject(initial()) }
        self.migrate = migrate; self.checkpointWhen = checkpointWhen
    }
    init<Value: Codable & Sendable, Seed: Codable & Sendable>(kind: String, version: Int, semantics: DocumentSemantics, initial: @escaping @Sendable (Seed) throws -> Value, migrate: (@Sendable (JSONObject, Int) throws -> JSONObject)?, checkpointWhen: (@Sendable (JSONObject, [Delta.Op], CheckpointInfo) throws -> Bool)?) throws {
        try Self.validate(kind, version)
        self.kind = kind; self.version = version; self.semantics = semantics; family = true
        self.initial = { seed in
            guard let seed else { throw DocumentDefinitionError("Document \(kind) requires a family seed") }
            return try documentObject(initial(seed.decode(Seed.self)))
        }
        self.migrate = migrate; self.checkpointWhen = checkpointWhen
    }
    private static func validate(_ kind: String, _ version: Int) throws {
        guard version > 0, version <= 9_007_199_254_740_991 else {
            throw DocumentDefinitionError("Document \(kind) version must be a positive integer")
        }
    }
    func check(_ record: DocumentRecord) throws { try check(scope: record.scope, id: record.id, kind: record.kind, history: record.history, fork: record.fork) }
    func check(scope: DocumentScope, id: DocumentID, kind: String, history: DocumentHistory?, fork: DocumentFork?) throws {
        let matches: Bool
        switch (semantics, scope) {
        case (.session, .session), (.task, .task): matches = true
        case (.conversation(let expectedHistory, let expectedFork, _), .conversation): matches = history == expectedHistory && fork == expectedFork
        default: matches = false
        }
        guard matches else { throw DocumentDefinitionError("Document \(id.rawValue) (\(kind)) does not match the supplied definition semantics") }
    }
    func checkVersion(_ version: Int, record: DocumentRecord) throws {
        if version > self.version { throw DocumentDefinitionError("Document \(record.id.rawValue) (\(record.kind)) has newer version \(version) than \(self.version)") }
        if version < self.version, migrate == nil { throw DocumentDefinitionError("Document \(record.id.rawValue) (\(record.kind)) requires migration from version \(version)") }
    }
    func materialize(_ stored: StoredDocument) throws -> JSONObject {
        try check(stored.record); try checkVersion(stored.version, record: stored.record)
        let value = stored.version == version ? stored.value : try migrate!(stored.value, stored.version)
        guard JSONValue.object(value).isStrictJSON else { throw JSONValueError.nonFiniteNumber }
        return value
    }
    func create(_ address: DocumentAddress, id: DocumentID) -> DocumentCreate {
        if case .conversation(let history, let fork, _) = semantics {
            return DocumentCreate(id: id, kind: kind, scope: address.scope, key: address.key, history: history, fork: fork)
        }
        return DocumentCreate(id: id, kind: kind, scope: address.scope, key: address.key)
    }
}

func documentObject<Value: Encodable>(_ value: Value) throws -> JSONObject {
    guard case .object(let result) = try JSONValue(encoding: value) else { throw DocumentDefinitionError("Document value must be a JSON object") }
    return result
}

func documentAddressID(_ address: DocumentAddress) -> String {
    let owner: JSONValue
    let scope: String
    switch address.scope {
    case .session: scope = "session"; owner = .null
    case .conversation(let id, _): scope = "conversation"; owner = .number(Double(id.rawValue))
    case .task(let id, _): scope = "task"; owner = .number(Double(id.rawValue))
    }
    return try! JSONValue.array([.string(address.kind), .string(scope), owner, address.key.map(JSONValue.string) ?? .null]).jsonText()
}

/// A session document singleton definition.
public struct SessionDocToken<Value: Codable & Sendable>: Sendable {
    public let definition: DocumentDefinition
    public init(kind: String, version: Int, initial: @escaping @Sendable () throws -> Value, migrate: (@Sendable (JSONObject, Int) throws -> JSONObject)? = nil, checkpointWhen: (@Sendable (JSONObject, [Delta.Op], CheckpointInfo) throws -> Bool)? = nil) throws {
        definition = try DocumentDefinition(kind: kind, version: version, semantics: .session(), initial: initial, migrate: migrate, checkpointWhen: checkpointWhen)
    }
}

/// A conversation document singleton definition.
public struct ConversationDocToken<Value: Codable & Sendable>: Sendable {
    public let definition: DocumentDefinition
    public init(kind: String, version: Int, fork: DocumentFork, initial: @escaping @Sendable () throws -> Value, migrate: (@Sendable (JSONObject, Int) throws -> JSONObject)? = nil, checkpointWhen: (@Sendable (JSONObject, [Delta.Op], CheckpointInfo) throws -> Bool)? = nil) throws {
        guard fork != .asOf else { throw DocumentDefinitionError("Latest conversation documents cannot use asOf forks") }
        definition = try DocumentDefinition(kind: kind, version: version, semantics: .conversation(history: .latest, fork: fork), initial: initial, migrate: migrate, checkpointWhen: checkpointWhen)
    }
}

/// A rewindable conversation document singleton definition.
public struct RewindableConversationDocToken<Value: Codable & Sendable>: Sendable {
    public let definition: DocumentDefinition
    public init(kind: String, version: Int, fork: DocumentFork, initial: @escaping @Sendable () throws -> Value, migrate: (@Sendable (JSONObject, Int) throws -> JSONObject)? = nil, checkpointWhen: (@Sendable (JSONObject, [Delta.Op], CheckpointInfo) throws -> Bool)? = nil) throws {
        definition = try DocumentDefinition(kind: kind, version: version, semantics: .conversation(history: .rewindable, fork: fork), initial: initial, migrate: migrate, checkpointWhen: checkpointWhen)
    }
}

/// A task document singleton definition.
public struct TaskDocToken<Value: Codable & Sendable>: Sendable {
    public let definition: DocumentDefinition
    public init(kind: String, version: Int, initial: @escaping @Sendable () throws -> Value, migrate: (@Sendable (JSONObject, Int) throws -> JSONObject)? = nil, checkpointWhen: (@Sendable (JSONObject, [Delta.Op], CheckpointInfo) throws -> Bool)? = nil) throws {
        definition = try DocumentDefinition(kind: kind, version: version, semantics: .task(), initial: initial, migrate: migrate, checkpointWhen: checkpointWhen)
    }
}

/// A session document family definition.
public struct SessionDocFamilyToken<Value: Codable & Sendable, Seed: Codable & Sendable>: Sendable {
    public let definition: DocumentDefinition
    public init(kind: String, version: Int, initial: @escaping @Sendable (Seed) throws -> Value, migrate: (@Sendable (JSONObject, Int) throws -> JSONObject)? = nil, checkpointWhen: (@Sendable (JSONObject, [Delta.Op], CheckpointInfo) throws -> Bool)? = nil) throws {
        definition = try DocumentDefinition(kind: kind, version: version, semantics: .session(), initial: initial, migrate: migrate, checkpointWhen: checkpointWhen)
    }
}

/// A conversation document family definition.
public struct ConversationDocFamilyToken<Value: Codable & Sendable, Seed: Codable & Sendable>: Sendable {
    public let definition: DocumentDefinition
    public init(kind: String, version: Int, fork: DocumentFork, initial: @escaping @Sendable (Seed) throws -> Value, migrate: (@Sendable (JSONObject, Int) throws -> JSONObject)? = nil, checkpointWhen: (@Sendable (JSONObject, [Delta.Op], CheckpointInfo) throws -> Bool)? = nil) throws {
        guard fork != .asOf else { throw DocumentDefinitionError("Latest conversation documents cannot use asOf forks") }
        definition = try DocumentDefinition(kind: kind, version: version, semantics: .conversation(history: .latest, fork: fork), initial: initial, migrate: migrate, checkpointWhen: checkpointWhen)
    }
}

/// A rewindable conversation document family definition.
public struct RewindableConversationDocFamilyToken<Value: Codable & Sendable, Seed: Codable & Sendable>: Sendable {
    public let definition: DocumentDefinition
    public init(kind: String, version: Int, fork: DocumentFork, initial: @escaping @Sendable (Seed) throws -> Value, migrate: (@Sendable (JSONObject, Int) throws -> JSONObject)? = nil, checkpointWhen: (@Sendable (JSONObject, [Delta.Op], CheckpointInfo) throws -> Bool)? = nil) throws {
        definition = try DocumentDefinition(kind: kind, version: version, semantics: .conversation(history: .rewindable, fork: fork), initial: initial, migrate: migrate, checkpointWhen: checkpointWhen)
    }
}

/// A task document family definition.
public struct TaskDocFamilyToken<Value: Codable & Sendable, Seed: Codable & Sendable>: Sendable {
    public let definition: DocumentDefinition
    public init(kind: String, version: Int, initial: @escaping @Sendable (Seed) throws -> Value, migrate: (@Sendable (JSONObject, Int) throws -> JSONObject)? = nil, checkpointWhen: (@Sendable (JSONObject, [Delta.Op], CheckpointInfo) throws -> Bool)? = nil) throws {
        definition = try DocumentDefinition(kind: kind, version: version, semantics: .task(), initial: initial, migrate: migrate, checkpointWhen: checkpointWhen)
    }
}
