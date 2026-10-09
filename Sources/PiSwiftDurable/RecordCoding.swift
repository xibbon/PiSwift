import PiSwiftChord

// Decode through the Chord JSON tree to keep absent fields distinct from JSON null.
func recordObject(_ decoder: any Decoder) throws -> JSONObject {
    try JSONObject(from: decoder)
}
func recordRequired<T: Decodable>(_ object: JSONObject, _ key: String, as: T.Type = T.self) throws -> T {
    guard let value = object[key] else {
        throw DecodingError.keyNotFound(RecordKey(key), .init(codingPath: [], debugDescription: "Missing field \(key)"))
    }
    return try value.decode(T.self)
}
func recordOptional<T: Decodable>(_ object: JSONObject, _ key: String, as: T.Type = T.self) throws -> T? {
    guard let value = object[key] else { return nil }
    return try value.decode(T.self)
}
func recordExtensions(_ object: JSONObject, excluding keys: [String]) -> JSONObject {
    var result = object
    for key in keys { result[key] = nil }
    return result
}
func recordSet<T: Encodable>(_ object: inout JSONObject, _ key: String, _ value: T) throws {
    object[key] = try JSONValue(encoding: value)
}
func recordSetOptional<T: Encodable>(_ object: inout JSONObject, _ key: String, _ value: T?) throws {
    object[key] = try value.map { try JSONValue(encoding: $0) }
}
func recordUnknown(_ discriminator: String, _ value: String) -> DecodingError {
    .dataCorrupted(.init(codingPath: [], debugDescription: "Unknown \(discriminator): \(value)"))
}
func recordForbid(_ object: JSONObject, _ keys: [String]) throws {
    if let key = keys.first(where: { object.contains($0) }) {
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Field \(key) is not allowed in this record case"))
    }
}
private struct RecordKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}
