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
        var pending: [(SchemaValue, SchemaValue)] = [(lhs, rhs)]
        while let (left, right) = pending.popLast() {
            switch (left, right) {
            case (.null, .null): break
            case let (.bool(a), .bool(b)) where a == b: break
            case let (.number(a), .number(b)) where a == b: break
            case let (.string(a), .string(b)) where a.utf16.elementsEqual(b.utf16): break
            case let (.array(a), .array(b)):
                guard a.count == b.count else { return false }
                for index in a.indices { pending.append((a[index], b[index])) }
            case let (.object(a), .object(b)):
                guard a.count == b.count else { return false }
                for (leftMember, rightMember) in zip(a, b) {
                    guard leftMember.key.utf16.elementsEqual(rightMember.key.utf16) else { return false }
                    pending.append((leftMember.value, rightMember.value))
                }
            default: return false
            }
        }
        return true
    }

    /// Converts Foundation JSON values. Dictionary member order is unspecified.
    public init(jsonObject: Any) throws {
        enum Step {
            case value(Any)
            case array(Int)
            case object([String])
        }
        var pending: [Step] = [.value(jsonObject)]
        var finished: [SchemaValue] = []
        while let step = pending.popLast() {
            switch step {
            case .value(let input):
                if input is NSNull { finished.append(.null); continue }
                if let value = input as? NSNumber {
                    finished.append(CFGetTypeID(value) == CFBooleanGetTypeID()
                                    ? .bool(value.boolValue) : .number(value.doubleValue))
                    continue
                }
                if let value = input as? String { finished.append(.string(value)); continue }
                if let values = input as? [Any] {
                    pending.append(.array(values.count))
                    for value in values.reversed() { pending.append(.value(value)) }
                    continue
                }
                if let values = input as? [String: Any] {
                    let keys = Array(values.keys)
                    pending.append(.object(keys))
                    for key in keys.reversed() {
                        if let value = values[key] { pending.append(.value(value)) }
                    }
                    continue
                }
                throw SchemaJSONError.unsupportedFoundationValue
            case .array(let count):
                let values = Array(finished.suffix(count))
                finished.removeLast(count)
                finished.append(.array(values))
            case .object(let keys):
                let values = Array(finished.suffix(keys.count))
                finished.removeLast(keys.count)
                var object = SchemaObject()
                for (key, value) in zip(keys, values) { object[key] = value }
                finished.append(.object(object))
            }
        }
        guard finished.count == 1, let value = finished.first else { throw SchemaJSONError.invalidJSON }
        self = value
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
    var pending: [(SchemaValue, SchemaValue)] = [(lhs, rhs)]
    while let (left, right) = pending.popLast() {
        switch (left, right) {
        case let (.array(a), .array(b)):
            guard a.count == b.count else { return false }
            for index in a.indices { pending.append((a[index], b[index])) }
        case let (.object(a), .object(b)):
            guard a.count == b.count else { return false }
            for member in a {
                guard let value = b[member.key] else { return false }
                pending.append((member.value, value))
            }
        case (.array, _), (.object, _): return false
        default:
            if left != right { return false }
        }
    }
    return true
}
