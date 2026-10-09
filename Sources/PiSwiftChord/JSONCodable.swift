import Foundation

extension JSONValue: Codable {
    /// Decodes the natural JSON shape. Port of chord `JsonValue`, `packages/chord/src/types.ts`.
    /// A foreign decoder supplies keys in its `allKeys` order and can merge key names before this call.
    public init(from decoder: any Decoder) throws {
        if let decoder = decoder as? ValueDecoder {
            self = decoder.value
            return
        }
        if let container = try? decoder.singleValueContainer() {
            if container.decodeNil() { self = .null; return }
            if let value = try? container.decode(Bool.self) { self = .bool(value); return }
            if let value = try? container.decode(Double.self) {
                guard value.isFinite else { throw JSONValueError.nonFiniteNumber }
                self = .number(value)
                return
            }
            if let value = try? container.decode(String.self) { self = .string(value); return }
        }
        if var array = try? decoder.unkeyedContainer() {
            var values: [JSONValue] = []
            while !array.isAtEnd { values.append(try array.decode(JSONValue.self)) }
            self = .array(values)
        } else { self = .object(try JSONObject(from: decoder)) }
    }

    /// Encodes the natural JSON shape. Port of chord `copyJson`, `packages/chord/src/json.ts`.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .number(let value):
            guard value.isFinite else { throw JSONValueError.nonFiniteNumber }
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values { try container.encode(value) }
        case .object(let object): try object.encode(to: encoder)
        }
    }

    /// Builds an owned JSON tree without a data round trip. Port of chord `copyJson`, `packages/chord/src/json.ts`.
    public init<T: Encodable>(encoding value: T) throws {
        let node = EncodingNode()
        try ValueEncoder(node: node, codingPath: []).encode(value)
        self = try node.finish(codingPath: [])
    }

    /// Decodes a Swift value directly from this tree. Swift bridge for chord `copyJson`, `packages/chord/src/json.ts`.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try T(from: ValueDecoder(value: self, codingPath: []))
    }
}

extension JSONObject: Codable {
    /// Decodes an object. Port of chord `JsonValue`, `packages/chord/src/types.ts`.
    /// A foreign decoder supplies keys in its `allKeys` order and can merge key names before this call.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: JSONCodingKey.self)
        self.init()
        for key in container.allKeys { self[key.stringValue] = try container.decode(JSONValue.self, forKey: key) }
    }

    /// Encodes entries in JavaScript key order. Port of chord `copyJson`, `packages/chord/src/json.ts`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: JSONCodingKey.self)
        for (key, value) in self { try container.encode(value, forKey: JSONCodingKey(key)) }
    }
}

private struct JSONCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init(_ value: String) { stringValue = value; intValue = nil }
    init(index: Int) { stringValue = "Index \(index)"; intValue = index }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}

private final class EncodingNode {
    enum Storage {
        case empty
        case value(JSONValue)
        case object([(String, EncodingNode)])
        case array([EncodingNode])
    }
    var storage: Storage = .empty
    var error: (any Error)?

    func object(codingPath: [any CodingKey]) {
        if case .empty = storage { storage = .object([]) }
        if case .object = storage { return }
        conflict(codingPath: codingPath)
    }
    func array(codingPath: [any CodingKey]) {
        if case .empty = storage { storage = .array([]) }
        if case .array = storage { return }
        conflict(codingPath: codingPath)
    }
    func conflict(codingPath: [any CodingKey]) {
        error = EncodingError.invalidValue("container", .init(codingPath: codingPath, debugDescription: "Cannot encode different container types at the same path"))
    }
    func set(_ value: JSONValue, codingPath: [any CodingKey]) throws {
        if let error { throw error }
        guard case .empty = storage else {
            conflict(codingPath: codingPath)
            throw error!
        }
        storage = .value(value)
    }
    func child(key: String, codingPath: [any CodingKey], replace: Bool = false) -> EncodingNode {
        object(codingPath: codingPath)
        guard case .object(var pairs) = storage else { return EncodingNode() }
        if let index = pairs.firstIndex(where: { $0.0.utf8.elementsEqual(key.utf8) }) {
            if !replace { return pairs[index].1 }
            let node = EncodingNode()
            pairs[index].1 = node
            storage = .object(pairs)
            return node
        }
        let node = EncodingNode()
        pairs.append((key, node))
        storage = .object(pairs)
        return node
    }
    func append(codingPath: [any CodingKey]) -> EncodingNode {
        array(codingPath: codingPath)
        let node = EncodingNode()
        if case .array(var nodes) = storage { nodes.append(node); storage = .array(nodes) }
        return node
    }
    var count: Int { if case .array(let nodes) = storage { return nodes.count }; return 0 }
    func finish(codingPath: [any CodingKey]) throws -> JSONValue {
        if let error { throw error }
        switch storage {
        case .empty:
            throw EncodingError.invalidValue("empty value", .init(codingPath: codingPath, debugDescription: "Encodable did not encode a value"))
        case .value(let value): return value
        case .object(let pairs):
            return .object(JSONObject(try pairs.map { key, node in
                (key, try node.finish(codingPath: codingPath + [JSONCodingKey(key)]))
            }))
        case .array(let nodes):
            return .array(try nodes.enumerated().map { index, node in
                try node.finish(codingPath: codingPath + [JSONCodingKey(index: index)])
            })
        }
    }
}

private struct ValueEncoder: Encoder {
    let node: EncodingNode
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        node.object(codingPath: codingPath)
        return KeyedEncodingContainer(ValueKeyedEncoder<Key>(encoder: self))
    }
    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        node.array(codingPath: codingPath)
        return ValueUnkeyedEncoder(encoder: self)
    }
    func singleValueContainer() -> any SingleValueEncodingContainer { ValueSingleEncoder(encoder: self) }
    func encode<T: Encodable>(_ value: T) throws {
        if let value = value as? JSONValue {
            guard value.isStrictJSON else { throw JSONValueError.nonFiniteNumber }
            try node.set(value, codingPath: codingPath)
        } else if let value = value as? JSONObject {
            let json = JSONValue.object(value)
            guard json.isStrictJSON else { throw JSONValueError.nonFiniteNumber }
            try node.set(json, codingPath: codingPath)
        } else { try value.encode(to: self) }
    }
    func number(_ value: Double) throws {
        guard value.isFinite else { throw JSONValueError.nonFiniteNumber }
        try node.set(.number(value), codingPath: codingPath)
    }
    func integer<T: BinaryInteger>(_ value: T) throws {
        guard let number = Double(exactly: value) else { throw JSONValueError.unsafeInteger }
        try self.number(number)
    }
    func child(_ key: any CodingKey, replace: Bool = false) -> ValueEncoder {
        ValueEncoder(node: node.child(key: key.stringValue, codingPath: codingPath, replace: replace), codingPath: codingPath + [key])
    }
    func append() -> ValueEncoder {
        let key = JSONCodingKey(index: node.count)
        return ValueEncoder(node: node.append(codingPath: codingPath), codingPath: codingPath + [key])
    }
}

private struct ValueSingleEncoder: SingleValueEncodingContainer {
    let encoder: ValueEncoder
    var codingPath: [any CodingKey] { encoder.codingPath }
    mutating func encodeNil() throws { try encoder.node.set(.null, codingPath: codingPath) }
    mutating func encode(_ value: Bool) throws { try encoder.node.set(.bool(value), codingPath: codingPath) }
    mutating func encode(_ value: String) throws { try encoder.node.set(.string(value), codingPath: codingPath) }
    mutating func encode(_ value: Double) throws { try encoder.number(value) }
    mutating func encode(_ value: Float) throws { try encoder.number(Double(value)) }
    mutating func encode(_ value: Int) throws { try encoder.integer(value) }
    mutating func encode(_ value: Int8) throws { try encoder.integer(value) }
    mutating func encode(_ value: Int16) throws { try encoder.integer(value) }
    mutating func encode(_ value: Int32) throws { try encoder.integer(value) }
    mutating func encode(_ value: Int64) throws { try encoder.integer(value) }
    mutating func encode(_ value: Int128) throws { try encoder.integer(value) }
    mutating func encode(_ value: UInt) throws { try encoder.integer(value) }
    mutating func encode(_ value: UInt8) throws { try encoder.integer(value) }
    mutating func encode(_ value: UInt16) throws { try encoder.integer(value) }
    mutating func encode(_ value: UInt32) throws { try encoder.integer(value) }
    mutating func encode(_ value: UInt64) throws { try encoder.integer(value) }
    mutating func encode(_ value: UInt128) throws { try encoder.integer(value) }
    mutating func encode<T: Encodable>(_ value: T) throws { try encoder.encode(value) }
}

private struct ValueKeyedEncoder<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: ValueEncoder
    var codingPath: [any CodingKey] { encoder.codingPath }
    mutating func encode(_ value: Int128, forKey key: Key) throws { try encoder.child(key, replace: true).integer(value) }
    mutating func encode(_ value: UInt128, forKey key: Key) throws { try encoder.child(key, replace: true).integer(value) }
    mutating func encodeNil(forKey key: Key) throws { var container = encoder.child(key, replace: true).singleValueContainer(); try container.encodeNil() }
    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws { try encoder.child(key, replace: true).encode(value) }
    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        encoder.child(key).container(keyedBy: keyType)
    }
    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer { encoder.child(key).unkeyedContainer() }
    mutating func superEncoder() -> any Encoder { encoder.child(JSONCodingKey("super")) }
    mutating func superEncoder(forKey key: Key) -> any Encoder { encoder.child(key) }
}

private struct ValueUnkeyedEncoder: UnkeyedEncodingContainer {
    let encoder: ValueEncoder
    var codingPath: [any CodingKey] { encoder.codingPath }
    var count: Int { encoder.node.count }
    mutating func encode(_ value: Int128) throws { try encoder.append().integer(value) }
    mutating func encode(_ value: UInt128) throws { try encoder.append().integer(value) }
    mutating func encodeNil() throws { var container = encoder.append().singleValueContainer(); try container.encodeNil() }
    mutating func encode<T: Encodable>(_ value: T) throws { try encoder.append().encode(value) }
    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> { encoder.append().container(keyedBy: keyType) }
    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer { encoder.append().unkeyedContainer() }
    mutating func superEncoder() -> any Encoder { encoder.append() }
}

private struct ValueDecoder: Decoder {
    let value: JSONValue
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let object) = value else { throw mismatch(JSONObject.self) }
        return KeyedDecodingContainer(ValueKeyedDecoder<Key>(decoder: self, object: object))
    }
    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard case .array(let values) = value else { throw mismatch([JSONValue].self) }
        return ValueUnkeyedDecoder(decoder: self, values: values)
    }
    func singleValueContainer() throws -> any SingleValueDecodingContainer { ValueSingleDecoder(decoder: self) }
    func mismatch(_ type: Any.Type) -> DecodingError {
        let context = DecodingError.Context(codingPath: codingPath, debugDescription: "Expected \(type), found \(value)")
        if value.isNull { return .valueNotFound(type, context) }
        return .typeMismatch(type, context)
    }
    func corrupt(_ reason: String) -> DecodingError { .dataCorrupted(.init(codingPath: codingPath, debugDescription: reason)) }
    func child(_ value: JSONValue, key: any CodingKey) -> ValueDecoder { ValueDecoder(value: value, codingPath: codingPath + [key]) }
    func number<T>(_ type: T.Type) throws -> Double {
        guard case .number(let number) = value else { throw mismatch(type) }
        guard number.isFinite else { throw corrupt("Number is not finite") }
        return number
    }
    func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let number = try number(type)
        guard let integer = T(exactly: number) else { throw corrupt("Number is not an integer in the range of \(type)") }
        return integer
    }
}

private struct ValueSingleDecoder: SingleValueDecodingContainer {
    let decoder: ValueDecoder
    var codingPath: [any CodingKey] { decoder.codingPath }
    func decodeNil() -> Bool { decoder.value.isNull }
    func decode(_ type: Bool.Type) throws -> Bool {
        guard case .bool(let value) = decoder.value else { throw decoder.mismatch(type) }; return value
    }
    func decode(_ type: String.Type) throws -> String {
        guard case .string(let value) = decoder.value else { throw decoder.mismatch(type) }; return value
    }
    func decode(_ type: Double.Type) throws -> Double { try decoder.number(type) }
    func decode(_ type: Float.Type) throws -> Float {
        let value = Float(try decoder.number(type))
        guard value.isFinite else { throw decoder.corrupt("Number is outside the range of Float") }
        return value
    }
    func decode(_ type: Int.Type) throws -> Int { try decoder.integer(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try decoder.integer(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try decoder.integer(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try decoder.integer(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try decoder.integer(type) }
    func decode(_ type: Int128.Type) throws -> Int128 { try decoder.integer(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try decoder.integer(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try decoder.integer(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try decoder.integer(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try decoder.integer(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try decoder.integer(type) }
    func decode(_ type: UInt128.Type) throws -> UInt128 { try decoder.integer(type) }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try T(from: decoder) }
}

private struct ValueKeyedDecoder<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: ValueDecoder
    let object: JSONObject
    var codingPath: [any CodingKey] { decoder.codingPath }
    var allKeys: [Key] { object.keys.compactMap(Key.init(stringValue:)) }
    func contains(_ key: Key) -> Bool { object.contains(key.stringValue) }
    func child(_ key: Key) throws -> ValueDecoder {
        guard let value = object[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "No value for key \(key.stringValue)"))
        }
        return decoder.child(value, key: key)
    }
    func decodeNil(forKey key: Key) throws -> Bool { try child(key).value.isNull }
    func decode(_ type: Int128.Type, forKey key: Key) throws -> Int128 { try child(key).integer(type) }
    func decode(_ type: UInt128.Type, forKey key: Key) throws -> UInt128 { try child(key).integer(type) }
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T { try T(from: child(key)) }
    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> { try child(key).container(keyedBy: type) }
    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer { try child(key).unkeyedContainer() }
    func superDecoder() throws -> any Decoder {
        let key = JSONCodingKey("super")
        guard let value = object[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "No value for key \(key.stringValue)"))
        }
        return decoder.child(value, key: key)
    }
    func superDecoder(forKey key: Key) throws -> any Decoder { try child(key) }
}

private struct ValueUnkeyedDecoder: UnkeyedDecodingContainer {
    let decoder: ValueDecoder
    let values: [JSONValue]
    var currentIndex = 0
    var codingPath: [any CodingKey] { decoder.codingPath }
    var count: Int? { values.count }
    var isAtEnd: Bool { currentIndex >= values.count }
    func child(_ type: Any.Type) throws -> ValueDecoder {
        let key = JSONCodingKey(index: currentIndex)
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(type, .init(codingPath: codingPath + [key], debugDescription: "Unkeyed container is at end"))
        }
        return decoder.child(values[currentIndex], key: key)
    }
    mutating func decodeNil() throws -> Bool {
        let value = try child(JSONValue.self).value
        if value.isNull { currentIndex += 1; return true }
        return false
    }
    mutating func decode(_ type: Int128.Type) throws -> Int128 {
        let result = try child(type).integer(type)
        currentIndex += 1
        return result
    }
    mutating func decode(_ type: UInt128.Type) throws -> UInt128 {
        let result = try child(type).integer(type)
        currentIndex += 1
        return result
    }
    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let result = try T(from: child(type))
        currentIndex += 1
        return result
    }
    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        let result = try child(JSONObject.self).container(keyedBy: type)
        currentIndex += 1
        return result
    }
    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let result = try child([JSONValue].self).unkeyedContainer()
        currentIndex += 1
        return result
    }
    mutating func superDecoder() throws -> any Decoder {
        let result = try child(JSONValue.self)
        currentIndex += 1
        return result
    }
}
