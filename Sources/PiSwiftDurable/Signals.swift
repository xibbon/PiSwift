import Foundation
import PiSwiftAI
import PiSwiftChord

/// The outcome of one signal delivery.
public enum SignalResult: String, Sendable, Codable {
    case delivered, duplicate, invalid, closed, not_found
}

/// The committed state of a signal key.
public enum SignalState<Value: Sendable>: Sendable {
    case value(Value)
    case expired
}

/// A typed signal and its JSON schema.
public struct SignalToken<Value: Codable & Sendable>: Sendable {
    public let name: String
    public let version: Int
    internal let schema: JSONValue
    internal let migrate: (@Sendable (JSONValue, Int) throws -> Value)?

    /// Creates a key for one wait.
    public func key(_ key: String) throws -> SignalKey {
        if key.isEmpty { throw SessionError.message("Signal \(name) key must be non-empty") }
        return SignalKey(signal: name, key: key)
    }
}

/// Built-in settlement signal. Its value is the durable settled submission record.
public let SubmissionSettled: SignalToken<SettledSubmissionRecord> = {
    func variant(_ type: String, _ status: String, _ fields: [String: JSONValue], _ required: [String]) -> JSONValue {
        var properties: JSONObject = [
            "id": ["type": "integer"], "conversationId": ["type": "integer"],
            "type": ["const": .string(type)], "status": ["const": .string(status)],
            "requestId": ["type": "string"],
            "notify": ["type": "object", "properties": ["taskId": ["type": "integer"], "key": ["type": "string"]],
                       "required": ["taskId", "key"]]
        ]
        for (name, value) in fields { properties[name] = value }
        return ["type": "object", "properties": .object(properties),
                "required": .array((["id", "conversationId", "type", "status"] + required).map(JSONValue.string))]
    }
    let integer: JSONValue = ["type": "integer"]
    let string: JSONValue = ["type": "string"]
    let branches: [JSONValue] = [
        variant("input", "done", ["entry": integer, "answer": integer], ["entry", "answer"]),
        variant("write", "done", ["entry": integer], ["entry"]),
        variant("continue", "done", ["answer": integer], ["answer"]),
        variant("input", "unanswered", ["entry": integer, "reason": string], ["reason"]),
        variant("write", "unanswered", ["reason": string], ["reason"]),
        variant("continue", "unanswered", ["reason": string], ["reason"])
    ]
    return try! defineSignal(name: "pi.submission-settled", version: 1, schema: ["anyOf": .array(branches)])
}()

/// Defines a signal kind with a positive version and a JSON-only schema.
public func defineSignal<Value: Codable & Sendable>(
    name: String, version: Int, schema: JSONValue,
    migrate: (@Sendable (JSONValue, Int) throws -> Value)? = nil
) throws -> SignalToken<Value> {
    if name.isEmpty || name.contains("/") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let quoted = String(data: try encoder.encode(name), encoding: .utf8) ?? "\"\(name)\""
        throw SessionError.message("Signal name \(quoted) must be non-empty, without \"/\"")
    }
    if version < 1 { throw SessionError.message("Signal \(name) version must be a positive integer") }
    if let nonJSON = signalNonJSONType(schema) {
        throw SessionError.message("Signal \(name) schema admits non-JSON values (\(nonJSON))")
    }
    let schemaText = try signalJSONText(schema)
    _ = try validateStructuredToolOutput(schemaJSON: schemaText, valueJSON: "null")
    return SignalToken(name: name, version: version, schema: schema, migrate: migrate)
}

private let signalSchemaChildren = [
    "items", "prefixItems", "additionalItems", "unevaluatedItems", "contains", "anyOf", "oneOf", "allOf",
    "not", "if", "then", "else", "additionalProperties", "unevaluatedProperties", "propertyNames"
]
private let signalSchemaMaps = [
    "properties", "patternProperties", "dependentSchemas", "dependencies", "$defs", "definitions"
]

private func signalNonJSONType(_ schema: JSONValue) -> String? {
    guard case .object(let object) = schema else { return nil }
    if let type = object["type"] {
        let names = type.arrayValue ?? [type]
        for name in names.compactMap(\.stringValue) where ["bytes", "bigint", "undefined"].contains(name) { return name }
    }
    for keyword in signalSchemaChildren {
        guard let child = object[keyword] else { continue }
        for node in child.arrayValue ?? [child] { if let found = signalNonJSONType(node) { return found } }
    }
    for keyword in signalSchemaMaps {
        guard let children = object[keyword]?.objectValue else { continue }
        for child in children.values { if let found = signalNonJSONType(child) { return found } }
    }
    return nil
}

private func signalJSONText(_ value: JSONValue) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let text = String(data: data, encoding: .utf8) else { throw SessionError.message("Invalid JSON text") }
    return text
}

internal func signalMemoName(_ signal: String, _ key: String) -> String { "pi.signal.\(signal)/\(key)" }

internal func signalStored(_ memos: JSONObject?, _ signal: String, _ key: String) -> JSONObject? {
    memos?[signalMemoName(signal, key)]?.objectValue
}

/// Reads a value, an expiry marker, or absence from committed task memos.
public func readSignal<Value: Codable & Sendable>(
    _ token: SignalToken<Value>, key: String, memos: JSONObject?
) throws -> SignalState<Value>? {
    guard let stored = signalStored(memos, token.name, key) else { return nil }
    if stored["expired"]?.boolValue == true { return .expired }
    guard let version = stored["version"]?.numberValue, let value = stored["value"] else { return nil }
    if version == Double(token.version) { return .value(try value.decode(Value.self)) }
    if version > Double(token.version) {
        throw SessionError.message("Signal \(token.name) value has version \(Int(version)), newer than \(token.version)")
    }
    guard let migrate = token.migrate else {
        throw SessionError.message("Signal \(token.name) has no migration from version \(Int(version))")
    }
    let migrated = try migrate(value, Int(version))
    let json = try JSONValue(encoding: migrated)
    if try validateStructuredToolOutput(schemaJSON: signalJSONText(token.schema), valueJSON: signalJSONText(json)) != nil {
        throw SessionError.message("Signal \(token.name) migration from version \(Int(version)) returned an invalid value")
    }
    return .value(migrated)
}

internal func deliverSignal<Value: Codable & Sendable>(
    record: TaskRecord?, token: SignalToken<Value>, key: String, value: Value, now: Double
) throws -> (SignalResult, TaskRecord?) {
    guard let record else { return (.not_found, nil) }
    if record.state.status == "terminal" || record.state.status == "completing" || record.abortRequested {
        return (.closed, nil)
    }
    let json: JSONValue
    do { json = try JSONValue(encoding: value) }
    catch { return (.invalid, nil) }
    guard !key.isEmpty,
          try validateStructuredToolOutput(schemaJSON: signalJSONText(token.schema), valueJSON: signalJSONText(json)) == nil
    else { return (.invalid, nil) }
    let name = signalMemoName(token.name, key)
    if let stored = record.memos?[name]?.objectValue {
        return (stored["expired"]?.boolValue == true ? .closed : .duplicate, nil)
    }
    if case .sleeping(_, let until?, _) = record.state, until <= now,
       try record.state.sleepSignals()?.contains(where: { $0.signal == token.name && $0.key == key }) == true {
        return (.closed, signalWithMemos(record, [name: .object(["expired": .bool(true)])]))
    }
    return (.delivered, signalWithMemos(record, [name: .object([
        "version": .number(Double(token.version)), "value": json
    ])]))
}

internal func signalWithMemos(_ record: TaskRecord, _ added: JSONObject) -> TaskRecord {
    var memos = record.memos ?? [:]
    for (name, value) in added { memos[name] = value }
    return record.replacing(memos: memos)
}

internal func checkSleep(_ state: TaskState, memos: JSONObject?, task: TaskID) throws {
    guard case .sleeping(_, let until, _) = state else { return }
    let keys = try state.sleepSignals() ?? []
    if until == nil && keys.isEmpty {
        throw SessionError.message("Task \(task.rawValue) cannot sleep without until or signals")
    }
    for key in keys {
        guard let stored = signalStored(memos, key.signal, key.key) else { continue }
        if stored["expired"]?.boolValue == true {
            throw SessionError.message("Task \(task.rawValue) cannot sleep on signal \(key.signal) key \(key.key): it expired")
        }
        if stored["consumed"]?.boolValue == true {
            throw SessionError.message("Task \(task.rawValue) cannot sleep on signal \(key.signal) key \(key.key): it already woke a wait")
        }
    }
}

internal func sleepDue(_ state: TaskState, memos: JSONObject?, now: Double) -> Bool {
    guard case .sleeping(_, let until, _) = state else { return false }
    if (try? readySignalKey(state, memos)) != nil { return true }
    return until.map { $0 <= now } ?? false
}

internal func sleepWake(_ state: TaskState, memos: JSONObject?, now: Double) throws -> (WakeReason, JSONObject)? {
    guard case .sleeping(_, let until, _) = state else { return nil }
    if let key = try readySignalKey(state, memos) {
        let name = signalMemoName(key.signal, key.key)
        var stored = signalStored(memos, key.signal, key.key) ?? [:]
        stored["consumed"] = .bool(true)
        return (.signal(signal: key.signal, key: key.key), [name: .object(stored)])
    }
    guard let until, until <= now else { return nil }
    let keys = try state.sleepSignals() ?? []
    if keys.isEmpty { return (.time(), [:]) }
    var expired: JSONObject = [:]
    for key in keys where signalStored(memos, key.signal, key.key) == nil {
        expired[signalMemoName(key.signal, key.key)] = .object(["expired": .bool(true)])
    }
    return (.expired(), expired)
}

private func readySignalKey(_ state: TaskState, _ memos: JSONObject?) throws -> SignalKey? {
    for key in try state.sleepSignals() ?? [] {
        guard let stored = signalStored(memos, key.signal, key.key) else { continue }
        if stored["expired"]?.boolValue != true && stored["consumed"]?.boolValue != true { return key }
    }
    return nil
}
