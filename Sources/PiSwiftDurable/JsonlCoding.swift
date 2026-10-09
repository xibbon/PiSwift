import PiSwiftChord

/// Options for JSONL storage.
public struct JsonlStorageOptions: Sendable {
    /// Flush each sidecar before the main marker. The default is false.
    public var fsync: Bool
    public init(fsync: Bool = false) { self.fsync = fsync }
}

/// A complete record or committed state is invalid.
public struct JsonlCorruptionError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public let cause: (any Error)?
    public var description: String { message }
    public init(message: String, cause: (any Error)? = nil) { self.message = message; self.cause = cause }
}

/// An I/O failure has an uncertain result. Open the storage again before use.
public struct JsonlStoragePoisonedError: Error, Sendable, CustomStringConvertible {
    public let message = "JSONL storage is poisoned and must be reopened"
    public let cause: any Error
    public var description: String { message }
    public init(cause: any Error) { self.cause = cause }
}

/// A file-system operation failed.
public struct JsonlFileError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public let cause: FileError
    public var description: String { message }
    public init(action: String, cause: FileError) {
        self.message = "JSONL \(action) failed: \(cause.message)"; self.cause = cause
    }
}

struct JsonlMarker: Sendable {
    let seq: Seq
    let writes: [JSONObject]
}
struct JsonlRecord: Sendable {
    let object: JSONObject
    let seq: Seq
    let ordinal: Int64
    let payload: JSONObject
}
struct JsonlLine<Value: Sendable>: Sendable {
    let value: Value
    let start: Int64
}
struct JsonlParsedFile<Value: Sendable>: Sendable {
    let path: String
    let lines: [JsonlLine<Value>]
}
struct JsonlRecordKey: Hashable, Sendable {
    let file: String
    let seq: Seq
    let ordinal: Int64
}
struct JsonlEncoded: Sendable {
    let marker: String
    // Preserve the first-write order of the upstream Map.
    let sidecars: [(file: String, content: String)]
    func content(for file: String) -> String? { sidecars.first { $0.file == file }?.content }
}

func jsonlCorruption(_ text: String) -> JsonlCorruptionError { .init(message: text) }
func jsonlFileResult<T>(_ result: Result<T, FileError>, action: String) throws -> T {
    switch result {
    case .success(let value): return value
    case .failure(let error): throw JsonlFileError(action: action, cause: error)
    }
}
func jsonlInteger(_ value: JSONValue?) -> Int64? {
    guard let integer = value?.int64Value, integer >= -Seq.maximumRawValue, integer <= Seq.maximumRawValue else { return nil }
    return integer
}
func jsonlNumber(_ value: Int64) -> JSONValue { .number(Double(value)) }
func jsonlFile(_ kind: String, _ id: Int64) -> String { "\(kind)-\(id).jsonl" }
func jsonlCurrentOnly(_ record: DocumentCreate) -> Bool {
    if case .conversation = record.scope { return record.history == .latest }
    return true
}
func jsonlObject(_ text: String, description: String) throws -> JSONObject? {
    do { return try JSONValue(jsonText: text).objectValue }
    catch { throw JsonlCorruptionError(message: "Malformed complete \(description)", cause: error) }
}
func jsonlParseMain(_ text: String, line: Int) throws -> JsonlMarker {
    let description = "main.jsonl line \(line)"
    guard let object = try jsonlObject(text, description: description), object["format"] == .number(1),
          object["type"] == .string("commit"), let seq = jsonlInteger(object["seq"]), seq >= 1,
          let writes = object["writes"]?.arrayValue else {
        throw jsonlCorruption("Invalid commit marker in \(description)")
    }
    let operations = try writes.map { value -> JSONObject in
        guard let write = value.objectValue, let type = write["type"]?.stringValue else {
            throw jsonlCorruption("Invalid write in \(description)")
        }
        switch type {
        case "conversation", "entry", "submission":
            guard let record = write["value"]?.objectValue, jsonlInteger(record["id"]) != nil else {
                throw jsonlCorruption("Invalid \(type) write in \(description)")
            }
        case "task":
            guard let record = write["value"]?.objectValue, jsonlInteger(record["id"]) != nil,
                  record["state"]?.objectValue?["status"] == .string("terminal") else {
                throw jsonlCorruption("Invalid terminal task write in \(description)")
            }
        case "document.retire":
            guard jsonlInteger(write["id"]) != nil else { throw jsonlCorruption("Invalid document retirement in \(description)") }
        case "task.sidecar", "document.change":
            guard jsonlInteger(write["id"]) != nil, let ordinal = jsonlInteger(write["ordinal"]), ordinal >= 0 else {
                throw jsonlCorruption("Invalid \(type == "task.sidecar" ? "task sidecar write" : "document change") in \(description)")
            }
        case "document.create":
            guard let record = write["record"]?.objectValue, jsonlInteger(record["id"]) != nil,
                  let ordinal = jsonlInteger(write["ordinal"]), ordinal >= 0 else {
                throw jsonlCorruption("Invalid document creation in \(description)")
            }
        default: throw jsonlCorruption("Unknown write type in \(description)")
        }
        return write
    }
    return JsonlMarker(seq: try Seq(seq), writes: operations)
}
func jsonlParseSidecar(_ text: String, file: String, line: Int) throws -> JsonlRecord {
    let description = "\(file) line \(line)"
    guard let object = try jsonlObject(text, description: description), object["format"] == .number(1),
          object["type"] == .string("record"), let seq = jsonlInteger(object["seq"]), seq >= 1,
          let ordinal = jsonlInteger(object["ordinal"]), ordinal >= 0,
          let payload = object["payload"]?.objectValue, let type = payload["type"]?.stringValue else {
        throw jsonlCorruption("Invalid sidecar record in \(description)")
    }
    switch type {
    case "task":
        guard let task = payload["value"]?.objectValue, jsonlInteger(task["id"]) != nil,
              let state = task["state"]?.objectValue, state["status"] != .string("terminal") else {
            throw jsonlCorruption("Invalid live task record in \(description)")
        }
    case "document":
        guard jsonlInteger(payload["id"]) != nil else { throw jsonlCorruption("Invalid document record in \(description)") }
        guard let content = payload["content"]?.objectValue,
              let version = jsonlInteger(content["version"]), version >= 1,
              (content["kind"] == .string("base") && content["value"]?.objectValue != nil) ||
              (content["kind"] == .string("delta") && content["ops"]?.arrayValue != nil) else {
            throw jsonlCorruption("Invalid document content in \(description)")
        }
    default: throw jsonlCorruption("Unknown sidecar record type in \(description)")
    }
    return JsonlRecord(object: object, seq: try Seq(seq), ordinal: ordinal, payload: payload)
}

func jsonlSidecarName(_ name: String, reclaim: Bool = false) -> Bool {
    let suffix = reclaim ? ".jsonl.reclaim" : ".jsonl"
    guard (name.hasPrefix("doc-") || name.hasPrefix("task-")), name.hasSuffix(suffix) else { return false }
    let start = name.firstIndex(of: "-")!
    let digits = name[name.index(after: start)..<name.index(name.endIndex, offsetBy: -suffix.count)]
    return !digits.isEmpty && digits.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } && (digits.count == 1 || digits.first != "0")
}
