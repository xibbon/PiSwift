import Foundation

/// Ordered JSON members. Ports chord object keys and `delta/tracker.ts` key order.
public struct JSONObject: Sendable, Equatable, ExpressibleByDictionaryLiteral, Sequence {
    private struct ScalarKey: Sendable, Hashable {
        let text: String
        // Equal UTF-8 bytes means equal Unicode scalars (JavaScript key identity),
        // unlike `String ==`, which uses canonical equivalence. Compare and hash the
        // contiguous bytes in one call each; a per-byte loop dominated object reads.
        static func == (lhs: Self, rhs: Self) -> Bool {
            var left = lhs.text, right = rhs.text
            return left.withUTF8 { a in
                right.withUTF8 { b in
                    a.count == b.count && (a.isEmpty || memcmp(a.baseAddress!, b.baseAddress!, a.count) == 0)
                }
            }
        }
        func hash(into hasher: inout Hasher) {
            var text = text
            text.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
        }
    }
    private var indexKeys: [(key: ScalarKey, index: UInt64)] = []
    private var otherKeys: [ScalarKey] = []
    private var members: [ScalarKey: JSONValue] = [:]

    /// Creates an empty object.
    public init() {}

    /// Creates members in pair order. A duplicate replaces its first value.
    public init(_ pairs: [(String, JSONValue)]) {
        for (key, value) in pairs { self[key] = value }
    }

    /// Creates members in literal order, then applies the JavaScript key rule.
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self.init(elements) }

    /// Gets or sets a member. Assign `nil` to remove it; use `.null` for JSON null.
    public subscript(key: String) -> JSONValue? {
        get { members[ScalarKey(text: key)] }
        set {
            let identity = ScalarKey(text: key)
            if let newValue {
                if members[identity] == nil {
                    if let index = Self.arrayIndex(key) {
                        var low = 0
                        var high = indexKeys.count
                        while low < high {
                            let middle = low + (high - low) / 2
                            if indexKeys[middle].index < index { low = middle + 1 }
                            else { high = middle }
                        }
                        indexKeys.insert((identity, index), at: low)
                    } else { otherKeys.append(identity) }
                }
                members[identity] = newValue
            } else { removeValue(forKey: key) }
        }
    }

    private var orderedKeys: [ScalarKey] { indexKeys.map(\.key) + otherKeys }

    /// Mutates a member without making an extra copy of its value.
    package mutating func withValue<R>(forKey key: String, _ body: (inout JSONValue) throws -> R) rethrows -> R? {
        let identity = ScalarKey(text: key)
        guard members[identity] != nil else { return nil }
        return try body(&members[identity]!)
    }

    private static func arrayIndex(_ text: String) -> UInt64? {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= 10 else { return nil }
        if bytes == [48] { return 0 }
        guard (49...57).contains(bytes[0]) else { return nil }
        var result: UInt64 = 0
        for byte in bytes {
            guard (48...57).contains(byte) else { return nil }
            result = result * 10 + UInt64(byte - 48)
        }
        return result < 4_294_967_295 ? result : nil
    }

    /// The keys in JavaScript property order.
    public var keys: [String] { orderedKeys.map(\.text) }
    /// The values in JavaScript property order.
    public var values: [JSONValue] { orderedKeys.compactMap { members[$0] } }
    /// The number of members.
    public var count: Int { members.count }
    /// Returns true when there are no members.
    public var isEmpty: Bool { members.isEmpty }
    /// Tests key identity by Unicode scalars.
    public func contains(_ key: String) -> Bool { members[ScalarKey(text: key)] != nil }
    /// Removes a member and returns its previous value.
    @discardableResult public mutating func removeValue(forKey key: String) -> JSONValue? {
        let identity = ScalarKey(text: key)
        guard let value = members.removeValue(forKey: identity) else { return nil }
        if Self.arrayIndex(key) != nil { indexKeys.removeAll { $0.key == identity } }
        else { otherKeys.removeAll { $0 == identity } }
        return value
    }
    /// Compares members without regard to key order.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.members == rhs.members }
    /// Iterates over members in JavaScript property order.
    public func makeIterator() -> IndexingIterator<[(key: String, value: JSONValue)]> {
        orderedKeys.compactMap { key in members[key].map { (key: key.text, value: $0) } }.makeIterator()
    }
    /// Writes compact JSON in JavaScript property order.
    public func jsonText() throws -> String { try JSONValue.object(self).jsonText() }
}
