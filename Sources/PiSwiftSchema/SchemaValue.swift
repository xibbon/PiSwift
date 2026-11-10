// JSON value support for packages/schema/src/compiler.ts at pi-mono v1.5.2.
import CoreFoundation
import Foundation

/// A JSON-compatible value. Object members retain their insertion order.
public indirect enum SchemaValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([SchemaValue])
    case object(SchemaObject)

    public static func == (lhs: SchemaValue, rhs: SchemaValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.string(a), .string(b)): return a.utf16.elementsEqual(b.utf16)
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)): return a == b
        default: return false
        }
    }

    /// Converts Foundation JSON values. Dictionary member order is unspecified.
    public init(jsonObject: Any) throws {
        if jsonObject is NSNull { self = .null; return }
        if let value = jsonObject as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
            return
        }
        if let value = jsonObject as? String { self = .string(value); return }
        if let value = jsonObject as? [Any] {
            self = .array(try value.map { try SchemaValue(jsonObject: $0) }); return
        }
        if let value = jsonObject as? [String: Any] {
            var object = SchemaObject()
            for (key, item) in value { object[key] = try SchemaValue(jsonObject: item) }
            self = .object(object); return
        }
        throw SchemaJSONError.unsupportedFoundationValue
    }
}

/// A JSON object in JavaScript property order, with UTF-16 key identity.
public struct SchemaObject: Sendable, Equatable, Sequence, ExpressibleByDictionaryLiteral {
    public typealias Element = (key: String, value: SchemaValue)
    private struct MemberKey: Hashable, Sendable {
        let units: [UInt16]
        init(_ string: String) { units = Array(string.utf16) }
    }
    private var members: [Element] = []
    private var indices: [MemberKey: Int] = [:]

    public init() {}
    public init(_ members: [Element]) {
        self.init()
        for (key, value) in members { self[key] = value }
    }
    public init(dictionaryLiteral elements: (String, SchemaValue)...) {
        self.init(elements.map { (key: $0.0, value: $0.1) })
    }
    public var keys: [String] { members.map(\.key) }
    public var count: Int { members.count }
    public var isEmpty: Bool { members.isEmpty }

    // JavaScript lists canonical array-index keys first. 2^32 - 1 is not an index.
    private static func arrayIndex(_ key: String) -> UInt32? {
        guard !key.isEmpty,
              key.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              (key == "0" || key.utf8.first != 48),
              let value = UInt32(key), value < UInt32.max else { return nil }
        return value
    }

    public subscript(key: String) -> SchemaValue? {
        get { indices[MemberKey(key)].map { members[$0].value } }
        set {
            let lookup = MemberKey(key)
            if let index = indices[lookup] {
                if let newValue { members[index].value = newValue }
                else {
                    members.remove(at: index)
                    indices.removeValue(forKey: lookup)
                    for i in index..<members.count { indices[MemberKey(members[i].key)] = i }
                }
            } else if let newValue {
                let position: Int
                if let newIndex = Self.arrayIndex(key) {
                    position = members.firstIndex { member in
                        guard let oldIndex = Self.arrayIndex(member.key) else { return true }
                        return oldIndex > newIndex
                    } ?? members.count
                } else {
                    position = members.count
                }
                members.insert((key, newValue), at: position)
                for i in position..<members.count { indices[MemberKey(members[i].key)] = i }
            }
        }
    }
    public func makeIterator() -> IndexingIterator<[Element]> { members.makeIterator() }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs.members, rhs.members).allSatisfy {
            $0.key.utf16.elementsEqual($1.key.utf16) && $0.value == $1.value
        }
    }
}

/// Compares JSON values without regard to object member order.
public func schemaEqual(_ lhs: SchemaValue, _ rhs: SchemaValue) -> Bool {
    switch (lhs, rhs) {
    case let (.array(a), .array(b)):
        return a.count == b.count && zip(a, b).allSatisfy { schemaEqual($0, $1) }
    case let (.object(a), .object(b)):
        guard a.count == b.count else { return false }
        return a.allSatisfy { member in
            guard let value = b[member.key] else { return false }
            return schemaEqual(member.value, value)
        }
    default:
        return lhs == rhs
    }
}
